import AppKit
import SwiftUI
import PerchCore

struct ProviderEditorView: View {
    @ObservedObject var perch: PerchModel
    var account: Account? = nil
    let close: () -> Void

    var body: some View {
        if account?.app == .api {
            APIProviderEditorView(perch: perch, account: account, close: close)
        } else {
            LocalProviderEditorView(perch: perch, account: account, close: close)
        }
    }
}

struct LocalProviderEditorView: View {
    @ObservedObject var perch: PerchModel
    let account: Account?
    let close: () -> Void
    @State private var name: String
    @State private var kind: LocalLaunchKind
    @State private var target: String
    @State private var arguments: String
    @State private var workingDirectory: String
    @State private var profilePath: String

    private var isImportedProvider: Bool {
        guard let account else { return false }
        return [.gemini, .geminiApp, .antigravity, .deepseek].contains(account.app)
    }

    init(perch: PerchModel, account: Account? = nil, close: @escaping () -> Void) {
        self.perch = perch
        self.account = account
        self.close = close
        let configuration = account?.localProvider
        _name = State(initialValue: account?.name ?? "")
        _kind = State(initialValue: configuration?.kind ?? .terminal)
        _target = State(initialValue: configuration?.target ?? "")
        _arguments = State(initialValue: configuration?.arguments.joined(separator: "\n") ?? "")
        _workingDirectory = State(initialValue: configuration?.workingDirectory ?? "")
        _profilePath = State(initialValue: account?.profilePath ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField("名称", placeholder: "例如 本机 CLI", text: $name)
            Picker("启动方式", selection: $kind) {
                Text(LocalLaunchKind.terminal.displayName).tag(LocalLaunchKind.terminal)
                Text(LocalLaunchKind.application.displayName).tag(LocalLaunchKind.application)
                Text(LocalLaunchKind.website.displayName).tag(LocalLaunchKind.website)
            }
            .pickerStyle(.menu)
            .disabled(isImportedProvider)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .website ? "网址" : "启动目标").font(.system(size: 11, weight: .medium))
                TextField(targetPlaceholder, text: $target).textFieldStyle(.roundedBorder)
                if kind != .website {
                    Button("选择\(kind == .application ? "应用" : "可执行文件")…") { chooseTarget() }
                        .controlSize(.small)
                }
            }
            if kind != .website {
                VStack(alignment: .leading, spacing: 4) {
                    Text("启动参数（可选，每行一个）").font(.system(size: 11, weight: .medium))
                    TextEditor(text: $arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 62)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                    Text("只填写参数，不填写 shell 命令或 API 密钥。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if kind == .terminal {
                labeledField("工作目录（可选）", placeholder: "留空使用默认目录", text: $workingDirectory)
                Button("选择工作目录…") { chooseDirectory { workingDirectory = $0 } }
                    .controlSize(.small)
            }
            if isImportedProvider {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机配置目录").font(.system(size: 11, weight: .medium))
                    Text(profilePath).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                labeledField("配置目录（可选）", placeholder: "引用本机已有目录", text: $profilePath)
                Button("选择配置目录…") { chooseDirectory { profilePath = $0 } }
                    .controlSize(.small)
            }
            Text(configurationHelp)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消", action: close)
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var configurationHelp: String {
        switch account?.app {
        case .gemini, .deepseek:
            return "启动时使用此本机配置目录，沿用已有登录。是否已登录需在客户端内确认。"
        case .geminiApp:
            return "沿用 Gemini 原生应用当前登录。打开应用内的 Antigravity 后可查询额度。"
        case .antigravity:
            return "引用本机现有配置；启动不会切换 Antigravity 登录账号。"
        default:
            return "配置目录仅作为本机引用保留，不会自动切换登录或传给启动程序。若工具需要指定目录，请按工具要求填写启动参数。"
        }
    }

    private var targetPlaceholder: String {
        switch kind {
        case .terminal: return "可执行文件绝对路径"
        case .application: return "应用的 .app 路径"
        case .website: return "https://example.com"
        }
    }

    private func save() {
        let configuration = LocalProviderConfiguration(
            kind: kind,
            target: target.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: kind == .website ? [] : arguments.components(separatedBy: .newlines).filter { !$0.isEmpty },
            workingDirectory: kind == .terminal ? workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )
        if perch.saveLocalProvider(existing: account, name: name, profilePath: profilePath.trimmingCharacters(in: .whitespacesAndNewlines), configuration: configuration) { close() }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = kind == .application ? "选择应用" : "选择可执行文件"
        if kind == .application { panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        if panel.runModal() == .OK, let url = panel.url { target = url.path }
    }

    private func chooseDirectory(_ accept: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { accept(url.path) }
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

struct APIProviderEditorView: View {
    @ObservedObject var perch: PerchModel
    let account: Account?
    let close: () -> Void
    @State private var name: String
    @State private var presetID: String
    @State private var displayName: String
    @State private var baseURL: String
    @State private var protocolKind: APIProtocol
    @State private var model: String
    @State private var dashboardURL: String
    @State private var key = ""
    @State private var removeKey = false

    private var endpointChanged: Bool {
        guard let previous = account?.apiProvider else { return false }
        return baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != previous.baseURL || protocolKind != previous.protocolKind
    }

    private var availableModels: [String] {
        guard let account else { return [] }
        return perch.apiModels[account.id] ?? []
    }

    init(perch: PerchModel, account: Account? = nil, close: @escaping () -> Void) {
        self.perch = perch
        self.account = account
        self.close = close
        let configuration = account?.apiProvider
        _name = State(initialValue: account?.name ?? "")
        _presetID = State(initialValue: configuration?.presetID ?? "custom")
        _displayName = State(initialValue: configuration?.displayName ?? "自定义供应商")
        _baseURL = State(initialValue: configuration?.baseURL ?? "")
        _protocolKind = State(initialValue: configuration?.protocolKind ?? .openAI)
        _model = State(initialValue: configuration?.model ?? "")
        _dashboardURL = State(initialValue: configuration?.dashboardURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("供应商", selection: $presetID) {
                ForEach(ProviderPreset.all, id: \.id) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: presetID) { _, newValue in applyPreset(newValue) }
            field("账号名称", placeholder: "例如 我的 API", text: $name)
            field("供应商名称", placeholder: "自定义供应商", text: $displayName)
            Picker("API 协议", selection: $protocolKind) {
                Text(APIProtocol.openAI.displayName).tag(APIProtocol.openAI)
                Text(APIProtocol.anthropic.displayName).tag(APIProtocol.anthropic)
                Text(APIProtocol.gemini.displayName).tag(APIProtocol.gemini)
            }
            .pickerStyle(.menu)
            field("API 基础地址", placeholder: "https://api.example.com/v1", text: $baseURL)
            field("模型（可选）", placeholder: "模型 ID", text: $model)
            if !availableModels.isEmpty && !endpointChanged {
                Menu("选择已发现的模型") {
                    ForEach(availableModels, id: \.self) { modelID in
                        Button(modelID) { model = modelID }
                    }
                }
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API 密钥").font(.system(size: 11, weight: .medium))
                SecureField(account == nil ? "可选，保存在 macOS 钥匙串" : (endpointChanged ? "新地址使用的密钥" : "留空保留已存密钥"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .disabled(removeKey)
                if account != nil {
                    Toggle("删除已存密钥", isOn: $removeKey).font(.system(size: 11))
                }
                if endpointChanged {
                    Text("API 地址已改变；如已保存密钥，请重新输入或删除。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            field("控制台网址（可选）", placeholder: "https://example.com/dashboard", text: $dashboardURL)
            Text("密钥保存在 macOS 钥匙串。保存后可检查模型列表连接；这不代表模型推理、余额或额度已验证。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { clearAndClose() }
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func applyPreset(_ id: String) {
        guard let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
        let configuration = preset.configuration
        displayName = configuration.displayName
        baseURL = configuration.baseURL
        protocolKind = configuration.protocolKind
        model = configuration.model
        dashboardURL = configuration.dashboardURL
        key = ""
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = preset.name }
    }

    private func save() {
        let configuration = APIProviderConfiguration(
            presetID: presetID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            protocolKind: protocolKind,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            dashboardURL: dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let updatedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if perch.saveAPIProvider(existing: account, name: name, configuration: configuration,
                                 key: updatedKey.isEmpty ? nil : updatedKey, removeKey: removeKey) {
            clearAndClose()
        }
    }

    private func clearAndClose() {
        key = ""
        removeKey = false
        close()
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
