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
            ("claude", "Claude 研究", false),
            ("dsh", "dsh 工作", false)
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
            if (app == "dsh")
            {
                a.Dsh = new DshConfiguration();
                snapshots[a.Id] = new(true, [new("demo-dsh-live", "查看 DeepSeek Harness 适配", "运行中", now.AddMinutes(-2)), new("demo-dsh-idle", "检查任务完成状态", "已完成", now.AddMinutes(-10)), new("demo-dsh-cold", "检查历史工作", "已完成", now.AddHours(-1))], "dsh 本机 Web", 0, now);
                demoQuotas[a.Id] = new([], now, "默认模型：DeepSeek API Key 已配置\n官方账户已登录 · 官方钱包与 API 余额独立查询", Balances: [new("充值", "CNY", 32.58m), new("赠送", "CNY", 5.25m)],
                    ApiBalance: new([new("总额", "CNY", 19.23456789m), new("充值", "CNY", 18m), new("赠送", "CNY", 1.23456789m)], now, "查询成功（演示）"));
            }
        }

        Store.Preferences.MediaEnabled = false;
        Store.Preferences.PetEnabled = true;
        Store.Preferences.PetVisible = true;
    }
}
