import AppKit
import SwiftUI
import PerchCore

struct MootRootView: View {
    @ObservedObject var model: MootModel
    @ObservedObject var perch: PerchModel
    @ObservedObject var pet: PetModel
    @State private var confirmUninstall = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Moot", systemImage: "person.3.sequence").font(.title3.weight(.semibold))
                Text(model.installation.map { "\($0.version) · \($0.state == .pendingUninstall ? "等待卸载" : $0.state == .installed ? "已安装" : "未安装")" } ?? "可选扩展").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if model.installed {
                    Button("保存配置") { model.saveConfig() }.disabled(model.busy || model.section == .runs)
                    Menu { Button("安装技能到客户端…") { model.chooseSkillRoot() }; Button("从本地包更新…") { model.choosePackage() }; Button("卸载…") { confirmUninstall = true } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }.padding(18)
            Divider()
            if model.installed {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(MootSection.allCases) { section in
                            Button { model.section = section } label: {
                                Label(section.title, systemImage: section.icon).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(model.section == section ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Text("执行独立于 Perch\n关闭窗口不会停止任务").font(.caption).foregroundStyle(.secondary)
                        if model.runs.contains(where: \.active) { Text("\(model.runs.filter(\.active).count) 项进行中").font(.caption) }
                    }.padding(12).frame(width: 160)
                    Divider()
                    Group {
                        switch model.section {
                        case .capabilities: MootCapabilityView(model: model)
                        case .connections: MootConnectionView(model: model, perch: perch)
                        case .meeting: MootMeetingPresetView(model: model)
                        case .runs: MootRunListView(model: model)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.busy)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "person.3.sequence").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("让已配置的 agent 协作").font(.title2)
                    Text("按能力委派、独立审核、订阅生图和多模型圆桌。\n安装后选择接入和技能位置，API 默认关闭。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("安装 Moot") { model.installBundled() }.disabled(model.busy)
                    Button("选择本地扩展包…") { model.choosePackage() }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = model.error ?? model.notice {
                Divider(); HStack { Image(systemName: model.error == nil ? "checkmark.circle" : "exclamationmark.circle"); Text(message).textSelection(.enabled); Spacer(); Button("关闭") { model.error = nil; model.notice = nil }.buttonStyle(.plain) }.font(.callout).padding(12)
            }
        }
        .background(pet.usesCharacterTheme ? pet.theme.background : Color(nsColor: .windowBackgroundColor))
        .tint(pet.usesCharacterTheme ? pet.theme.accent : Color.accentColor)
        .accentColor(pet.usesCharacterTheme ? pet.theme.accent : Color.accentColor)
        .preferredColorScheme(pet.usesCharacterTheme ? .dark : nil)
        .confirmationDialog("卸载 Moot", isPresented: $confirmUninstall) {
            Button("任务结束后卸载") { model.uninstall(cancel: false) }
            Button("取消任务并卸载", role: .destructive) { model.uninstall(cancel: true) }
        } message: { Text("默认保留配置、记录与产物。等待主持人的圆桌也属于未完成任务。") }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.windowVisible ? 5 : 20))
                guard model.installed, !model.busy else { continue }
                do { try await model.refreshIfChanged() } catch { model.error = error.localizedDescription }
            }
        }
    }
}
