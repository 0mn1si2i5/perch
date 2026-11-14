import AppKit
import SwiftUI
import PerchCore

/// The same editor creates Web accounts and adds Web capability to an existing native DeepSeek account.
struct DshAccountEditor: View {
    @ObservedObject var perch: PerchModel
    let close: () -> Void
    @State private var accountID: String?
    @State private var name: String
    @State private var mode: DshMode
    @State private var installation: String
    @State private var node: String
    @State private var profile: String
    @State private var home: String
    @State private var balanceHome: String
    @State private var authorization = ""
    @State private var error: String?
    @State private var validation: String?
    @State private var submitting = false

    init(perch: PerchModel, account: Account? = nil, close: @escaping () -> Void) {
        self.perch = perch; self.close = close
        let config = account?.dshWeb ?? DshConfiguration(mode: account == nil ? .npm : .external,
                                                       balanceHome: account?.profilePath ?? "")
        _accountID = State(initialValue: account?.id)
        _name = State(initialValue: account?.name ?? "DeepSeek Harness")
        _mode = State(initialValue: config.mode)
        _installation = State(initialValue: config.installationPath)
        _node = State(initialValue: config.nodePath)
        _profile = State(initialValue: config.profile)
        _home = State(initialValue: account?.profilePath ?? "")
        _balanceHome = State(initialValue: config.balanceHome)
    }

    private var isBusy: Bool { submitting || accountID.map { perch.dshBusy.contains($0) } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if accountID == nil {
                TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            } else {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text("保留原账号与数据；同一数据目录的 Web 会话显示在此账号中。")
                    .foregroundStyle(.secondary)
            }
            Picker("连接方式", selection: $mode) {
                ForEach(DshMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.pickerStyle(.menu)
            if mode != .external { installationFields }
            if mode != .external {
                pathField("账号数据目录（DSH_HOME）", text: $home, directories: true, disabled: accountID != nil)
                Text(accountID == nil ? "留空创建独立目录；选择已有目录会关联原账号，不复制登录信息。" : "已有账号的数据目录保持不变。")
                    .foregroundStyle(.secondary)
                DisclosureGroup("高级：Node 与 Web profile") {
                    VStack(alignment: .leading, spacing: 8) {
                        pathField("Node 可执行文件（可留空）", text: $node, directories: false)
                        TextField("Web profile", text: $profile).textFieldStyle(.roundedBorder)
                        Text("默认 web；不接管 Electron 的 desktop profile。")
                            .foregroundStyle(.secondary)
                    }.padding(.top, 6)
                }
            } else {
                pathField("余额凭据目录（可选）", text: $balanceHome, directories: true)
                Text("填写此实例的 DSH_HOME 才能查询标准文件中的官方 API 余额；留空仍可查看任务和官方钱包。")
                    .foregroundStyle(.secondary)
            }
            if mode == .external {
                SecureField("本机授权 URL（含 token）", text: $authorization).textFieldStyle(.roundedBorder)
                Text("粘贴 dsh 启动时输出的完整本机 URL。授权保存在当前用户钥匙串中；已连接时可留空沿用。")
                    .foregroundStyle(.secondary)
            }
            if let failure = error ?? accountID.flatMap({ perch.dshErrors[$0] }) {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let validation { Text(validation).foregroundStyle(.secondary) }
            Text("退出 Perch 不停止服务。移除账号保留数据和运行中的任务。")
                .foregroundStyle(.secondary)
            HStack {
                Button("取消", action: close).disabled(isBusy)
                Spacer(minLength: 4)
                if mode != .external {
                    Button("检查配置", action: validate).disabled(isBusy)
                }
                Button(submitting ? "连接中…" : accountID == nil ? (mode == .external ? "添加并连接" : "添加并打开") : "保存并打开") {
                    submit()
                }
                .disabled(isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (mode == .external && accountID == nil && authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: mode) { authorization = ""; error = nil; validation = nil }
    }

    private var installationFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(perch.dshScanning ? "查找中…" : "查找本机安装") { perch.scanDshInstallations() }
                    .disabled(perch.dshScanning || isBusy)
                if !perch.dshInstallations.isEmpty {
                    Menu("选择安装（\(perch.dshInstallations.count)）") {
                        ForEach(perch.dshInstallations) { candidate in
                            Button(candidate.label + " · " + candidate.path) { choose(candidate) }
                        }
                    }
                }
            }
            pathField(mode == .source ? "已构建的源码目录" : "npm 包目录或 dsh 命令", text: $installation, directories: nil)
            if !installation.isEmpty, let candidate = DshInstallation.inspect(installation) {
                Text(candidate.label + (candidate.nodeRequirement.isEmpty ? "" : " · Node " + candidate.nodeRequirement))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("复制安装命令") {
                    perch.pasteboard.clearContents()
                    perch.pasteboard.setString("npx @deepseek-ai/dsh web", forType: .string)
                    validation = "已复制；在终端运行后查找安装，或连接它输出的本机 URL。"
                }
                Link("官方说明", destination: URL(string: "https://github.com/deepseek-ai/deepseek-harness#run")!)
            }
            Text(mode == .source ? "源码需先完成 pnpm install 和 pnpm run build。" : "支持全局/项目 npm 安装和 npx 缓存。Perch 不自动安装或升级依赖。")
                .foregroundStyle(.secondary)
        }
    }

    private func pathField(_ label: String, text: Binding<String>, directories: Bool?, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, text: text).textFieldStyle(.roundedBorder).disabled(disabled)
                if !disabled {
                    Button("选择…") {
                        let picker = NSOpenPanel()
                        picker.canChooseDirectories = directories != false
                        picker.canChooseFiles = directories != true
                        picker.allowsMultipleSelection = false
                        picker.showsHiddenFiles = true
                        if picker.runModal() == .OK, let url = picker.url {
                            text.wrappedValue = url.path
                            validation = nil
                        }
                    }.disabled(isBusy)
                }
            }
        }
    }

    private func choose(_ candidate: DshInstallCandidate) {
        installation = candidate.path; mode = candidate.mode
        if node.isEmpty { node = candidate.node }
        error = nil; validation = candidate.label
    }

    private var configuration: DshConfiguration {
        DshConfiguration(mode: mode, installationPath: installation, nodePath: node,
                         profile: profile, balanceHome: balanceHome)
    }

    private func checkedConfiguration() throws -> DshConfiguration {
        let config = try perch.checkedDshConfiguration(configuration, home: home)
        if !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try DshConnection.validateURL(authorization)
        }
        return config
    }

    private func validate() {
        do { _ = try checkedConfiguration(); error = nil; validation = "配置检查通过，可以启动 Web 服务。" }
        catch { self.error = error.localizedDescription; validation = nil }
    }

    private func submit() {
        error = nil; validation = nil
        submitting = true
        Task { @MainActor in
            do {
                let config = try checkedConfiguration()
                let saved = try await perch.saveDsh(name: name, home: home, configuration: config, accountID: accountID)
                accountID = saved.id
                home = saved.profilePath
                let finish: (LaunchOutcome) -> Void = { outcome in
                    submitting = false
                    if case .failed(let detail) = outcome { error = detail } else { authorization = ""; close() }
                }
                if !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    perch.connectDsh(saved, url: authorization) { connected in
                        if connected { perch.launchDsh(saved, then: finish) }
                        else { submitting = false; error = perch.dshErrors[saved.id] ?? "连接未完成，请检查授权 URL 后重试。" }
                    }
                } else { perch.launchDsh(saved, then: finish) }
            } catch { self.error = error.localizedDescription; submitting = false }
        }
    }
}
