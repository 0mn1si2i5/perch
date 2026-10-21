using System;
using System.Collections.Generic;
using System.IO;

namespace Perch.Windows;

public sealed partial class PanelModel
{
    private readonly Dictionary<string, Quota> demoQuotas = [];

    private void PopulateDemo()
    {
        foreach (var (app, name, missing) in new[]
        {
            ("codex", "Omnix 工作", false),
            ("codex", "个人项目", true),
            ("claude", "Claude 研究", false)
        }

        )
        {
            var path = Path.Combine(Store.Root, name);
            if (!missing)
                Directory.CreateDirectory(path);
            var a = new Account
            {
                App = app,
                Name = name,
                ProfilePath = path,
                SessionRoot = path
            };
            Store.Add(a);
            var now = DateTimeOffset.UtcNow;
            var list = new List<Session>
            {
                new(Guid.NewGuid().ToString(), "完善 Windows 端原生体验", "运行中", now.AddMinutes(-2)),
                new(Guid.NewGuid().ToString(), "确认交互与验收结果", "等待输入", now.AddMinutes(-5)),
                new(Guid.NewGuid().ToString(), "整理账号隔离方案", "已完成", now.AddMinutes(-22)),
                new(Guid.NewGuid().ToString(), "检查网络请求", "遇到问题", now.AddHours(-1)),
                new(Guid.NewGuid().ToString(), "同步项目进度", "已完成", now.AddHours(-3)),
                new(Guid.NewGuid().ToString(), "验证测试样本", "已完成", now.AddDays(-1))
            };
            snapshots[a.Id] = new Snapshot(!missing, list, "", 1);
            demoQuotas[a.Id] = new Quota([new("5h", app == "codex" ? 72 : 92, now.AddHours(3)), new("周", 36, now.AddDays(4))], now.AddMinutes(-8), missing ? "网络暂不可用" : "", missing);
        }

        Store.Preferences.MediaEnabled = false;
        Store.Preferences.PetEnabled = true;
        Store.Preferences.PetVisible = true;
    }
}
