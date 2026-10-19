using System;
using System.Collections.Generic;
using System.Linq;

namespace Perch.Windows;

// macOS: SessionChanges.swift. Compares one account's conversations between polls. The first update only
// records them, so a conversation that finished before Perch started is never reported.
public sealed class SessionChangeTracker
{
    private Dictionary<string, string>? last;

    public static bool Active(string status) => status is "运行中" or "等待输入";

    /// Conversations seen running or waiting on an earlier poll that have now completed, failed or started
    /// waiting, plus one that first appears already waiting. One merely new to the list and already finished
    /// is not reported: nothing says when it finished.
    public List<Session> Update(IEnumerable<Session> sessions)
    {
        var list = sessions.ToList();
        var current = new Dictionary<string, string>();
        foreach (var s in list)
            current.TryAdd(s.Id, s.Status);
        var previous = last;
        // A conversation seen running keeps that record when one read misses it, so its finish is still noticed.
        last = new Dictionary<string, string>(current);
        foreach (var (id, status) in previous ?? [])
            if (Active(status))
                last.TryAdd(id, status);
        if (previous == null)
            return [];
        var reported = new HashSet<string>();
        return list.Where(s => reported.Add(s.Id) && (previous.GetValueOrDefault(s.Id), s.Status) switch
        {
            ("运行中", "等待输入" or "已完成" or "遇到问题") => true,
            ("等待输入", "已完成" or "遇到问题") => true,
            (null, "等待输入") => true,
            _ => false
        }).ToList();
    }
}

// macOS: DraftWatch.swift. The source has finished writing a handoff draft once the file exists, is not empty,
// kept the same size over two polls in a row, and the source conversation is no longer running. Says so once.
public sealed class DraftWatch(string handoffId)
{
    private long? size;
    private bool reported;
    public string HandoffId { get; } = handoffId;
    public bool Reported => reported;

    public bool Observe(long? next, bool sourceBusy)
    {
        var before = size;
        size = next;
        if (reported || sourceBusy || next is not > 0 || next != before)
            return false;
        reported = true;
        return true;
    }
}

// macOS: HandoffTargetOrder.swift. The handoff menu lists the accounts with the most quota left first.
public static class HandoffTargets
{
    /// Most quota left first; targets without quota data keep their order at the end.
    public static List<T> Ordered<T>(IEnumerable<T> targets, Func<T, double?> remaining) =>
        targets.Select((target, index) => (target, index, left: remaining(target)))
            .OrderBy(t => t.left == null ? 1 : 0)
            .ThenByDescending(t => t.left ?? 0)
            .ThenBy(t => t.index)
            .Select(t => t.target)
            .ToList();

    /// "剩 62%", or null when there is no quota data to show.
    public static string? Label(double? remaining) => remaining is { } left ? "剩 " + Math.Round(left, MidpointRounding.AwayFromZero) + "%" : null;

    /// Percent left in the tightest window; a window that has already reset counts as full. Null without windows.
    public static double? Remaining(Quota? quota, DateTimeOffset now) => quota is { Windows.Count: > 0 }
        ? quota.Windows.Min(w => w.Resets is { } r && r <= now ? 100 : Math.Clamp(100 - w.Used, 0, 100))
        : null;
}
