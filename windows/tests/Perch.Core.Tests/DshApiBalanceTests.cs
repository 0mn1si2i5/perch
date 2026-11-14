using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Perch.Windows;

internal static class DshApiBalanceTests
{
    private const string FakeKey = "sk-perch-balance-test-only-NOT-A-REAL-KEY";
    private const string Payload = """
    {"is_available":true,"balance_infos":[
      {"currency":"CNY","total_balance":"12.34567890123456789","granted_balance":"0.34567890123456789","topped_up_balance":"12"},
      {"currency":"USD","total_balance":"0","granted_balance":"0","topped_up_balance":"0"}]}
    """;
    private static void Check(bool ok, string why) { if (!ok) throw new Exception(why); }

    public static async Task Run(string root)
    {
        var home = Path.Combine(root, "api-balance-home");
        Store.PrivateDirectory(home);
        var path = Path.Combine(home, ".credentials.yaml");
        void Save(string key = FakeKey) => File.WriteAllText(path, "version: 1\nrefs:\n  MY_DEEPSEEK_KEY: '" + key + "' # comment\n  UNRELATED_KEY: unused\nrecords: {}\n");
        Save();
        var original = File.ReadAllBytes(path);
        Check(DshCredentialReader.Read(home, "MY_DEEPSEEK_KEY") == FakeKey, "Quoted custom credential references must resolve");
        Check(File.ReadAllBytes(path).SequenceEqual(original), "Credential reads must not rewrite the file");
        foreach (var bad in new[] {
            "version: 2\nrefs: {MY_DEEPSEEK_KEY: '" + FakeKey + "'}",
            "version: 1\nrefs:\n  MY_DEEPSEEK_KEY: '" + FakeKey + "'\n  MY_DEEPSEEK_KEY: duplicate",
            "version: 1\nrefs: {MY_DEEPSEEK_KEY: [wrong]}",
            "version: 1\nrefs: {MY_DEEPSEEK_KEY: 123}",
            "version: 1\nrefs: {MY_DEEPSEEK_KEY: \"bad\\nkey\"}",
            "version: 1\nrefs:\n  MY_DEEPSEEK_KEY: [ '" + FakeKey,
            "MY_DEEPSEEK_KEY: '" + FakeKey + "'" })
        {
            File.WriteAllText(path, bad);
            bool refused = false;
            try { DshCredentialReader.Read(home, "MY_DEEPSEEK_KEY"); }
            catch (IOException e) { refused = true; Check(!e.ToString().Contains(FakeKey), "YAML errors must not retain secret scalars or inner diagnostics"); }
            Check(refused, "Invalid credential files must be refused");
        }
        Save();
        var route = new DshBilling("", "deepseek-official", "MY_DEEPSEEK_KEY", true, "file", "https://api.deepseek.com/anthropic");
        using var handler = new BalanceHttp();
        using var api = new DshApiBalance(handler);
        var first = (await api.Read(route, home))!;
        Check(first.Balances.Count == 6 && first.Balances[0].Amount == 12.34567890123456789m && first.Balances[3].Amount == 0m, "Multiple currencies and real zero balances retain decimal precision");
        Check(first.Observed != null && !first.Cached, "Successful balances must have an observation time");
        await api.Read(route, home);
        Check(handler.Count == 1, "Automatic polling must not bypass the five-minute HTTP interval");
        await api.Read(route, home, true);
        Check(handler.Count == 2, "Manual refresh must issue a fresh query");
        foreach (var status in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.Forbidden, HttpStatusCode.TooManyRequests, HttpStatusCode.Found, HttpStatusCode.InternalServerError })
        {
            handler.Status = status;
            var failure = (await api.Read(route, home, true))!;
            Check(failure.Cached && failure.Observed != null && failure.Balances.Count == 6, "Same-key HTTP failures preserve the last successful wallet");
            Check(!failure.Detail.Contains(FakeKey), "HTTP errors must not echo upstream bodies");
            if (status == HttpStatusCode.Found) Check(failure.Detail.Contains("重定向"), "Redirects must be refused");
            if ((int)status == 429) Check(failure.Detail.Contains("限流"), "Rate limits must have a distinct hint");
        }
        handler.Error = "timeout";
        Check((await api.Read(route, home, true))!.Detail.Contains("超时"), "Timeouts must have a distinct hint");
        handler.Error = "network";
        Check((await api.Read(route, home, true))!.Cached, "Transient network failures preserve same-key cache");
        handler.Error = "";
        Save(FakeKey + "-changed");
        var changed = (await api.Read(route, home))!;
        Check(changed.Balances.Count == 0 && !changed.Cached, "Changed keys must not reuse another key's cached balance, even inside the refresh interval");
        handler.Status = HttpStatusCode.OK;
        handler.Body = "{" + FakeKey;
        Check((await api.Read(route, home, true))!.Balances.Count == 0, "Malformed upstream data must not fabricate zero balances");
        handler.Body = Payload.Replace("12.34567890123456789", "invalid");
        Check((await api.Read(route, home, true))!.Balances.Count == 0, "Invalid amounts must not become zero");
        handler.Body = Payload;
        await api.Read(route, home, true);
        File.WriteAllText(path, "version: 1\nrefs:\n  MY_DEEPSEEK_KEY: '" + FakeKey + "'\n  SECOND_KEY: '" + FakeKey + "'\n");
        await api.Read(route, home, true);
        handler.Status = HttpStatusCode.Unauthorized;
        var changedReference = (await api.Read(route with { Reference = "SECOND_KEY" }, home))!;
        Check(changedReference.Balances.Count == 0, "A changed reference must invalidate the prior wallet even if the key bytes match");
        handler.Status = HttpStatusCode.OK;
        await api.Read(route, home, true);
        var otherHome = Path.Combine(root, "another-api-home");
        Store.PrivateDirectory(otherHome);
        File.Copy(path, Path.Combine(otherHome, ".credentials.yaml"));
        handler.Status = HttpStatusCode.Unauthorized;
        Check((await api.Read(route, otherHome))!.Balances.Count == 0, "Changing home must not reuse another home's wallet");
        handler.Status = HttpStatusCode.OK;
        await api.Read(route, home, true);
        var requests = handler.Count;
        foreach (var source in new[] { "env", "project-env", "user-env", "", "custom" })
        {
            var unsupported = (await api.Read(route with { Source = source }, home, true))!;
            Check(unsupported.Balances.Count == 0 && unsupported.Detail.Contains("来源暂不支持") && handler.Count == requests, "Non-file credential sources must never fall back to a file key");
        }
        foreach (var endpoint in new[] { "http://api.deepseek.com", "https://api.deepseek.com.evil.test", "https://api.deepseek.com:8443", "https://user@api.deepseek.com", "https://api.deepseek.com/?key=bad", "https://gateway.example/v1" })
            Check((await api.Read(route with { BaseUrl = endpoint }, home, true))!.Balances.Count == 0 && handler.Count == requests, "Non-official model endpoints must not trigger authenticated balance requests");
        Check(await api.Read(route with { Provider = "custom-provider" }, home, true) == null && handler.Count == requests, "Third-party providers must not use the DeepSeek endpoint");
        Check((await api.Read(route, "", true))!.Detail.Contains("凭据目录"), "External instances need an explicitly selected credential home");
        await api.Read(route, home, true);
        handler.OnRequest = () => Save(FakeKey + "-rotated-during-request");
        Check((await api.Read(route, home, true))!.Balances.Count == 0, "Key changes during HTTP must discard the previous wallet");
        handler.OnRequest = null;
        File.Delete(path);
        Check((await api.Read(route, home, true))!.Balances.Count == 0, "Missing files must clear cached balances");
        Save();
        using var otherHttp = new BalanceHttp { Status = HttpStatusCode.Unauthorized };
        using var otherAccount = new DshApiBalance(otherHttp);
        Check((await otherAccount.Read(route, home, true))!.Balances.Count == 0, "Accounts must not share successful balance caches");
        var configStore = new Store(Path.Combine(root, "api-balance-persistence"));
        configStore.Add(new Account { App = "dsh", Name = "Test", ProfilePath = home, SessionRoot = home, Dsh = new() { Mode = "external", BalanceHome = home } });
        Check(!File.ReadAllText(Path.Combine(configStore.Root, "accounts.json")).Contains(FakeKey), "Account persistence stores the selected home only, never the key");
        Check(new Store(configStore.Root).Accounts.Single().Dsh!.BalanceHome == home, "External balance home must survive restart");
        Console.WriteLine("PASS dsh independent API balance: credential safety, official transport, errors, refresh, key rotation and account isolation");
    }

    private sealed class BalanceHttp : HttpMessageHandler
    {
        public int Count;
        public HttpStatusCode Status = HttpStatusCode.OK;
        public string Body = Payload, Error = "";
        public Action? OnRequest;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            Count++;
            Check(request.Method == HttpMethod.Get && request.RequestUri!.AbsoluteUri == DshApiBalance.Endpoint, "Balance requests must use the fixed official GET endpoint");
            Check(request.Content == null && request.Headers.Authorization?.Scheme == "Bearer" && request.Headers.Authorization.Parameter!.StartsWith(FakeKey, StringComparison.Ordinal), "Credentials belong only in the Authorization header");
            Check(!request.RequestUri!.ToString().Contains(FakeKey) && !request.Headers.Contains("Cookie"), "No key in URLs and no dsh cookie sent to DeepSeek");
            OnRequest?.Invoke();
            if (Error == "timeout") throw new TaskCanceledException(FakeKey);
            if (Error == "network") throw new HttpRequestException(FakeKey);
            var response = new HttpResponseMessage(Status) { Content = new StringContent(Status == HttpStatusCode.OK ? Body : FakeKey, Encoding.UTF8, "application/json") };
            if (Status == HttpStatusCode.Found) response.Headers.Location = new Uri("https://untrusted.example/" + FakeKey);
            return Task.FromResult(response);
        }
    }
}
