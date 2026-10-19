import SwiftUI
import PerchCore

struct AccountCard: View {
    @ObservedObject var perch: PerchModel
    let account: Account
    @State private var expanded = false
    @State private var targeted = false

    var body: some View {
        let rows = perch.rows(for: account)
        let running = perch.runningIDs.contains(account.id)
        let missing = perch.dataMissing(account)
        // The Antigravity CLI card shows a quota only after the owner refreshed it.
        let queried = perch.providerUsage[account.id] != nil || perch.providerUsageErrors[account.id] != nil
            || perch.refreshingQuotas.contains(account.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(perch.title(for: account)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if running {
                    Circle().fill(ReadableStatusColor.green).frame(width: 6, height: 6).help("客户端运行中")
                }
                Spacer(minLength: 4)
                if !missing, let quota = perch.quotas[account.id] {
                    QuotaFreshnessView(quota: quota)
                } else if !missing, perch.supportsProviderUsage(account) {
                    QuotaFreshnessView(quota: ProviderUsagePresentation.display(
                        usage: perch.providerUsage[account.id], error: perch.providerUsageErrors[account.id]))
                }
                if !missing, account.app.hasQuota || perch.supportsProviderUsage(account) {
                    Button { perch.refreshQuota(account) } label: {
                        Image(systemName: "arrow.clockwise")
                            .opacity(perch.refreshingQuotas.contains(account.id) ? 0.4 : 1)
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .disabled(perch.refreshingQuotas.contains(account.id))
                    .help(perch.refreshingQuotas.contains(account.id) ? "正在同步额度…"
                          : account.app == .antigravity ? "运行一次 agy 查询额度" : "立即同步额度")
                    .accessibilityLabel("同步 \(account.name) 的额度")
                }
                if missing {
                    // A local provider's data is found again by scanning; desktop accounts can be pointed elsewhere.
                    if account.localProvider == nil { Button("配置") { perch.relocate(account) }.controlSize(.small) }
                } else {
                    Button(launchLabel(running: running)) { perch.launch(account) }.controlSize(.small)
                }
            }
            if perch.localWebURL(account) != nil {
                Button("打开本机网页") { perch.openLocalWeb(account) }.controlSize(.small)
                Text("先启动服务，再打开网页。登录在客户端完成。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !missing, let quota = perch.quotas[account.id] {
                QuotaRowView(quota: quota)
            }
            if !missing, perch.supportsProviderUsage(account), account.app != .antigravity || queried {
                ProviderUsageView(usage: perch.providerUsage[account.id], error: perch.providerUsageErrors[account.id],
                                  refreshing: perch.refreshingQuotas.contains(account.id))
            }
            if missing {
                Text("数据目录不存在").font(.system(size: 11)).foregroundStyle(.orange)
            } else if rows.isEmpty, account.app != .geminiApp {
                Text(perch.emptyText(for: account)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            let active = rows.filter(\.isActive)
            let finished = rows.filter { !$0.isActive }
            // In-progress conversations always show, above a divider; finished ones fold to 3.
            ForEach(active) { row in
                SessionRowView(perch: perch, account: account, row: row)
            }
            if !active.isEmpty && !finished.isEmpty {
                Divider()
            }
            ForEach(finished.prefix(expanded ? 15 : 3)) { row in
                SessionRowView(perch: perch, account: account, row: row)
            }
            if finished.count > 3 {
                Button(expanded ? "收起" : "更多") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .top) {
            // Where a dragged account will land: just above this card.
            if targeted { Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -5) }
        }
        .draggable(PanelDrag.account(account.id)) { DragChip(title: account.name) }
        .dropDestination(for: String.self) { items, _ in
            PanelDrag.drop(items, on: account.app, account: account, perch: perch)
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("改名…") { perch.rename(account) }
            if account.app.hasQuota, !perch.isDefaultData(account) {
                Button("改用直接打开的 \(account.app.displayName)…") { perch.useDefaultData(account) }
            }
            Button("删除…") { perch.delete(account) }
        }
    }
    private func launchLabel(running: Bool) -> String {
        if account.app == .deepseek, account.localProvider?.kind == .terminal { return running ? "终端" : "启动服务" }
        if account.localProvider?.kind == .terminal { return running ? "终端" : "启动" }
        return running ? "前台" : "启动"
    }
}
