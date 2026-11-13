using System;
using System.IO;
using System.Windows;
using Perch.Windows;

static class Program
{
    [STAThread]
    static void Main()
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var root = Path.Combine(Path.GetTempPath(), "perch-ui-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            using var theme = new ThemeManager(() => false, null);
            DshEditorTests.Run(root);
            AccountLayoutTests.Run(root);
        }
        finally
        {
            app.Shutdown();
            Directory.Delete(root, true);
        }
    }
}
