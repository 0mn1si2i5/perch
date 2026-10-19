import AppKit
import SwiftUI
import PerchCore

enum DelegatePanelLayout {
    static let header: CGFloat = 36
    static let row: CGFloat = 48
    static let maxCollapsedRows = 4
    static let empty: CGFloat = 44
    static let collapsedWidth: CGFloat = 320
    static let expanded = NSSize(width: 420, height: 540)

    static func size(expanded isExpanded: Bool, runCount: Int) -> NSSize {
        if isExpanded { return expanded }
        let body = runCount == 0 ? empty : CGFloat(min(runCount, maxCollapsedRows)) * row
        return NSSize(width: collapsedWidth, height: header + body + 6)
    }
}

struct DelegatePanelView: View {
    @ObservedObject var monitor: DelegateMonitor
    let close: () -> Void
    let expandedChanged: () -> Void
    @AppStorage(DelegatePanelController.expandedKey) private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if monitor.runs.isEmpty {
                Text("还没有委派任务。Claude 用 codex-delegate 技能启动 Codex 后会显示在这里。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 12)
            } else if expanded {
                DelegateExpandedView(monitor: monitor)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.runs.prefix(DelegatePanelLayout.maxCollapsedRows)) { run in
                        DelegateRunRow(run: run, selected: false)
                            .frame(height: DelegatePanelLayout.row)
                            .contentShape(Rectangle())
                            .onTapGesture { monitor.selectedID = run.id; setExpanded(true) }
                            .contextMenu { DelegateRunActions(run: run) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background(NativePanelMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 12, weight: .semibold))
            Text("Codex 子代理").font(.system(size: 12, weight: .semibold))
            if monitor.runningCount > 0 {
                Text("\(monitor.runningCount) 个运行中").font(.system(size: 11)).foregroundStyle(ReadableStatusColor.green)
            }
            Spacer()
            Button { setExpanded(!expanded) } label: {
                Image(systemName: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .help(expanded ? "收起" : "展开")
            Button(action: close) { Image(systemName: "xmark") }.help("隐藏面板（菜单栏图标右键可再打开）")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: DelegatePanelLayout.header)
    }

    private func setExpanded(_ value: Bool) {
        expanded = value
        expandedChanged()
    }
}

struct DelegateRunRow: View {
    let run: DelegateRun
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DelegateStateIcon(state: run.state).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if run.kind == .review { Text("审核").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Text(run.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    DelegateElapsed(run: run)
                }
                Text(summary).font(.system(size: 11, design: run.latest?.kind == .command ? .monospaced : .default))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    }

    private var summary: String {
        switch run.state {
        case .running: return run.latest.map { $0.text.replacingOccurrences(of: "\n", with: " ") } ?? "启动中…"
        case .succeeded: return "完成 · \(run.commandCount) 条命令 · \(run.changedFiles.count) 个文件"
        case .failed(let code): return "失败（退出码 \(code)）· " + (run.events.last { $0.kind == .error }?.text ?? "看运行目录里的 stderr.log")
        case .interrupted: return "中断：启动进程已退出，没有结果"
        }
    }
}

struct DelegateStateIcon: View {
    let state: DelegateRun.State

    var body: some View {
        switch state {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(ReadableStatusColor.green).font(.system(size: 12))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(ReadableStatusColor.red).font(.system(size: 12))
        case .interrupted: Image(systemName: "pause.circle.fill").foregroundStyle(ReadableStatusColor.amber).font(.system(size: 12))
        }
    }
}

struct DelegateElapsed: View {
    let run: DelegateRun

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let end = run.endedAt ?? (run.isRunning ? context.date : run.startedAt)
            Text(Self.format(end.timeIntervalSince(run.startedAt)))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct DelegateRunActions: View {
    let run: DelegateRun

    var body: some View {
        Button("在 Finder 中显示运行记录") { NSWorkspace.shared.activateFileViewerSelecting([run.directory]) }
        if !run.workdir.isEmpty {
            Button("在 Finder 中显示工作目录") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.workdir)]) }
        }
        Button("打开任务说明") { NSWorkspace.shared.open(run.directory.appendingPathComponent("brief.md")) }
        if let report = run.report, !report.isEmpty {
            Button("复制最终汇报") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }
}

