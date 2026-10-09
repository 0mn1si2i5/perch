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
                Text("\(source) → \(target)").lineLimit(1).foregroundStyle(.secondary)
                    .help("\(source) → \(target)")
                Text("在源对话粘贴提示词并发送，文档生成后继续。")
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
