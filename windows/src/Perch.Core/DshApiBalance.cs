using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using YamlDotNet.Core;
using YamlDotNet.RepresentationModel;

namespace Perch.Windows;

// Public route facts only. Never attach a resolved secret to this value.
public sealed record DshBilling(string Detail, string Provider = "", string Reference = "", bool Configured = false, string Source = "", string BaseUrl = "");

// Only errors authored here may be shown verbatim; OS/parser/transport errors are redacted.
internal sealed class DshBalanceException(string message) : IOException(message);

public static class DshCredentialReader
{
    public static string Read(string home, string reference)
    {
        if (!Regex.IsMatch(reference, @"\A[A-Za-z_][A-Za-z0-9_]*\z"))
            throw new DshBalanceException("dsh API Key 引用无效。");
        try
        {
            using var file = new FileStream(Path.Combine(home, ".credentials.yaml"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (file.Length > 1024 * 1024) throw new DshBalanceException("凭据文件过大，无法查询余额。");
            using var reader = new StreamReader(file, Encoding.UTF8, true);
            var yaml = new YamlStream();
            yaml.Load(reader);
            if (yaml.Documents.Count != 1 || yaml.Documents[0].RootNode is not YamlMappingNode root
                || root.Children.Keys.Any(k => k is not YamlScalarNode scalar || scalar.Value is not ("version" or "refs" or "records"))
                || !root.Children.TryGetValue(new YamlScalarNode("version"), out var version) || version is not YamlScalarNode { Value: "1", Style: ScalarStyle.Plain }
                || !root.Children.TryGetValue(new YamlScalarNode("refs"), out var refs) || refs is not YamlMappingNode values)
                throw new DshBalanceException("dsh 凭据格式不兼容，仅支持 version: 1 的标准凭据文件。");
            if (!values.Children.TryGetValue(new YamlScalarNode(reference), out var target))
                throw new DshBalanceException("dsh 凭据文件中未找到当前 API Key 引用。");
            if (target is not YamlScalarNode key || string.IsNullOrEmpty(key.Value) || key.Value.Length > 8192
                || !key.Tag.IsEmpty && key.Tag.Value != "tag:yaml.org,2002:str"
                || key.Value.Any(c => c < '!' || c > '~')
                || key.Tag.IsEmpty && key.Style == ScalarStyle.Plain && Regex.IsMatch(key.Value, @"\A(?:null|~|true|false|[-+]?(?:[0-9].*|\.inf|\.nan))\z", RegexOptions.IgnoreCase))
                throw new DshBalanceException("dsh API Key 值无效。");
            return key.Value;
        }
        // YAML diagnostics can include the offending scalar. Never retain inner exceptions.
        catch (YamlException) { throw new DshBalanceException("dsh 凭据 YAML 无效或包含重复键。"); }
        catch (UnauthorizedAccessException) { throw new DshBalanceException("无法读取 dsh 凭据文件，请检查目录权限。"); }
        catch (FileNotFoundException) { throw new DshBalanceException("未找到 dsh 标准凭据文件。"); }
        catch (DirectoryNotFoundException) { throw new DshBalanceException("余额凭据目录不存在。"); }
        catch (ArgumentException) { throw new DshBalanceException("余额凭据目录无效。"); }
    }
}

/// One account's in-memory balance cache. Only a fingerprint survives a query, never the key.
/// The owning DshService entry serializes calls, including manual refreshes.
public sealed class DshApiBalance : IDisposable
{
    public const string Endpoint = "https://api.deepseek.com/user/balance";
    private readonly HttpClient http;
    private string identity = "";
    private DateTimeOffset nextQuery;
    private ApiBalanceResult? cached;

    public DshApiBalance(HttpMessageHandler? handler = null)
    {
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(15) };
    }

    public void Clear() { identity = ""; nextQuery = default; cached = null; }

    private ApiBalanceResult Unavailable(string detail)
    {
        Clear();
        return new([], null, detail);
    }

    public static bool OfficialEndpoint(string value) => value.Length == 0 || Uri.TryCreate(value, UriKind.Absolute, out var uri)
        && uri.Scheme == "https" && uri.Host.Equals("api.deepseek.com", StringComparison.OrdinalIgnoreCase) && uri.IsDefaultPort
        && uri.UserInfo.Length == 0 && uri.Query.Length == 0 && uri.Fragment.Length == 0;

    public async Task<ApiBalanceResult?> Read(DshBilling route, string home, bool manual = false, CancellationToken cancel = default)
    {
        if (route.Provider != "deepseek-official") { Clear(); return null; }
        if (!route.Configured) return Unavailable("API Key 未配置，请在 dsh 模型设置中配置。");
        if (route.Source != "file") return Unavailable("当前凭据来源暂不支持余额查询（仅支持标准文件来源）。");
        if (!OfficialEndpoint(route.BaseUrl)) return Unavailable("模型端点不是 DeepSeek 官方 HTTPS 地址，未发送 API Key。");
        if (string.IsNullOrWhiteSpace(home)) return Unavailable("请在账号配置中选择已有实例的余额凭据目录（DSH_HOME）。");

        string key;
        string current;
        try
        {
            key = DshCredentialReader.Read(home, route.Reference);
            current = Fingerprint(home, route.Reference, key);
        }
        catch (IOException e) { return Unavailable(SafeReadError(e)); }
        if (identity != current) { Clear(); identity = current; }
        if (!manual && cached != null && DateTimeOffset.UtcNow < nextQuery) return cached;
        nextQuery = DateTimeOffset.UtcNow.AddMinutes(5);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new DshBalanceException("DeepSeek API 鉴权失败，请检查 dsh 中的 API Key。");
            if ((int)response.StatusCode == 429) throw new DshBalanceException("DeepSeek API 查询限流（HTTP 429），请稍后重试。");
            if ((int)response.StatusCode is >= 300 and < 400) throw new DshBalanceException("DeepSeek API 返回重定向，已拒绝跟随以保护 API Key。");
            if (!response.IsSuccessStatusCode) throw new DshBalanceException($"DeepSeek API 余额查询失败（HTTP {(int)response.StatusCode}）。");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var body = new MemoryStream();
            var buffer = new byte[4096];
            int count;
            while ((count = await stream.ReadAsync(buffer, timeout.Token)) > 0)
            {
                if (body.Length + count > 65536) throw new DshBalanceException("DeepSeek API 余额响应过大。");
                body.Write(buffer, 0, count);
            }
            using var doc = JsonDocument.Parse(body.ToArray());
            var balances = Parse(doc.RootElement);
            // A key changed during the HTTP request must not receive the old wallet.
            if (Fingerprint(home, route.Reference, DshCredentialReader.Read(home, route.Reference)) != current)
                return Unavailable("API Key 已变更，请刷新余额。");
            return cached = new(balances, DateTimeOffset.UtcNow, "查询成功");
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { return FailedForIdentity(home, route.Reference, current, "DeepSeek API 余额查询超时。"); }
        catch (HttpRequestException) { return FailedForIdentity(home, route.Reference, current, "DeepSeek API 余额网络查询失败。"); }
        catch (JsonException) { return FailedForIdentity(home, route.Reference, current, "DeepSeek API 余额响应格式不兼容。"); }
        catch (IOException e)
        {
            return FailedForIdentity(home, route.Reference, current, e is DshBalanceException ? e.Message : "DeepSeek API 余额查询失败。");
        }
    }

    private ApiBalanceResult Failed(string message) => cached = cached?.Observed != null
        ? cached with { Cached = true, Detail = message } : new([], null, message);

    private ApiBalanceResult FailedForIdentity(string home, string reference, string current, string message)
    {
        try
        {
            if (Fingerprint(home, reference, DshCredentialReader.Read(home, reference)) != current)
                return Unavailable("API Key 已变更，请刷新余额。");
        }
        catch (IOException) { return Unavailable("无法确认当前 API Key，已清除余额缓存。"); }
        return Failed(message);
    }

    private static string SafeReadError(IOException error) => error is DshBalanceException ? error.Message : "无法读取 dsh 凭据文件。";

    private static string Fingerprint(string home, string reference, string key)
    {
        var bytes = Encoding.UTF8.GetBytes(Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant() + "\0" + reference + "\0" + key);
        try { return Convert.ToHexString(SHA256.HashData(bytes)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    public static List<WalletBalance> Parse(JsonElement value)
    {
        if (value.At("is_available").ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || value.At("balance_infos").ValueKind != JsonValueKind.Array || value.At("balance_infos").GetArrayLength() == 0)
            throw new DshBalanceException("DeepSeek API 余额响应格式不兼容。");
        var result = new List<WalletBalance>();
        var currencies = new HashSet<string>();
        foreach (var wallet in value.At("balance_infos").EnumerateArray())
        {
            var currency = wallet.Text("currency");
            if (currency is not ("CNY" or "USD") || !currencies.Add(currency)) throw new DshBalanceException("DeepSeek API 余额币种不兼容。");
            foreach (var (field, label) in new[] { ("total_balance", "总额"), ("topped_up_balance", "充值"), ("granted_balance", "赠送") })
            {
                if (!decimal.TryParse(wallet.Text(field), NumberStyles.AllowDecimalPoint | NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var amount))
                    throw new DshBalanceException("DeepSeek API 余额金额格式不兼容。");
                result.Add(new(label, currency, amount));
            }
        }
        return result;
    }

    public void Dispose() => http.Dispose();
}
