using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Effects;
using Microsoft.Win32;
using System.Windows.Threading;
using global::Windows.Media.Control;
using global::Windows.Media;

namespace Perch.Windows;

public sealed class PetWindow : Window
{
    private readonly Store store;
    private readonly Action click, doubleClick;
    private readonly Image sprite = new()
    {
        Stretch = Stretch.Uniform
    };
    private readonly Border orb;
    private readonly TextBlock label = new()
    {
        FontSize = 10,
        Foreground = Brushes.WhiteSmoke,
        Padding = new Thickness(8, 4, 8, 4)
    };
    private readonly Border capsule = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Bottom,
        CornerRadius = new CornerRadius(10),
        Background = new SolidColorBrush(Color.FromArgb(219, 26, 31, 38)),
        Visibility = Visibility.Collapsed
    };
    private readonly TextBlock completion = new()
    {
        FontSize = 12,
        Foreground = Brushes.WhiteSmoke,
        TextWrapping = TextWrapping.Wrap,
        Padding = new Thickness(12, 8, 12, 8)
    };
    private readonly Border bubble = new()
    {
        MaxWidth = 250,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Top,
        CornerRadius = new CornerRadius(13),
        Background = new SolidColorBrush(Color.FromArgb(240, 26, 31, 38)),
        Visibility = Visibility.Collapsed
    };
    private string? feedback;
    private readonly BitmapSource[] frames;
    private readonly DispatcherTimer animation = new()
    {
        Interval = TimeSpan.FromMilliseconds(100)
    };
    private readonly DispatcherTimer single = new()
    {
        Interval = TimeSpan.FromMilliseconds(280)
    };
    private Point anchor;
    private double left, top;
    private bool dragging, pressed, mediaBusy, playing;
    private string mediaKind = "unknown";
    private int pose, ticks;
    private DateTimeOffset previewUntil, celebrationUntil;
    private HashSet<string> active = [];
    private List<Session> sessions = [];
    public PetWindow(Store state, Action onClick, Action onDoubleClick, bool inspection = false)
    {
        store = state;
        click = onClick;
        doubleClick = onDoubleClick;
        Title = "Perch 桌宠";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = inspection;
        ShowActivated = false;
        Topmost = true;
        var bitmap = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Resources", "pox-atlas.png")));
        bitmap.Freeze();
        frames = new BitmapSource[8];
        var split = (int)Math.Round(bitmap.PixelHeight * 449.0 / 887);
        for (var i = 0; i < 8; i++)
        {
            int x = i % 4 * bitmap.PixelWidth / 4, right = (i % 4 + 1) * bitmap.PixelWidth / 4, y = i < 4 ? 0 : split;
            frames[i] = new CroppedBitmap(bitmap, new Int32Rect(x, y, right - x, i < 4 ? split : bitmap.PixelHeight - split));
            frames[i].Freeze();
        }

        // One solid brand-colored ball: the icon's own fill is the circle, so no ring or gap shows.
        orb = new Border
        {
            Width = 44,
            Height = 44,
            Child = new Image
            {
                Source = Brand.Image(round: true),
                Width = 44,
                Height = 44
            },
            Effect = new DropShadowEffect
            {
                BlurRadius = 10,
                ShadowDepth = 2,
                Opacity = .28
            }
        };
        capsule.Child = label;
        bubble.Child = completion;
        var grid = new Grid();
        sprite.Margin = new Thickness(0, 100, 0, 25);
        grid.Children.Add(sprite);
        grid.Children.Add(orb);
        grid.Children.Add(capsule);
        grid.Children.Add(bubble);
        Content = grid;
        ToolTip = "单击展开 / 收起面板 · 双击调出忙碌账号 · 拖动移动 · 右键菜单";
        var menu = new ContextMenu();
        foreach (var (label, action) in new[]
        {
            ("打开 Perch", click),
            ("恢复桌宠位置", (Action)ResetPosition),
            ("隐藏桌宠", (Action)(() =>
            {
                store.Preferences.PetVisible = false;
                store.Save();
                Hide();
            })),
            ("退出 Perch", (Action)(() => Application.Current.Shutdown()))
        }

        )
        {
            var item = new MenuItem
            {
                Header = label
            };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        ContextMenu = menu;
        Left = store.Preferences.PetLeft ?? SystemParameters.WorkArea.Right - 210;
        Top = store.Preferences.PetTop ?? SystemParameters.WorkArea.Bottom - 240;
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2)
            {
                single.Stop();
                Preview(5, 2);
                feedback = "向你敬礼";
                doubleClick();
                return;
            }

            anchor = PointToScreen(e.GetPosition(this));
            var rect = NativeWindow.Rectangle(this);
            left = rect.X;
            top = rect.Y;
            pressed = true;
            dragging = false;
            CaptureMouse();
        };
        MouseMove += (_, e) =>
        {
            if (!pressed)
                return;
            if (e.LeftButton != MouseButtonState.Pressed)
            {
                FinishDrag();
                ReleaseMouseCapture();
                return;
            }

            var point = PointToScreen(e.GetPosition(this));
            var delta = point - anchor;
            if (Math.Abs(delta.X) + Math.Abs(delta.Y) > 5)
                dragging = true;
            if (dragging)
            {
                single.Stop();
                NativeWindow.Move(this, left + delta.X, top + delta.Y);
                sprite.Source = frames[7];
            }
        };
        MouseLeftButtonUp += (_, _) =>
        {
            if (!pressed)
                return;
            var moved = dragging;
            FinishDrag();
            ReleaseMouseCapture();
            if (!moved)
            {
                single.Stop();
                single.Start();
            }
        };
        LostMouseCapture += (_, _) => FinishDrag();
        single.Tick += (_, _) =>
        {
            single.Stop();
            click();
        };
        IsVisibleChanged += (_, _) =>
        {
            if (IsVisible && store.Preferences.PetCharacter == "pox")
                animation.Start();
            else
            {
                animation.Stop();
                playing = false;
            }
        };
        SystemEvents.DisplaySettingsChanged += DisplayChanged;
        Closed += (_, _) =>
        {
            animation.Stop();
            single.Stop();
            SystemEvents.DisplaySettingsChanged -= DisplayChanged;
        };
        animation.Tick += async (_, _) =>
        {
            ticks++;
            if (ticks % 50 == 0 && store.Preferences.MediaEnabled && !mediaBusy)
            {
                mediaBusy = true;
                try
                {
                    var manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
                    var states = manager.GetSessions().Where(s => s.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing).ToList();
                    playing = states.Count > 0;
                    var kinds = states.Select(s => MediaPolicy.Classify(s.SourceAppUserModelId, s.GetPlaybackInfo().PlaybackType?.ToString())).ToList();
                    mediaKind = kinds.Contains("video") ? "video" : kinds.Contains("music") ? "music" : "unknown";
                }
                catch
                {
                    playing = false;
                }
                finally
                {
                    mediaBusy = false;
                }
            }

            bubble.Visibility = !store.Preferences.Quiet && celebrationUntil > DateTimeOffset.UtcNow ? Visibility.Visible : Visibility.Collapsed;
            if (dragging)
            {
                label.Text = "好家伙，被提起来了";
                capsule.Visibility = store.Preferences.Quiet ? Visibility.Collapsed : Visibility.Visible;
                return;
            }

            if (previewUntil < DateTimeOffset.UtcNow)
                pose = celebrationUntil > DateTimeOffset.UtcNow && !store.Preferences.Quiet ? 5 : sessions.Any(s => s.Status == "等待输入") ? 1 : sessions.Any(s => s.Status == "运行中") ? 2 : playing && store.Preferences.MediaEnabled ? mediaKind == "music" ? 3 : 4 : 0;
            sprite.Source = frames[pose];
            sprite.RenderTransform = new TranslateTransform(0, store.Preferences.Quiet ? 0 : Math.Sin(ticks * 0.14) * 2);
            label.Text = previewUntil > DateTimeOffset.UtcNow ? "动作预览" : Strings.Get("pet.pose." + pose);
            if (previewUntil > DateTimeOffset.UtcNow && feedback != null)
                label.Text = feedback;
            if (pose == 2 && previewUntil < DateTimeOffset.UtcNow)
                label.Text = "Codex · " + sessions.Count(s => s.Status == "运行中") + " 个任务";
            if (pose == 4 && mediaKind == "unknown" && previewUntil < DateTimeOffset.UtcNow)
                label.Text = "媒体播放中";
            capsule.Visibility = !store.Preferences.Quiet && (IsMouseOver || pose != 0) ? Visibility.Visible : Visibility.Collapsed;
        };
        Configure();
    }

    private void FinishDrag()
    {
        var moved = dragging;
        pressed = false;
        dragging = false;
        if (!moved)
            return;
        Configure();
        store.Preferences.PetLeft = Left;
        store.Preferences.PetTop = Top;
        store.Save();
        Preview(6, 2);
        feedback = "好家伙，搬家了。";
    }

    public void Configure()
    {
        var native = store.Preferences.PetCharacter != "pox";
        Width = native ? 60 : store.Preferences.PetSize;
        Height = native ? 60 : store.Preferences.PetSize + 125;
        orb.Visibility = native ? Visibility.Visible : Visibility.Collapsed;
        sprite.Visibility = native ? Visibility.Collapsed : Visibility.Visible;
        sprite.Source = frames[pose];
        if (native)
            animation.Stop();
        else if (IsVisible)
            animation.Start();
        if (native)
        {
            capsule.Visibility = Visibility.Collapsed;
            bubble.Visibility = Visibility.Collapsed;
        }

        var physical = NativeWindow.Rectangle(this);
        double scale = NativeWindow.Scale(NativeWindow.Area(this));
        var placed = PanelPlacement.ClampPet(physical with
        {
            Width = Width * scale,
            Height = Height * scale
        }, NativeWindow.Screens());
        NativeWindow.Move(this, placed.X, placed.Y);
    }

    public void SetActivity(List<Session> current)
    {
        var now = current.Where(s => s.Status == "运行中").Select(s => s.Id).ToHashSet();
        var finished = current.FirstOrDefault(s => active.Contains(s.Id) && s.Status == "已完成");
        if (finished != null)
            ShowCompletion(finished.Title);
        sessions = current;
        active = now;
    }

    public void Preview(int index, int seconds = 8)
    {
        feedback = null;
        pose = Math.Clamp(index, 0, 7);
        previewUntil = DateTimeOffset.UtcNow.AddSeconds(seconds);
        sprite.Source = frames[pose];
    }

    public void ShowCompletion(string title)
    {
        completion.Text = "搞定一个。\n" + (title.Length > 28 ? title[..28] : title);
        celebrationUntil = DateTimeOffset.UtcNow.AddSeconds(7);
    }

    /// Moves to a physical-pixel origin, keeps it on screen and remembers it like a drag would.
    public void MoveTo(double x, double y)
    {
        NativeWindow.Move(this, x, y);
        Configure();
        store.Preferences.PetLeft = Left;
        store.Preferences.PetTop = Top;
        store.Save();
    }

    public void ResetPosition()
    {
        var primary = NativeWindow.PrimaryArea();
        double scale = NativeWindow.Scale(primary);
        NativeWindow.Move(this, primary.Right - (Width + 28) * scale, primary.Bottom - (Height + 28) * scale);
        Configure();
        store.Preferences.PetLeft = Left;
        store.Preferences.PetTop = Top;
        store.Save();
    }

    private void DisplayChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(Configure);
}