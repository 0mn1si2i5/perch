using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Perch.Windows;

// Defects fixed in the Windows phase 2 pass: unchanged saves, one-time recovery notices,
// the 30-minute stall rule, recycling and bringing windows forward.
internal static class RegressionTests
{
    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
    }

    private static bool Throws<T>(Action action) where T : Exception
    {
        try
        {
            action();
            return false;
        }
        catch (T)
        {
            return true;
        }
    }

    public static void Run(string root)
    {
        SavesOnlyChanges(Path.Combine(root, "save-on-change"));
        RecoveryNoticesOnce(Path.Combine(root, "recovery-once"));
        StallThreshold();
        Recycling(Path.Combine(root, "recycle"));
        BringingForward(root);
        ClaudeHistoryOwnership(Path.Combine(root, "claude-history"));
    }

    private static void ClaudeHistoryOwnership(string dir)
    {
        Directory.CreateDirectory(dir);
        var now = DateTimeOffset.UtcNow;
        long older = now.AddHours(-2).ToUnixTimeMilliseconds(), newer = now.AddMinutes(-10).ToUnixTimeMilliseconds();
        File.WriteAllText(Path.Combine(dir, "plan-usage-history.json"), "{\"version\":2,\"samples\":[{\"t\":" + older + ",\"org\":\"org-new\",\"u\":{\"fh\":10,\"sd\":20}},{\"t\":" + newer + ",\"org\":\"org-old\",\"u\":{\"fh\":70,\"sd\":60}}]}");
        Check(QuotaService.ClaudeHistory(dir, "org-new")?.Windows.Last().Used == 20, "History fallback keeps the current organization's samples");
        Check(QuotaService.ClaudeHistory(dir) == null, "With several organizations and none known, history shows nothing");
        File.WriteAllText(Path.Combine(dir, "config.json"), "{\"lastKnownAccountUuid\":\"acct-1\"}");
        Check(QuotaService.ClaudeOwner(dir) == "acct-1" && QuotaService.ClaudeOwner(Path.Combine(dir, "missing")) == "", "The signed-in Claude account is read from config.json");
    }

    private static void SavesOnlyChanges(string dir)
    {
        var store = new Store(dir);
        store.Add(new Account
        {
            Name = "A",
            ProfilePath = Path.Combine(dir, "a"),
            SessionRoot = Path.Combine(dir, "a")
        });
        var accounts = Path.Combine(dir, "accounts.json");
        var preferences = Path.Combine(dir, "preferences.json");
        var old = new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(accounts, old);
        File.SetLastWriteTimeUtc(preferences, old);
        store.Save();
        Check(File.GetLastWriteTimeUtc(accounts) == old && File.GetLastWriteTimeUtc(preferences) == old, "Saving unchanged state must not rewrite either file");
        new Store(dir).Save();
        Check(File.GetLastWriteTimeUtc(accounts) == old && File.GetLastWriteTimeUtc(preferences) == old, "A freshly loaded store must not rewrite what it read");
        store.Preferences.PetLeft = 12;
        store.Save();
        Check(File.GetLastWriteTimeUtc(preferences) != old && File.GetLastWriteTimeUtc(accounts) == old, "Only the changed file is written");
        Check(new Store(dir).Preferences.PetLeft == 12, "The changed preference survives restart");
    }

    private static void RecoveryNoticesOnce(string dir)
    {
        _ = new Store(dir);
        File.WriteAllText(Path.Combine(dir, "preferences.json"), "{broken");
        var store = new Store(dir);
        Check(store.TakeRecoveryDetail() != null && store.TakeRecoveryDetail() == null, "A preferences recovery notice is shown once");
    }

    private static void StallThreshold()
    {
        var now = DateTimeOffset.UtcNow;
        Check(Sessions.Status("inProgress", true, now.AddMinutes(-5)) == "运行中", "A recent Codex turn is running");
        Check(Sessions.Status("inProgress", true, now.AddMinutes(-5), true) == "等待输入", "A recent Codex turn can wait for input");
        Check(Sessions.Status("inProgress", true, now.AddMinutes(-31)) == "已停止", "A Codex turn untouched for 30 minutes is stopped, as on macOS");
    }

    private static void Recycling(string dir)
    {
        var store = new Store(dir);
        var account = new Account
        {
            Name = "A",
            ProfilePath = Path.Combine(dir, "profile"),
            SessionRoot = Path.Combine(dir, "profile")
        };
        Check(Throws<IOException>(() => store.CheckRecycle(account, RunState.Running)), "A profile in use by a running client is not recycled");
        Check(Throws<IOException>(() => store.CheckRecycle(account, RunState.Unknown)), "A profile is not recycled when it is unknown whether a client uses it");
        Check(Throws<IOException>(() => store.CheckRecycle(new Account { ProfilePath = store.Root }, RunState.NotRunning)), "Perch's own root is not recycled");
        Check(Throws<IOException>(() => store.CheckRecycle(new Account { ProfilePath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) }, RunState.NotRunning)), "The user folder is not recycled");
        store.CheckRecycle(account, RunState.NotRunning);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var msix = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages", "Claude_pzs8sxrjxfjjc", "LocalCache", "Roaming", "Claude");
        Check(Clients.IsDefaultProfile("codex", Path.Combine(appData, "Codex")) && Clients.IsDefaultProfile("claude", msix + "\\"), "Default data is recognized by path, without discovery");
        Check(!Clients.IsDefaultProfile("codex", msix) && !Clients.IsDefaultProfile("claude", account.ProfilePath), "Other folders are not default data");
        Check(Throws<IOException>(() => store.CheckRecycle(new Account { App = "claude", ProfilePath = msix }, RunState.NotRunning)), "A client's default data is not recycled even when not flagged Default");

        var copy = account.Copy();
        Check(copy.SameData(account), "A poll's copy matches the account it was taken from");
        account.ProfilePath = Path.Combine(dir, "moved");
        Check(!copy.SameData(account) && copy.ProfilePath != account.ProfilePath, "A relocation during a poll does not change the copy, and its result is discarded");
        account.ProfilePath = copy.ProfilePath;

        // From the process scan to the decision: what the scan or discovery could not see is never "not running".
        var installed = new List<Client> { new("codex", @"C:\Apps\ChatGPT.exe", account.ProfilePath, account.SessionRoot) };
        RunState StateAfterScan(ProcessScan scan, List<Client> clients)
        {
            var c = new Clients(() => scan, clients);
            c.Scan().Wait();
            return c.State(account);
        }

        var unreadable = StateAfterScan(new ProcessScan([], false), installed);
        Check(unreadable == RunState.Unknown && Throws<IOException>(() => store.CheckRecycle(account, unreadable)), "A process the scan could not read blocks recycling");
        var undiscovered = StateAfterScan(new ProcessScan([], true), []);
        Check(undiscovered == RunState.Unknown && Throws<IOException>(() => store.CheckRecycle(account, undiscovered)), "A failed client discovery blocks recycling");
        var elsewhere = StateAfterScan(new ProcessScan([new Running(7, @"D:\Other\ChatGPT.exe", "ChatGPT.exe \"--user-data-dir=" + account.ProfilePath + "\"", 0)], false), []);
        Check(elsewhere == RunState.Running, "A client outside the discovered install is still seen as running");
        Check(StateAfterScan(new ProcessScan([new Running(8, @"C:\Apps\Claude.exe", "Claude.exe \"--user-data-dir=" + account.ProfilePath + "\"", 0)], true), installed) == RunState.NotRunning, "Another client's process does not count");
        Check(StateAfterScan(new ProcessScan([], true), installed) == RunState.NotRunning, "A complete scan with no match allows recycling");
    }

    private static void BringingForward(string root)
    {
        Check(Clients.NeedsLaunch(null) && Clients.NeedsLaunch(new Running(1, "ChatGPT.exe", "ChatGPT.exe", 0)), "Stopped clients and clients in the tray are started");
        Check(!Clients.NeedsLaunch(new Running(1, "ChatGPT.exe", "ChatGPT.exe", 42)), "A client with a window is brought forward, not started again");
        Check(Clients.ShowCommand(true) == 9 && Clients.ShowCommand(false) == 5, "Only a minimized window is restored; a maximized one stays maximized");
        var codex = new Account
        {
            App = "codex",
            ProfilePath = Path.Combine(root, "codex profile"),
            SessionRoot = Path.Combine(root, "codex profile", "codex-home")
        };
        var info = Clients.StartInfo(codex, new Client("codex", Path.Combine(root, "ChatGPT.exe"), "", ""));
        Check(info.ArgumentList.Single() == "--user-data-dir=" + codex.ProfilePath && info.Environment["CODEX_HOME"] == codex.SessionRoot, "Starting a tray client again uses the account's own profile and home");
        var direct = Clients.StartInfo(new Account { App = "codex", Default = true, SessionRoot = codex.SessionRoot }, new Client("codex", Path.Combine(root, "ChatGPT.exe"), "", ""));
        Check(direct.ArgumentList.Count == 0, "The default account starts without a profile argument");
    }
}
