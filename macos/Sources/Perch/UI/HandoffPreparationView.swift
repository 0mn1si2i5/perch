import SwiftUI

struct HandoffPreparationView: View {
    @ObservedObject var perch: PerchModel

    var body: some View {
        if let pending = perch.pendingHandoff {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("待继续接力", systemImage: "doc.on.clipboard").fontWeight(.semibold)
                    Spacer()
                    Menu {
                        Button("使用已有文档…") { perch.useExistingHandoffDocument() }
                        Button("打开交接文件夹") { perch.revealHandoffs() }
                        Button("取消接力", role: .destructive) { perch.cancelHandoffPreparation() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(perch.completingHandoff)
                    .accessibilityLabel("接力选项")
                }
                Text(pending.title).lineLimit(1).help(pending.title)
                let source = perch.accounts.first { $0.id == pending.sourceID }?.name ?? "源账号已移除"
                let target = perch.accounts.first { $0.id == pending.targetID }?.name ?? "目标账号已移除"
                let route = PerchModel.handoffRoute(source: source, target: target, sameAccount: pending.staysInAccount)
                    + (pending.scope == .split ? " · 拆出需求" : "")
                Text(route).lineLimit(1).foregroundStyle(.secondary).help(route)
                Text(pending.scope == .split
                     ? "在源对话粘贴提示词，在末尾写上要拆出的需求再发送；文档写好后 Perch 会通知你继续。"
                     : "在源对话粘贴提示词并发送，文档写好后 Perch 会通知你继续。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("复制提示词") { perch.copyPreparationPrompt() }
                    Spacer()
                    Button(perch.completingHandoff ? "准备中…" : "继续接力") { perch.continueHandoff() }
                }
                .disabled(perch.completingHandoff)
            }
            .font(.system(size: 11))
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
