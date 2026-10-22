import XCTest
@testable import PerchCore

final class SharedStringsTests: XCTestCase {
    func testEveryKeyTheAppLooksUpExists() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"Strings\.get\("([^"\\]+)"\)"#)
        var keys: Set<String> = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        keys.formUnion(PetPose.allCases.map { "pet.pose.\($0.rawValue)" })
        XCTAssertGreaterThan(keys.count, 20)
        XCTAssertEqual(keys.filter { Strings.all[$0] == nil }.sorted(), [])
    }

    func testLabelsComeFromTheSharedFile() {
        XCTAssertEqual(PetPose.lifted.label, "好家伙，被提起来了")
        XCTAssertEqual(TaskStatus.running.label, "进行中")
        XCTAssertEqual(TaskStatus.waiting.label, "等你回应")
        XCTAssertEqual(TaskStatus.failed.label, Strings.all["status.failed"])
    }
}
