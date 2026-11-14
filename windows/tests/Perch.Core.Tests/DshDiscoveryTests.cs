using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using Perch.Windows;

internal static class DshDiscoveryTests
{
    public static void Run(string root)
    {
        root = Path.Combine(root, "dsh discovery with spaces");
        Directory.CreateDirectory(root);
        var env = new DshSearchEnvironment(Path.Combine(root, "custom", "bin"), Path.Combine(root, "user"), Path.Combine(root, "roaming"), Path.Combine(root, "local"));
        Directory.CreateDirectory(env.SearchPath);
        Directory.CreateDirectory(env.Home);
        string Package(string directory, string version, string name = "@deepseek-ai/dsh")
        {
            Directory.CreateDirectory(Path.Combine(directory, "lib"));
            File.WriteAllText(Path.Combine(directory, "package.json"), JsonSerializer.Serialize(new { name, version, bin = new { dsh = "lib/bin.js" }, engines = new { node = ">=24.9.0" } }));
            File.WriteAllText(Path.Combine(directory, "lib", "bin.js"), "// fixture, never executed");
            return Path.GetFullPath(directory);
        }
        var custom = Package(Path.Combine(root, "custom", "app", "node_modules", "@deepseek-ai", "dsh"), "0.2.1-rc.5");
        var command = Path.Combine(env.SearchPath, "dsh.cmd");
        File.WriteAllText(command, """
            @echo off
            setlocal
            set "DSH_ROOT=%~dp0.."
            set "DSH_NODE=%DSH_ROOT%\node\node.exe"
            "%DSH_NODE%" "%DSH_ROOT%\app\node_modules\@deepseek-ai\dsh\lib\bin.js" %*
            echo this script must never run > should-not-exist
            """);
        Directory.CreateDirectory(Path.Combine(root, "custom", "node"));
        File.WriteAllText(Path.Combine(root, "custom", "node", "node.exe"), "fixture");
        var prefix = Path.Combine(root, "custom npm prefix");
        var global = Package(Path.Combine(prefix, "node_modules", "@deepseek-ai", "dsh"), "0.2.2-rc.1");
        File.WriteAllText(Path.Combine(env.Home, ".npmrc"), $"prefix={prefix}\ncache={Path.Combine(root, "custom cache")}\n//registry.example/:_authToken=must-not-be-read\n");
        var cache = Package(Path.Combine(root, "custom cache", "_npx", "hash", "node_modules", "@deepseek-ai", "dsh"), "0.2.2-rc.2");
        var broken = Package(Path.Combine(env.AppData, "npm", "node_modules", "@deepseek-ai", "dsh"), "broken");
        File.WriteAllText(Path.Combine(broken, "package.json"), "{ invalid json");
        var found = DshDiscovery.Discover(env);
        Check(found.Count == 3 && found[0].Path == custom && found[1].Path == global && found[2].Path == cache, "PATH wrappers, npmrc prefixes and official npx cache must all be found, skipping corrupt manifests");
        Check(found[0].Node.EndsWith("node\\node.exe") && found[0].NodeRequirement == ">=24.9.0", "Wrapper's bundled Node and package's Node requirement must be retained");
        Check(!File.Exists("should-not-exist"), "Discovery must not execute commands");
        Check(DshDiscovery.Inspect(command)?.Path == custom && DshDiscovery.Inspect(prefix)?.Path == global && DshDiscovery.Inspect(Path.Combine(global, "package.json"))?.Path == global, "Manual command, prefix and manifest selection resolve the same package");
        var shimRoot = Path.Combine(root, "npm shim");
        var npm = Package(Path.Combine(shimRoot, "node_modules", "@deepseek-ai", "dsh"), "npm");
        File.WriteAllText(Path.Combine(shimRoot, "dsh.cmd"), "@\"%dp0%\\node.exe\" \"%dp0%\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js\" %*");
        File.WriteAllText(Path.Combine(shimRoot, "dsh.ps1"), "& \"$basedir/node.exe\" \"$basedir/node_modules/@deepseek-ai/dsh/lib/bin.js\" $args");
        Check(DshDiscovery.Inspect(Path.Combine(shimRoot, "dsh.ps1"))?.Path == npm, "npm PowerShell shim resolves without execution-policy changes");
        Check(DshDiscovery.Discover(env with { SearchPath = shimRoot + ";" + shimRoot + ";relative-path", Prefix = shimRoot }).Count(c => c.Path == npm) == 1, "Repeated paths, shims and prefixes deduplicate while relative PATH entries are ignored");
        File.Delete(Path.Combine(cache, "lib", "bin.js"));
        Check(DshDiscovery.Discover(env).Count == 2, "Evicted npx cache must not remain discoverable");
        var impostor = Package(Path.Combine(root, "unrelated"), "1", "not-dsh");
        Check(DshDiscovery.Inspect(impostor) == null, "A directory name is not sufficient evidence of dsh");
        var source = Path.Combine(root, "source");
        Package(Path.Combine(source, "apps", "cli"), "source");
        File.WriteAllText(Path.Combine(source, "package.json"), """{"name":"@deepseek-ai/dsh-root"}""");
        Check(DshDiscovery.Inspect(source)?.Mode == "source", "Source root must be recognized independently of the currently selected mode");
        Console.WriteLine("PASS: dsh discovery, wrappers, npm prefixes, npx caches, manual paths, deduplication and invalid-install fallback");
    }
    private static void Check(bool value, string why) { if (!value) throw new Exception(why); }
}
