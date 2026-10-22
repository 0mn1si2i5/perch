using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;

namespace Perch.Windows;

public sealed class Account
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string App { get; set; } = "codex";
    public string ProfilePath { get; set; } = "";
    public string SessionRoot { get; set; } = "";
    public bool Default
    {
        get; set;
    }
    public bool ThirdParty
    {
        get; set;
    }
}

// Exec: started by `codex exec` (for example a delegate run) rather than in the desktop app.
public sealed record Session(string Id, string Title, string Status, DateTimeOffset Updated, string Cwd = "", string Path = "", bool Exec = false);
public sealed record QuotaWindow(string Name, double Used, DateTimeOffset? Resets);
/// `Owner` is the Claude account the values belong to (empty for Codex), so a switched login never shows them.
public sealed record Quota(List<QuotaWindow> Windows, DateTimeOffset Observed, string Detail, bool Cached = false, string Owner = "");
public sealed record Client(string App, string Executable, string DefaultProfile, string DefaultSessions);
public sealed record Running(int Pid, string Executable, string CommandLine, long Handle);
/// `Complete` is false when some client process could not be read, so a missing match proves nothing.
public sealed record ProcessScan(List<Running> Items, bool Complete);
public enum RunState
{
    NotRunning,
    Running,
    Unknown
}

public sealed record Snapshot(bool Running, List<Session> Sessions, string Detail, long Handle);
public sealed class Preferences
{
    public bool AutoQuota { get; set; } = true;
    public bool NotifySessionChanges { get; set; } = true;
    public bool PetEnabled
    {
        get; set;
    }
    public bool PetVisible { get; set; } = true;
    public string PetCharacter { get; set; } = "native";
    public double PetSize { get; set; } = 190;
    public bool Quiet
    {
        get; set;
    }
    public bool MediaEnabled { get; set; } = true;
    public double? PetLeft
    {
        get; set;
    }
    public double? PetTop
    {
        get; set;
    }
    public List<string> GroupOrder { get; set; } = ["codex", "claude"];
    public Dictionary<string, List<string>> SessionOrder { get; set; } = [];
    public List<string> DismissedDefaults { get; set; } = [];
    public List<string> ExpandedAccounts { get; set; } = [];
    public List<string> Collapsed { get; set; } = [];
}

public sealed class Store
{
    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    public string Root
    {
        get;
    }
    public List<Account> Accounts
    {
        get; private set;
    }
    public Preferences Preferences
    {
        get;
    }
    private string? recoveryDetail;
    // Content last read from or written to disk, so Save skips files that did not change.
    private readonly Dictionary<string, string> saved = [];

    public Store(string? root = null)
    {
        Root = root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Perch");
        PrivateDirectory(Root);
        try
        {
            Accounts = Read<List<Account>>("accounts.json") ?? [];
        }
        catch (JsonException e)
        {
            throw new IOException("账号文件无法读取，请检查：" + Path.Combine(Root, "accounts.json"), e);
        }

        try
        {
            Preferences = Read<Preferences>("preferences.json") ?? new();
        }
        catch (JsonException)
        {
            File.Move(Path.Combine(Root, "preferences.json"), Path.Combine(Root, "preferences.json.unreadable-" + Guid.NewGuid().ToString("N") + ".json"));
            Preferences = new();
            recoveryDetail = "偏好文件无法读取，已保留备份并恢复默认设置。";
        }

        if (File.Exists(Path.Combine(Root, "accounts.json")))
            saved["accounts.json"] = JsonSerializer.Serialize(Accounts, Json);
        if (File.Exists(Path.Combine(Root, "preferences.json")))
            saved["preferences.json"] = JsonSerializer.Serialize(Preferences, Json);
    }

    /// Returns the recovery notice once, then forgets it.
    public string? TakeRecoveryDetail()
    {
        var detail = recoveryDetail;
        recoveryDetail = null;
        return detail;
    }

