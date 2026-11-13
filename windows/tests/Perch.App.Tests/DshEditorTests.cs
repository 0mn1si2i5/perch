using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Perch.Windows;

internal static class DshEditorTests
{
    public static void Run(string root)
    {
        var store = new Store(Path.Combine(root, "dsh editor"));
        using var model = new PanelModel(store, false);
        model.AddDshManually.Execute(null);
        Check(model.NewDsh && model.Page == "add" && model.DshHelpExpanded, "Missing-install entry must open dsh with manual instructions");
        model.DshPath = Path.Combine(root, "missing installation");
        model.CheckDshInstallation.Execute(null);
        Check(model.HasDshValidation && model.DshHelpExpanded && store.Accounts.Count == 0, "Failed checks remain inline without saving an account");
        model.ConnectDshInstead.Execute(null);
        Check(model.DshExternal && model.CreateLabel == "连接并添加", "Manual instructions must lead to the existing-instance form");
        model.DshMode = 1;
        model.DshPath = Path.Combine(root, "missing installation");
        model.CheckDshInstallation.Execute(null);
        var page = new NewAccountPage { DataContext = model, Width = 312 };
        page.Measure(new Size(312, double.PositiveInfinity));
        page.Arrange(new Rect(0, 0, 312, page.DesiredSize.Height));
        page.UpdateLayout();
        Check(page.DesiredSize.Height > 500, "Expanded manual instructions must render in the add-page scroll area");
        var output = Environment.GetEnvironmentVariable("PERCH_DSH_QA_OUTPUT");
        if (!string.IsNullOrWhiteSpace(output))
        {
            Directory.CreateDirectory(output);
            var bitmap = new RenderTargetBitmap(340, (int)Math.Ceiling(page.ActualHeight + 28), 96, 96, PixelFormats.Pbgra32);
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                context.DrawRectangle((Brush)Application.Current.FindResource("PanelFill"), null, new Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight));
                context.DrawRectangle(new VisualBrush(page), null, new Rect(14, 14, 312, page.ActualHeight));
            }
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(Path.Combine(output, "manual-add.png"));
            encoder.Save(stream);
        }
        model.DshNode = "changed-node.exe";
        Check(!model.HasDshValidation, "Editing startup configuration must clear the old check result");
        model.SelectedDshInstall = new(Path.Combine(root, "first package"), "npm", "0.2.1", "fixture");
        model.DshPath = "manual override";
        model.SelectedDshInstall = null;
        model.SelectedDshInstall = new(Path.Combine(root, "first package"), "npm", "0.2.1", "fixture");
        Check(model.DshPath.EndsWith("first package"), "Selecting a detected package again must replace the manual override");
        Console.WriteLine("PASS: dsh missing-install entry, persistent validation, manual connection fallback and WPF help layout");
    }
    private static void Check(bool value, string why) { if (!value) throw new Exception(why); }
}
