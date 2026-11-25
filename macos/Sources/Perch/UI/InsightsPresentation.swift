import Foundation
import PerchCore

enum InsightsPresentation {
    static func badgeText(_ summary: InsightsSummary) -> String {
        "\(summary.window.days)天 · \(summary.totals.sessions)会话"
    }

    static func windowText(_ summary: InsightsSummary) -> String {
        var parts = ["近 \(summary.window.days) 天"]
        if let range = dateRange(summary.window) {
            parts.append("（\(range)）")
        }
        return parts.joined() + " · 更新于 \(timestamp(summary.generatedAt))"
    }

    static func totalsText(_ totals: InsightsSummary.Totals) -> String {
        var parts = ["\(totals.sessions) 会话"]
        if let subagents = totals.subagents {
            parts.append("\(subagents) 子代理")
        }
        if let activeDays = totals.activeDays {
            parts.append("活跃 \(activeDays) 天")
        }
        return parts.joined(separator: " · ")
    }

    static func ratesText(cacheHitRate: Double?, errorRate: Double?) -> String? {
        var parts: [String] = []
        if let hit = cacheHitRate {
            parts.append("缓存命中 \(percent(hit))")
        }
        if let err = errorRate {
            parts.append("错误率 \(percent(err))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func deltaText(_ delta: InsightsSummary.Delta?) -> String? {
        guard let delta else { return nil }
        var parts: [String] = []
        if let sessions = delta.sessions {
            parts.append("会话 \(signedInt(sessions))")
        }
        if let hit = delta.cacheHitRate {
            parts.append("命中率 \(signedPercent(hit))")
        }
        if let err = delta.errorRate {
            parts.append("错误率 \(signedPercent(err))")
        }
        guard !parts.isEmpty else { return nil }
        return "较上次：" + parts.joined(separator: " · ")
    }

    static func agentCountText(_ agent: InsightsSummary.Agent) -> String {
        if let subagents = agent.subagents, subagents > 0 {
            return "\(agent.sessions) 会话 / \(subagents) 子代理"
        }
        return "\(agent.sessions) 会话"
    }

    static func tooltip(_ summary: InsightsSummary, hasReport: Bool) -> String {
        var lines: [String] = []
        if let range = dateRange(summary.window) {
            lines.append("使用诊断（近 \(summary.window.days) 天，\(range)）")
        } else {
            lines.append("使用诊断（近 \(summary.window.days) 天）")
        }

        var overview = "总计：\(totalsText(summary.totals))"
        if let rates = ratesText(cacheHitRate: summary.totals.cacheHitRate, errorRate: summary.totals.errorRate) {
            overview += " · \(rates)"
        }
        lines.append(overview)

        if let delta = deltaText(summary.delta) {
            lines.append(delta)
        }

        for agent in summary.agents {
            let roleTag = agent.role == "historical" ? "（历史）" : ""
            var line = "· \(agent.name)\(roleTag)：\(agentCountText(agent))"
            if let rates = ratesText(cacheHitRate: agent.cacheHitRate, errorRate: agent.errorRate) {
                line += " · \(rates)"
            }
            lines.append(line)
        }

        let footer = "更新于 \(timestamp(summary.generatedAt))" + (hasReport ? " · 点击打开报告" : "")
        lines.append(footer)
        return lines.joined(separator: "\n")
    }

    private static func dateRange(_ window: InsightsSummary.Window) -> String? {
        guard let start = window.start, let end = window.end else { return nil }
        return "\(shortDate(start)) ~ \(shortDate(end))"
    }

    private static func shortDate(_ raw: String) -> String {
        raw.count >= 10 ? String(raw.prefix(10)) : raw
    }

    private static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    private static func signedInt(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private static func signedPercent(_ delta: Double) -> String {
        let pct = delta * 100
        if pct > 0 { return String(format: "+%.1f%%", pct) }
        return String(format: "%.1f%%", pct)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}
