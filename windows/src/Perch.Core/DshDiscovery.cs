using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Perch.Windows;

public sealed record DshInstallCandidate(string Path, string Mode, string Version, string Source, string Node = "", string NodeRequirement = "")
{
    public string Label => $"{Source} · {Version}";
}

/// Search installation metadata only. Never execute shims, npm, or npx during discovery.
public sealed record DshSearchEnvironment(string SearchPath, string Home, string AppData, string LocalAppData, string Prefix = "", string Cache = "")
{
    public static DshSearchEnvironment Current() => new(
        string.Join(';', new[] { Environment.GetEnvironmentVariable("PATH"), Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User), Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine) }),
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Environment.GetEnvironmentVariable("npm_config_prefix") ?? "", Environment.GetEnvironmentVariable("npm_config_cache") ?? "");
}

public static class DshDiscovery
{
    public const string OfficialGuide = "https://github.com/deepseek-ai/deepseek-harness#run";
    public const string QuickStart = "npx.cmd @deepseek-ai/dsh web";
    public const string ManualHelp = "已安装但没找到？在终端运行 where.exe dsh，选择输出的 dsh.cmd；也可运行 npm.cmd root -g，选择该目录下的 @deepseek-ai\\dsh。项目本地安装可直接选项目目录。";

    public static string Normalize(string value)
    {
        value = Environment.ExpandEnvironmentVariables(value.Trim().Trim('"'));
        if (value == "~" || value.StartsWith("~/") || value.StartsWith("~\\")) value = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + value[1..];
        return System.IO.Path.GetFullPath(value);
    }

    public static IReadOnlyList<DshInstallCandidate> Discover(DshSearchEnvironment? environment = null)
    {
        var env = environment ?? DshSearchEnvironment.Current();
        var results = new List<DshInstallCandidate>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Add(string path, string source)
        {
            try
            {
                var candidate = Inspect(path, source);
                if (candidate != null && seen.Add(candidate.Path)) results.Add(candidate);
            }
            catch (Exception e) when (IsPathError(e)) { /* One stale or inaccessible installation must not hide the others. */ }
        }
        foreach (var folder in env.SearchPath.Split(';', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Trim().Trim('"')).Where(System.IO.Path.IsPathFullyQualified).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            foreach (var shim in new[] { "dsh.cmd", "dsh.ps1" }) Add(System.IO.Path.Combine(folder, shim), "PATH 命令");
            Add(folder, "PATH / npm");
            // Unix-style npm prefixes and package-manager bin directories.
            Add(System.IO.Path.Combine(folder, "..", "lib"), "PATH / npm 前缀");
        }
        var npmrc = ReadNpmPaths(System.IO.Path.Combine(env.Home, ".npmrc"));
        foreach (var prefix in new[] { env.Prefix, npmrc.Prefix, System.IO.Path.Combine(env.AppData, "npm") }.Where(p => p.Length > 0)) Add(prefix, "npm 全局安装");
        foreach (var cache in new[] { env.Cache, npmrc.Cache, System.IO.Path.Combine(env.LocalAppData, "npm-cache"), System.IO.Path.Combine(env.AppData, "npm-cache") }.Where(p => p.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var npx = System.IO.Path.Combine(Normalize(cache), "_npx");
                if (Directory.Exists(npx))
                    foreach (var folder in new DirectoryInfo(npx).GetDirectories().OrderByDescending(d => d.LastWriteTimeUtc)) Add(folder.FullName, "npx 缓存（可能被 npm 清理）");
            }
            catch (Exception e) when (IsPathError(e)) { }
        }
        return results;
    }

