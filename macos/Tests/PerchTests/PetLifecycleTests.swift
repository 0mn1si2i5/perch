import XCTest
import PerchCore
@testable import Perch

final class PetLifecycleTests: XCTestCase {
    func testWhaleDialogueStaysWithWhaleAndKeepsTaskDetails() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "mediaEnabled")
        let pet = PetModel(defaults: defaults)
        pet.setEnabled(true)
        pet.select(.deepseekWhale)
        pet.preview(.idle)
        XCTAssertEqual(pet.statusLabel, "摸会儿鱼，等口白饭～")
        XCTAssertEqual(pet.bubble, "动作预览 · 摸会儿鱼，等口白饭～")
        let task = CodexTask(id: "fixture", title: "Fixture title", status: .running,
                             turnID: "turn", updatedAt: Date(), source: "fixture")
        // Switching clears the preview, then the live task label includes its count.
        pet.select(.pox)
        XCTAssertNil(pet.bubble)
        pet.update(tasks: [task], completed: nil)
        XCTAssertEqual(pet.statusLabel, "Codex · 1 个任务")
        pet.select(.deepseekWhale)
        XCTAssertEqual(pet.statusLabel, "1 个任务，努力游！")
        pet.update(tasks: [], completed: task)
        XCTAssertEqual(pet.bubble, "做完啦！开饭～ ♡\nFixture title")
        pet.select(.pox)
        pet.update(tasks: [], completed: task)
        XCTAssertEqual(pet.bubble, "搞定一个。\nFixture title")
        pet.preview(.lifted)
        XCTAssertEqual(pet.bubble, "动作预览 · 好家伙，被提起来了")
        pet.select(.native)
        pet.update(tasks: [], completed: task)
        XCTAssertNil(pet.bubble)
        pet.setEnabled(false)
    }

    func testWhaleSelectionPersistsWithoutPoxTheme() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "mediaEnabled")
        let pet = PetModel(defaults: defaults)
        pet.setEnabled(true)
        pet.select(.deepseekWhale)
        pet.preview(.listening)
        XCTAssertTrue(pet.previewing)
        XCTAssertEqual(pet.pose, .listening)
        XCTAssertFalse(pet.usesCharacterTheme)
        pet.setVisible(false)
        let restored = PetModel(defaults: defaults)
        XCTAssertEqual(restored.character, .deepseekWhale)
        XCTAssertTrue(restored.enabled)
        XCTAssertFalse(restored.visible)
        XCTAssertFalse(restored.usesCharacterTheme)
        XCTAssertFalse(pet.previewing)
        XCTAssertNil(pet.bubble)
        pet.preview(.salute)
        XCTAssertFalse(pet.previewing)
        pet.setVisible(true)
        pet.preview(.salute)
        pet.setEnabled(false)
        pet.refreshPose()
        XCTAssertEqual(pet.pose, .idle)
        XCTAssertFalse(pet.previewing)
    }

    func testSwitchingSpriteCharactersClearsFeedbackAndRestoresTaskPose() throws {
        let suite = "perch-pet-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "mediaEnabled")
        let pet = PetModel(defaults: defaults)
        pet.setEnabled(true)
        pet.select(.pox)
        pet.update(tasks: [CodexTask(id: "running", title: "Fixture", status: .running,
                                    turnID: "turn", updatedAt: Date(), source: "fixture")], completed: nil)
        pet.preview(.celebrating)
        pet.select(.deepseekWhale)
        XCTAssertEqual(pet.pose, .thinking)
        XCTAssertFalse(pet.previewing)
        XCTAssertNil(pet.bubble)
        XCTAssertFalse(pet.usesCharacterTheme)
        pet.preview(.confused)
        pet.select(.pox)
        XCTAssertEqual(pet.pose, .thinking)
        XCTAssertFalse(pet.previewing)
        XCTAssertTrue(pet.usesCharacterTheme)
        pet.setEnabled(false)
    }

    func testWhaleAtlasHasEightEquallySizedFrames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let atlas = try XCTUnwrap(SpriteAtlas(url: root.appendingPathComponent("shared/assets/deepseek-whale-atlas.png"), rowSplit: 0.5))
        XCTAssertEqual(atlas.cgSprites.count, PetPose.allCases.count)
        // Odd source dimensions can distribute one extra pixel to a row/column.
        XCTAssertTrue(atlas.cgSprites.allSatisfy { abs($0.width - atlas.cgSprites[0].width) <= 1 && abs($0.height - atlas.cgSprites[0].height) <= 1 })
    }

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
