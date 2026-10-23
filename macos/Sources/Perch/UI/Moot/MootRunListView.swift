import SwiftUI
import PerchCore
struct MootRunListView: View {
    @ObservedObject var model: MootModel
    @State private var search = ""
    @State private var status = "all"
    var filtered: [MootRunSnapshot] { model.runs.filter { (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) && (status == "all" || $0.state == status) } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("运行记录").font(.headline); Spacer(); Button { model.perform { try await model.reload() } } label: { Image(systemName: "arrow.clockwise") } }
                TextField("搜索任务", text: $search)
                Button("打开已有运行目录…") { model.openHistory() }
                Picker("状态", selection: $status) { Text("全部").tag("all"); Text("运行中").tag("running"); Text("等待主持人").tag("awaitingHost"); Text("已结束").tag("ended"); Text("失败").tag("failed"); Text("已取消").tag("cancelled") }
                List {
                    ForEach(filtered) { run in
                        Button { model.selectedRunID = run.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(run.title).lineLimit(2)
                                Text(MootRunDetailView.stateLabel(run.state) + (run.record["readOnlyHistory"].flag ? " · 历史只读" : "")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(model.selectedRunID == run.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedRunID == run.id ? .isSelected : [])
                    }
                }.listStyle(.plain)
                if filtered.isEmpty { Text("尚无运行记录").foregroundStyle(.secondary) }
            }.padding(12).frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
            if let run = model.runs.first(where: { $0.id == model.selectedRunID }) {
                MootRunDetailView(model: model, run: run).frame(minWidth: 330)
            } else { Text("选择一次运行查看发言、结果和产物").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}
