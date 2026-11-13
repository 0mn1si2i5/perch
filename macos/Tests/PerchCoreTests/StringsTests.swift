import Foundation
import XCTest
@testable import PerchCore

final class StringsTests: XCTestCase {
    func testDevelopmentReadsCanonicalJSONAndPoseLabels() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/strings/zh-CN.json")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source))
        XCTAssertEqual(Strings.all, expected)
        for pose in PetPose.allCases {
            XCTAssertEqual(pose.label, expected["pet.pose.\(pose.rawValue)"])
        }
        XCTAssertEqual(Strings.format("pet.preview.detail", "测试 ♡ {name}"),
                       Strings.get("pet.preview.detail").replacingOccurrences(of: "{0}", with: "测试 ♡ {name}"))
    }

    func testPackagedAppReadsItsOwnJSONAndRequiresResource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-strings-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.omnis.perch.strings-test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let url = resources.appendingPathComponent("zh-CN.json")
        // A different value proves a packaged app uses its own resource, not the checkout.
        let expected = ["pet.whale.pose.0": "打包资源验证 ♡"]
        try JSONEncoder().encode(expected).write(to: url)
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(try Strings.load(bundle: bundle), expected)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try Strings.load(bundle: bundle))
    }
}
