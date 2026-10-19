using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Perch.Windows;

public sealed partial class PanelModel : Observable, IDisposable
{
    public Store Store
    {
        get;
    }
    public Clients Clients { get; } = new();
    public QuotaService Quotas
    {
        get;
    }
    public Handoffs Handoffs
    {
        get;
    }
    public bool Demo
    {
        get;
    }
    // Counts user-started operations (dialogs, launches) that keep the panel open; background refreshes do not count.
    private int interacting;
    public bool Interacting => interacting > 0;
    public bool Sorting
    {
        get; set;
    }

    public Action? ConfigurationChanged;
    public Action? RequestHide;
    public Action<int>? PreviewPet;
    public Func<string, string, string?>? Prompt;
    public Func<Account, (bool Confirm, bool Recycle)>? ConfirmDelete;
    public Func<string, bool>? Confirm;
    public event Action<string>? BackgroundError;
    public ObservableCollection<GroupModel> Groups { get; } = [];
    public ObservableCollection<DiscoveredModel> Discovered { get; } = [];
    public ObservableCollection<HistoryModel> History { get; } = [];

    private readonly Dictionary<string, AccountModel> accounts = [];
    private readonly Dictionary<string, GroupModel> groups = [];
    private readonly Dictionary<string, ImageSource?> icons = [];
    private readonly Dictionary<string, Snapshot> snapshots = [];
    private readonly DispatcherTimer pollTimer = new();
    private readonly DispatcherTimer clock = new()
    {
        Interval = TimeSpan.FromSeconds(30)
    };
    private readonly DispatcherTimer messageTimer = new()
    {
        Interval = TimeSpan.FromSeconds(6)
    };
    private bool polling, disposed, started;
    private DateTimeOffset lastQuota;
    private string page = "accounts", message = "", newName = "";
    private int newKind;
    public string Page
    {
        get => page;
        set
        {
            if (Set(ref page, value))
            {
                Changed(nameof(Title));
                Changed(nameof(IsAccounts));
                Changed(nameof(IsSettings));
                Changed(nameof(IsInfo));
                Changed(nameof(IsAdd));
            }
        }
    }

    public string Title => Page switch
    {
        "settings" => "设置",
        "info" => "信息",
        "add" => "新建账号",
        _ => "Perch"
    };
    public bool IsAccounts => Page == "accounts";
    public bool IsSettings => Page == "settings";
    public bool IsInfo => Page == "info";
    public bool IsAdd => Page == "add";

    public string Message
    {
        get => message;
        private set
        {
            Set(ref message, value);
            Changed(nameof(HasMessage));
        }
    }

    public bool HasMessage => Message.Length > 0;

    public string NewName
    {
        get => newName;
        set
        {
            Set(ref newName, value);
            CommandManager.InvalidateRequerySuggested();
        }
    }

    public int NewKind
    {
        get => newKind;
        set
        {
            Set(ref newKind, value);
            Changed(nameof(NewCodex));
            Changed(nameof(NewClaude));
        }
    }

    public bool NewCodex
    {
        get => NewKind == 0;
        set
        {
            if (value)
                NewKind = 0;
        }
    }

    public bool NewClaude
    {
        get => NewKind == 1;
        set
        {
            if (value)
                NewKind = 1;
        }
    }

    public bool ThirdParty
    {
        get; set;
    }

    public bool PetEnabled
    {
        get => Store.Preferences.PetEnabled;
        set
        {
            Store.Preferences.PetEnabled = value;
            Store.Preferences.PetVisible = value;
            Configure();
            Changed();
            Changed(nameof(PetVisible));
        }
    }

    public bool PetVisible => Store.Preferences.PetVisible;

    public int PetKind
    {
        get => Store.Preferences.PetCharacter == "pox" ? 1 : 0;
        set
        {
            Store.Preferences.PetCharacter = value == 1 ? "pox" : "native";
            Configure();
            Changed();
            Changed(nameof(IsPox));
            Changed(nameof(PetHelp));
        }
    }

    public bool IsPox => PetKind == 1;
    public string PetHelp => IsPox ? "Pox 会陪伴任务进度与媒体播放。" : "轻巧的桌面入口；单击展开或收起面板。";

    public double PetSize
    {
        get => Store.Preferences.PetSize;
        set
        {
            Store.Preferences.PetSize = value;
            Configure();
            Changed();
        }
    }