    public static DshInstallCandidate? Inspect(string input, string source = "手动选择")
    {
        if (string.IsNullOrWhiteSpace(input)) return null;
        var path = Normalize(input);
        if (File.Exists(path))
        {
            if (System.IO.Path.GetExtension(path) is ".cmd" or ".ps1") return FromShim(path, source);
            path = System.IO.Path.GetDirectoryName(path)!;
            // Accept package.json or the manifest's CLI entry under lib/ or bin/.
            for (int i = 0; i < 3; i++)
            {
                var found = Package(path, source);
                if (found != null) return found;
                path = System.IO.Path.GetDirectoryName(path) ?? path;
            }
            return null;
        }
        if (!Directory.Exists(path)) return null;
        var direct = Package(path, source);
        if (direct != null) return direct;
        var manifest = System.IO.Path.Combine(path, "package.json");
        if (File.Exists(manifest))
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(manifest));
            if (doc.RootElement.Text("name") == "@deepseek-ai/dsh-root")
            {
                var cli = Package(System.IO.Path.Combine(path, "apps", "cli"), source);
                if (cli != null) return cli with { Path = path, Mode = "source" };
            }
        }
        foreach (var relative in new[] { "node_modules/@deepseek-ai/dsh", "@deepseek-ai/dsh", "lib/node_modules/@deepseek-ai/dsh" })
        {
            var found = Package(System.IO.Path.Combine(path, relative), source);
            if (found != null) return found;
        }
        return null;
    }

    private static DshInstallCandidate? Package(string path, string source)
    {
        var manifest = System.IO.Path.Combine(path, "package.json");
        if (!File.Exists(manifest)) return null;
        using var doc = JsonDocument.Parse(File.ReadAllText(manifest));
        var root = doc.RootElement;
        if (root.Text("name") != "@deepseek-ai/dsh") return null;
        var bin = root.At("bin");
        var entry = bin.ValueKind == JsonValueKind.String ? bin.GetString()! : bin.Text("dsh");
        if (entry.Length == 0 || !File.Exists(System.IO.Path.Combine(path, entry))) return null;
        path = Normalize(path);
        path = new DirectoryInfo(path).ResolveLinkTarget(true)?.FullName ?? path;
        return new(path, "npm", root.Text("version") is { Length: > 0 } version ? version : "版本未知", source, NodeRequirement: root.At("engines").Text("node"));
    }

    private static DshInstallCandidate? FromShim(string shim, string source)
    {
        if (new FileInfo(shim).Length > 65536) return null;
        var script = File.ReadAllText(shim);
        var directory = System.IO.Path.GetDirectoryName(shim)! + System.IO.Path.DirectorySeparatorChar;
        var variables = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["dp0"] = directory };
        string Expand(string value)
        {
            value = value.Replace("%~dp0", directory, StringComparison.OrdinalIgnoreCase).Replace("${basedir}", directory, StringComparison.OrdinalIgnoreCase).Replace("$basedir", directory, StringComparison.OrdinalIgnoreCase);
            return Environment.ExpandEnvironmentVariables(Regex.Replace(value, @"%([^%]+)%", m => variables.GetValueOrDefault(m.Groups[1].Value, m.Value)));
        }
        foreach (Match set in Regex.Matches(script, "(?im)^\\s*@?set\\s+\"?([A-Za-z_][A-Za-z0-9_]*)=([^\\r\\n]*)"))
            variables[set.Groups[1].Value] = Expand(set.Groups[2].Value.Trim().TrimEnd('"'));
        foreach (Match quoted in Regex.Matches(script, "[\"']([^\"'\\r\\n]+)[\"']"))
        {
            var value = Expand(quoted.Groups[1].Value);
            if (!value.Replace('\\', '/').Contains("/@deepseek-ai/dsh/", StringComparison.OrdinalIgnoreCase) || value.Contains('%') || value.Contains('$')) continue;
            if (System.IO.Path.GetExtension(value).ToLowerInvariant() is not (".js" or ".mjs" or ".cjs" or ".json")) continue;
            var found = Inspect(value, source);
            if (found == null) continue;
            var node = variables.TryGetValue("DSH_NODE", out var declared) && File.Exists(declared) ? Normalize(declared)
                : File.Exists(System.IO.Path.Combine(directory, "node.exe")) ? System.IO.Path.Combine(directory, "node.exe") : "";
            return found with { Node = node };
        }
        return null;
    }

    private static (string Prefix, string Cache) ReadNpmPaths(string file)
    {
        string prefix = "", cache = "";
        try
        {
            if (File.Exists(file)) foreach (var line in File.ReadLines(file))
            {
                var parts = line.Split('=', 2);
                if (parts.Length != 2) continue;
                var key = parts[0].Trim();
                // Read only path settings, never authentication or registry settings.
                if (key.Equals("prefix", StringComparison.OrdinalIgnoreCase)) prefix = NpmPath(parts[1]);
                if (key.Equals("cache", StringComparison.OrdinalIgnoreCase)) cache = NpmPath(parts[1]);
            }
        }
        catch (Exception e) when (IsPathError(e)) { }
        return (prefix, cache);
    }
    private static string NpmPath(string value) => Regex.Replace(value.Trim().Trim('"', '\''), @"\$\{([^}]+)\}", m => Environment.GetEnvironmentVariable(m.Groups[1].Value) ?? m.Value);
    public static bool IsPathError(Exception e) => e is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException or System.Security.SecurityException;
}
