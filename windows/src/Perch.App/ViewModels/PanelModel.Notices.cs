using System;
using System.Collections.Generic;
using System.Linq;

namespace Perch.Windows;

// What clicking a notice does; a notice without one opens the panel.
public abstract record NoticeAction;
public sealed record OpenSessionAction(string AccountId, string SessionId) : NoticeAction;

// macOS: PerchModel.apply / notifySessions.
public sealed partial class PanelModel
{
    private readonly Dictionary<string, SessionChangeTracker> trackers = [];

    /// A tray notice: title, body and what clicking it does.
    public event Action<string, string, NoticeAction?>? Notice;

    public bool NotifySessionChanges
    {
        get => Store.Preferences.NotifySessionChanges;
        set
        {
            Store.Preferences.NotifySessionChanges = value;
            Run(Store.Save);
            Changed();
        }
    }

    // Runs after every poll with the accounts that poll read.
    private void CheckChanges(Account[] read)
    {
        foreach (var id in trackers.Keys.Except(Store.Accounts.Select(a => a.Id)).ToArray())
            trackers.Remove(id);
        var changes = new List<(Account Account, Session Session)>();
        foreach (var account in read)
        {
            if (!Store.Accounts.Any(a => a.Id == account.Id) || !snapshots.TryGetValue(account.Id, out var snapshot))
                continue;
            if (!trackers.TryGetValue(account.Id, out var tracker))
                trackers[account.Id] = tracker = new();
            changes.AddRange(tracker.Update(snapshot.Sessions).Select(s => (account, s)));
        }

        // `codex exec` runs are what the subagent panel shows.
        if (NotifySessionChanges)
            NotifySessions(changes.Where(c => !c.Session.Exec).ToList());
    }

    // One notice per poll: a single change opens its conversation when clicked, several open the panel.
    private void NotifySessions(List<(Account Account, Session Session)> changes)
    {
        if (changes.Count == 0)
            return;
        static string Line((Account Account, Session Session) c) => c.Account.Name + "：" + (c.Session.Title.Length > 60 ? c.Session.Title[..60] : c.Session.Title);
        if (changes.Count == 1)
        {
            var (account, session) = changes[0];
            var title = session.Status switch
            {
                "等待输入" => "对话在等你回应",
                "遇到问题" => "对话遇到问题",
                _ => "对话已完成"
            };
            Notice?.Invoke(title, Line(changes[0]), new OpenSessionAction(account.Id, session.Id));
            return;
        }

        var lines = changes.Take(3).Select(c => Line(c) + " · " + c.Session.Status).ToList();
        if (changes.Count > 3)
            lines.Add($"另有 {changes.Count - 3} 个");
        Notice?.Invoke($"{changes.Count} 个对话有新状态", string.Join("\n", lines), null);
    }

    /// A clicked notice. Returns false when the panel should open instead.
    public bool Perform(NoticeAction action)
    {
        switch (action)
        {
            case OpenSessionAction open:
                var account = Store.Accounts.FirstOrDefault(a => a.Id == open.AccountId);
                if (account == null)
                    return false;
                var session = snapshots.GetValueOrDefault(account.Id)?.Sessions.FirstOrDefault(s => s.Id == open.SessionId);
                Run(() => session != null ? OpenSession(account, session) : Clients.Open(account));
                return true;
            default:
                return false;
        }
    }
}