struct DelegateExpandedView: View {
    @ObservedObject var monitor: DelegateMonitor
    @State private var opened: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(monitor.runs) { run in
                        DelegateRunRow(run: run, selected: run.id == monitor.selected?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { monitor.selectedID = run.id }
                            .contextMenu { DelegateRunActions(run: run) }
                    }
                }
            }
            .frame(height: min(CGFloat(monitor.runs.count), 3) * DelegatePanelLayout.row)
            Divider().opacity(0.5)
            if let run = monitor.selected { detail(run) }
        }
    }

    private func detail(_ run: DelegateRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(facts(run)).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(abbreviate(run.workdir)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(timeline(run)) { event in eventRow(event) }
                        if let report = run.report, !report.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("最终汇报").font(.system(size: 11, weight: .semibold))
                                Text(report).font(.system(size: 11)).textSelection(.enabled)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo("bottom") }
                .onChange(of: run.id) { proxy.scrollTo("bottom") }
                .onChange(of: run.events.count) { if run.isRunning { withAnimation { proxy.scrollTo("bottom") } } }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: DelegateEvent) -> some View {
        let hasDetail = event.detail.map { !$0.isEmpty } ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(event.kind)).font(.system(size: 10)).frame(width: 12)
                    .foregroundStyle(color(event))
                Text(event.text)
                    .font(.system(size: 11, design: event.kind == .command ? .monospaced : .default))
                    .italic(event.kind == .reasoning)
                    .foregroundStyle(event.kind == .reasoning ? .secondary : .primary)
                    .lineLimit(opened.contains(event.id) || event.kind == .message ? nil : 3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if event.status == .running { ProgressView().controlSize(.mini) }
                if hasDetail {
                    Image(systemName: opened.contains(event.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if hasDetail, opened.contains(event.id), let detail = event.detail {
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
                    .padding(.leading, 18)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasDetail else { return }
            if opened.contains(event.id) { opened.remove(event.id) } else { opened.insert(event.id) }
        }
    }

    /// The last agent message is the final report; show it once, in the report box.
    private func timeline(_ run: DelegateRun) -> [DelegateEvent] {
        guard let report = run.report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty,
              let last = run.events.last(where: { $0.kind == .message }),
              last.text.trimmingCharacters(in: .whitespacesAndNewlines) == report else { return run.events }
        return run.events.filter { $0.id != last.id }
    }

    private func facts(_ run: DelegateRun) -> String {
        var parts = [run.kind == .review ? "审核" : "执行"]
        if !run.model.isEmpty { parts.append(run.model) }
        parts.append("\(run.commandCount) 条命令")
        parts.append("\(run.changedFiles.count) 个文件")
        if let tokens = run.tokens { parts.append(tokens >= 1000 ? "\(tokens / 1000)k tokens" : "\(tokens) tokens") }
        return parts.joined(separator: " · ")
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func icon(_ kind: DelegateEvent.Kind) -> String {
        switch kind {
        case .message: return "text.bubble"
        case .reasoning: return "brain"
        case .command: return "chevron.left.forwardslash.chevron.right"
        case .fileChange: return "doc.badge.ellipsis"
        case .tool: return "wrench.and.screwdriver"
        case .search: return "magnifyingglass"
        case .todo: return "checklist"
        case .error: return "exclamationmark.triangle"
        case .turn: return "flag"
        }
    }

    private func color(_ event: DelegateEvent) -> Color {
        if event.status == .failed { return ReadableStatusColor.red }
        switch event.kind {
        case .fileChange: return ReadableStatusColor.amber
        case .command: return event.status == .ok ? ReadableStatusColor.green : .secondary
        default: return .secondary
        }
    }
}
