using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Perch.Windows;

// What clicking a notice does; a notice without one opens the panel.
public abstract record NoticeAction;
public sealed record OpenSessionAction(string AccountId, string SessionId) : NoticeAction;
public sealed record ContinueHandoffAction(string HandoffId) : NoticeAction;

// macOS: PerchModel.apply / notifySessions / watchDraft.
public sealed partial class PanelModel
{
    private readonly Dictionary<string, SessionChangeTracker> trackers = [];
    private DraftWatch? draftWatch;

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

    private Quota? QuotaFor(string id) => Demo ? demoQuotas.GetValueOrDefault(id) : Quotas.Get(id);

    /// Other accounts a conversation can move to, most quota left first.
    public List<Account> HandoffTargetsFor(Account source)
    {
        var now = DateTimeOffset.UtcNow;
        return HandoffTargets.Ordered(Store.Accounts.Where(a => a.Id != source.Id), a => HandoffTargets.Remaining(QuotaFor(a.Id), now));
    }

    /// "名称（客户端）· 剩 62%"; no number when the account has no quota data.
    public string HandoffTargetLabel(Account target)
    {
        var name = target.Name + "（" + Label(target.App) + "）";
        return HandoffTargets.Label(HandoffTargets.Remaining(QuotaFor(target.Id), DateTimeOffset.UtcNow)) is { } left ? name + " · " + left : name;
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

        var pending = Handoffs.Pending;
        if (NotifySessionChanges)
        {
            // `codex exec` runs are what the subagent panel shows. When a pending handoff's draft is already
            // written, the draft notice from WatchDraft stands in for its source's completion.
            var drafting = pending != null && DraftNoticeDue(pending) ? pending.SessionId : null;
            NotifySessions(changes.Where(c => !c.Session.Exec && (c.Session.Id != drafting || c.Session.Status != "已完成")).ToList());
        }

        WatchDraft(pending);
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

    // Once the draft has stopped growing and the source conversation has stopped, offer to continue.
    private void WatchDraft(PendingHandoff? pending)
    {
        // A handoff that already copied its document only needs a retry, which the panel offers.
        if (pending is not { DocumentPath: null } || HandoffBusy)
        {
            draftWatch = null;
            return;
        }

        if (draftWatch?.HandoffId != pending.Id)
            draftWatch = new(pending.Id);
        // Without the source row (an unreadable database, a removed account) nothing says it stopped: wait.
        var source = snapshots.GetValueOrDefault(pending.SourceId)?.Sessions.FirstOrDefault(s => s.Id == pending.SessionId);
        var target = Store.Accounts.FirstOrDefault(a => a.Id == pending.TargetId);
        if (source == null || !draftWatch.Observe(DraftSize(pending), SessionChangeTracker.Active(source.Status)) || target == null)
            return;
        var place = pending.SameAccount ? target.Name + " 的新对话" : target.Name;
        Notice?.Invoke("交接文档已写好", "点通知或 Perch 里的“继续接力”，复制文档并打开 " + place + "。", new ContinueHandoffAction(pending.Id));
    }

    // The draft is written but its notice has not gone out yet, so that notice will stand in for the source's
    // completion. Without a draft the source's completion is notified as usual.
    private bool DraftNoticeDue(PendingHandoff pending) =>
        pending.DocumentPath == null && DraftSize(pending) > 0 && !(draftWatch?.HandoffId == pending.Id && draftWatch.Reported);

    private long? DraftSize(PendingHandoff pending)
    {
        var file = new FileInfo(Handoffs.Draft(pending));
        return file.Exists ? file.Length : null;
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
            case ContinueHandoffAction next:
                if (Handoffs.Pending?.Id != next.HandoffId || HandoffBusy)
                    return false;
                // Failures (the source still running, the target not opening) arrive as a tray message.
                Run(() => Finish(false));
                return true;
            default:
                return false;
        }
    }
}
