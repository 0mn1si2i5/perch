using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace Perch.Windows;

public static class ViewMenus
{
    private static MenuItem Item(string label, Action action, bool enabled = true)
    {
        var item = new MenuItem
        {
            Header = label,
            IsEnabled = enabled
        };
        item.Click += (_, _) => action();
        return item;
    }

    private static void Show(FrameworkElement owner, ContextMenu menu)
    {
        owner.ContextMenu = menu;
        menu.PlacementTarget = owner;
        menu.Placement = PlacementMode.MousePoint;
        menu.IsOpen = true;
    }

    public static void Account(FrameworkElement owner, ContextMenuEventArgs e)
    {
        if (e.Handled || owner.DataContext is not AccountModel account)
            return;
        e.Handled = true;
        var model = account.Owner;
        var menu = new ContextMenu();
        menu.Items.Add(Item("改名…", () => model.Run(() => model.Rename(account.Value))));
        menu.Items.Add(Item("打开数据目录", () => model.Run(() => PanelModel.Reveal(account.Value.ProfilePath))));
        var client = model.Clients.Installed.FirstOrDefault(c => c.App == account.Value.App);
        if (client != null && !account.Value.Default)
            menu.Items.Add(Item("改用直接打开的 " + PanelModel.Label(client.App) + "…", () => model.Run(() => model.SwitchDefault(account.Value, client))));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("移除账号…", () => model.Run(() => model.Remove(account.Value))));
        Show(owner, menu);
    }

    public static void Session(FrameworkElement owner, ContextMenuEventArgs e)
    {
        if (owner.DataContext is not SessionModel session)
            return;
        e.Handled = true;
        var model = session.Account.Owner;
        var menu = new ContextMenu();
        menu.Items.Add(Item("打开", () => session.Open.Execute(null)));
        menu.Items.Add(HandoffMenu("接力到…", Handoffs.TaskScope, session, model));
        menu.Items.Add(HandoffMenu("拆出需求到…", Handoffs.SplitScope, session, model));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("复制会话文件路径", () => model.Run(() => ClipboardWriter.Set(session.Value.Path)), session.Value.Path.Length > 0));
        menu.Items.Add(Item("在资源管理器中显示", () => model.Run(() => PanelModel.Reveal(session.Value.Path)), File.Exists(session.Value.Path)));
        Show(owner, menu);
    }

    // The source account comes first as a new conversation there; a running conversation cannot write the document yet.
    private static MenuItem HandoffMenu(string header, string scope, SessionModel session, PanelModel model)
    {
        var source = session.Account.Value;
        var handoff = new MenuItem
        {
            Header = header,
            IsEnabled = session.Status is not ("运行中" or "等待输入")
        };
        handoff.Items.Add(Item("本账号新对话", () => model.Run(() => model.BeginHandoff(source, source, session.Value, scope))));
        var targets = model.Store.Accounts.Where(a => a.Id != source.Id).ToList();
        if (targets.Count > 0)
            handoff.Items.Add(new Separator());
        foreach (var target in targets)
            handoff.Items.Add(Item(target.Name + "（" + PanelModel.Label(target.App) + "）", () => model.Run(() => model.BeginHandoff(source, target, session.Value, scope))));
        return handoff;
    }

    public static void Pending(Button button)
    {
        if (button.DataContext is not PanelModel model)
            return;
        var menu = new ContextMenu();
        menu.Items.Add(Item("使用已有文档…", () => model.ExistingHandoff.Execute(null)));
        menu.Items.Add(Item("打开交接文件夹", () => model.RevealHandoffs.Execute(null)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("取消接力", () => model.CancelHandoff.Execute(null)));
        Show(button, menu);
    }

    public static void Discovered(Button button)
    {
        if (button.DataContext is not DiscoveredModel discovered || !discovered.HasAccounts)
            return;
        var model = Window.GetWindow(button)?.DataContext as PanelModel;
        if (model == null)
            return;
        var menu = new ContextMenu();
        var client = model.Clients.Installed.FirstOrDefault(c => c.App == discovered.App);
        var existing = new MenuItem
        {
            Header = "已有账号…",
            IsEnabled = client != null
        };
        if (client != null)
            foreach (var account in model.Store.Accounts.Where(a => a.App == client.App))
                existing.Items.Add(Item(account.Name, () => model.Run(() => model.SwitchDefault(account, client))));
        menu.Items.Add(existing);
        menu.Items.Add(Item("新账号…", () => discovered.Add.Execute(null)));
        Show(button, menu);
    }
}

public static class Icon
{
    public static readonly DependencyProperty KindProperty = DependencyProperty.RegisterAttached("Kind", typeof(string), typeof(Icon), new PropertyMetadata("", Changed));
    public static string GetKind(DependencyObject value) => (string)value.GetValue(KindProperty);
    public static void SetKind(DependencyObject value, string kind) => value.SetValue(KindProperty, kind);
    private static void Changed(DependencyObject value, DependencyPropertyChangedEventArgs e)
    {
        if (value is Button button)
            button.Content = Icons.Make((string)e.NewValue);
        else if (value is ContentControl content)
            content.Content = Icons.Make((string)e.NewValue, false);
    }
}

public static class ColorToken
{
    public static readonly DependencyProperty KeyProperty = DependencyProperty.RegisterAttached("Key", typeof(string), typeof(ColorToken), new PropertyMetadata("TextPrimary", Changed));
    public static string GetKey(DependencyObject value) => (string)value.GetValue(KeyProperty);
    public static void SetKey(DependencyObject value, string key) => value.SetValue(KeyProperty, key);
    private static void Changed(DependencyObject value, DependencyPropertyChangedEventArgs e)
    {
        if (value is FrameworkElement element)
            element.SetResourceReference(TextBlock.ForegroundProperty, e.NewValue);
    }
}