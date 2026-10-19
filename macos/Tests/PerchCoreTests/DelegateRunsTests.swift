import Foundation
import XCTest
@testable import PerchCore

final class DelegateRunsTests: XCTestCase {
    private func makeRun(_ root: URL, name: String, pid: Int32 = 4242, title: String = "改造面板") throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = """
        {"version":1,"id":"\(name)","kind":"worker","title":"\(title)","workdir":"/tmp/wt","brief":"/tmp/b.md",\
        "codexHome":"/tmp/h","model":"","effort":"","startedAt":"2026-10-19T08:00:00Z","pid":\(pid)}
        """
        try meta.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("events.jsonl").path, contents: nil)
        return dir
    }

    private func append(_ dir: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-19T08:05:00Z")!

    func testReadsEventsIncrementallyIncludingPartialLines() throws {
        let root = try makeTempDir()
        let dir = try makeRun(root, name: "20261019-080000-a-1")
        let reader = DelegateRunReader(root: root, isAlive: { _ in true })
        try append(dir, """
        {"type":"thread.started","thread_id":"t"}
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"Under-development features enabled: chronicle."}}
        {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}
        {"type":"item.completed","item":{"id":"item_1","type":"command_e
        """)
        var run = try XCTUnwrap(reader.read(now: now).first)
        XCTAssertEqual(run.state, .running)
        XCTAssertEqual(run.title, "改造面板")
        XCTAssertEqual(run.events.map(\.text), ["ls"])
        XCTAssertEqual(run.events.first?.status, .running)

        try append(dir, """
        xecution","command":"/bin/zsh -lc ls","aggregated_output":"a.txt\\n","exit_code":0,"status":"completed"}}
        {"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/wt/Sources/A.swift","kind":"update"},{"path":"/tmp/wt/B.md","kind":"add"}],"status":"completed"}}
        {"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc \\"swift test\\"","aggregated_output":"","exit_code":null,"status":"in_progress"}}

        """)
        run = try XCTUnwrap(reader.read(now: now).first)
        XCTAssertEqual(run.events.map(\.text), ["ls", "~ A.swift  + B.md", "swift test"])
        XCTAssertEqual(run.events[0].status, .ok)
        XCTAssertEqual(run.events[0].detail, "a.txt\n")
        XCTAssertEqual(run.commandCount, 2)
        XCTAssertEqual(run.changedFiles, ["/tmp/wt/Sources/A.swift", "/tmp/wt/B.md"])
        XCTAssertEqual(run.latest?.text, "swift test")
    }

    func testFinishesWithResultAndReport() throws {
        let root = try makeTempDir()
        let dir = try makeRun(root, name: "20261019-080000-a-1")
        try append(dir, """
        {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"false","aggregated_output":"","exit_code":null,"status":"in_progress"}}
        {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"完成了"}}
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":20}}

        """)
        try "汇报正文".write(to: dir.appendingPathComponent("last.md"), atomically: true, encoding: .utf8)
        try #"{"exitCode":0,"endedAt":"2026-10-19T08:03:00Z"}"#.write(to: dir.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        let run = try XCTUnwrap(DelegateRunReader(root: root, isAlive: { _ in false }).read(now: now).first)
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertEqual(run.report, "汇报正文")
        XCTAssertEqual(run.tokens, 120)
        XCTAssertEqual(run.events.first?.status, .ok)   // unfinished items close with the run
        XCTAssertEqual(run.endedAt, ISO8601DateFormatter().date(from: "2026-10-19T08:03:00Z"))
    }

    func testDeadLauncherWithoutResultIsInterruptedAndFailuresKeepExitCode() throws {
        let root = try makeTempDir()
        _ = try makeRun(root, name: "20261019-080000-a-1", pid: 1)
        let failed = try makeRun(root, name: "20261019-080100-b-2", pid: 2)
        try #"{"exitCode":1,"endedAt":"2026-10-19T08:04:00Z"}"#.write(to: failed.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        let runs = DelegateRunReader(root: root, isAlive: { _ in false }).read(now: now)
        XCTAssertEqual(runs.map(\.id), ["20261019-080100-b-2", "20261019-080000-a-1"])
        XCTAssertEqual(runs.map(\.state), [.failed(1), .interrupted])
    }

    func testOldFinishedRunsAreHiddenAndMissingMetaIsSkipped() throws {
        let root = try makeTempDir()
        let old = try makeRun(root, name: "20261017-080000-old-1")
        try #"{"exitCode":0,"endedAt":"2026-10-17T08:04:00Z"}"#.write(to: old.appendingPathComponent("result.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20261019-090000-nometa"), withIntermediateDirectories: true)
        _ = try makeRun(root, name: "20261019-080000-live-2")
        let runs = DelegateRunReader(root: root, isAlive: { _ in true }).read(now: now)
        XCTAssertEqual(runs.map(\.id), ["20261019-080000-live-2"])
        XCTAssertTrue(DelegateRunReader(root: root.appendingPathComponent("missing")).read().isEmpty)
    }

    func testShortCommandUnwrapsShellQuoting() {
        XCTAssertEqual(DelegateRunReader.shortCommand(#"/bin/zsh -lc "printf '%s\\n' \"bye\"""#), #"printf '%s\n' "bye""#)
        XCTAssertEqual(DelegateRunReader.shortCommand("/bin/zsh -lc ls"), "ls")
        XCTAssertEqual(DelegateRunReader.shortCommand("git status"), "git status")
    }
}