    public T? Read<T>(string name) => File.Exists(Path.Combine(Root, name)) ? JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(Root, name)), Json) : default;
    public void Save()
    {
        SaveChanged("accounts.json", Accounts);
        SaveChanged("preferences.json", Preferences);
    }

    // The panel saves on every pet move and poll; unchanged files are left alone.
    private void SaveChanged<T>(string name, T value)
    {
        var text = JsonSerializer.Serialize(value, Json);
        if (saved.TryGetValue(name, out var last) && last == text)
            return;
        WriteText(name, text);
        saved[name] = text;
    }

    public void Write<T>(string name, T value) => WriteText(name, JsonSerializer.Serialize(value, Json));

    private void WriteText(string name, string text)
    {
        var target = Path.Combine(Root, name);
        PrivateDirectory(Path.GetDirectoryName(target)!);
        var temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, text);
            File.Move(temp, target, true);
        }
        finally
        {
            if (File.Exists(temp))
                File.Delete(temp);
        }
    }

    public static void PrivateDirectory(string path)
    {
        if (Directory.Exists(path))
            return;
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        acl.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        FileSystemAclExtensions.Create(new DirectoryInfo(path), acl);
    }

    public Account Create(string name, string app)
    {
        if (string.IsNullOrWhiteSpace(name))
            throw new InvalidOperationException("请输入账号名称。");
        var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".perch", "profiles", Guid.NewGuid().ToString("N")[..10]);
        PrivateDirectory(profile);
        var account = new Account
        {
            Name = name.Trim(),
            App = app,
            ProfilePath = profile,
            SessionRoot = app == "codex" ? Path.Combine(profile, "codex-home") : profile
        };
        PrivateDirectory(account.SessionRoot);
        Add(account);
        return account;
    }

    public void Add(Account account)
    {
        if (string.IsNullOrWhiteSpace(account.Name))
            throw new InvalidOperationException("请输入账号名称。");
        account.ProfilePath = Path.GetFullPath(account.ProfilePath);
        account.SessionRoot = Path.GetFullPath(account.SessionRoot);
        if (Accounts.Any(a => a.App == account.App && SamePath(a.ProfilePath, account.ProfilePath)))
            throw new InvalidOperationException("这个客户端目录已经添加。");
        Accounts.Add(account);
        Save();
    }

    /// Refuses to recycle the user folder, Perch's own root, a client's default data, or a profile a client may still have open.
    public void CheckRecycle(Account account, RunState state)
    {
        if (state == RunState.Running)
            throw new IOException("客户端仍在使用这个数据目录，请先退出它再移除并回收。");
        if (state == RunState.Unknown)
            throw new IOException("无法确认客户端是否还在使用这个数据目录，已取消移除。");
        if (SamePath(account.ProfilePath, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) || SamePath(account.ProfilePath, Root))
            throw new IOException("不能回收用户目录或 Perch 数据根目录。");
        if (Clients.IsDefaultProfile("codex", account.ProfilePath) || Clients.IsDefaultProfile("claude", account.ProfilePath))
            throw new IOException("不能回收客户端直接打开时使用的数据目录。");
    }

    public void Remove(Account account)
    {
        Accounts.Remove(account);
        Preferences.SessionOrder.Remove(account.Id);
        Preferences.ExpandedAccounts.Remove(account.Id);
        Save();
    }

    public static bool SamePath(string a, string b) => string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
}

public static class J
{
    public static JsonElement At(this JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) ? v : default;
    public static string Text(this JsonElement e, string key, string fallback = "") => e.At(key).ValueKind == JsonValueKind.String ? e.At(key).GetString() ?? fallback : fallback;
    public static double Number(this JsonElement e, string key, double fallback = 0) => e.At(key).TryNumber(fallback);
    public static double TryNumber(this JsonElement e, double fallback = 0) => e.ValueKind == JsonValueKind.Number && e.TryGetDouble(out var d) ? d : fallback;
    public static DateTimeOffset Time(this JsonElement e, string key) => DateTimeOffset.TryParse(e.Text(key), out var t) ? t : DateTimeOffset.FromUnixTimeMilliseconds((long)e.Number(key));
}