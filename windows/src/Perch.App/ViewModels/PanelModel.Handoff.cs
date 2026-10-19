using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Perch.Windows;

public sealed partial class PanelModel
{
    private bool allHistory;
    public bool HasPending => Handoffs.Pending != null;
    public string PendingTitle => Handoffs.Pending?.Title ?? "";
    public string PendingRoute => Handoffs.Pending is { } p ? Route(AccountName(p.SourceId), AccountName(p.TargetId), p.SameAccount) + (p.Scope == Handoffs.SplitScope ? " · 拆出需求" : "") : "";
    public string PendingHint => Handoffs.Pending?.Scope == Handoffs.SplitScope ? "在源对话粘贴提示词，在末尾写上要拆出的需求再发送；文档生成后继续。" : "在源对话粘贴提示词，文档生成后继续。";
    public bool HandoffBusy
    {
        get; private set;
    }
    public string ContinueLabel => HandoffBusy ? "准备中…" : "继续接力";
    public string HistoryMore => allHistory ? "收起记录" : $"查看其余 {Math.Max(0, Handoffs.History.Count - 5)} 条";
    public bool HasHistoryMore => Handoffs.History.Count > 5;

    public void BeginHandoff(Account source, Account target, Session session, string scope = Handoffs.TaskScope)
    {
        var pending = Handoffs.Prepare(source, target, session, scope);
        try
        {
            ClipboardWriter.Set(Handoffs.Prompt(Handoffs.Draft(pending), pending.Scope));
        }
        finally
        {
            UpdateHandoffs();
        }

        if (!Demo)
            Run(async () =>
            {
                await Clients.Open(source);
                RequestHide?.Invoke();
            });
    }

    private async Task Finish(bool choose)
    {
        string? path = null;
        if (choose)
        {
            var picker = new OpenFileDialog
            {
                Filter = "Markdown|*.md",
                CheckFileExists = true
            };
            if (picker.ShowDialog() != true)
                return;
            path = picker.FileName;
        }

        var pending = Handoffs.Pending ?? throw new IOException("没有待继续的接力。");
        var target = Store.Accounts.FirstOrDefault(a => a.Id == pending.TargetId) ?? throw new IOException("目标账号已移除。");
        HandoffBusy = true;
        Changed(nameof(HandoffBusy));
        Changed(nameof(ContinueLabel));
        try
        {
            Handoffs.Transfer(ClipboardWriter.Set, path);
            UpdateHandoffs();
            if (!Demo)
                await Clients.Open(target);
            Notify(pending.SameAccount ? "接力文档已复制，请在本账号新建一个对话，粘贴发送。" : "接力文档已复制，请在目标新对话粘贴发送。");
        }
        finally
        {
            HandoffBusy = false;
            Changed(nameof(HandoffBusy));
            Changed(nameof(ContinueLabel));
        }
    }

    private string AccountName(string id) => Store.Accounts.FirstOrDefault(a => a.Id == id)?.Name ?? "已移除账号";
    // "A → B", or "A · 新对话" when the document stays in the same account.
    public static string Route(string source, string target, bool sameAccount) => sameAccount ? source + " · 新对话" : source + " → " + target;
    public void UpdateHandoffs()
    {
        Changed(nameof(HasPending));
        Changed(nameof(PendingTitle));
        Changed(nameof(PendingRoute));
        Changed(nameof(PendingHint));
        Changed(nameof(HistoryMore));
        Changed(nameof(HasHistoryMore));
        var records = Handoffs.History.Take(allHistory ? int.MaxValue : 5).Select(r => History.FirstOrDefault(h => h.Id == r.Id) ?? new HistoryModel(r.Id, $"{r.Created.LocalDateTime:MM-dd HH:mm} {Route(r.SourceName, r.TargetName, r.SameAccount)}", r.Scope == Handoffs.SplitScope ? "拆出需求 · " + r.Title : r.Title, r.Path, new(() => Run(() => Reveal(r.Path))), new(() =>
        {
            Handoffs.Forget(r.Id);
            UpdateHandoffs();
        })));
        Merge(History, records);
        if (Handoffs.RecoveryDetail is { } recovery)
            Notify(recovery);
    }
}
