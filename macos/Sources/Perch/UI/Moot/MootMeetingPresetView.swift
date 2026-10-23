import SwiftUI
import PerchCore
struct MootMeetingPresetView: View {
    @ObservedObject var model: MootModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("圆桌会议").font(.title2)
                Text("当前与你对话的 agent 担任主持人。第一轮独立发言，后续轮次回应其他观点；每轮由主持人归纳。").foregroundStyle(.secondary)
                Toggle("允许自动发起圆桌", isOn: $model.config.automaticRoundtable).toggleStyle(.switch)
                Text("默认关闭。你明确要求圆桌时仍可发起，普通委派不受影响。").font(.callout).foregroundStyle(.secondary)
                Stepper("轮数上限：\(model.config.meetingPreset.maxRounds)", value: $model.config.meetingPreset.maxRounds, in: 1...10)
                Toggle("允许主持人在完整一轮后提前结束", isOn: $model.config.meetingPreset.allowEarlyFinish)
                Divider()
                HStack { Text("参与席位").font(.headline); Spacer(); Button("添加席位") { var seat = MootSeat(); seat.connectionID = model.config.connections.first(where: { $0.authMode == "subscription" })?.id ?? ""; model.config.meetingPreset.seats.append(seat) }.disabled(model.config.meetingPreset.seats.count >= 6) }
                ForEach($model.config.meetingPreset.seats) { $seat in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Picker("交给谁", selection: $seat.connectionID) { Text("选择订阅接入").tag(""); ForEach(model.config.connections.filter { $0.authMode == "subscription" }) { Text($0.name).tag($0.id) } }; Button { model.config.meetingPreset.seats.removeAll { $0.seatID == seat.seatID } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                        TextField("具体模型（留空使用默认）", text: $seat.model)
                        TextField("角色，如技术评估、产品设计、反方审视", text: $seat.role)
                        TextField("角色职责", text: $seat.instructions, axis: .vertical).lineLimit(2...4)
                    }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("一轮 = 每个席位发言一次 + 主持人总结。达到上限后停止，未解决问题保留。").font(.callout).foregroundStyle(.secondary)
                Button("复制圆桌发起提示") { model.copy("请使用 moot-roundtable 技能，按我在 Perch 保存的参与模型、角色和轮数召开圆桌。由你主持，每轮归纳共识与分歧，达到上限后保留未解决问题。议题：") }
            }.padding(22)
        }
    }
}
