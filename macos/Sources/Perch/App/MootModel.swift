import AppKit
import SwiftUI
import PerchCore

enum MootSection: String, CaseIterable, Identifiable {
    case capabilities, connections, meeting, runs
    var id: String { rawValue }
    var title: String { switch self { case .capabilities: return "能力配置"; case .connections: return "模型接入"; case .meeting: return "圆桌会议"; case .runs: return "运行记录" } }
    var icon: String { switch self { case .capabilities: return "square.grid.2x2"; case .connections: return "person.2"; case .meeting: return "bubble.left.and.bubble.right"; case .runs: return "clock" } }
}
@MainActor final class MootModel: ObservableObject {
    @Published var config = MootConfig()
    @Published var installation: MootInstallReceipt?
    @Published var runs: [MootRunSnapshot] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var section: MootSection = .capabilities
    @Published var selectedRunID: String?
    @Published var focusedMessage: String?
    private var importedHistory: [MootRunSnapshot] = []
    var hasLoadedConfiguration = false
    var windowVisible = false
    weak var window: NSWindow?
    private var diskStamp = ""
    let paths: MootPaths
    var client: MootRPCClient { .init(paths: paths) }
    var installed: Bool { installation?.state == .installed || installation?.state == .pendingUninstall }
    init(paths: MootPaths = MootPaths()) { self.paths = paths; installation = MootInstaller(paths: paths).receipt() }
    func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; notice = nil
        Task { defer { busy = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    func reload(loadConfig: Bool = false) async throws {
        installation = MootInstaller(paths: paths).receipt()
        guard installed else { return }
        if loadConfig { let response = try await client.call(.init(operation: "config.read")); config = try response.data!.decode(MootConfig.self); hasLoadedConfiguration = true }
        let response = try await client.call(.init(operation: "run.list"))
        let next = (response.data?.items ?? []).map { MootRunSnapshot(record: $0) }
        let combined = next + importedHistory.filter { old in !next.contains { $0.id == old.id } }; if combined != runs { runs = combined }
    }
    func refreshIfChanged() async throws {
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: paths.root.appendingPathComponent("runs"), includingPropertiesForKeys: nil)) ?? []
        let files = directories.map { $0.appendingPathComponent("run.json") } + [paths.receipt]
        let stamp = files.sorted { $0.path < $1.path }.map { "\($0.path):\((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0)" }.joined(separator: "|")
        guard stamp != diskStamp else { return }; try await reload(); diskStamp = stamp
    }
    func saveConfig() {
        let submitted = config
        perform { [self] in
            let payload: MootJSON = .object(["config": try .encode(submitted), "expectedRevision": .number(Double(submitted.revision))])
            let response = try await client.call(.init(operation: "config.write", payload: payload))
            config = try response.data!.decode(MootConfig.self); notice = "配置已保存，后续任务使用新设置。"
        }
    }
    func install(package: URL) {
        perform { [self] in installation = try await MootInstaller(paths: paths).install(package: package); try await reload(loadConfig: true); notice = "Moot 已安装。请选择要开放的接入与技能位置。" }
    }
    func choosePackage() {
        let panel = NSOpenPanel(); panel.title = "选择 Moot 扩展包"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.treatsFilePackagesAsDirectories = true
        choose(panel) { [self] url in install(package: url) }
    }
    func installBundled() {
        guard let url = Bundle.main.url(forResource: "Moot-" + MootInstaller.architecture, withExtension: "mootpkg") else { choosePackage(); return }; install(package: url)
    }
    func check(_ connection: MootConnection) {
        perform { [self] in
            let response = try await client.call(.init(operation: "connection.check", payload: .object(["connection": try .encode(connection)])))
            if let index = config.connections.firstIndex(where: { $0.id == connection.id }) {
                config.connections[index].verification = response.data
                let models = response.data?["models"].items.map(\.text) ?? []
                if !models.isEmpty { config.connections[index].models = models }
            }
            notice = response.data?["status"].text == "loginDetected" ? "检测到登录；仍需实际任务验证模型和工具。" : "未检测到可用订阅登录。"
        }
    }
    func addIndependent(_ adapter: String) {
        var c = MootConnection(); c.adapter = adapter; c.executable = LocalProviderDiscovery.executable(adapter) ?? ""
        c.name = adapter == "claude" ? "Claude Code 本机订阅" : adapter == "agy" ? "Gemini 本机订阅" : "Codex 本机订阅"
        c.accountRoot = NSHomeDirectory() + (adapter == "claude" ? "/.claude" : adapter == "agy" ? "/.gemini/antigravity-cli" : "/.codex")
        if adapter == "agy" { c.tools = ["image"] }
        config.connections.append(c)
    }
    func addCapability(_ mode: String = "delegate", title: String = "自定义能力") {
        var c = MootCapability(); c.description = title; c.completionMode = mode
        if config.capabilities.isEmpty { c.id = "general"; c.description = "通用委派" }
        let connection = config.connections.first { $0.enabled && $0.authMode == "subscription" && (mode != "image" || $0.adapter == "agy") }
        c.primaryConnectionID = connection?.id ?? ""; c.enabled = connection != nil
        if mode == "image" { c.requiredTools = ["image"] }
        config.capabilities.append(c)
    }
    func chooseSkillRoot() {
        let panel = NSOpenPanel(); panel.title = "选择客户端的 skills 目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.showsHiddenFiles = true
        choose(panel) { [self] directory in
            do { try MootInstaller(paths: paths).installSkills(in: directory); notice = "技能已安装到选定目录。新对话可发现统一技能家族。" } catch { self.error = error.localizedDescription }
        }
    }
    func openHistory() {
        let panel = NSOpenPanel(); panel.title = "只读打开已有 runs 目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        choose(panel) { [self] root in
            do { importedHistory = try MootLegacyRunReader.read(root: root); perform { try await self.reload() }; notice = "已只读载入历史；未修改原记录。" } catch { self.error = error.localizedDescription }
        }
    }
    func migrateSkills() {
        let panel = NSOpenPanel(); panel.title = "选择要迁移的客户端 skills 目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        choose(panel) { [self] directory in
            let migration = MootMigration(paths: paths), proposal = MootMigration(paths: paths).inspect(skillRoot: directory)
            let alert = NSAlert(); alert.messageText = "迁移到统一技能家族"
            alert.informativeText = proposal.paths.map(\.lastPathComponent).joined(separator: "\n") + "\n以上入口将备份后收起，并安装 Moot 三项技能。其他技能保留。"
            alert.addButton(withTitle: "备份并迁移"); alert.addButton(withTitle: "取消")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [self] response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    let receipt = try migration.apply(proposal)
                    do { try MootInstaller(paths: paths).installSkills(in: directory); notice = "已迁移，恢复记录：" + receipt.file.path }
                    catch { try? migration.restore(receipt); throw error }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func restoreSkills() {
        let panel = NSOpenPanel(); panel.title = "选择技能备份的 migration.json"; panel.directoryURL = paths.root.appendingPathComponent("backups"); panel.canChooseDirectories = false
        choose(panel) { [self] file in
            do {
                let receipt = try JSONDecoder().decode(MootMigrationReceipt.self, from: Data(contentsOf: file))
                try MootMigration(paths: paths).restoreManaged(receipt)
                notice = "旧技能已恢复；当前 Moot 技能已留存备份。"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func choose(_ panel: NSOpenPanel, selection: @escaping (URL) -> Void) {
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { selection(url) } }
    }

    func uninstall(cancel: Bool) {
        perform { [self] in _ = try await MootInstaller(paths: paths).uninstall(policy: cancel ? .cancelRuns : .afterRunsFinish); installation = MootInstaller(paths: paths).receipt(); notice = "停止接收新任务；任务结束后卸载，保留配置、记录和产物。" }
    }
    func cancel(_ run: MootRunSnapshot) { perform { [self] in _ = try await client.call(.init(operation: "run.cancel", payload: .object(["runID": .string(run.id)]))); try await reload() } }
    func showMessage(runID: String, round: Int, seatID: String, messageID: String) { selectedRunID = runID; focusedMessage = messageID; section = .runs }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
