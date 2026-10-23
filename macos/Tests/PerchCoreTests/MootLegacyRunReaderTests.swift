import XCTest
@testable import PerchCore
final class MootLegacyRunReaderTests: XCTestCase {
    func testLegacyUnknownFieldsAreNotInvented() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("old"), withIntermediateDirectories: true)
        try Data(#"{"version":1,"id":"old","title":"Legacy task","state":"done","startedAt":"2026-01-01"}"#.utf8).write(to: root.appendingPathComponent("old/meeting.json"))
        let records = try MootLegacyRunReader.read(root: root)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].record["rounds"].items.isEmpty)
        XCTAssertFalse(records[0].active)
        XCTAssertEqual(records[0].state, "legacy")
    }
}
