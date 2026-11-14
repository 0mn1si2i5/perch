using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Perch.Windows;

internal static class DshTests
{
    private static void Check(bool value, string why) { if (!value) throw new Exception(why); }
    private static void Refuses(Action action, string why)
    {
        try { action(); } catch (IOException) { return; }
        throw new Exception(why);
    }
    private static async Task Refuses(Func<Task> action, string why)
    {
        try { await action(); } catch (IOException) { return; }
        throw new Exception(why);
    }

    public static async Task Run(string root)
    {
        var store = new Store(Path.Combine(root, "dsh-test-store"));
        var legacy = new Preferences { GroupOrder = ["claude", "codex"] };
        store.Write("preferences.json", legacy);
        Check(string.Join(',', new Store(store.Root).Preferences.GroupOrder) == "claude,codex,dsh", "Old group order must gain dsh without reordering");
        foreach (var bad in new[] { "https://127.0.0.1/?token=t", "http://example.com/?token=t", "http://127.0.0.1.evil/?token=t", "http://user@localhost/?token=t", "http://localhost/api?token=t", "http://localhost/", "http://localhost/?token=", "http://localhost/?token=t&token=b" })
            Refuses(() => DshConnection.ValidateUrl(bad), "Remote or malformed authorization URL must be refused");
        Check(DshConnection.ValidateUrl("http://[::1]:3080/?token=sample").IsLoopback, "IPv6 loopback must be accepted");
        using var metadata = JsonDocument.Parse("""
        {"items":[
          {"sessionId":"active","updatedAt":1791552000000,"running":true,"agentAvailable":true,"cwd":"D:/demo","projections":{"kind":"sequenced","values":{"title":"Metadata title","inbox":{"secret":"not a title"}}}},
          {"sessionId":"idle","updatedAt":1791552000000,"running":false,"agentAvailable":true},
          {"sessionId":"cold","updatedAt":1791552000000,"running":false,"agentAvailable":false,"projections":{"kind":"cached","values":{"title":"Latest renamed title"}}},
          {"sessionId":"child","parentSessionId":"active","updatedAt":1791552000000,"running":true},
          {"sessionId":"unknown","updatedAt":1791552000000,"agentAvailable":true}
        ]}
        """);
        var sessions = DshConnection.ParseSessions(metadata.RootElement);
        Check(sessions.Count == 4 && sessions[0].Title == "Metadata title" && sessions.All(s => s.Path == ""), "dsh reads root metadata only, without inventing local paths");
        Check(sessions.Single(s => s.Id == "cold").Title == "Latest renamed title" && sessions.Single(s => s.Id == "idle").Title == "未命名会话" && sessions[0].Cwd == "D:/demo", "Live and persisted Web titles are strings; absent titles do not use chat text");
        Check(sessions.Single(s => s.Id == "idle").Status == "空闲" && sessions.Single(s => s.Id == "cold").Status == "未运行" && sessions.Single(s => s.Id == "unknown").Status == "状态未知", "False running must never mean successful completion");
        using var workspaceSessions = JsonDocument.Parse("""
        {"items":[
          {"sessionId":"blank-idle","updatedAt":1791552300000,"cwd":"C:/demo/project","blank":true,"running":false,"agentAvailable":true,"projections":{"values":{"title":null}}},
          {"sessionId":"blank-cold","updatedAt":1791552200000,"cwd":"C:/demo/project","blank":true,"running":false,"agentAvailable":false},
          {"sessionId":"conversation","updatedAt":1791552000000,"cwd":"C:/demo/project","blank":false,"running":false,"agentAvailable":true,"projections":{"values":{"title":"Latest actual conversation"}}},
          {"sessionId":"unnamed","updatedAt":1791551900000,"blank":false,"running":false,"projections":{"values":{"title":null}}},
          {"sessionId":"blank-running","updatedAt":1791551800000,"blank":true,"running":true},
          {"sessionId":"unknown-blank","updatedAt":1791551700000,"blank":null,"running":false}
        ]}
        """);
        var visible = DshConnection.ParseSessions(workspaceSessions.RootElement);
        Check(visible.Count == 4 && visible.All(s => s.Id is not ("blank-idle" or "blank-cold")), "Pre-created idle and cold workspace placeholders must not displace real conversations");
        Check(visible[0].Id == "blank-running" && visible[1].Title == "Latest actual conversation" && visible[1].Cwd == "C:/demo/project", "Running sessions remain visible and latest real conversation retains its title and project path");
        Check(visible.Single(s => s.Id == "unnamed").Title == "未命名会话" && visible.Any(s => s.Id == "unknown-blank"), "Missing titles and unknown blank metadata do not prove a session is empty");
        var manyPlaceholders = JsonSerializer.SerializeToElement(new { items = Enumerable.Range(0, 45).Select(i => new { sessionId = "placeholder-" + i, updatedAt = 1791552300000L + i, blank = true, running = false })
            .Cast<object>().Append(new { sessionId = "real", updatedAt = 1791552000000L, blank = false, running = false, projections = new { values = new { title = "Older real conversation" } } }) });
        Check(DshConnection.ParseSessions(manyPlaceholders).Single().Title == "Older real conversation", "Blank filtering must happen before the 40-session limit");
        using var wallet = JsonDocument.Parse("""{"status":"ready","value":[{"currency":"CNY","balance":"12.34567890123456789"},{"currency":"USD","balance":"0"}],"bonusWallets":[{"currency":"CNY","balance":"1.20"}]}""");
        var balances = DshConnection.ParseBalance(wallet.RootElement);
        Check(balances.Count == 3 && balances[0].Amount == 12.34567890123456789m && balances[1].Currency == "USD" && balances[2].Kind == "赠送", "Wallets preserve decimal precision, currency and kind");
        using var failed = JsonDocument.Parse("""{"status":"failed"}""");
        Refuses(() => DshConnection.ParseBalance(failed.RootElement), "Failed wallets must not fabricate a zero balance");

        var state = new DshState(store.Root, DshState.ForAccount("test"));
        state.Write(new("ready", Authorization: new("http://localhost:3080/?token=sensitive-test-token", "cookie=secret")));
        Check(state.Read()?.Authorization?.Cookie == "cookie=secret" && !Encoding.UTF8.GetString(File.ReadAllBytes(state.RuntimePath)).Contains("sensitive-test-token"), "Runtime credentials must round-trip through DPAPI without plaintext");
        using var handler = new FakeHttp();
        using var connection = new DshConnection(new("http://127.0.0.1:3080/?token=sample", ""), handler);
        await connection.Authenticate();
        Check((await connection.Sessions()).Single().Status == "空闲" && handler.SawNamedRequest, "RPC must send dsh's named _request parameter with the auth cookie");
        handler.EndReason = "completed";
        handler.Seq++;
        Check((await connection.Sessions()).Single().Status == "已完成", "A durable completed turn gets the shared green check status");
        var pageReads = handler.PageReads;
        Check((await connection.Sessions()).Single().Status == "已完成" && handler.PageReads == pageReads, "Unchanged event cursor reuses only the parsed outcome");
        foreach (var (reason, expected) in new[] { ("aborted", "已停止"), ("interrupted", "已停止"), ("forked", "已停止"), ("error", "遇到问题"), ("blocked", "遇到问题"), ("max-tokens", "遇到问题"), ("new-reason", "状态未知") })
        {
            handler.EndReason = reason;
            handler.Seq++;
            Check((await connection.Sessions()).Single().Status == expected, "Non-success lifecycle must never get a green check: " + reason);
        }
        handler.EndReason = "completed";
        handler.Seq++;
        handler.StartDuringPage = true;
        Check((await connection.Sessions()).Single().Status == "运行中", "A turn starting during outcome lookup supersedes old completion");
        handler.StartDuringPage = handler.Running = false;
        handler.PendingInput = true;
        Check((await connection.Sessions()).Single().Status == "空闲", "Queued input supersedes completion even before running becomes true");
        handler.PendingInput = false;
        handler.Seq++;
        handler.PageUnavailable = true;
        Check((await connection.Sessions()).Single().Status == "空闲", "History failure must clear a previous green check and preserve live metadata");
        handler.PageUnavailable = false;
        using var newTurn = JsonDocument.Parse("""{"records":[{"type":"event","event":{"type":"turn/end","data":{"reason":{"kind":"completed"}}}},{"type":"event","event":{"type":"turn/start","data":{"turn":2}}}]}""");
        Check(DshConnection.CompletionStatus(newTurn.RootElement) == "已停止", "An unfinished latest turn must not inherit an earlier completion");
        Check((await connection.Balance()).Balances!.Single().Amount == 7.25m && handler.SawClient, "Official balance RPC includes UI metadata");
        handler.SignedOut = true;
        var route = await connection.BillingRoute();
        Check(route.Source == "file" && route.Reference == "DEEPSEEK_API_KEY" && route.BaseUrl == "https://api.deepseek.com/anthropic", "Billing facts must include credential source and model endpoint without the key");
        var keyQuota = await connection.Balance();
        Check(keyQuota.Balances == null && keyQuota.Detail.Contains("DeepSeek API Key 已配置") && !keyQuota.Detail.Contains("未接入"), "Signed-out official account must not hide configured API-key billing");
        handler.KeyConfigured = false;
        Check((await connection.Balance()).Detail.Contains("API Key 未配置"), "Model discovery alone must not claim API-key presence");
        handler.KeyConfigured = true;
        handler.Provider = "custom-gateway";
        Check((await connection.Balance()).Detail.Contains("custom-gateway API Key 已配置"), "Third-party route uses its own credential reference");
        handler.Provider = "deepseek-account";
        Check((await connection.Balance()).Detail.Contains("官方账户计费"), "Official account billing is separate from API keys");
        handler.Provider = "deepseek-official";
        handler.SignedOut = false;
        handler.NullBalance = true;
        Check((await connection.Balance()).Detail.Contains("登录已失效"), "Null balance after stored login means expired login, not API-key mode");
        handler.NullBalance = false;
        handler.BadState = true;
        await Refuses(async () => await connection.Balance(), "Unknown account status must not imply signed-in");
        handler.BadState = false;
        handler.InvalidId = true;
        await Refuses(async () => await connection.Sessions(), "Mismatched RPC correlation must fail");
        handler.InvalidId = false;
        handler.Status = HttpStatusCode.Unauthorized;
        await Refuses(async () => await connection.Sessions(), "Expired authentication must fail explicitly");
        handler.Status = HttpStatusCode.OK;
        handler.RpcError = true;
        await Refuses(async () => await connection.Sessions(), "RPC business failures must not become empty success");
        handler.RpcError = false;
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        try { await connection.Sessions(canceled.Token); throw new Exception("Cancellation must propagate"); } catch (OperationCanceledException) { }

        var node = DshInstallation.FindNode();
        var install = Path.Combine(root, "dsh installation with spaces");
        var cli = Path.Combine(install, "apps", "cli");
        Directory.CreateDirectory(Path.Combine(install, "apps", "web", "dist"));
        Directory.CreateDirectory(cli);
        File.WriteAllText(Path.Combine(install, "package.json"), """{"name":"@deepseek-ai/dsh-root"}""");
        File.WriteAllText(Path.Combine(cli, "package.json"), """{"name":"@deepseek-ai/dsh","bin":{"dsh":"bin.js"}}""");
        File.WriteAllText(Path.Combine(install, "apps", "web", "dist", "index.html"), "demo");
        File.WriteAllText(Path.Combine(cli, "bin.js"), ServerScript);
        var account = new Account { App = "dsh", Name = "Test dsh", ProfilePath = Path.Combine(root, "isolated dsh home"), SessionRoot = Path.Combine(root, "isolated dsh home"), Dsh = new() { Mode = "source", InstallationPath = install, NodePath = Path.Combine(root, "missing-node.exe") } };
        Refuses(() => DshInstallation.Resolve(account), "Missing Node must be diagnosed before startup");
        if (node == null) { Console.WriteLine("SKIP: dsh process lifecycle test (Node.js unavailable)"); return; }
        account.Dsh.NodePath = node;
        var launch = DshInstallation.Resolve(account);
        Check(launch.StartInfo().ArgumentList[0] == Path.Combine(cli, "bin.js") && launch.StartInfo().ArgumentList.Contains("0") && launch.StartInfo().Environment["DSH_HOME"] == account.ProfilePath, "Source launch uses argument boundaries, isolated home and OS-assigned port");
        File.Delete(Path.Combine(install, "apps", "web", "dist", "index.html"));
        Refuses(() => DshInstallation.Resolve(account), "Missing Web build must request an explicit build");
        File.WriteAllText(Path.Combine(install, "apps", "web", "dist", "index.html"), "demo");
        var project = Path.Combine(root, "npm local project");
        var npm = Path.Combine(project, "node_modules", "@deepseek-ai", "dsh");
        Directory.CreateDirectory(npm);
        File.Copy(Path.Combine(cli, "package.json"), Path.Combine(npm, "package.json"));
        File.Copy(Path.Combine(cli, "bin.js"), Path.Combine(npm, "bin.js"));
        var npmAccount = new Account { App = "dsh", Name = "npm dsh", ProfilePath = Path.Combine(root, "npm home"), SessionRoot = Path.Combine(root, "npm home"), Dsh = new() { InstallationPath = project, NodePath = node } };
        Check(DshInstallation.Resolve(npmAccount).Entry == Path.Combine(npm, "bin.js"), "Local npm installation resolves the manifest bin");
        await Lifecycle(store, account, npmAccount);
        Console.WriteLine("PASS: dsh install resolution, RPC/auth, wallet precision, cache and independent host lifecycle");
    }

