using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Perch.Windows;

// Defects fixed in the Windows phase 2 pass: unchanged saves, one-time recovery notices,
// the 30-minute stall rule, handoff launch failures, recycling and bringing windows forward.
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
        HandoffLaunchFailure(Path.Combine(root, "handoff-launch"));
        Recycling(Path.Combine(root, "recycle"));
        BringingForward(root);
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
        var handoffs = new Handoffs(store);
        Store.PrivateDirectory(store.Handoffs);
        File.WriteAllText(Path.Combine(store.Handoffs, "pending.json"), "{broken");
        Check(handoffs.Pending == null && handoffs.TakeRecoveryDetail() != null, "A corrupt pending handoff is reported");
        Check(handoffs.Pending == null && handoffs.TakeRecoveryDetail() == null, "A corrupt pending handoff is reported only once");
    }

    private static void StallThreshold()
    {
        var now = DateTimeOffset.UtcNow;
        Check(Sessions.Status("inProgress", true, now.AddMinutes(-5)) == "运行中", "A recent Codex turn is running");
        Check(Sessions.Status("inProgress", true, now.AddMinutes(-5), true) == "等待输入", "A recent Codex turn can wait for input");
        Check(Sessions.Status("inProgress", true, now.AddMinutes(-31)) == "已停止", "A Codex turn untouched for 30 minutes is stopped, as on macOS");
    }

    private static void HandoffLaunchFailure(string dir)
    {
        var store = new Store(dir);
        var source = new Account
        {
            Name = "Source",
            ProfilePath = Path.Combine(dir, "source"),
            SessionRoot = Path.Combine(dir, "source")
        };
        var target = new Account
        {
            Name = "Target",
            App = "claude",
            ProfilePath = Path.Combine(dir, "target"),
            SessionRoot = Path.Combine(dir, "target")
        };
        store.Add(source);
        store.Add(target);
        var handoffs = new Handoffs(store);
        var now = DateTimeOffset.UtcNow;
        var pending = handoffs.Prepare(source, target, new Session("s", "Task", "已完成", now));
        Check(Throws<InvalidOperationException>(() => Handoffs.EnsureSourceStopped(pending, [new Session("s", "Task", "运行中", now)])), "Continuing waits while the source still runs");
        Check(Throws<InvalidOperationException>(() => Handoffs.EnsureSourceStopped(pending, [new Session("s", "Task", "等待输入", now)])), "Continuing waits while the source waits for input");
        Handoffs.EnsureSourceStopped(pending, [new Session("s", "Task", "已完成", now), new Session("other", "Other", "运行中", now)]);

        File.WriteAllText(handoffs.Draft(pending), "# Launch failure");
        string? copied = null;
        var (record, error) = handoffs.Deliver(text => copied = text, () => throw new IOException("数据目录不存在，请重新定位。")).GetAwaiter().GetResult();
        Check(error is IOException && copied?.Contains("# Launch failure") == true && copied.Contains(record.Path), "A failed launch still copies the document and its path");
        Check(File.Exists(record.Path) && handoffs.History.Single().Id == record.Id, "A failed launch still records the handoff");
        Check(handoffs.Pending?.Id == pending.Id, "A failed launch keeps the pending handoff");

        var (retry, asyncError) = handoffs.Deliver(_ => { }, () => Task.FromException(new System.ComponentModel.Win32Exception(2))).GetAwaiter().GetResult();
        Check(asyncError is System.ComponentModel.Win32Exception && handoffs.Pending?.Id == pending.Id, "A client that fails to start keeps the pending handoff");
        Check(retry.Id == record.Id && retry.Path == record.Path && handoffs.History.Count == 1 && Directory.GetFiles(store.Handoffs, "*.md").Length == 1, "A retry reuses the first copy and record");

        File.WriteAllText(handoffs.Draft(pending), "# Launch failure, revised");
        copied = null;
        var (revised, _) = handoffs.Deliver(text => copied = text, () => throw new IOException("数据目录不存在，请重新定位。")).GetAwaiter().GetResult();
        Check(revised.Id == record.Id && revised.Path != record.Path && File.ReadAllText(revised.Path) == "# Launch failure, revised" && copied?.Contains(revised.Path) == true, "A rewritten draft is copied again under the same record");
        Check(handoffs.History.Single().Path == revised.Path && File.Exists(record.Path), "The record points at the new copy; the earlier copy stays");

        var (_, refused) = handoffs.Deliver(_ => { }, () => throw new ForegroundRefusedException()).GetAwaiter().GetResult();
        Check(refused == null && handoffs.Pending == null && handoffs.History.Count == 1, "A window shown without focus counts as opened and clears the pending handoff");

        var next = handoffs.Prepare(source, target, new Session("s2", "Task", "已完成", now));
        File.WriteAllText(handoffs.Draft(next), "# Next");
        var (fresh, none) = handoffs.Deliver(_ => { }, () => Task.CompletedTask).GetAwaiter().GetResult();
        Check(none == null && fresh.Id != record.Id && handoffs.Pending == null && handoffs.History.Count == 2, "A new handoff gets its own record and clears once the target opens");
        var old = JsonSerializer.Deserialize<PendingHandoff>("{\"Id\":\"old\",\"SourceId\":\"a\",\"TargetId\":\"b\",\"SessionId\":\"s\",\"Title\":\"task\",\"Created\":\"2026-01-01T00:00:00Z\"}")!;
        Check(old.DocumentPath == null && old.RecordId == null, "Pending handoffs written before retries were tracked still load");
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
        Check(Throws<IOException>(() => store.CheckRecycle(account, true)), "A profile in use by a running client is not recycled");
        Check(Throws<IOException>(() => store.CheckRecycle(new Account { ProfilePath = store.Root }, false)), "Perch's own root is not recycled");
        Check(Throws<IOException>(() => store.CheckRecycle(new Account { ProfilePath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) }, false)), "The user folder is not recycled");
        store.CheckRecycle(account, false);
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
