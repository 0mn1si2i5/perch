import SwiftUI
import PerchCore

struct AccountCard: View {
    @ObservedObject var perch: PerchModel
    let account: Account
    @State private var editing = false
    @State private var expanded = false
    @State private var targeted = false

    var body: some View {
        let rows = perch.rows(for: account)
        let running = perch.runningIDs.contains(account.id)
        let missing = perch.dataMissing(account)
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
                    .help(perch.refreshingQuotas.contains(account.id) ? "正在同步额度…" : "立即同步额度")
                    .accessibilityLabel("同步 \(account.name) 的额度")
                }
                if missing {
                    Button("配置") { if account.localProvider != nil { editing = true } else { perch.relocate(account) } }.controlSize(.small)
                } else {
                    Button(launchLabel(running: running)) { perch.launch(account) }.controlSize(.small)
                        .disabled(account.apiProvider?.dashboardURL.isEmpty == true)
                }
            }
            if let api = account.apiProvider {
                Text(api.displayName + " · " + api.protocolKind.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                if !api.model.isEmpty { Text(api.model).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                HStack {
                    Button(perch.checkingAPI.contains(account.id) ? "检查中…" : "检查连接") { perch.checkAPI(account) }
                        .disabled(perch.checkingAPI.contains(account.id))
                    Button("配置…") { editing = true }
                }.controlSize(.small)
                if let status = perch.apiChecks[account.id] {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if perch.localWebURL(account) != nil {
                Button("打开本机网页") { perch.openLocalWeb(account) }.controlSize(.small)
                Text("先启动服务，再打开网页。登录在客户端完成。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !missing, let quota = perch.quotas[account.id] {
                QuotaRowView(quota: quota)
            }
            if !missing, perch.supportsProviderUsage(account) {
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
            if account.localProvider != nil || account.apiProvider != nil {
                Button("供应商配置…") { editing = true }
            }
            if account.apiProvider != nil { Button("复制连接配置") { perch.copyAPIConfiguration(account) } }
            if account.app.hasQuota, !perch.isDefaultData(account) {
                Button("改用直接打开的 \(account.app.displayName)…") { perch.useDefaultData(account) }
            }
            Button("删除…") { perch.delete(account) }
        }
        .sheet(isPresented: $editing) {
            ScrollView { ProviderEditorView(perch: perch, account: account) { editing = false }.padding(20) }
                .frame(width: 360, height: 550)
                .safeAreaInset(edge: .bottom) {
                    if let message = perch.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange).padding(10) }
                }
        }
    }
    private func launchLabel(running: Bool) -> String {
        if account.apiProvider != nil { return "控制台" }
        if account.app == .deepseek, account.localProvider?.kind == .terminal { return running ? "终端" : "启动服务" }
        if account.localProvider?.kind == .terminal { return running ? "终端" : "启动" }
        return running ? "前台" : "启动"
    }
}
