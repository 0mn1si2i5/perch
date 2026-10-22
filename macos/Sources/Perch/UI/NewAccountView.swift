import SwiftUI
import PerchCore

struct NewAccountView: View {
    @ObservedObject var perch: PerchModel
    let close: () -> Void
    @State private var name = ""
    @State private var app: AppKind = .codex
    @State private var hasScanned = false
    @State private var search = ""

    private var localCandidates: [LocalProviderCandidate] {
        perch.localCandidates.filter { matchesSearch($0.name) || matchesSearch($0.app.displayName) }
    }

    private var launchUpdates: [LocalLaunchUpdate] {
        perch.localLaunchUpdates.filter { matchesSearch($0.account.name) || matchesSearch($0.account.app.displayName) }
    }

    private var desktopCandidates: [AppKind] {
        perch.discovered.filter { matchesSearch($0.displayName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("自动获取可用供应商") {
                perch.scanLocalProviders()
                perch.refreshDiscovered()
                hasScanned = true
            }
            if hasScanned { scanResults }

            Divider()
            Text("手动添加").font(.system(size: 12, weight: .semibold))
            Picker("类型", selection: $app) {
                ForEach(AppKind.desktopClients, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            desktopAccount
        }
    }

    private var scanResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择要添加的本机供应商")
                .font(.system(size: 12, weight: .medium))
            TextField("搜索供应商名称", text: $search).textFieldStyle(.roundedBorder)
            if localCandidates.isEmpty && desktopCandidates.isEmpty && launchUpdates.isEmpty {
                Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "没有发现新的可用入口。已添加的供应商可在账号列表中查看。"
                     : "没有匹配的供应商。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(launchUpdates) { update in
                VStack(alignment: .leading, spacing: 6) {
                    Text(update.account.name).font(.system(size: 12, weight: .medium))
                    Text("启动位置已变化")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("原来：\(update.account.localProvider?.target ?? "")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(update.account.localProvider?.target ?? "")
                    Text("现在：\(update.configuration.target)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(update.configuration.target)
                    Button("更新启动位置") { _ = perch.updateLocalLaunch(update) }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(desktopCandidates, id: \.self) { candidate in
                desktopCandidate(candidate)
            }
            ForEach(localCandidates) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.name).font(.system(size: 12, weight: .medium))
                    Text(candidate.configuration.target)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(candidate.configuration.target)
                    if !candidate.profilePath.isEmpty {
                        Text(candidate.profilePath)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).help(candidate.profilePath)
                    }
                    Button("添加到 Perch") { _ = perch.importLocal(candidate) }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func desktopCandidate(_ candidate: AppKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.displayName).font(.system(size: 12, weight: .medium))
            Text("直接打开客户端时使用的本机数据")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button("添加到 Perch") { perch.addDiscovered(candidate) }
                let existing = perch.accounts.filter { $0.app == candidate }
                if !existing.isEmpty {
                    Menu("关联已有账号") {
                        ForEach(existing) { account in
                            Button(account.name) { perch.useDefaultData(account) }
                        }
                    }
                    .menuStyle(.borderedButton)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var desktopAccount: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(Strings.get("account.nameHint"), text: $name).textFieldStyle(.roundedBorder)
            Text(Strings.get("account.createHelp"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: close)
                Spacer()
                Button(Strings.get("account.create")) { if perch.create(name: name, app: app) { close() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func matchesSearch(_ value: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }
}
