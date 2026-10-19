using System;
using System.Collections.Generic;
using System.Linq;
using Perch.Windows;

// Phase 3, mirroring macOS SessionChangeTrackerTests: status notices, the draft-written check and the
// handoff target order.
internal static class NoticeTests
{
    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
    }

    private static Session S(string id, string status) => new(id, "标题", status, DateTimeOffset.UtcNow);

    private static string Ids(List<Session> changes) => string.Join(",", changes.Select(c => c.Id + ":" + c.Status));

    public static void Run()
    {
        SessionChanges();
        Drafts();
        Targets();
    }

    private static void SessionChanges()
    {
        var start = new SessionChangeTracker();
        Check(start.Update([S("a", "已完成"), S("b", "等待输入")]).Count == 0, "Conversations finished before start are not reported");
        Check(start.Update([S("a", "已完成"), S("b", "等待输入")]).Count == 0, "An unchanged list reports nothing");

        var t = new SessionChangeTracker();
        t.Update([S("a", "运行中"), S("b", "运行中"), S("c", "运行中")]);
        Check(Ids(t.Update([S("a", "已完成"), S("b", "等待输入"), S("c", "遇到问题")])) == "a:已完成,b:等待输入,c:遇到问题", "Running to completed, waiting or failed is reported");
        Check(t.Update([S("a", "已完成"), S("b", "等待输入"), S("c", "遇到问题")]).Count == 0, "Each change is reported once");
        Check(t.Update([S("b", "运行中")]).Count == 0, "Waiting to running is not reported");
        Check(Ids(t.Update([S("b", "已完成")])) == "b:已完成", "Running again then completed is reported");

        var stopped = new SessionChangeTracker();
        stopped.Update([S("a", "运行中")]);
        Check(stopped.Update([S("a", "已停止")]).Count == 0, "Stopped is not reported");
        Check(stopped.Update([S("a", "已完成")]).Count == 0, "Stopped to completed is not reported");

        var fresh = new SessionChangeTracker();
        fresh.Update([]);
        Check(Ids(fresh.Update([S("old", "已完成"), S("new", "等待输入"), S("busy", "运行中")])) == "new:等待输入", "Only a new conversation that is waiting is reported");

        var missing = new SessionChangeTracker();
        missing.Update([S("a", "运行中"), S("b", "已完成")]);
        Check(missing.Update([]).Count == 0, "A failed read reports nothing");
        Check(Ids(missing.Update([S("a", "已完成"), S("b", "已完成")])) == "a:已完成", "A running conversation missing from one read is still noticed");
    }

    private static void Drafts()
    {
        var writing = new DraftWatch("p");
        Check(!writing.Observe(null, true) && !writing.Observe(0, true) && !writing.Observe(0, false) && !writing.Observe(120, false) && !writing.Observe(480, false), "A draft still being written is not reported");

        var done = new DraftWatch("p");
        Check(!done.Observe(900, true) && !done.Observe(900, true), "The source is still running");
        Check(done.Observe(900, false), "A stable draft is reported once the source stops");
        Check(!done.Observe(900, false) && !done.Observe(1200, false) && !done.Observe(1200, false), "It is reported once");

        var rewritten = new DraftWatch("p");
        Check(!rewritten.Observe(300, false) && !rewritten.Observe(null, false) && !rewritten.Observe(300, false) && rewritten.Observe(300, false), "A removed and rewritten draft needs two stable polls");
    }

    private static void Targets()
    {
        var now = DateTimeOffset.UtcNow;
        Check(HandoffTargets.Remaining(new Quota([new("5h", 20, now.AddHours(1)), new("周", 70, now.AddDays(1))], now, ""), now) == 30, "The tightest window decides");
        Check(HandoffTargets.Remaining(new Quota([new("5h", 95, now.AddMinutes(-1)), new("周", 40, now.AddDays(1))], now, ""), now) == 60, "A window that already reset counts as full");
        Check(HandoffTargets.Remaining(new Quota([], now, ""), now) == null && HandoffTargets.Remaining(null, now) == null, "No windows, no number");

        var left = new Dictionary<string, double> { ["low"] = 12, ["high"] = 80, ["mid"] = 50 };
        var ordered = HandoffTargets.Ordered(["none-1", "low", "high", "none-2", "mid"], id => left.TryGetValue(id, out var v) ? v : null);
        Check(string.Join(",", ordered) == "high,mid,low,none-1,none-2", "Most quota first; accounts without data keep their order at the end");
        Check(HandoffTargets.Label(61.6) == "剩 62%" && HandoffTargets.Label(null) == null, "Menu label");
    }
}
