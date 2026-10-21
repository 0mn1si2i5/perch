using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Security.AccessControl;
using Perch.Windows;

static class Program
{
    static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
    }

    static void Main()
    {
        var root = Path.Combine(Path.GetTempPath(), "perch-tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new Store(root);
            var a = new Account
            {
                Name = "A",
                ProfilePath = Path.Combine(root, "profile a"),
                SessionRoot = Path.Combine(root, "home")
            };
            store.Add(a);
            var b = new Account
            {
                Name = "B",
                App = "claude",
                ProfilePath = Path.Combine(root, "profile b"),
                SessionRoot = Path.Combine(root, "profile b")
            };
            store.Add(b);
            Check(new Store(root).Accounts.Count == 2, "Accounts must survive restart");
            Check(new DirectoryInfo(root).GetAccessControl().AreAccessRulesProtected, "Private root must not inherit broad ACLs");
            Check(Clients.Matches("client.exe \"--user-data-dir=" + a.ProfilePath + "\"", a), "Quoted profile paths must match");
            Check(!Clients.Matches("client.exe --user-data-dir=\"" + a.ProfilePath + " extra\"", a), "Prefix path must not match another account");
            Check(!Clients.Matches("client.exe \"--user-data-dir=" + a.ProfilePath + "\" --type=renderer", a), "Renderer is not an account root");
            Check(!Clients.Matches("client.exe", a), "An independent slot must not claim default process");
            using var quota = JsonDocument.Parse("{\"primary\":{\"usedPercent\":120,\"windowDurationMins\":10080,\"resetsAt\":2000000000}}");
            var parsed = QuotaService.ParseCodex(quota.RootElement);
            Check(parsed.Single().Name == "周" && parsed.Single().Used == 100, "Name windows by duration and clamp percentage");
            Check(Sessions.Status("inProgress", false, DateTimeOffset.UtcNow) == "已停止", "Closed clients must not look busy");
            var claude = Path.Combine(root, "claude");
            var sessionRoot = Path.Combine(claude, "local-agent-mode-sessions", "org", "user");
            Directory.CreateDirectory(sessionRoot);
            File.WriteAllText(Path.Combine(sessionRoot, "local_12345678-1234-1234-1234-123456789abc.json"), "{\"sessionId\":\"12345678-1234-1234-1234-123456789abc\",\"title\":\"Metadata title\",\"lastActivityAt\":1791552004000,\"initialMessage\":\"Must never become a title\"}");
            Directory.CreateDirectory(Path.Combine(sessionRoot, "12345678"));
            File.WriteAllText(Path.Combine(sessionRoot, "12345678", "audit.jsonl"), "{\"type\":\"result\",\"is_error\":false}\n");
            var claudeSessions = Sessions.ReadClaude(claude, true);
            Check(claudeSessions.Single().Title == "Metadata title" && claudeSessions.Single().Status == "已完成", "Desktop Claude audit lifecycle and metadata titles must parse");
            // Cached parses must still follow a client that keeps appending to the same files.
            File.AppendAllText(Path.Combine(sessionRoot, "12345678", "audit.jsonl"), "{\"type\":\"user\"}\n");
            File.WriteAllText(Path.Combine(sessionRoot, "local_12345678-1234-1234-1234-123456789abc.json"), "{\"sessionId\":\"12345678-1234-1234-1234-123456789abc\",\"title\":\"Renamed metadata\",\"lastActivityAt\":" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + "}");
            var changedSessions = Sessions.ReadClaude(claude, true);
            Check(changedSessions.Single().Title == "Renamed metadata" && changedSessions.Single().Status == "运行中", "Changed session files must not be served from the parse cache");
            Check(PanelPlacement.Overlaps(new Bounds(0, 0, 340, 570), new Bounds(300, 500, 60, 60)) && !PanelPlacement.Overlaps(new Bounds(0, 0, 340, 570), new Bounds(352, 500, 60, 60)), "Panel and pet overlap must be detected exactly");
            var ids = new System.Collections.Generic.List<string>
            {
                "a",
                "b",
                "c"
            };
            Ordering.Move(ids, "a", "c");
            Check(string.Join(",", ids) == "b,c,a", "Dragging down must move past the target");
            Ordering.Move(ids, "a", "b");
            Check(string.Join(",", ids) == "a,b,c", "Dragging up must move before the target");
            Ordering.Move(ids, "missing", "b");
            Check(ids.Count == 3, "Unknown drag sources must not mutate order");
            Check(MediaPolicy.Classify("Chrome", "Music") == "unknown", "Browser video must not be mislabeled as music");
            Check(MediaPolicy.Classify("Spotify", "Music") == "music", "Music players retain music detection");
            Check(MediaPolicy.Classify("Chrome", "Video") == "video", "Explicit video metadata wins");
            File.WriteAllText(Path.Combine(root, "session_index.jsonl"), "{\"id\":\"12345678-1234-1234-1234-123456789abc\",\"thread_name\":\"Generated title\"}\n{\"id\":\"12345678-1234-1234-1234-123456789abc\",\"thread_name\":\"Renamed title\"}\n{partial");
            Check(Sessions.ReadCodexTitles(root).Values.Single() == "Renamed title", "Latest indexed title wins even during concurrent append");
            var recoveryRoot = Path.Combine(root, "recovery");
            var recovery = new Store(recoveryRoot);
            File.WriteAllText(Path.Combine(recoveryRoot, "preferences.json"), "{broken");
            Check(new Store(recoveryRoot).Preferences.AutoQuota, "Corrupt preferences must recover to defaults");
            Check(Directory.GetFiles(recoveryRoot, "preferences.json.unreadable-*.json").Length == 1, "Corrupt preferences must be preserved");
            File.WriteAllText(Path.Combine(recoveryRoot, "accounts.json"), "{broken");
            bool badAccounts = false;
            try
            {
                _ = new Store(recoveryRoot);
            }
            catch (IOException ex)
            {
                badAccounts = ex.Message.Contains("accounts.json");
            }

            Check(badAccounts, "Corrupt accounts must block startup with their path");
            store.Preferences.SessionOrder[a.Id] = ["s"];
            store.Preferences.ExpandedAccounts.Add(a.Id);
            store.Remove(a);
            Check(!store.Preferences.SessionOrder.ContainsKey(a.Id) && !store.Preferences.ExpandedAccounts.Contains(a.Id), "Removal cleans associated preferences");
            var placed = PanelPlacement.Compute(new Bounds(0, 0, 1200, 800), new Bounds(50, 750, 60, 60), 340, 570);
            Check(placed.X == 122 && placed.Bottom == 800, "Place to the right and clamp vertically");
            var clamped = PanelPlacement.ClampPet(new Bounds(1300, 900, 100, 100), [new Bounds(0, 0, 1200, 800), new Bounds(1200, 0, 1200, 700)]);
            Check(clamped.Bottom <= 800, "Pet in a display gap must move onto a display");
            Check(SessionRouting.CanDeepLink("codex", "12345678-1234-1234-1234-123456789abc", 1), "A single Codex instance can deep-link");
            Check(!SessionRouting.CanDeepLink("codex", "12345678-1234-1234-1234-123456789abc", 2) && !SessionRouting.CanDeepLink("claude", "bad", 1), "Multiple instances and Claude cannot deep-link");
            var insertion = new System.Collections.Generic.List<string>
            {
                "a",
                "b",
                "c"
            };
            Ordering.MoveBefore(insertion, "a", "c");
            Check(string.Join(",", insertion) == "b,a,c", "Insertion line means before the target");
            var scaled = PanelPlacement.Compute(new Bounds(1920, 0, 2560, 1440), new Bounds(2000, 1200, 285, 472), 510, 855, 18);
            Check(scaled.X == 2303 && scaled.Y == 585 && scaled.Width == 510, "Physical origins and scaled dimensions stay separate");
            Check(Sessions.Status("error", true, DateTimeOffset.UtcNow) == "遇到问题", "Failed tasks must remain distinct from stopped tasks");
            FixtureTests.Run(root);
            RegressionTests.Run(root);
            NoticeTests.Run();
            Console.WriteLine("PASS: persistence, ACLs, process isolation, quota windows, task lifecycle, launch failures and session notices");
        }
        finally
        {
            if (Directory.Exists(root))
                Directory.Delete(root, true);
        }
    }
}