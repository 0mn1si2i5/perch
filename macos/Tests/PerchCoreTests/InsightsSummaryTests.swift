import Foundation
import XCTest
@testable import PerchCore

final class InsightsSummaryTests: XCTestCase {
    private func makeFixtureDir() throws -> URL {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testParsesValidSchemaWithMicrosecondsAndDateOnlyWindow() throws {
        let json = """
        {
          "version": 1,
          "generatedAt": "2026-11-24T23:48:54.171960+08:00",
          "window": { "days": 30, "start": "2026-10-16", "end": "2026-11-24" },
          "reportPath": "/Users/demo/.agents/omni-insights/latest.html",
          "totals": { "sessions": 198, "subagents": 502, "activeDays": 35, "cacheHitRate": 0.983, "errorRate": 0.023 },
          "agents": [
            { "id": "codex", "name": "Codex", "role": "active", "sessions": 45, "subagents": 1, "cacheHitRate": 0.98, "errorRate": 0.056 },
            { "id": "claude", "name": "Claude", "role": "historical", "sessions": 146 }
          ],
          "delta": { "comparedTo": "2026-11-24T23:48:51.692243+08:00", "sessions": 5, "cacheHitRate": 0.012, "errorRate": -0.003 }
        }
        """
        let summary = try XCTUnwrap(InsightsSummary.decode(Data(json.utf8)))
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.window.days, 30)
        XCTAssertEqual(summary.window.start, "2026-10-16")
        XCTAssertEqual(summary.window.end, "2026-11-24")
        XCTAssertNotNil(summary.window.startDate)
        XCTAssertNotNil(summary.window.endDate)
        XCTAssertEqual(summary.reportPath, "/Users/demo/.agents/omni-insights/latest.html")
        XCTAssertEqual(summary.totals.sessions, 198)
        XCTAssertEqual(summary.totals.subagents, 502)
        XCTAssertEqual(summary.totals.activeDays, 35)
        XCTAssertEqual(summary.totals.cacheHitRate ?? 0, 0.983, accuracy: 0.0001)
        XCTAssertEqual(summary.totals.errorRate ?? 0, 0.023, accuracy: 0.0001)
        XCTAssertEqual(summary.agents.count, 2)
        XCTAssertEqual(summary.agents[0].id, "codex")
        XCTAssertEqual(summary.agents[0].role, "active")
        XCTAssertEqual(summary.agents[1].subagents, nil)
        XCTAssertEqual(summary.delta?.sessions, 5)
        XCTAssertNotNil(summary.delta?.comparedToDate)
    }

    func testParsesMinimalForwardCompatibleSchemaAndUTCTimestamp() throws {
        let json = """
        {
          "version": 1,
          "generatedAt": "2026-11-24T15:48:54Z",
          "window": { "days": 7, "start": "2026-11-17T00:00:00Z", "end": "2026-11-24T00:00:00Z" },
          "totals": { "sessions": 12 }
        }
        """
        let summary = try XCTUnwrap(InsightsSummary.decode(Data(json.utf8)))
        XCTAssertEqual(summary.window.days, 7)
        XCTAssertNotNil(summary.window.startDate)
        XCTAssertNotNil(summary.window.endDate)
        XCTAssertNil(summary.reportPath)
        XCTAssertEqual(summary.totals.sessions, 12)
        XCTAssertNil(summary.totals.subagents)
        XCTAssertNil(summary.totals.activeDays)
        XCTAssertNil(summary.totals.cacheHitRate)
        XCTAssertNil(summary.totals.errorRate)
        XCTAssertTrue(summary.agents.isEmpty)
        XCTAssertNil(summary.delta)
    }

