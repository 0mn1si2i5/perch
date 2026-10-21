import SwiftUI

struct PanelInfoView: View {
    @ObservedObject var perch: PerchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            item("账号与任务", symbol: "rectangle.stack") {
                Text("点账号或会话调出客户端，右键查看更多操作。分组可收起；分组、账号可拖动排序。会话整行可拖动，仅限同一账号、同一状态分区。")
            }
            item("额度", symbol: "gauge.with.dots.needle.50percent") {
                Text("Codex 与 Claude 的百分比为已用额度，悬停查看剩余。打开面板会同步，也可手动刷新。")
                Text("同步失败时保留缓存；标记表示记录时间，悬停警示查看原因。")
                    .foregroundStyle(.secondary)
            }
            item("供应商入口", symbol: "point.3.connected.trianglepath.dotted") {
                Text("在“新建账号”中点“自动获取可用供应商”，添加本机 Gemini 应用、Gemini CLI、Antigravity、DeepSeek Harness。")
                Text("本机入口沿用现有登录；成功启动不代表登录已验证。")
                    .foregroundStyle(.secondary)
            }
            item("桌面入口", symbol: "pawprint") {
                Text("在设置开启桌宠，爪印控制显示与隐藏。单击打开面板，拖动换位置。原生浮球保留系统外观，Pox 使用角色主题。")
            }
            Divider()
            PanelDisclosure("数据与限制") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("平时只读任务元数据，不提取或自动发送聊天。")
                    Text("Claude 额度使用对应账号授权，仅在内存中使用。首次手动同步可能需要钥匙串授权；后台不弹提示。")
                    Text("Codex 单实例可直接定位对话；多实例时只调出所属客户端。Claude 目前只调出客户端，需自行选择会话。")
                    Text("Claude 桌面会话按账号目录读取。“Code”表示本机 Claude Code 历史，仅显示在默认客户端卡片；其登录账号可能与桌面客户端不同。")
                    Text("本机供应商只引用已有目录，不复制登录凭据。Gemini CLI、Antigravity 与 DeepSeek Harness 读取本机会话索引。")
                    Text("Antigravity 额度以 Gemini 应用为准。Antigravity CLI 卡片只在点刷新时运行一次 agy 查询，后台不运行。")
                    if let backup = perch.removedAccountsBackup {
                        Text("API 供应商和自定义客户端已移除，原来的这类账号保存在：")
                        Text(backup.path).textSelection(.enabled)
                        Text("它们的 API 密钥仍在钥匙串里，Perch 不会删除。要清理，打开“钥匙串访问”，搜索 com.omnis.perch.api-provider，删除找到的条目。")
                    }
                    if !perch.skippedImports.isEmpty {
                        Text("旧账号导入时跳过：\(perch.skippedImports.joined(separator: "、"))。该导入流程仅支持 Codex 与 Claude；其他供应商可在“新建账号”中添加。")
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            }
            .help("本机数据、授权与客户端限制")
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).fontWeight(.semibold)
            content()
        }
    }
}
