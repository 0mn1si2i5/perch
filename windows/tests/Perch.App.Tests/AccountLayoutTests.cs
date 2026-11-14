using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Perch.Windows;

internal static class AccountLayoutTests
{
    static IEnumerable<T> Find<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T value) yield return value;
            foreach (var item in Find<T>(child)) yield return item;
        }
    }
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static void Run(string root)
    {
        using var model = new PanelModel(new Store(Path.Combine(root, "layout")), true);
        model.NewDsh = true;
        model.DshInstalls.Add(new(@"C:\fixture\dsh", "npm", "0.2.1", "fixture"));
        model.SelectedDshInstall = model.DshInstalls[0];
        var page = new NewAccountPage { DataContext = model };
        var host = new Window { Content = page, Width = 340, Height = 900, ShowActivated = false, Left = -10000, Top = -10000 };
        host.Show();
        try
        {
            host.UpdateLayout();
            var input = Find<TextBox>(page).First();
            var hint = (TextBlock)input.Template.FindName("Hint", input);
            var hintOrigin = hint.TransformToAncestor(input).Transform(new Point());
            input.Text = "名称";
            host.UpdateLayout();
            var caret = input.GetRectFromCharacterIndex(0);
            Check(Math.Abs(caret.X - hintOrigin.X - hint.Padding.Left) <= 1 && Math.Abs(caret.Y - hintOrigin.Y) <= 2,
                $"Placeholder and actual input must align: hint {hintOrigin}, caret {caret}");
            var selected = Find<ComboBox>(page).First(c => c.ItemsSource != null);
            Check(Find<TextBlock>(selected).Any(t => t.Text == model.SelectedDshInstall.Label), "Selected install must display Label rather than record ToString");
            var hoverKey = (DependencyPropertyKey)typeof(UIElement).GetField("IsMouseOverPropertyKey", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!.GetValue(null)!;
            foreach (var radio in Find<RadioButton>(page))
            {
                Check(Find<Image>(radio).Single().Source != null, "Every client segment must have an icon");
                var before = radio.DesiredSize;
                radio.SetValue(hoverKey, true);
                host.UpdateLayout();
                Check(radio.DesiredSize == before, "Hover must preserve segment dimensions");
                radio.SetValue(hoverKey, false);
            }
            var account = new AccountModel(model, new Account { App = "dsh", Name = "fixture" });
            var now = DateTimeOffset.UtcNow;
            var api = new ApiBalanceResult([new("总额", "CNY", 40.94m), new("充值", "CNY", 40.94m), new("赠送", "CNY", 0)], now, "查询成功");
            account.Update(new(true, [], "dsh 本机 Web", 0, now), new([], now, "默认模型：DeepSeek API Key 已配置\n官方账户未登录", ApiBalance: api));
            Check(account.ApiBalanceSummary == "￥40.94", "Normal API account has concise balance and no false login warning");
            var rows = new QuotaRows { DataContext = account };
            model.Page = "settings";
            model.Home.Execute(null);
            Check(model.IsAccounts, "Home must always navigate directly to accounts");
            host.Content = rows;
            host.UpdateLayout();
            var expander = Find<Expander>(rows).Single();
            var toggle = Find<ToggleButton>(expander).First();
            Check(!expander.IsExpanded, "API balance starts collapsed");
            Check(!Find<TextBlock>(rows).Any(t => t.IsVisible && t.Text == "dsh 本机 Web"), "Connection details collapse with balance");
            toggle.IsChecked = true;
            host.UpdateLayout();
            Check(expander.IsExpanded && account.ApiBalanceExpanded && Find<TextBlock>(rows).Any(t => t.IsVisible && t.Text == "充值 · CNY"), "Click expands actual balance breakdown");
            var visibleDetails = Find<TextBlock>(rows).Where(t => t.IsVisible).Select(t => t.Text).ToList();
            Check(visibleDetails.IndexOf("总额 · CNY") < visibleDetails.IndexOf("充值 · CNY")
                && visibleDetails.IndexOf("充值 · CNY") < visibleDetails.IndexOf("赠送 · CNY")
                && visibleDetails.IndexOf("赠送 · CNY") < visibleDetails.IndexOf("dsh 本机 Web")
                && visibleDetails.IndexOf("dsh 本机 Web") < visibleDetails.IndexOf(account.QuotaDetail), "Expanded balance preserves old vertical detail order");
            var qa = Environment.GetEnvironmentVariable("PERCH_PANEL_QA_OUTPUT");
            if (!string.IsNullOrEmpty(qa))
            {
                Directory.CreateDirectory(qa);
                var card = new AccountCard { DataContext = account, Width = 308 };
                host.Content = new StackPanel { Children = { card } };
                host.UpdateLayout();
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(308, (int)Math.Ceiling(card.ActualHeight), 96, 96, PixelFormats.Pbgra32);
                var visual = new DrawingVisual();
                using (var drawing = visual.RenderOpen())
                {
                    drawing.DrawRectangle((Brush)Application.Current.FindResource("PanelFill"), null, new Rect(0, 0, 308, card.ActualHeight));
                    drawing.DrawRectangle(new VisualBrush(card), null, new Rect(0, 0, 308, card.ActualHeight));
                }
                bitmap.Render(visual);
                var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                using var file = File.Create(Path.Combine(qa, "expanded-balance.png"));
                encoder.Save(file);
                host.Content = rows;
                host.UpdateLayout();
            }
            account.Update(new(true, [], "dsh 本机 Web", 0, now), new([], now, "查询失败", ApiBalance: api with { Cached = true }));
            Check(account.ApiBalanceSummary.Contains("缓存") && account.QuotaDetail == "查询失败" && expander.IsExpanded, "Refresh preserves expansion and exposes stale/error status");
            account.Update(new(true, [], "dsh 本机 Web", 0, now), new([], now, "查询失败", ApiBalance: new([], null, "网络查询失败")));
            Check(account.ApiBalanceSummary == "暂不可用", "Missing balance must never appear as zero");
        }
        finally { host.Close(); }
        Console.WriteLine("PASS: actual WPF input alignment, segment hover/icons, install label, balance disclosure and cache/error states");
    }
}
