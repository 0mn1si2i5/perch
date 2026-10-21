import XCTest
import PerchCore
@testable import Perch

final class PollingTests: XCTestCase {
    func testPollingSlowsDownWhileThePanelIsHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-polling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(root: root, agentDeskProfiles: root.appendingPathComponent("absent-agent-desk.json"), home: root.path)
        let model = PerchModel(store: store, launcher: Launcher(activate: { _ in false }, processes: { [] }),
                               notificationSender: { _, completion in completion(true) })
        XCTAssertNil(model.pollingInterval)
        model.start()
        XCTAssertEqual(model.pollingInterval, 20)
        model.panelOpened()
        XCTAssertEqual(model.pollingInterval, 5)
        model.panelClosed()
        XCTAssertEqual(model.pollingInterval, 20)
    }
}
