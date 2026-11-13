using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Perch.Windows;

public static class ClientKinds
{
    public static readonly string[] All = ["codex", "claude", "dsh"];
    public static string Label(string app) => app switch { "codex" => "Codex", "claude" => "Claude", "dsh" => "DeepSeek Harness", _ => app };
}

/// Installation is independent of the account's DSH_HOME. Secrets never belong here.
public sealed class DshConfiguration
{
    public string Mode { get; set; } = "npm";
    public string InstallationPath { get; set; } = "";
    public string NodePath { get; set; } = "";
    public string Profile { get; set; } = "web";
    public string BalanceHome { get; set; } = "";
}

public sealed record DshLaunch(string Node, string Entry, string WorkingDirectory, string Home, string Profile)
{
    public ProcessStartInfo StartInfo()
    {
        var info = new ProcessStartInfo(Node) { WorkingDirectory = WorkingDirectory, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { Entry, "--profile", Profile, "--host", "127.0.0.1", "--port", "0", "--no-open" })
            info.ArgumentList.Add(arg);
        info.Environment["DSH_HOME"] = Home;
        return info;
    }
}

public static class DshInstallation
{
    public static string? FindNode() => DshSearchEnvironment.Current().SearchPath.Split(';', StringSplitOptions.RemoveEmptyEntries)
        .Select(p => p.Trim().Trim('"')).Where(Path.IsPathFullyQualified)
        .Select(p => Path.Combine(p, "node.exe")).FirstOrDefault(File.Exists);

    public static string? FindNpm()
    {
        return DshDiscovery.Discover().FirstOrDefault()?.Path;
    }

    public static DshLaunch Resolve(Account account)
    {
        var config = account.Dsh ?? throw new IOException("请重新配置 dsh 启动方式。");
        if (config.Mode is not ("source" or "npm"))
            throw new IOException("这个 dsh 账号只连接已有实例，请提供新的授权 URL。");
        string? install = null;
        DshInstallCandidate? detected;
        try
        {
            detected = string.IsNullOrWhiteSpace(config.InstallationPath) ? DshDiscovery.Discover().FirstOrDefault() : DshDiscovery.Inspect(config.InstallationPath);
            install = detected?.Path ?? (string.IsNullOrWhiteSpace(config.InstallationPath) ? null : DshDiscovery.Normalize(config.InstallationPath));
        }
        catch (Exception e) when (DshDiscovery.IsPathError(e)) { throw new IOException("无法读取 dsh 安装。请检查路径与权限，或展开“未识别到？手动添加指引”。", e); }
        var node = string.IsNullOrWhiteSpace(config.NodePath) ? detected?.Node is { Length: > 0 } bundled ? bundled : FindNode() : DshDiscovery.Normalize(config.NodePath);
        if (node == null || !File.Exists(node))
            throw new IOException("找不到 Node.js，请安装符合 dsh 要求的 Node 或选择 node.exe。");
        if (install == null)
            throw new IOException("未发现可用的 dsh。请展开“未识别到？手动添加指引”，选择安装位置或连接已有实例。");
        if (detected != null) install = detected.Path;
        string package;
        if (config.Mode == "source")
        {
            using var manifest = ReadManifest(install);
            if (manifest.RootElement.Text("name") != "@deepseek-ai/dsh-root")
                throw new IOException("请选择 deepseek-harness 源码仓库根目录。");
            package = Path.Combine(install, "apps", "cli");
            if (!File.Exists(Path.Combine(install, "apps", "web", "dist", "index.html")))
                throw new IOException("dsh Web 尚未构建，请在源码目录运行 pnpm install 和 pnpm run build。");
        }
        else
        {
            if (detected?.Mode == "source") throw new IOException("这是源码仓库，请将启动方式切换为“源码构建版”。");
            package = detected?.Path ?? install;
            // Accept either the package itself or a project containing a local npm install.
            if (File.Exists(Path.Combine(package, "node_modules", "@deepseek-ai", "dsh", "package.json")))
                package = Path.Combine(package, "node_modules", "@deepseek-ai", "dsh");
        }
        using var cli = ReadManifest(package);
        if (cli.RootElement.Text("name") != "@deepseek-ai/dsh")
            throw new IOException("请选择 npm 的 @deepseek-ai/dsh 包目录或 deepseek-harness 源码目录。");
        var bin = cli.RootElement.At("bin");
        var entryName = bin.ValueKind == JsonValueKind.String ? bin.GetString()! : bin.Text("dsh");
        var entry = Path.GetFullPath(Path.Combine(package, entryName));
        if (entryName.Length == 0 || !File.Exists(entry))
            throw new IOException(config.Mode == "source" ? "dsh CLI 尚未构建，请在源码目录运行 pnpm run build。" : "dsh 安装不完整，找不到包声明的 CLI 入口。");
        var profile = config.Profile.Trim();
        if (profile.Length == 0 || profile.Equals("desktop", StringComparison.OrdinalIgnoreCase) || profile.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || profile is "." or "..")
            throw new IOException("请选择有效的 Web profile，不能使用 Electron 专属的 desktop。");
        var home = Path.GetFullPath(account.ProfilePath);
        if (profile != "web" && !File.Exists(Path.Combine(home, "profiles", profile, "package.json")))
            throw new IOException("自定义 Web profile 不存在，请先在 dsh 中创建并配置。");
        return new(node, entry, install, home, profile);
    }

    private static JsonDocument ReadManifest(string directory)
    {
        try { return JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "package.json"))); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { throw new IOException("无法读取 dsh 的 package.json，请检查安装目录。", e); }
    }
}
