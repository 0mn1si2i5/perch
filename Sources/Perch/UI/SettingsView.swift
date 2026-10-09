import AppKit
import SwiftUI
import PerchCore

struct SettingsView: View {
    @ObservedObject var perch: PerchModel
    @ObservedObject var pet: PetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("开启桌宠", isOn: Binding(get: { pet.enabled }, set: { pet.setEnabled($0) }))
                    .toggleStyle(.switch)
                if pet.enabled {
                    Picker("桌宠", selection: Binding(get: { pet.character }, set: { pet.select($0) })) {
                        ForEach(CompanionKind.allCases) { character in
                            Text(character.title).tag(character)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("爪印控制显示与隐藏；隐藏后保留所选主题。").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if pet.character == .native {
                        Text("静态浮球，保持 macOS 原生外观。可拖动定位，单击打开面板。").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if pet.enabled && pet.character == .pox {
                    Text("桌宠 Pox").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text("大小")
                        Slider(value: $pet.petSize, in: 135...265, step: 5).onChange(of: pet.petSize) { pet.saveSettings() }
                    }
                    Toggle("安静模式（收起气泡与动作）", isOn: $pet.quiet).onChange(of: pet.quiet) { pet.saveSettings() }
                    Toggle("媒体感知", isOn: $pet.mediaEnabled).onChange(of: pet.mediaEnabled) { pet.saveSettings() }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(PetPose.allCases, id: \.rawValue) { pose in
                            Button(pose.label) { pet.preview(pose) }.buttonStyle(.bordered)
                        }
                    }
                    Text("动作预览持续 8 秒，随后恢复真实状态。").foregroundStyle(.secondary)
                }

            }
            .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 8) {
                Toggle("自动同步额度（每 5 分钟）", isOn: $perch.automaticallySyncQuota)
                    .toggleStyle(.switch)
                Button(perch.refreshingQuotas.isEmpty ? "立即同步所有账号" : "正在同步…") {
                    perch.refreshQuotas(manual: true)
                }
                .disabled(!perch.refreshingQuotas.isEmpty)
                Text("打开面板也会同步；账号旁的刷新按钮可立即重试。后台同步不会弹出钥匙串授权，遇到限流会延后重试。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            if !perch.skippedImports.isEmpty {
                Text("从 agent-desk 导入时跳过了：\(perch.skippedImports.joined(separator: "、"))。Perch 只支持 Codex 和 Claude。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if perch.accounts.filter({ $0.app == .claude }).count > 1 {
                Text("Claude 的本地 Code 会话不区分账号，统一显示在第一个 Claude 账号下。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("文档接力").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("打开交接文件夹") { perch.revealHandoffs() }.buttonStyle(.plain).font(.system(size: 11))
            }
            Text(perch.handoffs.directory.path).font(.system(size: 10)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !perch.handoffLog.isEmpty { HandoffHistoryView(perch: perch) }
            Text("平时读取任务元数据、会话标题和工作目录。接力只复制你选择的交接文档，不提取聊天正文；请在目标新对话手动粘贴并发送。文档只保存在本机。查询 Claude 额度时会读取对应客户端的登录授权，仅在内存中使用，不保存到 Perch 文件或日志。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("退出 Perch") { NSApp.terminate(nil) }
            }
        }
    }
}
