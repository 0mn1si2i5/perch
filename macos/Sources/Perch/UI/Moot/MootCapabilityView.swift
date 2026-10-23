import SwiftUI
import PerchCore
struct MootCapabilityView: View {
    @ObservedObject var model: MootModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("能力配置").font(.title2); Spacer(); Menu("添加能力") { Button("通用 / 自定义") { model.addCapability() }; Button("代码审核") { model.addCapability("audit", title: "代码审核") }; Button("文档与文案") { model.addCapability("draft", title: "文档与文案") }; Button("图像生成") { model.addCapability("image", title: "图像生成") } } }
                Text("在你配置的范围内自动选择。明确指定模型时，按你的要求执行。").foregroundStyle(.secondary)
                if model.config.capabilities.isEmpty { Text("先在模型接入中选择账号，再添加能力。").padding(.vertical, 20) }
                ForEach($model.config.capabilities) { $capability in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Toggle("启用", isOn: $capability.enabled).labelsHidden(); TextField("能力名称", text: $capability.description).font(.headline); Button { model.config.capabilities.removeAll { $0.id == capability.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                        Picker("交给谁", selection: $capability.primaryConnectionID) {
                            Text("选择接入").tag("")
                            ForEach(model.config.connections.filter { $0.authMode == "subscription" }) { Text($0.name).tag($0.id) }
                        }
                        Picker("怎么完成", selection: $capability.completionMode) { Text("委派执行").tag("delegate"); Text("独立审核").tag("audit"); Text("撰写内容").tag("draft"); Text("使用内置生图工具").tag("image") }
                            .onChange(of: capability.completionMode) { capability.requiredTools = capability.completionMode == "image" ? ["image"] : [] }
                        if capability.completionMode == "image" { Text("默认由 Gemini 订阅使用内置工具生图，需返回真实图片文件。").font(.callout).foregroundStyle(.secondary) }
                        TextField("补充要求", text: $capability.instructions, axis: .vertical).lineLimit(2...5)
                        PanelDisclosure("详细配置") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("能力 ID", text: $capability.id).help("技能按此 ID 发起任务；通用能力使用 general")
                                TextField("具体模型（留空使用接入默认值）", text: Binding(get: { capability.modelOverride ?? "" }, set: { capability.modelOverride = $0.isEmpty ? nil : $0 }))
                                Text("备用接入 · 按下列顺序，订阅优先").font(.callout)
                                ForEach(model.config.connections.filter { $0.id != capability.primaryConnectionID }) { c in
                                    Toggle(c.name + (c.authMode == "api" ? " · API" : " · 订阅"), isOn: Binding(get: { capability.fallbackConnectionIDs.contains(c.id) }, set: { enabled in if enabled { capability.fallbackConnectionIDs.append(c.id) } else { capability.fallbackConnectionIDs.removeAll { $0 == c.id } } }))
                                }
                                Text("共享的工具与调用路径在“模型接入”中设置。").font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 10)
                        }
                    }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                Toggle("允许 API 作为备用", isOn: $model.config.apiEnabled).toggleStyle(.switch)
                Text("默认关闭。开启后仍需配置 API 接入、凭据和能力备用；不会因订阅失败自动开启。").font(.callout).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
}
