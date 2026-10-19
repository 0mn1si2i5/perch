import XCTest
@testable import PerchCore

final class SubprocessTests: XCTestCase {
    func testCapturesOutputStatusAndLimits() throws {
        let echo = try Subprocess.run("/bin/echo", ["fixture"], timeout: 5).get()
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(String(decoding: echo.stdout, as: UTF8.self), "fixture\n")
        XCTAssertEqual(Subprocess.run("/usr/bin/yes", timeout: 5, outputLimit: 1000), .failure(.tooLarge))
        XCTAssertEqual(Subprocess.run("/nonexistent/fixture", timeout: 5), .failure(.launchFailed))
    }

    func testAsyncRunReportsStatusAndErrors() async throws {
        let failed = try await Subprocess.run("/bin/sh", ["-c", "echo problem >&2; exit 3"], timeout: 5, captureErrors: true).get()
        XCTAssertEqual(failed.status, 3)
        XCTAssertEqual(String(decoding: failed.stderr, as: UTF8.self), "problem\n")
    }

    /// A child that ignores TERM and leaves a grandchild behind: a timeout must still stop both.
    func testTimeoutStopsTheWholeProcessGroup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fixture.sh")
        try """
            trap '' TERM
            (trap '' TERM; exec sleep 30) &
            echo $! > "$1/grandchild.pid"
            exec sleep 30
            """.write(to: script, atomically: true, encoding: .utf8)
        let started = Date()
        XCTAssertEqual(Subprocess.run("/bin/sh", [script.path, dir.path], timeout: 1), .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let text = try String(contentsOf: dir.appendingPathComponent("grandchild.pid"), encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(kill(pid, 0), -1, "the grandchild should be gone")
        XCTAssertEqual(errno, ESRCH)
    }
}
