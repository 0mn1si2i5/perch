using System;
using System.Collections.Generic;
using System.Linq;
using Perch.Windows;

// Phase 3, mirroring macOS SessionChangeTrackerTests: status notices.
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
}
