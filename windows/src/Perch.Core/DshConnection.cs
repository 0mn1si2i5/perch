using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Perch.Windows;

/// The token URL and cookie are stored only by DshState's current-user encryption.
public sealed record DshAuthorization(string Url, string Cookie);

public sealed class DshConnection : IDisposable
{
    private readonly HttpClient http;
    private readonly Uri origin;
    private string cookie;
    public DshAuthorization Authorization { get; private set; }

    public DshConnection(DshAuthorization authorization, HttpMessageHandler? handler = null)
    {
        Authorization = authorization;
        var url = ValidateUrl(authorization.Url);
        origin = new Uri(url.GetLeftPart(UriPartial.Authority) + "/");
        cookie = authorization.Cookie;
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseProxy = false }) { Timeout = TimeSpan.FromSeconds(10) };
    }

    public static Uri ValidateUrl(string value)
    {
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "http" || uri.UserInfo.Length > 0 || uri.AbsolutePath != "/" || uri.Fragment.Length > 0
            || !(uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || IPAddress.TryParse(uri.Host.Trim('[', ']'), out var ip) && IPAddress.IsLoopback(ip)))
            throw new IOException("请粘贴 dsh 启动时输出的本机 http:// 回环授权 URL。");
        var fields = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 1 || !fields[0].StartsWith("token=", StringComparison.Ordinal) || fields[0].Length <= 6 || value.Length > 8192)
            throw new IOException("授权 URL 缺少有效 token，请从 dsh 启动输出重新复制。");
        return uri;
    }

    public async Task Authenticate(CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Authorization.Url);
        using var response = await http.SendAsync(request, cancel);
        if (response.StatusCode is not (HttpStatusCode.SeeOther or HttpStatusCode.OK))
            throw new IOException("dsh 授权已失效，请重新连接并粘贴当前启动的授权 URL。");
        if (response.Headers.TryGetValues("Set-Cookie", out var values))
        {
            var jar = new CookieContainer();
            foreach (var value in values)
                jar.SetCookies(origin, value);
            cookie = jar.GetCookieHeader(origin);
        }
        if (cookie.Length == 0)
            throw new IOException("dsh 未返回认证 cookie，请使用启动输出中的完整授权 URL。");
        Authorization = Authorization with { Cookie = cookie };
    }

    public async Task<JsonElement> Rpc(string method, object args, CancellationToken cancel = default)
    {
        if (cookie.Length == 0)
            await Authenticate(cancel);
        var id = Guid.NewGuid().ToString();
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(origin, "api/" + method));
        request.Headers.Add("Cookie", cookie);
        request.Content = new StringContent(JsonSerializer.Serialize(new { type = "client-request", rpcId = id, method, payload = new { args } }), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, cancel);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new IOException("dsh 连接授权已失效，请重新连接。");
        if (!response.IsSuccessStatusCode)
            throw new IOException($"dsh 接口 {method} 返回 HTTP {(int)response.StatusCode}；请检查版本与连接。");
        try
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancel));
            var root = doc.RootElement;
            if (root.Text("type") != "server-response" || root.Text("rpcId") != id)
                throw new IOException("dsh RPC 响应不兼容，请检查 dsh 版本。");
            var result = root.At("result");
            if (result.At("ok").ValueKind != JsonValueKind.True)
                throw new IOException($"dsh 接口 {method} 不可用，请检查 dsh 版本与 profile 配置。");
            if (result.At("value").ValueKind == JsonValueKind.Undefined)
                throw new IOException($"dsh 接口 {method} 未返回结果，请检查版本兼容性。");
            return result.At("value").Clone();
        }
        catch (JsonException e) { throw new IOException("dsh 返回了无法识别的数据，请检查 dsh 版本。", e); }
    }

    private readonly ConcurrentDictionary<string, (long Seq, string Status)> outcomes = new();

    public async Task<List<Session>> Sessions(CancellationToken cancel = default)
    {
        var listed = ParseSessions(await Rpc("session/list", new { _request = new { } }, cancel));
        using var gate = new SemaphoreSlim(4);
        var resolved = await Task.WhenAll(listed.Select(async session =>
        {
            if (session.Status is not ("空闲" or "未运行")) return session;
            await gate.WaitAsync(cancel);
            try
            {
                // A fresh baseline is cold-safe: it neither activates an Agent nor
                // compares a persisted list watermark with a live sequence space.
                var baseline = await Rpc("session/projections", new { request = new { sessionId = session.Id } }, cancel);
                var cursor = baseline.At("asOfSeq");
                if (cursor.ValueKind != JsonValueKind.Number || !cursor.TryGetInt64(out var seq) || seq < 0) return session;
                var inbox = baseline.At("values").At("inbox");
                if (new[] { "next-turn", "next-step" }.Any(key => inbox.At(key).ValueKind == JsonValueKind.Array && inbox.At(key).GetArrayLength() > 0))
                    return session;
                if (!outcomes.TryGetValue(session.Id, out var cached) || cached.Seq != seq)
                {
                    // Only the last message window is needed. Inspect lifecycle
                    // fields in memory; never retain message text or RPC bodies.
                    var page = await Rpc("session/page", new { request = new { address = new { kind = "session", sessionId = session.Id }, throughSeq = seq, maxMessages = 1 } }, cancel);
                    cached = (seq, CompletionStatus(page));
                    outcomes[session.Id] = cached;
                }
                return cached.Status.Length == 0 ? session : session with { Status = cached.Status };
            }
            catch (Exception e) when (e is IOException or HttpRequestException || e is OperationCanceledException && !cancel.IsCancellationRequested)
            {
                // Older profiles may not expose history/projections. Keep their
                // live idle status rather than guessing that they completed.
                return session;
            }
            finally { gate.Release(); }
        }));
        if (resolved.SequenceEqual(listed)) return listed;
        // A new prompt or active turn wins over the historical cut read above.
        var current = ParseSessions(await Rpc("session/list", new { _request = new { } }, cancel));
        var previous = listed.ToDictionary(s => s.Id);
        var statuses = resolved.ToDictionary(s => s.Id, s => s.Status);
        foreach (var id in outcomes.Keys.Except(current.Select(s => s.Id))) outcomes.TryRemove(id, out _);
        return current.Select(s => previous.TryGetValue(s.Id, out var before) && s == before ? s with { Status = statuses[s.Id] } : s).ToList();
    }

    public static string CompletionStatus(JsonElement page)
    {
        var records = page.At("records");
        if (records.ValueKind != JsonValueKind.Array) throw new IOException("dsh 会话结束状态格式不兼容。");
        foreach (var record in records.EnumerateArray().Reverse())
        {
            if (record.Text("type") != "event") continue;
            var ev = record.At("event");
            if (ev.Text("type") == "turn/start") return "已停止";
            if (ev.Text("type") != "turn/end") continue;
            return ev.At("data").At("reason").Text("kind") switch
            {
                "completed" => "已完成",
                "aborted" or "interrupted" or "forked" => "已停止",
                "error" or "blocked" or "max-tokens" => "遇到问题",
                _ => "状态未知"
            };
        }
        return "";
    }

    public static List<Session> ParseSessions(JsonElement value)
    {
        if (value.At("items").ValueKind != JsonValueKind.Array)
            throw new IOException("dsh 会话列表格式不兼容。");
        var sessions = new List<Session>();
        foreach (var item in value.At("items").EnumerateArray())
        {
            if (item.Text("parentSessionId").Length > 0 || item.Text("origin") == "subagent")
                continue;
            // dsh pre-creates blank sessions when a workspace is opened. Their
            // cwd and creation time are real, but they are not recent conversations.
            // Keep a running row even if its list metadata has not caught up yet.
            if (item.At("blank").ValueKind == JsonValueKind.True && item.At("running").ValueKind != JsonValueKind.True)
                continue;
            var id = item.Text("sessionId");
            if (id.Length == 0)
                continue;
            // dsh's title projection is a string, shared with the Web session list.
            var title = item.At("projections").At("values").Text("title");
            if (string.IsNullOrWhiteSpace(title)) title = "未命名会话";
            var state = item.At("running").ValueKind == JsonValueKind.True ? "运行中" : item.At("running").ValueKind != JsonValueKind.False ? "状态未知"
                : item.At("agentAvailable").ValueKind == JsonValueKind.True ? "空闲" : "未运行";
            var time = item.Number("updatedAt", -1);
            if (!double.IsFinite(time) || time < 0 || time > 253402300799999)
                throw new IOException("dsh 会话时间格式不兼容。");
            sessions.Add(new(id, title[..Math.Min(title.Length, 140)], state, DateTimeOffset.FromUnixTimeMilliseconds((long)time), item.Text("cwd")));
        }
        return sessions.OrderBy(s => s.Status == "运行中" ? 0 : 1).ThenByDescending(s => s.Updated).Take(40).ToList();
    }

    public async Task<Quota> Balance(CancellationToken cancel = default)
    {
        string billing;
        try { billing = (await BillingRoute(cancel)).Detail; }
        catch (Exception e) when (e is IOException or HttpRequestException || e is OperationCanceledException && !cancel.IsCancellationRequested)
        { billing = "模型计费通道查询失败"; }
        return await OfficialBalance(billing, cancel);
    }

    public async Task<Quota> OfficialBalance(string billing, CancellationToken cancel = default)
    {
        var state = await Rpc("account/getState", new { }, cancel);
        var status = state.Text("status");
        if (status is not ("signed-out" or "credential-stored"))
            throw new IOException("dsh 官方账户状态格式不兼容。");
        if (status == "signed-out")
            return new([], DateTimeOffset.UtcNow, billing + "\n官方账户未登录");
        var value = await Rpc("account/getBalance", new { client = new { version = typeof(DshConnection).Assembly.GetName().Version?.ToString(3) ?? "0.2.0", locale = "zh-CN", timezoneOffsetSeconds = (int)TimeZoneInfo.Local.GetUtcOffset(DateTimeOffset.Now).TotalSeconds } }, cancel);
        if (value.ValueKind == JsonValueKind.Null)
            return new([], DateTimeOffset.UtcNow, billing + "\n官方账户登录已失效，请在 dsh 重新登录");
        return new([], DateTimeOffset.UtcNow, billing + "\n官方账户已登录 · 以下为官方钱包余额", Balances: ParseBalance(value));
    }

    public async Task<DshBilling> BillingRoute(CancellationToken cancel = default)
    {
        var catalog = await Rpc("session/modelCatalog", new { }, cancel);
        var provider = catalog.At("default").Text("provider");
        if (provider == "deepseek-account") return new("默认模型：DeepSeek 官方账户计费", provider);
        if (provider.Length == 0) return new("尚未选择默认模型");

        // Discovery advertises models even without a usable key. Query presence,
        // using the same redacted settings and credential API as dsh's Models page.
        var settings = await Rpc("settings/describe", new { }, cancel);
        var config = ProviderSettings(settings, provider);
        var reference = config.Text("apiKeyEnv");
        var label = provider == "deepseek-official" ? "DeepSeek API Key" : provider + " API Key";
        if (reference.Length == 0) return new("默认模型：" + label + " · 凭据状态未知", provider);
        var credentials = await Rpc("credentials/describe", new { refs = new[] { reference } }, cancel);
        var configured = credentials.At(reference).At("configured");
        if (configured.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new IOException("dsh API Key 状态格式不兼容。");
        return new("默认模型：" + label + (configured.ValueKind == JsonValueKind.True
            ? provider == "deepseek-official" ? " 已配置" : " 已配置\n按提供方计费 · 余额请在提供方查看"
            : " 未配置 · 请在 dsh 模型设置中配置"), provider, reference, configured.ValueKind == JsonValueKind.True,
            credentials.At(reference).Text("source"), config.Text("baseURL"));
    }

    public static JsonElement ProviderSettings(JsonElement settings, string provider)
    {
        var namespaces = settings.At("namespaces");
        if (namespaces.ValueKind != JsonValueKind.Array) throw new IOException("dsh 模型设置格式不兼容。");
        foreach (var ns in namespaces.EnumerateArray())
        {
            var value = ns.At("value");
            var route = value.At("providers").At(provider);
            if (route.ValueKind == JsonValueKind.Object) return route;
            // Official package's default namespace is llm-deepseek; users may
            // also retain its plugin name as the entry id.
            if (provider == "deepseek-official" && ns.Text("ns") is "llm-deepseek" or "llm-deepseek-api-key")
                return value;
        }
        return default;
    }

    public static List<WalletBalance> ParseBalance(JsonElement value)
    {
        if (value.Text("status") != "ready")
            throw new IOException("dsh 官方账户余额查询失败。");
        var result = new List<WalletBalance>();
        foreach (var (key, label) in new[] { ("value", "充值"), ("bonusWallets", "赠送") })
        {
            var wallets = value.At(key);
            if (wallets.ValueKind != JsonValueKind.Array)
                throw new IOException("dsh 钱包数据格式不兼容。");
            foreach (var wallet in wallets.EnumerateArray())
            {
                var currency = wallet.Text("currency");
                if (currency is not ("CNY" or "USD") || !decimal.TryParse(wallet.Text("balance"), NumberStyles.AllowDecimalPoint | NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var amount))
                    throw new IOException("dsh 钱包金额格式不兼容。");
                result.Add(new(label, currency, amount));
            }
        }
        return result;
    }

    public void Dispose() => http.Dispose();
}
