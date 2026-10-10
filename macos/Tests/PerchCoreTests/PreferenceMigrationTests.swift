import XCTest
@testable import PerchCore

final class PreferenceMigrationTests: XCTestCase {
    private var names: [String] = []
    private func suite() -> UserDefaults {
        let name = "perch.test.\(UUID().uuidString)"
        names.append(name)
        return UserDefaults(suiteName: name)!
    }
    override func tearDown() {
        for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    func testPoxPreferencesMigrateOnceWithoutOverwriting() {
        let legacy = suite(), target = suite()
        legacy.set(120.0, forKey: "petX")
        legacy.set(true, forKey: "quiet")
        legacy.set(200.0, forKey: "petSize")
        legacy.set("unrelated", forKey: "scope")
        target.set(150.0, forKey: "petSize")

        XCTAssertEqual(Set(PreferenceMigration.run(from: legacy, to: target)), ["petX", "quiet"])
        XCTAssertEqual(target.double(forKey: "petX"), 120)
        XCTAssertTrue(target.bool(forKey: "quiet"))
        XCTAssertEqual(target.double(forKey: "petSize"), 150, "已有的新偏好不能被旧值覆盖")
        XCTAssertNil(target.object(forKey: "scope"), "只迁移列出的键")

        legacy.set(999.0, forKey: "petY")
        XCTAssertEqual(PreferenceMigration.run(from: legacy, to: target), [], "迁移只做一次")
        XCTAssertNil(target.object(forKey: "petY"))
    }

    func testMissingLegacyDomainStillMarksDone() {
        let target = suite()
        XCTAssertEqual(PreferenceMigration.run(from: nil, to: target), [])
        XCTAssertTrue(target.bool(forKey: "migratedFromPox"))
    }
}