    private static async Task Lifecycle(Store store, Account source, Account npm)
    {
        Store.PrivateDirectory(source.ProfilePath);
        Store.PrivateDirectory(npm.ProfilePath);
        store.Add(source);
        store.Add(npm);
        using var service = new DshService(store);
        var external = new Account { App = "dsh", Name = "External", ProfilePath = Path.Combine(store.Root, "external"), SessionRoot = Path.Combine(store.Root, "external"), Dsh = new() { Mode = "external" } };
        try
        {
            var parentInfo = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "--dsh-parent-exit", store.Root, source.Id }) parentInfo.ArgumentList.Add(arg);
            using (var parent = Process.Start(parentInfo)!)
            {
                await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(80));
                Check(parent.ExitCode == 0, "The launching panel process must exit normally");
            }
            Check(DshState.ChildAlive(service.State(source).Read()), "dsh must survive the actual launching process exiting");
            await service.Ensure(npm);
            var before = service.State(source).Read()!;
            Check(before.Phase == "ready" && before.ChildPid != service.State(npm).Read()!.ChildPid, "Independent homes must start distinct processes");
            var url = await service.Ensure(source);
            Check(service.State(source).Read()!.ChildPid == before.ChildPid, "Repeated open must not spawn another runtime");
            using (var reopened = new DshService(new Store(store.Root)))
            {
                await reopened.Ensure(source);
                Check(reopened.State(source).Read()!.ChildPid == before.ChildPid, "New panel instance must recover the existing host");
            }
            await service.Connect(external, url);
            Check((await service.Read(external)).Running, "Manually connected existing instance must expose real HTTP summaries");
            File.WriteAllBytes(service.State(external).RuntimePath, [1, 2, 3]);
            Check((await service.Read(external)).Cached, "Unreadable authorization must report disconnected cached metadata");
            await service.Connect(external, url);
            Check((await service.Read(external)).Running, "External reconnect must recover an unreadable descriptor");
            await service.Stop(external);
            Check(DshState.ChildAlive(before) && !(await service.Read(external)).Running, "External disconnect must not terminate the owner's runtime");
            store.Remove(source);
            Check(DshState.ChildAlive(before), "Account removal must leave running service intact");
            var read = await service.Read(source);
            Check(read.Running && !read.Cached && read.Sessions.Single().Status == "空闲", "Fresh service summaries remain available after account removal");
            var npmRuntime = service.State(npm).Read()!;
            using (var host = Process.GetProcessById(npmRuntime.HostPid)) { host.Kill(); await host.WaitForExitAsync(); }
            Check((await service.Read(npm)).Detail.Contains("宿主已退出") && DshState.ChildAlive(npmRuntime), "Host crash must report the still-running child accurately");
            await service.Ensure(npm);
            Check(service.State(npm).Read()!.ChildPid == npmRuntime.ChildPid, "Host loss must not duplicate a surviving runtime");
            using (var child = Process.GetProcessById(before.ChildPid)) { child.Kill(true); await child.WaitForExitAsync(); }
            var offline = await service.Read(source);
            Check(offline.Cached && !offline.Running && offline.Sessions.Single().Status == "状态未知", "Crashed runtime preserves cached metadata without reporting completion");
        }
        finally
        {
            await service.Stop(source);
            await service.Stop(npm);
        }
    }

    private sealed class FakeHttp : HttpMessageHandler
    {
        public HttpStatusCode Status = HttpStatusCode.OK;
        public bool InvalidId, RpcError, SignedOut, SawNamedRequest, SawClient, NullBalance, BadState;
        public bool KeyConfigured = true;
        public string Provider = "deepseek-official";
        public string EndReason = "";
        public int Seq = 1, PageReads;
        public bool StartDuringPage, Running, PendingInput, PageUnavailable;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            cancel.ThrowIfCancellationRequested();
            if (request.Method == HttpMethod.Get)
            {
                var auth = new HttpResponseMessage(HttpStatusCode.SeeOther);
                auth.Headers.Add("Set-Cookie", "dsh-auth-test=example; Path=/; HttpOnly");
                return auth;
            }
            Check(request.Headers.GetValues("Cookie").Single() == "dsh-auth-test=example", "RPC must attach the exchanged cookie");
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancel));
            var e = body.RootElement;
            Check(e.Text("type") == "client-request", "RPC request envelope");
            var args = e.At("payload").At("args");
            object? value;
            if (e.Text("method") == "session/list") { SawNamedRequest = args.At("_request").ValueKind == JsonValueKind.Object; value = new { items = new[] { new { sessionId = "test", updatedAt = 1791552000000L, running = Running, agentAvailable = true } } }; }
            else if (e.Text("method") == "session/projections") value = new { asOfSeq = Seq, values = new { inbox = new Dictionary<string, object[]> { ["next-turn"] = PendingInput ? [new { id = "pending" }] : [], ["next-step"] = [] } } };
            else if (e.Text("method") == "session/page")
            {
                Check(args.At("request").Number("maxMessages") == 1 && args.At("request").Number("throughSeq") == Seq, "Outcome reads use a bounded message window at the fresh projection cursor");
                PageReads++;
                if (StartDuringPage) Running = true;
                if (PageUnavailable) return new(HttpStatusCode.NotFound);
                value = new { records = EndReason.Length == 0 ? Array.Empty<object>() : new object[] { new { type = "event", @event = new { type = "turn/end", data = new { reason = new { kind = EndReason } } } } } };
            }
            else if (e.Text("method") == "account/getState") value = new { status = BadState ? "unknown" : SignedOut ? "signed-out" : "credential-stored" };
            else if (e.Text("method") == "session/modelCatalog") value = new { @default = new { provider = Provider } };
            else if (e.Text("method") == "settings/describe") value = new { namespaces = new object[] { new { ns = "llm-deepseek", value = new { apiKeyEnv = "DEEPSEEK_API_KEY", baseURL = "https://api.deepseek.com/anthropic" } }, new { ns = "llm-pi-ai", value = new { providers = new Dictionary<string, object> { ["custom-gateway"] = new { apiKeyEnv = "CUSTOM_API_KEY" } } } } } };
            else if (e.Text("method") == "credentials/describe") value = new Dictionary<string, object> { [args.At("refs")[0].GetString()!] = new { configured = KeyConfigured, source = "file" } };
            else if (e.Text("method") == "account/getBalance") { SawClient = args.At("client").Text("locale") == "zh-CN"; value = NullBalance ? null : new { status = "ready", value = new[] { new { currency = "CNY", balance = "7.25" } }, bonusWallets = Array.Empty<object>() }; }
            else throw new Exception("Unexpected RPC " + e.Text("method"));
            return new HttpResponseMessage(Status) { Content = new StringContent(JsonSerializer.Serialize(new { type = "server-response", rpcId = InvalidId ? "wrong" : e.Text("rpcId"), result = new { ok = !RpcError, value } }), Encoding.UTF8, "application/json") };
        }
    }

    private const string ServerScript = """
    const http = require('node:http');
    const fs = require('node:fs');
    fs.mkdirSync(process.env.DSH_HOME, {recursive:true});
    const server = http.createServer(async (req,res) => {
      if (req.method === 'GET') {
        res.writeHead(303, {'Set-Cookie':'dsh-auth-test=test; Path=/; HttpOnly', Location:'./'}); res.end(); return;
      }
      if (req.headers.cookie !== 'dsh-auth-test=test') { res.writeHead(401);res.end();return; }
      let body='';for await(const chunk of req) body+=chunk;
      const input=JSON.parse(body);
      const value=input.method==='session/list' ? {items:[{sessionId:'test-session',updatedAt:Date.now(),running:false,agentAvailable:true,projections:{values:{title:'Isolated test'}}}]} : {status:'signed-out'};
      res.setHeader('Content-Type','application/json'); res.end(JSON.stringify({type:'server-response',rpcId:input.rpcId,result:{ok:true,value}}));
    });
    server.listen(0,'127.0.0.1',()=>console.log(`dsh web: http://127.0.0.1:${server.address().port}/?token=isolated-test`));
    """;
}
