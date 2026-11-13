using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Perch.Windows;

/// Opt-in smoke against installed dsh packages. No prompts, sign-in changes, or model calls.
internal static class DshSmoke
{
    public static async Task Discovered(string? hostExecutable = null)
    {
        var found = DshDiscovery.Discover();
        if (found.Count == 0) throw new IOException("No real dsh installation discovered");
        Console.WriteLine($"Discovered {found.Count} real installations; first={found[0].Source}, version={found[0].Version}");
        var root = Path.GetFullPath(Path.Combine("scratch", "dsh-discovery-smoke-" + Guid.NewGuid().ToString("N")));
        var store = new Store(root);
        var account = new Account { App = "dsh", Name = "Discovery smoke", ProfilePath = Path.Combine(root, "isolated home"), Dsh = new() };
        account.SessionRoot = account.ProfilePath;
        Store.PrivateDirectory(account.ProfilePath);
        store.Add(account);
        using var service = new DshService(store, hostExecutable);
        var external = new Account { App = "dsh", Name = "Manual fallback smoke", ProfilePath = Path.Combine(root, "external"), Dsh = new() { Mode = "external" } };
        try
        {
            var url = await service.Ensure(account);
            var snapshot = await service.Read(account);
            if (!snapshot.Running || snapshot.Cached || snapshot.Sessions.Count != 0) throw new IOException("Discovered installation failed isolated Web/RPC check");
            var child = service.State(account).Read()!.ChildPid;
            await service.Connect(external, url);
            if (!(await service.Read(external)).Running) throw new IOException("Manual fallback could not authenticate");
            await service.Stop(external);
            using var restored = new DshService(new Store(root), hostExecutable);
            await restored.Ensure(account);
            if (restored.State(account).Read()!.ChildPid != child) throw new IOException("Reconnect launched a duplicate runtime");
            Console.WriteLine("PASS real discovered dsh: isolated startup, authenticated sessions, manual URL fallback, disconnect and recovery; no model calls or personal home changes");
        }
        finally { await service.Stop(account); }
    }

    public static void PrepareApiBalanceUi(string root, string accountId, string isolatedRoot)
    {
        var store = new Store(root);
        var account = store.Accounts.Single(a => a.Id == accountId && a.App == "dsh");
        using var service = new DshService(store);
        var authorization = service.State(account).Read()?.Authorization ?? throw new IOException("dsh 尚未连接。");
        var isolated = new Store(isolatedRoot);
        isolated.Preferences.DismissedDefaults = ["codex", "claude"];
        var clone = new Account { App = "dsh", Name = "DeepSeek API 余额验收", ProfilePath = Path.Combine(isolated.Root, "external"), SessionRoot = isolated.Root,
            Dsh = new() { Mode = "external", BalanceHome = account.Dsh?.Mode == "external" ? account.Dsh.BalanceHome : account.ProfilePath } };
        isolated.Add(clone);
        using var testService = new DshService(isolated);
        testService.State(clone).Write(new("ready", Authorization: authorization));
        Console.WriteLine("Prepared isolated normal-product UI check; only paths and DPAPI-encrypted local authorization saved, no API key copied");
    }

    // Explicitly opted-in real balance check through the same service used by the panel.
    // Does not save accounts, alter credentials, start/stop dsh or print keys/wallet amounts.
    public static async Task CheckApiBalance(string root, string accountId)
    {
        var store = new Store(root);
        var account = store.Accounts.Single(a => a.Id == accountId && a.App == "dsh");
        using var service = new DshService(store);
        var result = await service.Balance(account, true);
        if (result.ApiBalance is not { Observed: not null, Cached: false } balance || balance.Balances.Count == 0)
            throw new IOException("真实 API 余额未通过：" + (result.ApiBalance?.Detail ?? "当前默认模型不使用 DeepSeek 官方 API"));
        Console.WriteLine($"PASS real dsh API balance: authenticated official response, walletRows={balance.Balances.Count}, observed=true, cached=false; no credential writes requested");
    }

    public static async Task Run(string source, string npm, string? hostExecutable = null, bool openBrowser = false)
    {
        var root = Path.GetFullPath(Path.Combine("scratch", "dsh-smoke-" + Guid.NewGuid().ToString("N")));
        var store = new Store(root);
        var a = Make("source", source, "Source build");
        var b = Make("npm", npm, "npm install");
        Account Make(string mode, string install, string name)
        {
            var home = Path.Combine(root, mode + " home");
            Store.PrivateDirectory(home);
            var account = new Account { App = "dsh", Name = name, ProfilePath = home, SessionRoot = home, Dsh = new() { Mode = mode, InstallationPath = Path.GetFullPath(install) } };
            DshInstallation.Resolve(account);
            store.Add(account);
            return account;
        }
        using var service = new DshService(store, hostExecutable);
        try
        {
            await Task.WhenAll(service.Ensure(a), service.Ensure(b));
            foreach (var account in new[] { a, b })
            {
                var snapshot = await service.Read(account);
                if (!snapshot.Running || snapshot.Cached) throw new Exception(account.Name + " failed to connect");
                var quota = await service.Balance(account);
                Console.WriteLine($"PASS real dsh {account.Dsh!.Mode}: authenticated, sessions={snapshot.Sessions.Count}, balance={quota.Detail}");
            }
            var existing = new Account { App = "dsh", Name = "Manual connection", ProfilePath = Path.Combine(root, "external"), SessionRoot = root, Dsh = new() { Mode = "external" } };
            await service.Connect(existing, await service.Ensure(a));
            if (!(await service.Read(existing)).Running) throw new Exception("Manual connection failed");
            await service.Stop(existing);
            if (!(await service.Read(a)).Running) throw new Exception("Disconnect stopped externally owned dsh");
            using var resumed = new DshService(new Store(root));
            await resumed.Ensure(a);
            if (resumed.State(a).Read()!.ChildPid != service.State(a).Read()!.ChildPid) throw new Exception("Recovery duplicated runtime");
            Console.WriteLine("PASS real dsh: two homes, manual connection/disconnect, panel reconnection without duplicate process");
            Console.WriteLine("Isolated smoke data: " + root);
            if (openBrowser)
            {
                var url = await service.Ensure(a);
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
                Console.WriteLine("Browser inspection origin: " + new Uri(url).GetLeftPart(UriPartial.Authority));
                await Task.Delay(TimeSpan.FromSeconds(45));
            }
        }
        finally
        {
            await service.Stop(a);
            await service.Stop(b);
        }
    }
}