    public bool Quiet
    {
        get => Store.Preferences.Quiet;
        set
        {
            Store.Preferences.Quiet = value;
            Configure();
            Changed();
        }
    }

    public bool MediaEnabled
    {
        get => Store.Preferences.MediaEnabled;
        set
        {
            Store.Preferences.MediaEnabled = value;
            Configure();
            Changed();
        }
    }

    public bool AutoQuota
    {
        get => Store.Preferences.AutoQuota;
        set
        {
            Store.Preferences.AutoQuota = value;
            Run(Store.Save);
            Changed();
        }
    }

    public int Preview
    {
        get => 0;
        set
        {
            if (value > 0)
                PreviewPet?.Invoke(value - 1);
        }
    }

    public bool NoAccounts => Store.Accounts.Count == 0;
    public string DataPath => Store.Handoffs;
    public Account? BusyAccount => Store.Accounts.FirstOrDefault(a => snapshots.TryGetValue(a.Id, out var s) && s.Sessions.Any(t => t.Status is "运行中" or "等待输入"));
    public Command Info
    {
        get;
    }
    public Command Settings
    {
        get;
    }
    public Command Add
    {
        get;
    }
    public Command CancelAdd
    {
        get;
    }
    public Command Create
    {
        get;
    }
    public Command Import
    {
        get;
    }
    public Command TogglePet
    {
        get;
    }
    public Command ClearMessage
    {
        get;
    }
    public Command RefreshAllCommand
    {
        get;
    }
    public Command RevealHandoffs
    {
        get;
    }
    public Command FinishHandoff
    {
        get;
    }
    public Command ExistingHandoff
    {
        get;
    }
    public Command CopyPrompt
    {
        get;
    }
    public Command CancelHandoff
    {
        get;
    }
    public Command MoreHistory
    {
        get;
    }
    public Command DiscoverAgain
    {
        get;
    }
    public Command TaskbarSettings
    {
        get;
    }
    public Command Quit { get; } = new(() => Application.Current.Shutdown());

    public PanelModel(Store store, bool demo)
    {
        Store = store;
        Demo = demo;
        Quotas = new QuotaService(Clients);
        Handoffs = new Handoffs(store);
        Info = new(() => Navigate("info"));
        Settings = new(() => Navigate("settings"));
        Add = new(() => Navigate("add"));
        CancelAdd = new(() => Page = "accounts");
        Create = new(() => Run(CreateAccount), () => !Interacting && !string.IsNullOrWhiteSpace(NewName));
        Import = new(() => Run(ImportAccount));
        TogglePet = new(() =>
        {
            Store.Preferences.PetVisible = !PetVisible;
            Configure();
            Changed(nameof(PetVisible));
        });
        ClearMessage = new(() => Message = "");
        RefreshAllCommand = new(() => Run(RefreshAll));
        RevealHandoffs = new(() => Run(() =>
        {
            Store.PrivateDirectory(Store.Handoffs);
            Reveal(Store.Handoffs);
        }));
        FinishHandoff = new(() => Run(() => Finish(false)), () => !HandoffBusy);
        ExistingHandoff = new(() => Run(() => Finish(true)), () => !HandoffBusy);
        CopyPrompt = new(() => Run(() =>
        {
            var p = Handoffs.Pending ?? throw new IOException("没有待继续的接力。");
            ClipboardWriter.Set(Handoffs.Prompt(Handoffs.Draft(p), p.Scope));
        }));
        CancelHandoff = new(() => Run(() =>
        {
            Handoffs.Clear();
            UpdateHandoffs();
        }));
        MoreHistory = new(() =>
        {
            allHistory = !allHistory;
            UpdateHandoffs();
        });
        DiscoverAgain = new(() => Run(async () =>
        {
            await Clients.Discover();
            icons.Clear();
            MergeAccounts();
        }));
        TaskbarSettings = new(() => Run(() => Process.Start(new ProcessStartInfo("ms-settings:taskbar") { UseShellExecute = true })?.Dispose()));
        messageTimer.Tick += (_, _) =>
        {
            Message = "";
            messageTimer.Stop();
        };
        pollTimer.Tick += async (_, _) => await Poll();
        clock.Tick += (_, _) => MergeAccounts();
        if (Demo)
            PopulateDemo();
        MergeAccounts();
        UpdateHandoffs();
        if (Store.TakeRecoveryDetail() is { } recovery)
            Notify(recovery);
    }