    func testParsesSharedFixture() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PerchCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // perch
        let fixture = repoRoot.appendingPathComponent("shared/fixtures/insights/summary.json")
        let reader = InsightsSummaryReader(fileURL: fixture)
        let summary = try XCTUnwrap(reader.read())
        XCTAssertEqual(summary.version, 1)
        XCTAssertEqual(summary.totals.sessions, 198)
        XCTAssertEqual(summary.agents.map(\.id), ["codex", "antigravity", "claude"])
        XCTAssertEqual(summary.delta?.sessions, 12)
    }

    func testDegradesSilentlyWhenMissingMalformedOrUnsupportedVersion() throws {
        let dir = try makeFixtureDir()
        let reader = InsightsSummaryReader(root: dir)

        // Missing file
        XCTAssertNil(reader.read())
        XCTAssertEqual(reader.readCount, 0)

        let insightsDir = dir.appendingPathComponent("insights")
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        let file = insightsDir.appendingPathComponent("summary.json")

        // Unsupported version
        try Data("""
        {"version": 2, "generatedAt": "2026-11-24T15:48:54Z", "window": {"days": 30}, "totals": {"sessions": 10}}
        """.utf8).write(to: file)
        XCTAssertNil(reader.read())

        // Malformed JSON
        try Data("{not valid json".utf8).write(to: file)
        XCTAssertNil(reader.read())

        // Valid write then delete clears cached summary
        try Data("""
        {"version": 1, "generatedAt": "2026-11-24T15:48:54Z", "window": {"days": 30}, "totals": {"sessions": 10}}
        """.utf8).write(to: file)
        XCTAssertEqual(reader.read()?.totals.sessions, 10)
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(reader.read())
    }

    func testRejectsOversizedSummaryOver256KB() throws {
        let dir = try makeFixtureDir()
        let insightsDir = dir.appendingPathComponent("insights")
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        let file = insightsDir.appendingPathComponent("summary.json")

        let padding = String(repeating: "a", count: Int(InsightsSummaryReader.maxBytes) + 128)
        let oversized = """
        {"version": 1, "generatedAt": "2026-11-24T15:48:54Z", "window": {"days": 30}, "reportPath": "\(padding)", "totals": {"sessions": 1}}
        """
        try Data(oversized.utf8).write(to: file)

        let reader = InsightsSummaryReader(root: dir)
        XCTAssertNil(reader.read())
        XCTAssertEqual(reader.readCount, 0)
    }

    func testPathValidationBlocksNonHtmlAndEscapingSymlinks() throws {
        let sandbox = try makeFixtureDir()
        let home = sandbox.appendingPathComponent("home")
        let siblingHome = sandbox.appendingPathComponent("home2")
        let outside = sandbox.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)

        let validHtml = home.appendingPathComponent(".agents/latest.html")
        let validHtm = home.appendingPathComponent(".agents/alt.HTM")
        let nonHtml = home.appendingPathComponent(".agents/run.sh")
        let dirHtml = home.appendingPathComponent(".agents/folder.html")
        let siblingHtml = siblingHome.appendingPathComponent("report.html")
        let outsideHtml = outside.appendingPathComponent("secret.html")

        try Data("<html/>".utf8).write(to: validHtml)
        try Data("<html/>".utf8).write(to: validHtm)
        try Data("#!/bin/sh".utf8).write(to: nonHtml)
        try fm.createDirectory(at: dirHtml, withIntermediateDirectories: true)
        try Data("<html/>".utf8).write(to: siblingHtml)
        try Data("<html/>".utf8).write(to: outsideHtml)

        // Valid absolute path, tilde path, .HTM uppercase, and in-home symlink
        XCTAssertNotNil(InsightsSummary.validateReportPath(validHtml.path, home: home.path))
        XCTAssertNotNil(InsightsSummary.validateReportPath("~/.agents/latest.html", home: home.path))
        XCTAssertNotNil(InsightsSummary.validateReportPath(validHtm.path, home: home.path))

        let safeLink = home.appendingPathComponent(".agents/current.html")
        try fm.createSymbolicLink(at: safeLink, withDestinationURL: validHtml)
        XCTAssertEqual(
            InsightsSummary.validateReportPath(safeLink.path, home: home.path)?.lastPathComponent,
            "latest.html"
        )

        // Rejections: non-html, directory with .html suffix, relative path, ~otheruser
        XCTAssertNil(InsightsSummary.validateReportPath(nonHtml.path, home: home.path))
        XCTAssertNil(InsightsSummary.validateReportPath(dirHtml.path, home: home.path))
        XCTAssertNil(InsightsSummary.validateReportPath("latest.html", home: home.path))
        XCTAssertNil(InsightsSummary.validateReportPath("~other/.agents/latest.html", home: home.path))

        // Rejections: outside home & sibling prefix
        XCTAssertNil(InsightsSummary.validateReportPath(outsideHtml.path, home: home.path))
        XCTAssertNil(InsightsSummary.validateReportPath(siblingHtml.path, home: home.path))

        // Rejections: symlink inside home escaping outside home
        let escapeLink = home.appendingPathComponent(".agents/escape.html")
        try fm.createSymbolicLink(at: escapeLink, withDestinationURL: outsideHtml)
        XCTAssertNil(InsightsSummary.validateReportPath(escapeLink.path, home: home.path))

        // Rejections: symlink named .html pointing to non-html script inside home
        let disguisedLink = home.appendingPathComponent(".agents/disguised.html")
        try fm.createSymbolicLink(at: disguisedLink, withDestinationURL: nonHtml)
        XCTAssertNil(InsightsSummary.validateReportPath(disguisedLink.path, home: home.path))

        // Rejections: directory symlink escaping outside home
        let escapeDir = home.appendingPathComponent("linked-outside")
        try fm.createSymbolicLink(at: escapeDir, withDestinationURL: outside)
        XCTAssertNil(InsightsSummary.validateReportPath(escapeDir.appendingPathComponent("secret.html").path, home: home.path))
    }

    func testCachesByMtimeAndFileSize() throws {
        let dir = try makeFixtureDir()
        let insightsDir = dir.appendingPathComponent("insights")
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        let file = insightsDir.appendingPathComponent("summary.json")

        let first = """
        {"version": 1, "generatedAt": "2026-11-24T15:48:54Z", "window": {"days": 30}, "totals": {"sessions": 10}}
        """
        try Data(first.utf8).write(to: file)

        let reader = InsightsSummaryReader(root: dir)
        XCTAssertEqual(reader.read()?.totals.sessions, 10)
        XCTAssertEqual(reader.readCount, 1)

        // Second read hits cache without touching disk contents
        XCTAssertEqual(reader.read()?.totals.sessions, 10)
        XCTAssertEqual(reader.readCount, 1)

        // Updating content changes size and/or mtime, invalidating cache
        let second = """
        {"version": 1, "generatedAt": "2026-11-24T16:48:54Z", "window": {"days": 30}, "totals": {"sessions": 123}}
        """
        try Data(second.utf8).write(to: file)
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)

        XCTAssertEqual(reader.read()?.totals.sessions, 123)
        XCTAssertEqual(reader.readCount, 2)
    }
}
