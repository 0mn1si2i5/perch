import XCTest
import PerchCore
@testable import Perch

final class PetLifecycleTests: XCTestCase {
    func testDisabledByDefaultEvenWithLegacyVisiblePreference() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "petVisible")
        let pet = PetModel(defaults: defaults)
        XCTAssertFalse(pet.visible)
        pet.preview(.salute)
        XCTAssertFalse(pet.previewing)
        XCTAssertNil(pet.bubble)
    }

    func testSettingPersistsAndDisablingClearsPetActivity() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "mediaEnabled")
        let pet = PetModel(defaults: defaults)
        var changes: [Bool] = []
        pet.configurationChanged = { [weak pet] in changes.append(pet?.enabled ?? false) }
        pet.setEnabled(true)
        XCTAssertTrue(PetModel(defaults: defaults).visible)
        pet.select(.pox)
        pet.preview(.salute)
        XCTAssertTrue(pet.previewing)
        XCTAssertNotNil(pet.bubble)
        pet.setEnabled(false)
        XCTAssertFalse(PetModel(defaults: defaults).visible)
        XCTAssertFalse(pet.previewing)
        XCTAssertNil(pet.bubble)
        pet.setEnabled(false)
        XCTAssertEqual(changes, [true, true, false])
    }

    func testHidingPoxKeepsCapabilitySelectionAndThemeAcrossRestart() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "mediaEnabled")
        let pet = PetModel(defaults: defaults)
        pet.setEnabled(true)
        pet.select(.pox)
        pet.setVisible(false)
        XCTAssertTrue(pet.enabled)
        XCTAssertFalse(pet.visible)
        XCTAssertTrue(pet.usesCharacterTheme)
        let restored = PetModel(defaults: defaults)
        XCTAssertTrue(restored.enabled)
        XCTAssertFalse(restored.visible)
        XCTAssertEqual(restored.character, .pox)
        XCTAssertTrue(restored.usesCharacterTheme)
        pet.setEnabled(false)
        XCTAssertFalse(pet.usesCharacterTheme)
        pet.setVisible(true)
        XCTAssertFalse(pet.visible)
    }

    func testNativeDefaultAndUnknownSelectionUseSystemThemeAndNeverAnimate() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-character", forKey: "petCharacter")
        let pet = PetModel(defaults: defaults)
        XCTAssertEqual(pet.character, .native)
        pet.setEnabled(true)
        XCTAssertTrue(pet.enabled)
        XCTAssertTrue(pet.visible)
        XCTAssertFalse(pet.usesCharacterTheme)
        pet.preview(.salute)
        pet.pollMedia()
        XCTAssertFalse(pet.previewing)
        XCTAssertNil(pet.bubble)
        XCTAssertEqual(pet.pose, .idle)
        pet.setVisible(false)
        XCTAssertTrue(pet.enabled)
        XCTAssertFalse(pet.usesCharacterTheme)
    }

}