    public async Task Start()
    {
        if (Demo)
            return;
        await Background(async () =>
        {
            await Clients.Discover();
            icons.Clear();
            await Poll();
            if (AutoQuota)
                await RefreshAll();
        });
        clock.Start();
        if (pollTimer.Interval <= TimeSpan.Zero)
            pollTimer.Interval = TimeSpan.FromSeconds(20);
        pollTimer.Start();
        started = true;
    }
    public void Opened()
    {
        Ready();
        if (Demo || !started || !AutoQuota)
            return;
        _ = Background(async () =>
        {
            foreach (var account in Store.Accounts.ToArray())
                await Refresh(account, false);
        });
    }

    public void SetVisible(bool panel, bool pet) => pollTimer.Interval = TimeSpan.FromSeconds(panel || pet ? 5 : 20);
    private void Configure() => Run(() =>
    {
        Store.Save();
        ConfigurationChanged?.Invoke();
    });

    private void Navigate(string destination) => Page = Page == destination ? "accounts" : destination;
    // Notices raised while the panel and tray are still being built (file recovery, hotkey) wait here,
    // since nothing is subscribed yet and the message would clear before anyone saw it.
    private List<string>? held = [];

    public void Notify(string value)
    {
        if (held != null)
        {
            if (!held.Contains(value))
                held.Add(value);
            return;
        }

        Message = value;
        messageTimer.Stop();
        messageTimer.Start();
        BackgroundError?.Invoke(value);
    }

    /// Shows the notices held during startup; called once the tray is listening or the panel first opens.
    public void Ready()
    {
        if (held == null)
            return;
        var waiting = held;
        held = null;
        if (waiting.Count > 0)
            Notify(string.Join("\n", waiting));
    }

    public void Run(Action action) => Run(() =>
    {
        action();
        return Task.CompletedTask;
    });
    public async void Run(Func<Task> action) => await Execute(action);
    private async Task Execute(Func<Task> action)
    {
        interacting++;
        CommandManager.InvalidateRequerySuggested();
        try
        {
            await action();
        }
        catch (Exception e)
        {
            Notify(Describe(e));
        }
        finally
        {
            interacting--;
            CommandManager.InvalidateRequerySuggested();
        }
    }

