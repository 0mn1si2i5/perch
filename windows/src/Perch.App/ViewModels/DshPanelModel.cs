using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Perch.Windows;

public sealed partial class PanelModel
{
    public DshService Dsh { get; }
    private Account? editingDsh;
    private int dshMode = 1;
    private string dshPath = "", dshNode = "", dshHome = "", dshProfile = "web", dshUrl = "", dshBalanceHome = "";
    private string dshDetectionDetail = "可扫描 npm 全局安装、PATH 命令和官方 npx 缓存。", dshValidation = "";
    private bool dshHelpExpanded;
    private DshInstallCandidate? selectedDshInstall;
    public ObservableCollection<DshInstallCandidate> DshInstalls { get; } = [];
    public DshInstallCandidate? SelectedDshInstall
    {
        get => selectedDshInstall;
        set { if (Set(ref selectedDshInstall, value) && value != null) ApplyDshInstall(value); }
    }
    public bool HasDshInstalls => DshInstalls.Count > 0;
    public bool NoDshAccounts => !Store.Accounts.Any(a => a.App == "dsh");
    public string DshDetectionDetail { get => dshDetectionDetail; private set => Set(ref dshDetectionDetail, value); }
    public string DshValidation { get => dshValidation; private set { Set(ref dshValidation, value); Changed(nameof(HasDshValidation)); } }
    public bool HasDshValidation => DshValidation.Length > 0;
    public bool DshHelpExpanded { get => dshHelpExpanded; set => Set(ref dshHelpExpanded, value); }
    public string DshManualHelp => DshDiscovery.ManualHelp;
    private void InitializeDshEditor()
    {
        dshPath = Demo ? @"C:\Tools\deepseek-harness" : "";
        dshNode = Demo ? @"C:\Program Files\nodejs\node.exe" : DshInstallation.FindNode() ?? "";
    }
    private async Task ScanDshInstallations(bool select = false)
    {
        IReadOnlyList<DshInstallCandidate> found = Demo ? new[] { new DshInstallCandidate(@"C:\Tools\dsh\node_modules\@deepseek-ai\dsh", "npm", "0.2.x", "npm 全局安装", NodeRequirement: ">=24.9.0") }
            : await Task.Run(() => DshDiscovery.Discover());
        SelectedDshInstall = null;
        DshInstalls.Clear();
        foreach (var item in found) DshInstalls.Add(item);
        Changed(nameof(HasDshInstalls));
        DshDetectionDetail = found.Count == 0 ? "未发现可用安装。已检查 PATH、npm 前缀和 npx 缓存；可按下方指引手动添加。"
            : $"发现 {found.Count} 个可用安装，请确认版本与位置。npx 缓存被清理后需重新识别。";
        if (found.Count == 0) DshHelpExpanded = true;
        else if (select || editingDsh == null && DshPath.Length == 0) SelectedDshInstall = found[0];
        MergeAccounts();
    }
    private void ApplyDshInstall(DshInstallCandidate candidate)
    {
        DshMode = candidate.Mode == "source" ? 0 : 1;
        DshPath = candidate.Path;
        if (candidate.Node.Length > 0) DshNode = candidate.Node;
        else if (DshNode.Length == 0) DshNode = Demo ? @"C:\Program Files\nodejs\node.exe" : DshInstallation.FindNode() ?? "";
        DshValidation = $"已识别 {candidate.Version}" + (candidate.NodeRequirement.Length > 0 ? $"；需要 Node.js {candidate.NodeRequirement}" : "") + "。可点“检查配置”验证启动文件。";
    }
    public Command AddDshManually => new(() => { ResetDshEditor(); NewDsh = true; Page = "add"; DshHelpExpanded = !HasDshInstalls; });
    public Command CheckDshInstallation => new(() => Run(() =>
    {
        try
        {
            var candidate = DshDiscovery.Inspect(DshPath) ?? throw new IOException("未找到完整的 @deepseek-ai/dsh 包。请选择 dsh.cmd、包目录、项目目录或已构建的源码根目录；桌面 EXE 不能作为 Node CLI 使用。");
            ApplyDshInstall(candidate);
            DshInstallation.Resolve(new Account { ProfilePath = string.IsNullOrWhiteSpace(DshHome) ? Path.Combine(Store.Root, "dsh-check") : DshDiscovery.Normalize(DshHome),
                Dsh = new() { Mode = candidate.Mode, InstallationPath = DshPath, NodePath = DshNode, Profile = DshProfile } });
            DshValidation = $"启动文件检查通过 · {candidate.Version}" + (candidate.NodeRequirement.Length > 0 ? $" · 请确认 Node.js {candidate.NodeRequirement}" : "") + "。尚未启动服务。";
        }
        catch (Exception e) when (DshDiscovery.IsPathError(e)) { DshValidation = e is IOException ? e.Message : "安装路径无效或不可读，请检查路径与权限。"; DshHelpExpanded = true; }
    }));
    public Command OpenDshGuide => new(() => Run(() => Process.Start(new ProcessStartInfo(DshDiscovery.OfficialGuide) { UseShellExecute = true })?.Dispose()));
    public Command CopyDshQuickStart => new(() => Run(() => { System.Windows.Clipboard.SetText(DshDiscovery.QuickStart); Notify("已复制官方 Web 启动命令，请在终端运行。"); }));
    public Command ConnectDshInstead => new(() => { DshMode = 2; DshHelpExpanded = true; });
    public bool NewDsh { get => NewKind == 2; set { if (value) NewKind = 2; } }
    public bool NewNative => !NewDsh;
    public string CreateLabel => NewDsh ? editingDsh != null ? "保存配置" : DshExternal ? "连接并添加" : "创建并启动" : Strings.Get("account.create");
    public int DshMode
    {
        get => dshMode;
        set
        {
            if (!Set(ref dshMode, value)) return;
            DshPath = Demo ? @"C:\Tools\deepseek-harness" : value == 1 ? DshInstalls.FirstOrDefault()?.Path ?? "" : "";
            Changed(nameof(DshExternal));
            Changed(nameof(DshManaged));
            Changed(nameof(DshInstallHint));
            Changed(nameof(CreateLabel));
        }
    }
    public bool DshExternal => DshMode == 2;
    public bool DshManaged => !DshExternal;
    public string DshInstallHint => DshMode == 0 ? "源码仓库根目录（先完成 pnpm run build）" : "dsh.cmd、npm 包目录或含本地安装的项目目录";
    public string DshPath { get => dshPath; set { if (Set(ref dshPath, value)) DshValidation = ""; } }
    public string DshNode { get => dshNode; set { if (Set(ref dshNode, value)) DshValidation = ""; } }
    public string DshHome { get => dshHome; set { if (Set(ref dshHome, value)) DshValidation = ""; } }
    public string DshProfile { get => dshProfile; set { if (Set(ref dshProfile, value)) DshValidation = ""; } }
    public string DshUrl { get => dshUrl; set { if (Set(ref dshUrl, value)) DshValidation = ""; } }
    public string DshBalanceHome { get => dshBalanceHome; set => Set(ref dshBalanceHome, value); }
    public Command ChooseDshBalanceHome => new(() => { var picker = new OpenFolderDialog { Title = "选择已有实例的 DSH_HOME（只读 API Key 查询余额）" }; if (picker.ShowDialog() == true) DshBalanceHome = picker.FolderName; });
    public Command ChooseDshInstallation => new(() => { var picker = new OpenFolderDialog { Title = DshInstallHint }; if (picker.ShowDialog() == true) DshPath = picker.FolderName; });
    public Command ChooseDshCommand => new(() => { var picker = new OpenFileDialog { Title = "选择 dsh 命令或 package.json", Filter = "dsh 命令 / 包清单|dsh.cmd;dsh.ps1;package.json|所有文件|*.*" }; if (picker.ShowDialog() == true) DshPath = picker.FileName; });
    public Command ChooseDshHome => new(() => { var picker = new OpenFolderDialog { Title = "选择已有 DSH_HOME（不复制登录信息）" }; if (picker.ShowDialog() == true) DshHome = picker.FolderName; });
    public Command ChooseDshNode => new(() => { var picker = new OpenFileDialog { Title = "选择 Node.js", Filter = "Node.js|node.exe" }; if (picker.ShowDialog() == true) DshNode = picker.FileName; });
    public Command DetectDsh => new(() => Run(() => ScanDshInstallations(true)));

