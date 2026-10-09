import AppKit
import SwiftUI
import PerchCore

struct SettingsView: View {
    @ObservedObject var perch: PerchModel
    @ObservedObject var pet: PetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("桌面入口") {
                Toggle("桌宠", isOn: Binding(get: { pet.enabled }, set: { pet.setEnabled($0) }))
                    .toggleStyle(.switch)
                if pet.enabled {
                    Picker("角色", selection: Binding(get: { pet.character }, set: { pet.select($0) })) {
                        ForEach(CompanionKind.allCases) { character in
                            Text(character.title).tag(character)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(pet.character == .native ? "静态浮球 · 系统外观" : "角色主题 · 隐藏后保留")
                        .foregroundStyle(.secondary)
                    if pet.character == .pox {
                        DisclosureGroup("桌宠选项") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("大小")
                                    Slider(value: $pet.petSize, in: 135...265, step: 5)
                                        .onChange(of: pet.petSize) { pet.saveSettings() }
                                }
                                Toggle("安静模式", isOn: $pet.quiet)
                                    .onChange(of: pet.quiet) { pet.saveSettings() }
                                    .help("收起气泡与动作")
                                Toggle("媒体感知", isOn: $pet.mediaEnabled)
                                    .onChange(of: pet.mediaEnabled) { pet.saveSettings() }
                                    .help("根据音乐或视频播放状态切换桌宠动作")
                                Menu("预览动作") {
                                    ForEach(PetPose.allCases, id: \.rawValue) { pose in
                                        Button(pose.label) { pet.preview(pose) }
                                    }
                                }
                                .help("预览 8 秒后恢复真实状态")
                            }
                            .padding(.top, 6)
                        }
                    }
                }
            }
            Divider()
            section("额度") {
                Toggle("自动同步", isOn: $perch.automaticallySyncQuota)
                    .toggleStyle(.switch)
                    .help("每 5 分钟同步；后台不会弹出钥匙串授权")
                HStack {
                    Text("每 5 分钟").foregroundStyle(.secondary)
                    Spacer()
                    Button(perch.refreshingQuotas.isEmpty ? "立即同步" : "同步中…") {
                        perch.refreshQuotas(manual: true)
                    }
                    .disabled(!perch.refreshingQuotas.isEmpty)
                    .help("同步所有账号；也可在账号旁单独刷新")
                }
            }
            Divider()
            section("文档接力") {
                Button { perch.revealHandoffs() } label: {
                    Label("打开交接文件夹", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .help(perch.handoffs.directory.path)
                if !perch.handoffLog.isEmpty { HandoffHistoryView(perch: perch) }
            }
            Divider()
            HStack {
                Spacer()
                Button("退出 Perch") { NSApp.terminate(nil) }
            }
        }
        .font(.system(size: 11))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }
}