    // Polling and automatic quota refreshes report errors without holding the panel open.
    private async Task Background(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception e)
        {
            Notify(Describe(e));
        }
    }

    public static string Describe(Exception e) => e is IOException or InvalidOperationException or UnauthorizedAccessException ? e.Message : "操作失败，请稍后重试。";

    private async Task Poll()
    {
        if (polling || disposed || Demo)
            return;
        polling = true;
        try
        {
            await Task.Run(() => Clients.Scan());
            var list = Store.Accounts.ToArray();
            var reads = await Task.Run(() => list.Select(a => (a.Id, Snapshot: Sessions.Read(a, Clients))).ToArray());
            foreach (var (id, snapshot) in reads)
                snapshots[id] = snapshot;
            MergeAccounts();
            ConfigurationChanged?.Invoke();
            if (AutoQuota && DateTimeOffset.UtcNow - lastQuota > TimeSpan.FromMinutes(5))
                _ = Background(RefreshAll);
        }
        catch
        {
            Notify("无法刷新客户端状态，请稍后重试。");
        }
        finally
        {
            polling = false;
        }
    }

    public async Task Refresh(Account account, bool manual = true)
    {
        if (Demo)
            return;
        if (accounts.TryGetValue(account.Id, out var vm))
            vm.Busy = true;
        try
        {
            await Quotas.Refresh(account, manual);
        }
        finally
        {
            if (vm != null)
                vm.Busy = false;
            MergeAccounts();
        }
    }

    private async Task RefreshAll()
    {
        lastQuota = DateTimeOffset.UtcNow;
        foreach (var account in Store.Accounts.ToArray())
            await Refresh(account);
    }

    public List<Session> AllSessions => snapshots.Values.SelectMany(s => s.Sessions).ToList();

    public void MergeAccounts()
    {
        if (Sorting)
            return;
        foreach (var id in accounts.Keys.Except(Store.Accounts.Select(a => a.Id)).ToArray())
            accounts.Remove(id);
        foreach (var a in Store.Accounts)
        {
            if (!accounts.TryGetValue(a.Id, out var vm))
                accounts[a.Id] = vm = new AccountModel(this, a);
            vm.Update(snapshots.GetValueOrDefault(a.Id) ?? new Snapshot(false, [], "", 0), Demo ? demoQuotas.GetValueOrDefault(a.Id) : Quotas.Get(a.Id));
        }

        var ordered = new List<GroupModel>();
        foreach (var app in Store.Preferences.GroupOrder)
        {
            if (!groups.TryGetValue(app, out var vm))
                groups[app] = vm = new GroupModel(this, app);
            Merge(vm.Accounts, Store.Accounts.Where(a => a.App == app).Select(a => accounts[a.Id]));
            vm.Notify();
            if (vm.Accounts.Count > 0)
                ordered.Add(vm);
        }

        Merge(Groups, ordered);
        var discoveries = new List<DiscoveredModel>();
        foreach (var client in Clients.Installed.Where(c => Clients.Processes.Any(p => Store.SamePath(p.Executable, c.Executable) && Clients.Matches(p.CommandLine, new Account { Default = true, ProfilePath = c.DefaultProfile })) && !Store.Accounts.Any(a => a.App == c.App && a.Default) && !Store.Preferences.DismissedDefaults.Contains(c.App)))
        {
            var app = client.App;
            var existing = Discovered.FirstOrDefault(d => d.App == app);
            discoveries.Add(existing ?? new DiscoveredModel(app, "发现直接打开的 " + Label(app), Store.Accounts.Any(a => a.App == app), new(() => Run(() => AddDefault(client))), new(() => Run(() =>
            {
                Store.Preferences.DismissedDefaults.Add(app);
                Store.Save();
                MergeAccounts();
            }))));
        }

        if (Demo && discoveries.Count == 0)
            discoveries.Add(new("codex", "发现直接打开的 Codex", true, new(() => Notify("演示模式")), new(() => Discovered.Clear())));
        Merge(Discovered, discoveries);
        Changed(nameof(NoAccounts));
    }

    private bool darkIcons;
    /// Dark panels need the package's white "unplated" logo; the exe icon is the light-mode glyph.
    public void UseDarkIcons(bool dark)
    {
        if (darkIcons == dark && icons.Count > 0)
            return;
        darkIcons = dark;
        icons.Clear();
        foreach (var group in Groups)
            group.Notify();
    }

    public ImageSource? ClientIcon(string app)
    {
        if (icons.TryGetValue(app, out var icon))
            return icon;
        try
        {
            var path = Clients.Installed.FirstOrDefault(c => c.App == app)?.Executable;
            var assets = path == null ? null : Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(path)!)!, "assets");
            var logo = assets == null ? null : Path.Combine(assets, "Square44x44Logo.targetsize-32_altform-" + (darkIcons ? "unplated" : "lightunplated") + ".png");
            if (logo != null && File.Exists(logo))
                icon = LoadImage(logo);
            else
            {
                using var extracted = path == null ? null : System.Drawing.Icon.ExtractAssociatedIcon(path);
                if (extracted != null)
                {
                    icon = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(extracted.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    icon.Freeze();
                }
            }
        }
        catch
        {
        }

        if (icon == null)
        {
            var folder = Path.Combine(AppContext.BaseDirectory, "Resources", "ClientIcons");
            var bundled = Path.Combine(folder, app + "-dark.png");
            if (!darkIcons || !File.Exists(bundled))
                bundled = Path.Combine(folder, app + ".png");
            if (File.Exists(bundled))
                icon = LoadImage(bundled);
        }

        icons[app] = icon;
        return icon;
    }

    private static BitmapImage LoadImage(string file)
    {
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.UriSource = new Uri(file);
        bitmap.EndInit();
        bitmap.Freeze();
        return bitmap;
    }

    public static string Label(string app) => app == "codex" ? "Codex" : "Claude";
    public static void Reveal(string path)
    {
        var info = new ProcessStartInfo("explorer.exe")
        {
            UseShellExecute = false
        };
        info.ArgumentList.Add(File.Exists(path) ? "/select," + path : path);
        Process.Start(info)?.Dispose();
    }

    public void Dispose()
    {
        disposed = true;
        pollTimer.Stop();
        clock.Stop();
        messageTimer.Stop();
    }
}
