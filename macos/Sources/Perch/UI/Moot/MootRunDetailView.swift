import AppKit
import SwiftUI
import PerchCore
struct MootRunDetailView: View {
    @ObservedObject var model: MootModel
    let run: MootRunSnapshot
    @State private var roundSelection = 0
    @State private var seatSelection = "all"
    static func stateLabel(_ state: String) -> String { switch state { case "running", "runningRound": return "运行中"; case "awaitingHost": return "等待主持人"; case "readyForNextRound": return "等待推进下一轮"; case "ended": return "执行已结束"; case "cancelled": return "已取消"; case "failed": return "失败"; case "legacy": return "旧记录（只读）"; default: return state } }
    var record: MootJSON { run.record }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(run.title).font(.title3).textSelection(.enabled)
                    HStack { Text(Self.stateLabel(run.state)).fontWeight(.medium); Spacer(); if run.active { Button("取消任务", role: .destructive) { model.cancel(run) } } }
                    Text(record["createdAt"].text).font(.caption).foregroundStyle(.secondary)
                    if !record["error"].text.isEmpty { Label(record["error"].text, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
                    if record["task"]["mode"].text != "roundtable" {
                        Text("\(record["route"]["model"].text.isEmpty ? "客户端默认模型" : record["route"]["model"].text) · \(record["route"]["authMode"].text == "api" ? "API" : "订阅")").font(.callout)
                        Text(record["route"]["reason"].text).font(.caption).foregroundStyle(.secondary)
                        Text(record["output"].text.isEmpty ? "等待输出…" : record["output"].text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if run.state == "awaitingHost" { Text("本轮发言已保存。当前对话的主持人需回读结果、提交总结，再推进下一轮。").foregroundStyle(.secondary) }
                        HStack {
                            Picker("轮次", selection: $roundSelection) { Text("全部轮次").tag(0); ForEach(record["rounds"].items, id: \.roundID) { Text("第 \($0["number"].integer) 轮").tag($0["number"].integer) } }
                            Picker("席位", selection: $seatSelection) { Text("全部席位").tag("all"); ForEach(record["meeting"]["seats"].items, id: \.seatID) { Text($0["role"].text).tag($0["seatID"].text) } }
                        }
                        ForEach(record["rounds"].items.filter { roundSelection == 0 || $0["number"].integer == roundSelection }, id: \.roundID) { round in
                            Text("第 \(round["number"].integer) 轮").font(.headline)
                            ForEach(round["seats"].items.filter { seatSelection == "all" || $0["seatID"].text == seatSelection }, id: \.seatID) { seat in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(seat["role"].text).fontWeight(.semibold); Spacer(); Text(seat["model"].text).font(.caption) }
                                    Text(Self.stateLabel(seat["state"].text)).font(.caption).foregroundStyle(.secondary)
                                    Text(seat["output"].text).textSelection(.enabled)
                                    if !seat["error"].text.isEmpty { Text(seat["error"].text).foregroundStyle(.secondary) }
                                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).id(seat["messageID"].text)
                            }
                            if round["summary"] != .null {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("主持人总结").font(.headline)
                                    Text("共同建议").fontWeight(.medium)
                                    ForEach(round["summary"]["commonGround"].items, id: \.pretty) { Text("• " + $0.text).textSelection(.enabled) }
                                    Text("主持人判断").fontWeight(.medium)
                                    Text(round["summary"]["hostJudgment"].text).textSelection(.enabled)
                                    if !round["summary"]["missingSeats"].items.isEmpty { Text("缺席 / 失败席位：" + round["summary"]["missingSeats"].items.map(\.text).joined(separator: "、")).foregroundStyle(.secondary) }
                                }.padding(.vertical, 8)
                            }
                            Divider()
                        }
                        Text("未解决分歧").font(.headline)
                        ForEach(record["issues"].items.filter { $0["status"].text == "open" }, id: \.issueID) { issue in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(issue["title"].text).fontWeight(.semibold); Text(issue["positions"].text).textSelection(.enabled); Text(issue["next"].text).foregroundStyle(.secondary)
                                ForEach(issue["references"].items, id: \.pretty) { ref in
                                    let exists = record["rounds"].items.contains { r in r["number"].integer == ref["round"].integer && r["seats"].items.contains { $0["seatID"].text == ref["seatID"].text && $0["messageID"].text == ref["messageID"].text } }
                                    let role = record["meeting"]["seats"].items.first { $0["seatID"].text == ref["seatID"].text }?["role"].text ?? ref["seatID"].text
                                    Button(exists ? "第 \(ref["round"].integer) 轮 · \(role)原文" : "原文缺失") {
                                        roundSelection = ref["round"].integer; seatSelection = ref["seatID"].text
                                        DispatchQueue.main.async { proxy.scrollTo("detail-top", anchor: .top) }
                                    }.disabled(!exists)
                                }
                            }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    if !record["artifacts"].items.isEmpty {
                        Text("产物").font(.headline)
                        ForEach(record["artifacts"].items, id: \.pretty) { artifact in
                            let url = URL(fileURLWithPath: artifact["path"].text)
                            if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260) }
                            HStack { Button(artifact["name"].text) { NSWorkspace.shared.open(url) }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                        }
                    }
                    PanelDisclosure("过程事件") { VStack(alignment: .leading, spacing: 8) { ForEach(record["events"].items.filter { $0["kind"].text != "delta" }, id: \.eventID) { Text($0["text"].text).font(.callout).textSelection(.enabled) } }.padding(.top, 10) }
                    PanelDisclosure("本次配置快照") { Text(record["configSnapshot"].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 10) }
                    HStack { Button("复制结果") { model.copy(exportText) }; Button("导出 Markdown…") { export() } }
                }.padding(20).id("detail-top")
            }.onChange(of: model.focusedMessage) { if let id = model.focusedMessage { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } } }
        }
    }
    var exportText: String {
        var text = "# \(run.title)\n\n\(Self.stateLabel(run.state))\n\n\(record["output"].text)\n"
        for round in record["rounds"].items { text += "\n## 第 \(round["number"].integer) 轮\n"; for seat in round["seats"].items { text += "\n### \(seat["role"].text) · \(seat["model"].text)\n\n\(seat["output"].text)\n" }; text += "\n主持人总结\n\n\(round["summary"].pretty)\n" }
        text += "\n## 分歧记录\n\n" + record["issues"].pretty
        return text
    }
    func export() { let panel = NSSavePanel(); panel.nameFieldStringValue = "Moot-\(run.id).md"; guard let window = model.window else { return }; panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { do { try exportText.write(to: url, atomically: true, encoding: .utf8) } catch { model.error = error.localizedDescription } } } }
}
