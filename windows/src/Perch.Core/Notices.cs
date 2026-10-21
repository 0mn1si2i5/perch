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
