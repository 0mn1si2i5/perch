import SwiftUI
import PerchCore
struct MootConnectionView: View {
    @ObservedObject var model: MootModel
    @ObservedObject var perch: PerchModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("模型接入").font(.title2); Spacer(); Menu("添加接入") {
                    ForEach(MootAccountBinding.candidates(accounts: perch.accounts)) { candidate in Button(candidate.connection.name) { model.config.connections.append(candidate.connection) } }
                    Divider()
                    Button("独立 Claude Code 绑定") { model.addIndependent("claude") }
                    Button("独立 Codex 绑定") { model.addIndependent("codex") }
                    Button("本机 Gemini / Antigravity") { model.addIndependent("agy") }
                    Button("Google 图像 API 备用") { var c = MootConnection(); c.name = "Google 图像 API"; c.adapter = "google-image-api"; c.authMode = "api"; c.tools = ["image"]; c.enabled = false; model.config.connections.append(c) }
                } }
                Text("只开放你选择的接入。桌面账号与命令行登录分别验证。").foregroundStyle(.secondary)
                ForEach($model.config.connections) { $connection in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Toggle("启用", isOn: $connection.enabled).labelsHidden(); TextField("账号名称", text: $connection.name).font(.headline); Spacer(); Text(connection.authMode == "api" ? "API 备用" : "订阅").foregroundStyle(.secondary); Button { model.config.connections.removeAll { $0.id == connection.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                        if connection.adapter == "agy" { Text("Gemini → 内置生图工具（Nano Banana）").font(.callout) }
                        if connection.adapter == "claude" { Text("使用独立 Claude Code 登录，不沿用 Claude 桌面 profile。").font(.callout).foregroundStyle(.secondary) }
                        HStack { Text(verificationLabel(connection)).font(.callout).foregroundStyle(.secondary); Spacer(); Button("检查接入") { model.check(connection) } }
                        PanelDisclosure("详细配置") {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("默认模型（留空使用客户端默认值）", text: $connection.defaultModel)
                                if let models = connection.models, !models.isEmpty { Menu("选择已发现模型") { ForEach(models, id: \.self) { name in Button(name) { connection.defaultModel = name } } } }
                                if connection.authMode == "subscription" { TextField("可执行程序绝对路径", text: $connection.executable); TextField("CLI 账号目录", text: $connection.accountRoot) }
                                Toggle("可调用内置生图工具", isOn: Binding(get: { connection.tools.contains("image") }, set: { value in connection.tools = value ? ["image"] : [] }))
                                if connection.authMode == "api" { MootCredentialField(connection: $connection) }
                                Text("路径与模型会用于后续任务；实际调用记录保留原配置。").font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 10)
                        }
                    }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                HStack { Text("统一技能家族").font(.headline); Spacer(); Button("选择客户端 skills 目录…") { model.chooseSkillRoot() } }
                HStack { Button("预览旧技能迁移…") { model.migrateSkills() }; Button("恢复旧技能…") { model.restoreSkills() } }
                Text("moot-delegate · moot-review · moot-roundtable\n既有技能发生冲突时保留原文件；迁移前可预览并备份。").font(.callout).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
    func verificationLabel(_ c: MootConnection) -> String { switch c.verification?["status"].text { case "loginDetected": return "检测到登录 · 工具仍需实际任务验证"; case "unavailable": return "接入不可用"; default: return "尚未验证" } }
}
