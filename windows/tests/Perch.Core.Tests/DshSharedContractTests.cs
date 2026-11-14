using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using Perch.Windows;

internal static class DshSharedContractTests
{
    public static void Run()
    {
        var fixtures = Path.Combine(AppContext.BaseDirectory, "fixtures", "dsh");
        using var sessionsFile = JsonDocument.Parse(File.ReadAllText(Path.Combine(fixtures, "sessions.json")));
        var sessions = DshConnection.ParseSessions(sessionsFile.RootElement);
        Check(sessions.Select(s => s.Id).SequenceEqual(new[] { "running", "idle", "cold", "untitled", "unknown" }),
            "The shared session list must retain five root conversations, omit blank/child/subagent rows and order live tasks first");
        Check(sessions.Select(s => s.Status).SequenceEqual(new[] { "运行中", "空闲", "未运行", "未运行", "状态未知" }),
            "Idle, cold and missing runtime state must not be guessed as successful completion");
        Check(sessions[0].Title == "Live task · 跨端" && sessions[3].Title == "未命名会话" && sessions[4].Title == "未命名会话",
            "Shared titles preserve Unicode and use an explicit fallback for missing names");
        Check(sessions[0].Cwd == "/Users/demo/Project with spaces" && sessions[1].Cwd == @"C:\Users\demo\Project with spaces",
            "Both platforms' directory separators and spaces remain opaque metadata");
        Check(sessions[0].Updated == DateTimeOffset.FromUnixTimeMilliseconds(1791552300000),
            "Shared session timestamps use milliseconds without a local timezone conversion");

        using var outcomes = JsonDocument.Parse(File.ReadAllText(Path.Combine(fixtures, "outcomes.json")));
        foreach (var sample in outcomes.RootElement.EnumerateArray())
        {
            var expected = sample.GetProperty("status").GetString() switch
            {
                "completed" => "已完成",
                "interrupted" => "已停止",
                "failed" => "遇到问题",
                "unknown" => "状态未知",
                null => "",
                var unsupported => throw new Exception("Unsupported shared outcome " + unsupported)
            };
            Check(DshConnection.CompletionStatus(sample.GetProperty("page")) == expected,
                "Shared completion evidence must map without inference: " + sample.GetProperty("name").GetString());
        }

        using var walletFile = JsonDocument.Parse(File.ReadAllText(Path.Combine(fixtures, "wallet.json")));
        var wallet = DshConnection.ParseBalance(walletFile.RootElement);
        Check(wallet.SequenceEqual(new[]
        {
            new WalletBalance("充值", "CNY", 12.34567890123456789m),
            new WalletBalance("充值", "USD", 0m),
            new WalletBalance("赠送", "CNY", 1.20m)
        }), "Shared wallets preserve all currencies, paid/granted components and decimal precision");
        Console.WriteLine("PASS: shared dsh root sessions, opaque paths, lifecycle evidence and precise wallets");
    }

    private static void Check(bool value, string why) { if (!value) throw new Exception(why); }
}