    public async Task OpenClient(Account account)
    {
        if (Demo) { Notify("演示模式，不打开客户端。"); return; }
        if (account.App != "dsh") { await Clients.Open(account); return; }
        try
        {
            var url = await Dsh.Ensure(account);
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
        }
        finally
        {
            snapshots[account.Id] = await Dsh.Read(account);
            MergeAccounts();
        }
    }

    private async Task CreateDsh()
    {
        var account = editingDsh ?? new Account { App = "dsh", Name = NewName.Trim() };
        if (editingDsh != null && (DshState.ChildAlive(Dsh.State(account).Read()) || Dsh.State(account).HostAlive()))
            throw new IOException("请先停止这个 dsh 服务，再修改启动配置；可用“重新连接”更新授权。");
        var home = DshExternal ? account.ProfilePath.Length > 0 && account.Dsh?.Mode == "external" ? account.ProfilePath : Path.Combine(Store.Root, "dsh-external", account.Id)
            : string.IsNullOrWhiteSpace(DshHome) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".perch", "profiles", Guid.NewGuid().ToString("N")[..10], "dsh-home") : Path.GetFullPath(DshHome.Trim());
        if (Store.Accounts.Any(a => a.Id != account.Id && a.App == "dsh" && Store.SamePath(a.ProfilePath, home)))
            throw new IOException("这个 DSH_HOME 已被另一个账号引用，请使用已有记录。");
        var config = new DshConfiguration { Mode = DshExternal ? "external" : DshMode == 0 ? "source" : "npm", InstallationPath = DshExternal ? "" : DshPath.Trim(), NodePath = DshExternal ? "" : DshNode.Trim(), Profile = DshProfile.Trim(),
            BalanceHome = DshExternal && !string.IsNullOrWhiteSpace(DshBalanceHome) ? Path.GetFullPath(DshBalanceHome.Trim()) : "" };
        // Validate a detached value so failed configuration never mutates a saved account.
        var candidate = new Account { Id = account.Id, App = "dsh", Name = NewName.Trim(), ProfilePath = home, SessionRoot = home, Dsh = config };
        if (DshExternal)
        {
            // Editing only the balance directory must not require another token or interrupt dsh.
            try
            {
                if (editingDsh?.Dsh?.Mode != "external" || !string.IsNullOrWhiteSpace(DshUrl)) await Dsh.Connect(candidate, DshUrl);
            }
            catch (IOException e) { DshValidation = e.Message; DshHelpExpanded = true; throw; }
        }
        else
        {
            try
            {
                var resolved = DshDiscovery.Inspect(config.InstallationPath);
                if (resolved != null) { config.InstallationPath = resolved.Path; config.Mode = resolved.Mode; if (config.NodePath.Length == 0) config.NodePath = resolved.Node; }
                DshInstallation.Resolve(candidate);
            }
            catch (Exception e) when (DshDiscovery.IsPathError(e)) { DshValidation = e is IOException ? e.Message : "安装路径无效或不可读，请检查路径与权限。"; DshHelpExpanded = true; throw new IOException(DshValidation); }
        }
        Store.PrivateDirectory(home);
        account.Name = candidate.Name;
        account.ProfilePath = home;
        account.SessionRoot = home;
        account.Dsh = config;
        if (editingDsh == null) Store.Add(account); else Store.Save();
        editingDsh = null;
        DshUrl = "";
        DshBalanceHome = "";
        NewName = "";
        Page = "accounts";
        Quotas.Clear(account.Id);
        MergeAccounts();
        await OpenClient(account);
        await Refresh(account);
        Changed(nameof(CreateLabel));
    }

    public void ConfigureDsh(Account account)
    {
        editingDsh = account;
        NewKind = 2;
        NewName = account.Name;
        DshMode = account.Dsh?.Mode switch { "source" => 0, "external" => 2, _ => 1 };
        DshPath = account.Dsh?.InstallationPath ?? "";
        DshNode = account.Dsh?.NodePath ?? "";
        DshProfile = account.Dsh?.Profile ?? "web";
        DshHome = account.Dsh?.Mode == "external" ? "" : account.ProfilePath;
        DshUrl = "";
        DshBalanceHome = account.Dsh?.BalanceHome ?? "";
        Page = "add";
        Changed(nameof(CreateLabel));
    }

    private void ResetDshEditor()
    {
        editingDsh = null;
        DshUrl = "";
        DshHome = "";
        DshBalanceHome = "";
        DshValidation = "";
        DshMode = 1;
        if (DshInstalls.FirstOrDefault() is { } install) { selectedDshInstall = null; SelectedDshInstall = install; }
        DshHelpExpanded = !HasDshInstalls;
        Changed(nameof(CreateLabel));
    }

    public async Task ReconnectDsh(Account account)
    {
        if (Demo) { Notify("演示模式，不连接真实实例。"); return; }
        var url = PromptConnection?.Invoke("粘贴 dsh 当前启动的本机授权 URL", "");
        if (string.IsNullOrWhiteSpace(url)) return;
        await Dsh.Connect(account, url);
        Quotas.Clear(account.Id);
        await Refresh(account);
    }

    public async Task StopDsh(Account account)
    {
        if (Demo) { Notify("演示模式，不停止真实服务。"); return; }
        var external = account.Dsh?.Mode == "external";
        if (!external && Confirm?.Invoke("停止这个 dsh 服务？正在运行的任务会被中断。数据目录将保留。") != true) return;
        await Dsh.Stop(account);
        Quotas.Clear(account.Id);
        snapshots[account.Id] = await Dsh.Read(account);
        MergeAccounts();
    }

}
