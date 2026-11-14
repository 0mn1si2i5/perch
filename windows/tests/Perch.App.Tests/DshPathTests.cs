using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Perch.Windows;

internal static class DshPathTests
{
    public static void Run(string root)
    {
        const string variable = "PERCH_TEST_DSH_HOME";
        var previous = Environment.GetEnvironmentVariable(variable);
        var home = Path.Combine(root, "existing dsh home with spaces");
        var install = Path.Combine(root, "dsh path package");
        Directory.CreateDirectory(Path.Combine(home, "profiles", "existing"));
        File.WriteAllText(Path.Combine(home, "profiles", "existing", "package.json"), "{}");
        Directory.CreateDirectory(install);
        File.WriteAllText(Path.Combine(install, "package.json"), """{"name":"@deepseek-ai/dsh","bin":{"dsh":"bin.js"}}""");
        File.WriteAllText(Path.Combine(install, "bin.js"), "// fixture, never executed");
        var node = Path.Combine(install, "node.exe");
        File.WriteAllText(node, "fixture, never executed");
        Environment.SetEnvironmentVariable(variable, home);
        try
        {
            var store = new Store(Path.Combine(root, "dsh managed path store"));
            using var model = new PanelModel(store, false);
            model.AddDshManually.Execute(null);
            model.NewName = "Expanded existing home";
            model.DshPath = install;
            model.DshNode = node;
            model.DshProfile = "existing";
            model.DshHome = "\"%" + variable + "%\"";
            model.CheckDshInstallation.Execute(null);
            Check(model.DshValidation.StartsWith("启动文件检查通过", StringComparison.Ordinal), "The existing custom profile must pass validation through its expanded home");

            // Prevent launching any process/browser after creation. The current process
            // is only a liveness marker; the error phase makes Ensure return immediately.
            using var current = Process.GetCurrentProcess();
            new DshState(store.Root, DshState.ForHome(home)).Write(new("error", ChildPid: current.Id,
                ChildStarted: current.StartTime.ToUniversalTime().Ticks, Detail: "Isolated path test does not launch dsh"));
            model.Create.Execute(null);
            Check(!model.Interacting && store.Accounts.Count == 1, "Creating the checked custom profile must resolve the same home without starting a service");
            var saved = new Store(store.Root).Accounts.Single();
            Check(Store.SamePath(saved.ProfilePath, home) && Store.SamePath(saved.SessionRoot, home), "Creation must persist the expanded home used by validation");

            var externalStore = new Store(Path.Combine(root, "dsh external path store"));
            var external = new Account { App = "dsh", Name = "Existing connection", ProfilePath = Path.Combine(externalStore.Root, "external home"), Dsh = new() { Mode = "external" } };
            externalStore.Add(external);
            using var externalModel = new PanelModel(externalStore, false);
            externalModel.ConfigureDsh(external);
            externalModel.DshBalanceHome = "\"%" + variable + "%\"";
            externalModel.Create.Execute(null);
            Check(!externalModel.Interacting && Store.SamePath(new Store(externalStore.Root).Accounts.Single().Dsh!.BalanceHome, home), "Editing an external balance directory must expand the same quoted environment path");
        }
        finally { Environment.SetEnvironmentVariable(variable, previous); }
        Console.WriteLine("PASS: dsh managed-home validation/creation and external balance-home path expansion");
    }

    private static void Check(bool value, string why) { if (!value) throw new Exception(why); }
}
