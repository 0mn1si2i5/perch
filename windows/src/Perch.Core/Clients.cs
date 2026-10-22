using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Perch.Windows;

/// The window was shown, but Windows refused to move focus to it.
public sealed class ForegroundRefusedException() : IOException("窗口已恢复；Windows 限制了前台切换，请点击任务栏窗口。");

public sealed class Clients
{
    public List<Client> Installed { get; private set; } = [];
    public List<Running> Processes { get; private set; } = [];
    public bool ScanComplete { get; private set; }
    private readonly Func<ProcessScan> scanner;

    /// `scanner` and `installed` are injectable for tests; the defaults read this machine.
    public Clients(Func<ProcessScan>? scanner = null, List<Client>? installed = null)
    {
        this.scanner = scanner ?? Perch.Windows.Processes.Scan;
        Installed = installed ?? [];
    }

    private static ProcessStartInfo Shell(string script)
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var p = new ProcessStartInfo(Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8
        };
        // PowerShell 7's module path can be inherited by a desktop process. Windows PowerShell
        // must load its own Security/CIM/Appx modules, without changing the user's environment.
        p.Environment["PSModulePath"] = Path.Combine(system, "WindowsPowerShell", "v1.0", "Modules") + ";" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules");
        p.ArgumentList.Add("-NoProfile");
        p.ArgumentList.Add("-NonInteractive");
        p.ArgumentList.Add("-EncodedCommand");
        p.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes("[Console]::OutputEncoding=[Text.UTF8Encoding]::new();$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';" + script)));
        return p;
    }

    private static async Task<string> Run(string script)
    {
        using var p = Process.Start(Shell(script)) ?? throw new IOException("无法查询 Windows 客户端。");
        using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var output = p.StandardOutput.ReadToEndAsync(cancel.Token);
        var error = p.StandardError.ReadToEndAsync(cancel.Token);
        try
        {
            await p.WaitForExitAsync(cancel.Token);
        }
        catch
        {
            if (!p.HasExited)
                p.Kill(true);
            throw;
        }

        var diagnostic = await error;
        if (p.ExitCode != 0)
            throw new IOException("Windows 客户端查询失败。", new InvalidOperationException(diagnostic));
        return await output;
    }

    public async Task Discover()
    {
        try
        {
            // Enumerating every package for the user takes seconds; keep it off the UI thread.
            Installed = await Task.Run(() =>
            {
                var manager = new global::Windows.Management.Deployment.PackageManager();
                var packages = manager.FindPackagesForUser("").Where(p => p.Id.Name is "OpenAI.Codex" or "Claude").Where(p => p.Status.VerifyIsOK() && p.SignatureKind != global::Windows.ApplicationModel.PackageSignatureKind.None).ToList();
                return packages.Select(p => MakeClient(p.Id.Name == "Claude" ? "claude" : "codex", Path.Combine(p.InstalledLocation.Path, "app", p.Id.Name == "Claude" ? "Claude.exe" : "ChatGPT.exe"), p.Id.FamilyName)).Where(c => File.Exists(c.Executable)).ToList();
            });
            return;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException or NotSupportedException)
        {
        }

        if (fallbackAttempted)
            return;
        fallbackAttempted = true;
        var result = await Run("$rows=@();foreach($name in @('OpenAI.Codex','Claude')){$pkg=Get-AppxPackage -Name $name | Select-Object -First 1;if($pkg){$exe=Join-Path $pkg.InstallLocation $(if($name -eq 'Claude'){'app\\Claude.exe'}else{'app\\ChatGPT.exe'});if((Test-Path -LiteralPath $exe) -and (Get-AuthenticodeSignature -LiteralPath $exe).Status -eq 'Valid'){$rows+=@{app=$(if($name -eq 'Claude'){'claude'}else{'codex'});exe=$exe;family=$pkg.PackageFamilyName}}}};ConvertTo-Json -InputObject @($rows) -Compress");
        using var doc = JsonDocument.Parse(result);
        Installed = doc.RootElement.EnumerateArray().Select(e => MakeClient(e.Text("app"), e.Text("exe"), e.Text("family"))).ToList();
    }

    private bool fallbackAttempted;
    private static Client MakeClient(string app, string executable, string family)
    {
        var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages", family, "LocalCache", "Roaming", DataName(app));
        if (!Directory.Exists(profile))
            profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), DataName(app));
        return new Client(app, executable, profile, DefaultSessions(app, profile));
    }

    private static string DataName(string app) => app == "codex" ? "Codex" : "Claude";
    public static string DefaultSessions(string app, string profile) => app == "codex" ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex") : profile;

    /// Whether this is where the client keeps data when opened directly: %APPDATA%\<name>, or the MSIX
    /// redirect Packages\<any family>\LocalCache\Roaming\<name>. Decided by path alone, so it holds when discovery failed.
    public static bool IsDefaultProfile(string app, string path)
    {
        var name = DataName(app);
        var full = Path.GetFullPath(path).TrimEnd('\\');
        if (Store.SamePath(full, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), name)))
            return true;
        var roaming = Path.GetDirectoryName(full);
        var cache = roaming == null ? null : Path.GetDirectoryName(roaming);
        var package = cache == null ? null : Path.GetDirectoryName(cache);
        return package != null && string.Equals(Path.GetFileName(full), name, StringComparison.OrdinalIgnoreCase)
            && string.Equals(Path.GetFileName(roaming), "Roaming", StringComparison.OrdinalIgnoreCase)
            && string.Equals(Path.GetFileName(cache), "LocalCache", StringComparison.OrdinalIgnoreCase)
            && Store.SamePath(Path.GetDirectoryName(package)!, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages"));
    }

    public Task Scan()
    {
        var scan = scanner();
        Processes = scan.Items;
        ScanComplete = scan.Complete;
        return Task.CompletedTask;
    }

    /// Whether a client uses this account's data, for recycling. Processes are matched by executable name,
    /// so a client outside the discovered install is still seen. With no match, an incomplete scan or a
    /// failed discovery means the answer is unknown, not "not running".
    public RunState State(Account account)
    {
        var exe = account.App == "claude" ? "Claude.exe" : "ChatGPT.exe";
        if (Processes.Any(p => string.Equals(Path.GetFileName(p.Executable), exe, StringComparison.OrdinalIgnoreCase) && Matches(p.CommandLine, account)))
            return RunState.Running;
        return ScanComplete && Installed.Any(c => c.App == account.App) ? RunState.NotRunning : RunState.Unknown;
    }

    public Running? Find(Account account)
    {
        var client = Installed.FirstOrDefault(c => c.App == account.App);
        if (client == null)
            return null;
        return Processes.FirstOrDefault(p => Store.SamePath(p.Executable, client.Executable) && Matches(p.CommandLine, account));
    }

    public static bool Matches(string command, Account a)
    {
        var args = Arguments(command);
        if (args.Any(x => x == "--type" || x.StartsWith("--type=", StringComparison.Ordinal) || x == "--crashpad-handler"))
            return false;
        for (int i = 0; i < args.Count; i++)
        {
            string? path = args[i].StartsWith("--user-data-dir=", StringComparison.Ordinal) ? args[i][16..] : args[i] == "--user-data-dir" && i + 1 < args.Count ? args[i + 1] : null;
            if (path != null)
            {
                try
                {
                    return Store.SamePath(path, a.ProfilePath);
                }
                catch
                {
                    return false;
                }
            }
        }

        return a.Default;
    }

    public static List<string> Arguments(string command)
    {
        var ptr = CommandLineToArgvW(command, out var count);
        if (ptr == IntPtr.Zero)
            return [];
        try
        {
            return Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(ptr, i * IntPtr.Size)) ?? "").ToList();
        }
        finally
        {
            LocalFree(ptr);
        }
    }

    public async Task Open(Account a)
    {
        if (!Directory.Exists(a.ProfilePath))
            throw new IOException("数据目录不存在，请重新定位。");
        var running = Find(a);
        if (!NeedsLaunch(running))
        {
            var window = (nint)running!.Handle;
            ShowWindow(window, ShowCommand(IsIconic(window)));
            if (!SetForegroundWindow(window))
                throw new ForegroundRefusedException();
            return;
        }

        // A client closed to the tray has no main window. Starting it again with the same arguments
        // reaches its single-instance handler, which brings the existing window forward.
        var client = Installed.FirstOrDefault(c => c.App == a.App) ?? throw new IOException("未找到已验证的客户端。当前支持 Microsoft Store / MSIX 安装版。");
        Process.Start(StartInfo(a, client))?.Dispose();
        await Task.Delay(600);
        await Scan();
    }

    public static bool NeedsLaunch(Running? running) => running is not { Handle: not 0 };
    // SW_RESTORE would also un-maximize a window, so only a minimized one is restored; others get SW_SHOW.
    public static int ShowCommand(bool minimized) => minimized ? 9 : 5;

    public static ProcessStartInfo StartInfo(Account a, Client client)
    {
        var p = new ProcessStartInfo(client.Executable)
        {
            UseShellExecute = false
        };
        if (!a.Default)
            p.ArgumentList.Add("--user-data-dir=" + a.ProfilePath);
        if (a.App == "codex")
            p.Environment["CODEX_HOME"] = a.SessionRoot;
        if (a.App == "claude" && a.ThirdParty)
        {
            p.Environment.Remove("CLAUDE_USER_DATA_DIR");
            p.Environment["LOCALAPPDATA"] = Path.Combine(a.ProfilePath, "local");
            p.Environment["APPDATA"] = Path.Combine(a.ProfilePath, "roaming");
        }

        return p;
    }

    public string ClaudeRoot(Account a) => a.ThirdParty ? Path.Combine(a.ProfilePath, "local", "Claude-3p") : a.ProfilePath;
    public string? CodexCli() => Installed.Where(c => c.App == "codex").Select(c => Path.Combine(Path.GetDirectoryName(c.Executable)!, "resources", "codex.exe")).FirstOrDefault(File.Exists);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern nint CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern nint LocalFree(nint h);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(nint window);
}