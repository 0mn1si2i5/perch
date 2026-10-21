using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.VisualBasic.FileIO;

namespace Perch.Windows;

public sealed partial class PanelModel
{
    public async Task OpenSession(Account account, Session session)
    {
        if (Demo)
        {
            Notify("演示模式，不打开客户端。");
            return;
        }

        await Clients.Open(account);
        int count = Clients.Processes.Count(p => p.Executable.EndsWith("ChatGPT.exe", StringComparison.OrdinalIgnoreCase) && !Clients.Arguments(p.CommandLine).Any(a => a.StartsWith("--type", StringComparison.Ordinal) || a == "--crashpad-handler"));
        if (SessionRouting.CanDeepLink(account.App, session.Id, count))
            Process.Start(new ProcessStartInfo("codex://threads/" + session.Id) { UseShellExecute = true })?.Dispose();
        RequestHide?.Invoke();
    }

    private async Task CreateAccount()
    {
        if (Demo)
        {
            Notify("演示模式，不创建真实账号。");
            return;
        }

        var account = Store.Create(NewName, NewKind == 0 ? "codex" : "claude");
        NewName = "";
        Page = "accounts";
        MergeAccounts();
        await Clients.Open(account);
    }

    private Task ImportAccount()
    {
        var folder = new OpenFolderDialog
        {
            Title = "选择客户端数据目录"
        };
        if (folder.ShowDialog() != true)
            return Task.CompletedTask;
        var app = NewKind == 0 ? "codex" : "claude";
        if (Store.Accounts.Any(a => a.App == app && Store.SamePath(a.ProfilePath, folder.FolderName)))
            throw new IOException("这个目录已被其他账号引用。");
        var client = Clients.Installed.FirstOrDefault(c => c.App == app);
        bool isDefault = client != null && Store.SamePath(client.DefaultProfile, folder.FolderName);
        Store.Add(new Account { Name = string.IsNullOrWhiteSpace(NewName) ? Label(app) + " 账号" : NewName.Trim(), App = app, ProfilePath = folder.FolderName, SessionRoot = isDefault ? client!.DefaultSessions : app == "codex" ? Path.Combine(folder.FolderName, "codex-home") : folder.FolderName, Default = isDefault, ThirdParty = !isDefault && app == "claude" && ThirdParty });
        Page = "accounts";
        MergeAccounts();
        return Task.CompletedTask;
    }

    public Task Relocate(Account account)
    {
        var folder = new OpenFolderDialog
        {
            Title = "重新定位账号数据目录"
        };
        if (folder.ShowDialog() != true)
            return Task.CompletedTask;
        if (Store.Accounts.Any(a => a.Id != account.Id && a.App == account.App && Store.SamePath(a.ProfilePath, folder.FolderName)))
            throw new IOException("这个目录已被其他账号引用。");
        account.ProfilePath = folder.FolderName;
        var client = Clients.Installed.FirstOrDefault(c => c.App == account.App);
        account.Default = client != null && Store.SamePath(client.DefaultProfile, folder.FolderName);
        if (account.Default)
            account.ThirdParty = false;
        account.SessionRoot = account.Default ? client!.DefaultSessions : account.App == "codex" ? Path.Combine(folder.FolderName, "codex-home") : folder.FolderName;
        Store.Save();
        Quotas.Clear(account.Id);
        snapshots.Remove(account.Id);
        trackers.Remove(account.Id);
        MergeAccounts();
        return Task.CompletedTask;
    }

    public void Rename(Account account)
    {
        var name = Prompt?.Invoke("账号名称", account.Name);
        if (string.IsNullOrWhiteSpace(name))
            return;
        account.Name = name.Trim();
        Store.Save();
        MergeAccounts();
    }

    public async Task Remove(Account account)
    {
        var choice = ConfirmDelete?.Invoke(account) ?? (false, false);
        if (!choice.Item1)
            return;
        if (choice.Item2 && !account.Default && Directory.Exists(account.ProfilePath))
        {
            // The last poll can be 20 seconds old; check the processes now.
            await Task.Run(Clients.Scan);
            Store.CheckRecycle(account, Clients.Find(account) != null);
            FileSystem.DeleteDirectory(account.ProfilePath, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        }

        Store.Remove(account);
        Quotas.Clear(account.Id);
        snapshots.Remove(account.Id);
        trackers.Remove(account.Id);
        MergeAccounts();
    }

    public void SwitchDefault(Account account, Client client)
    {
        if (Store.Accounts.Any(a => a.Id != account.Id && a.App == client.App && a.Default))
            throw new IOException("默认数据已被另一个账号引用。");
        if (Confirm?.Invoke("改用直接打开的 " + Label(client.App) + " 数据？原目录将保留。") != true)
            return;
        account.ProfilePath = client.DefaultProfile;
        account.SessionRoot = client.DefaultSessions;
        account.Default = true;
        account.ThirdParty = false;
        Store.Save();
        Quotas.Clear(account.Id);
        snapshots.Remove(account.Id);
        trackers.Remove(account.Id);
        MergeAccounts();
    }

    private void AddDefault(Client client)
    {
        Store.Add(new Account { App = client.App, Name = Label(client.App) + " 默认账号", ProfilePath = client.DefaultProfile, SessionRoot = client.DefaultSessions, Default = true });
        MergeAccounts();
        if (AutoQuota)
            _ = Background(RefreshAll);
    }
}
