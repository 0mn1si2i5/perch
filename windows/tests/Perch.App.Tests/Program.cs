using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Perch.Windows;

static class Program
{
    static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    static void Pump(int milliseconds)
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(milliseconds) };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
    }

    [STAThread]
    static void Main()
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var root = Path.Combine(Path.GetTempPath(), "perch-pet-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new Store(root);
            store.Preferences.MediaEnabled = false;
            using var model = new PanelModel(store, false);
            using var theme = new ThemeManager(() => model.PetEnabled ? model.Store.Preferences.PetCharacter : null, null);
            DshEditorTests.Run(root);
            AccountLayoutTests.Run(root);
            var systemTheme = theme.Name;
            var pet = new PetWindow(store, () => { }, () => { });
            try
            {
                model.ConfigurationChanged = () => { pet.Configure(); theme.Apply(); };
                var grid = (Grid)pet.Content;
                var sprite = (Image)grid.Children[0];
                var capsule = (Border)grid.Children[2];
                var bubble = (Border)grid.Children[3];
                model.PetEnabled = true;
                model.PetKind = 1;
                pet.Show();
                Pump(150);
                Check(theme.Name == "Pox", "Pox keeps its panel theme");
                pet.Preview(7);
                Check(((CroppedBitmap)sprite.Source).SourceRect.Y == 449, "Pox keeps the legacy crop boundary");
                pet.ShowCompletion("fixture completion");
                Check(((TextBlock)bubble.Child).Text == Strings.Get("pet.completion") + "\nfixture completion", "Pox keeps its completion copy");
                model.PetKind = 2;
                Pump(150);
                Check(theme.Name == "DeepSeek" && ((SolidColorBrush)app.FindResource("Accent")).Color == Color.FromRgb(77, 107, 254), "Whale uses official DeepSeek blue dark palette");
                Check(model.IsSpritePet && pet.Title == "DeepSeek 鲸鱼娘", "Whale exposes animated pet options");
                Check(((CroppedBitmap)sprite.Source).SourceRect.X == 0 && ((CroppedBitmap)sprite.Source).SourceRect.Y == 0, "Switch clears the prior preview");
                Check(bubble.Visibility == Visibility.Collapsed, "Switch clears prior completion bubble");
                model.PetSize = 135;
                pet.SetActivity([new("fixture", "Running fixture", "运行中", DateTimeOffset.UtcNow)]);
                for (int i = 0; i < 8; i++)
                {
                    pet.Preview(i);
                    Pump(150);
                    Check(((TextBlock)capsule.Child).Text == Strings.Get("pet.whale.pose." + i), "Whale preview uses character-specific dialogue");
                    capsule.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                    Check(capsule.DesiredSize.Width <= pet.Width, "Whale dialogue fits the smallest pet size");
                    var crop = (CroppedBitmap)sprite.Source;
                    var source = (BitmapSource)crop.Source;
                    Check(crop.SourceRect.X == i % 4 * source.PixelWidth / 4 && crop.SourceRect.Y == (i < 4 ? 0 : (source.PixelHeight + 1) / 2), "Whale pose order and equal grid crops");
                }
                pet.Preview(5, 1);
                Pump(1250);
                Check(((CroppedBitmap)sprite.Source).SourceRect.X == ((BitmapSource)((CroppedBitmap)sprite.Source).Source).PixelWidth / 2, "Preview expires into current task pose");
                Check(((TextBlock)capsule.Child).Text == Strings.Get("pet.whale.running").Replace("{0}", "1"), "Whale keeps the live task count");
                pet.ShowCompletion("fixture completion");
                Pump(150);
                Check(bubble.Visibility == Visibility.Visible && ((TextBlock)bubble.Child).Text == Strings.Get("pet.whale.completion") + "\nfixture completion", "Whale completion keeps the title and uses shared dialogue");
                model.PetKind = 1;
                Pump(150);
                Check(bubble.Visibility == Visibility.Collapsed && ((TextBlock)capsule.Child).Text == Strings.Get("pet.running").Replace("{0}", "1"), "Switching to Pox clears whale feedback and restores Pox copy");
                pet.Preview(7);
                Pump(150);
                Check(((TextBlock)capsule.Child).Text == Strings.Get("pet.preview"), "Pox preview keeps its original copy");
                model.PetKind = 0;
                pet.ShowCompletion("native fixture");
                Pump(150);
                Check(bubble.Visibility == Visibility.Collapsed && capsule.Visibility == Visibility.Collapsed, "Native orb never displays whale dialogue");
                model.PetKind = 2;
                foreach (double size in new[] { 135d, 190d, 265d })
                {
                    model.PetSize = size;
                    Check(Math.Abs(pet.Width - size) < 1 && Math.Abs(pet.Height - size - 125) < 1, $"Whale supports pet sizing: requested {size}, actual {pet.Width} x {pet.Height}");
                }
                model.Quiet = true;
                pet.ShowCompletion("Quiet fixture");
                Pump(150);
                Check(bubble.Visibility == Visibility.Collapsed && capsule.Visibility == Visibility.Collapsed && sprite.RenderTransform.Value == Matrix.Identity, "Quiet mode suppresses bubbles and motion");
                model.Quiet = false;
                pet.Hide();
                model.TogglePet.Execute(null);
                Check(theme.Name == "DeepSeek", "Hiding whale preserves its theme");
                Check(!new Store(root).Preferences.PetVisible && new Store(root).Preferences.PetCharacter == "deepseek-whale", "Hidden selection survives reload");
                pet.Show();
                model.TogglePet.Execute(null);
                model.PetKind = 1;
                model.PetKind = 2;
                Check(((CroppedBitmap)sprite.Source).SourceRect.X == ((BitmapSource)((CroppedBitmap)sprite.Source).Source).PixelWidth / 2, "Switch restores active tasks immediately");
                model.PetEnabled = false;
                Check(theme.Name == systemTheme, "Disabling pet restores system appearance");
                var before = sprite.Source;
                pet.Preview(7);
                Pump(150);
                Check(ReferenceEquals(before, sprite.Source), "Disabled pet stops activity and rejects previews");
                store.Preferences.PetCharacter = "removed-character";
                pet.Configure();
                Check(model.PetKind == 0 && !model.IsSpritePet && pet.Width == 60, "Unknown character falls back to native orb");
            }
            finally { pet.Close(); }
            Console.WriteLine("PASS: real WPF pet crops, switching, persistence, themes, preview expiry, sizing, quiet mode and lifecycle");
        }
        finally
        {
            app.Shutdown();
            Directory.Delete(root, true);
        }
    }
}
