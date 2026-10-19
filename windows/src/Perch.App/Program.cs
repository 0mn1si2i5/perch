using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace Perch.Windows;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        bool demo = args.Contains("--demo");
        string? Option(string key)
        {
            int i = Array.IndexOf(args, key);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }

        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\com.omnis.perch.windows.show");
        using var mutex = new Mutex(!demo, demo ? "Local\\com.omnis.perch.demo." + Guid.NewGuid() : "Local\\com.omnis.perch.windows", out var first);
        if (!demo && !first)
        {
            show.Set();
            return;
        }

        var app = new Application
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown
        };
        string? temp = demo ? Path.Combine(Path.GetTempPath(), "perch-demo-" + Guid.NewGuid().ToString("N")) : null;
        Panel? shown = null;
        bool running = false;
        // A file or clipboard error that escapes a handler is reported in the panel instead of closing Perch.
        // Screenshot runs must fail and exit instead, so they keep the default behavior.
        if (Option("--screenshot") == null)
            app.DispatcherUnhandledException += (_, e) =>
            {
                if (shown == null || e.Exception is not (IOException or UnauthorizedAccessException or COMException))
                    return;
                e.Handled = true;
                shown.Model.Notify(PanelModel.Describe(e.Exception));
            };
        TaskScheduler.UnobservedTaskException += (_, e) => e.SetObserved();
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            // Off the UI thread nothing can be recovered; say so before the process ends.
            if (Option("--screenshot") == null)
                MessageBox.Show("Perch 遇到意外错误，即将退出。账号和接力文档不受影响。", "Perch", MessageBoxButton.OK, MessageBoxImage.Error);
        };
        try
        {
            var store = new Store(temp);
            if (demo)
                store.Preferences.PetCharacter = Option("--theme") == "pox" ? "pox" : "native";
            using var theme = new ThemeManager(() => store.Preferences.PetEnabled && store.Preferences.PetCharacter == "pox", Option("--theme"));
            var panel = new Panel(store, theme, demo, args.Contains("--keep-open") || Option("--screenshot") != null, args.Contains("--inspect"));
            shown = panel;
            panel.Model.Page = Option("--page") ?? "accounts";
            using var tray = demo && !args.Contains("--tray-menu") ? null : new Tray(panel);
            var wait = demo ? null : ThreadPool.RegisterWaitForSingleObject(show, (_, _) => app.Dispatcher.BeginInvoke(panel.OpenPanel), null, -1, false);
            app.Exit += (_, _) =>
            {
                wait?.Unregister(null);
                panel.Dispose();
            };
            if (args.Contains("--show") || demo || store.Accounts.Count == 0)
                panel.OpenPanel();
            // The tray now listens; notices held during startup can reach it.
            app.Dispatcher.BeginInvoke(panel.Model.Ready);
            panel.DemoPet(int.TryParse(Option("--pet-pose"), out int pose) ? pose : null, args.Contains("--pet-complete"));
            if (args.Contains("--tray-menu"))
                panel.Dispatcher.BeginInvoke(() => tray?.ShowMenu());
            if (Option("--screenshot") is string directory)
            {
                var timer = new DispatcherTimer
                {
                    Interval = TimeSpan.FromMilliseconds(800)
                };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    if (double.TryParse(Option("--scroll"), out double offset))
                        panel.DemoScroll(offset);
                    panel.Capture(directory, int.TryParse(Option("--dpi"), out int dpi) ? dpi : 96);
                    if (args.Contains("--tray-menu"))
                        tray?.Capture(directory);
                    app.Shutdown();
                };
                timer.Start();
            }

            running = true;
            app.Run();
        }
        catch (Exception e)
        {
            if (Option("--screenshot") is string dir)
            {
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "error.txt"), e.ToString());
                Environment.ExitCode = 1;
            }
            else if (running)
                MessageBox.Show("Perch 遇到意外错误，已退出。账号和接力文档不受影响。", "Perch", MessageBoxButton.OK, MessageBoxImage.Error);
            else
                MessageBox.Show(e is IOException ? e.Message : "Perch 无法启动，请检查本机数据目录。原始文件已保留。", "Perch", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            if (temp != null && Directory.Exists(temp))
                Directory.Delete(temp, true);
        }
    }
}
