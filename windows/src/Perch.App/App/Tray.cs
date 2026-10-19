using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Perch.Windows;

public sealed class Tray : IDisposable
{
    private readonly Forms.NotifyIcon icon;
    private readonly System.Drawing.Icon drawing;
    private readonly Panel panel;
    private ContextMenu? menu;
    // The shell does not say which balloon was clicked or closed, so balloons are shown one at a time and the
    // one on screen keeps its own action (null opens the panel). One that never reports closing is given up.
    private readonly Queue<(string Title, string Body, Forms.ToolTipIcon Kind, NoticeAction? Action)> waiting = new();
    private readonly DispatcherTimer giveUp = new() { Interval = TimeSpan.FromSeconds(10) };
    private bool showing;
    private NoticeAction? action;
    public Tray(Panel window)
    {
        panel = window;
        drawing = Brand.TrayIcon();
        icon = new Forms.NotifyIcon
        {
            Icon = drawing,
            Text = "Perch · Codex / Claude",
            Visible = true
        };
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
                panel.TrayToggle();
            else if (e.Button == Forms.MouseButtons.Right)
                ShowMenu();
        };
        icon.BalloonTipClicked += (_, _) =>
        {
            var clicked = action;
            ShowNext();
            if (clicked == null || !panel.Model.Perform(clicked))
                panel.OpenPanel();
        };
        icon.BalloonTipClosed += (_, _) => ShowNext();
        giveUp.Tick += (_, _) => ShowNext();
        panel.BackgroundError += Error;
        panel.Notice += Show;
    }

    private void Error(string value) => Enqueue("Perch", value, Forms.ToolTipIcon.Warning, null);
    private void Show(string title, string body, NoticeAction? next) => Enqueue(title, body, Forms.ToolTipIcon.Info, next);

    private void Enqueue(string title, string body, Forms.ToolTipIcon kind, NoticeAction? next)
    {
        waiting.Enqueue((Fit(title, 63), Fit(body, 255), kind, next));
        if (!showing)
            ShowNext();
    }

    private void ShowNext()
    {
        giveUp.Stop();
        showing = waiting.TryDequeue(out var next);
        action = showing ? next.Action : null;
        if (!showing)
            return;
        icon.ShowBalloonTip(5000, next.Title, next.Body, next.Kind);
        giveUp.Start();
    }

    // The shell keeps at most 63 characters of a balloon title and 255 of its text.
    private static string Fit(string text, int limit) => text.Length > limit ? text[..(limit - 1)] + "…" : text;
    public void ShowMenu()
    {
        menu?.SetCurrentValue(ContextMenu.IsOpenProperty, false);
        menu = new ContextMenu
        {
            Placement = PlacementMode.MousePoint
        };
        void Add(string label, Action action)
        {
            var item = new MenuItem
            {
                Header = label
            };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("打开面板", panel.OpenPanel);
        if (panel.Model.PetEnabled)
        {
            Add(panel.Model.PetVisible ? "隐藏桌宠" : "显示桌宠", panel.TogglePet);
            Add("恢复桌宠位置", panel.ResetPet);
        }

        menu.Items.Add(new Separator());
        Add("退出 Perch", () => Application.Current.Shutdown());
        // A popup opened while another app is in front never sees the outside click or Esc.
        // Bring an invisible Perch window forward first so the menu dismisses like a native one.
        var owner = Host();
        owner.Show();
        owner.Activate();
        SetForegroundWindow(new WindowInteropHelper(owner).Handle);
        menu.Closed += (_, _) => owner.Hide();
        menu.IsOpen = true;
    }

    private Window? host;
    private Window Host() => host ??= new Window
    {
        WindowStyle = WindowStyle.None,
        AllowsTransparency = true,
        Background = Brushes.Transparent,
        ShowInTaskbar = false,
        Topmost = true,
        Width = 1,
        Height = 1,
        Left = -32000,
        Top = -32000
    };

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);

    public void Dispose()
    {
        panel.BackgroundError -= Error;
        panel.Notice -= Show;
        giveUp.Stop();
        menu?.SetCurrentValue(ContextMenu.IsOpenProperty, false);
        host?.Close();
        icon.Visible = false;
        icon.Dispose();
        drawing.Dispose();
    }
    public void Capture(string directory)
    {
        ShowMenu();
        menu!.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        menu.Arrange(new Rect(menu.DesiredSize));
        Panel.SaveImage(menu, Path.Combine(directory, "tray-menu.png"), 96);
    }
}
