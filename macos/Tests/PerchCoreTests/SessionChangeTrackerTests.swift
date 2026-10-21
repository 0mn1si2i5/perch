import XCTest
@testable import PerchCore

final class SessionChangeTrackerTests: XCTestCase {
    func testConversationsAlreadyFinishedAtStartAreNotReported() {
        var tracker = SessionChangeTracker()
        XCTAssertEqual(tracker.update([("a", .completed), ("b", .waiting), ("c", .failed)]), [])
        XCTAssertEqual(tracker.update([("a", .completed), ("b", .waiting), ("c", .failed)]), [])
    }

    func testRunningToCompletedWaitingOrFailedIsReportedOnce() {
        var tracker = SessionChangeTracker()
        _ = tracker.update([("a", .running), ("b", .running), ("c", .running)])
        XCTAssertEqual(tracker.update([("a", .completed), ("b", .waiting), ("c", .failed)]),
                       [SessionChange(id: "a", status: .completed), SessionChange(id: "b", status: .waiting),
                        SessionChange(id: "c", status: .failed)])
        XCTAssertEqual(tracker.update([("a", .completed), ("b", .waiting), ("c", .failed)]), [])
        // The owner answers; the conversation runs again and then finishes.
        XCTAssertEqual(tracker.update([("b", .running)]), [])
        XCTAssertEqual(tracker.update([("b", .completed)]), [SessionChange(id: "b", status: .completed)])
    }

    func testWaitingThatFinishesBetweenPollsIsReported() {
        var tracker = SessionChangeTracker()
        _ = tracker.update([("a", .running)])
        _ = tracker.update([("a", .waiting)])
        XCTAssertEqual(tracker.update([("a", .completed)]), [SessionChange(id: "a", status: .completed)])
    }

    func testInterruptedIsNotReported() {
        var tracker = SessionChangeTracker()
        _ = tracker.update([("a", .running)])
        XCTAssertEqual(tracker.update([("a", .interrupted)]), [])
        XCTAssertEqual(tracker.update([("a", .completed)]), [])
    }

    func testNewConversationOnlyReportedWhenItIsWaiting() {
        var tracker = SessionChangeTracker()
        _ = tracker.update([])
        XCTAssertEqual(tracker.update([("old", .completed), ("new", .waiting), ("busy", .running)]),
                       [SessionChange(id: "new", status: .waiting)])
    }

    func testRunningConversationMissingFromOneReadIsStillNoticed() {
        var tracker = SessionChangeTracker()
        _ = tracker.update([("a", .running), ("b", .completed)])
        XCTAssertEqual(tracker.update([]), [])
        XCTAssertEqual(tracker.update([("a", .completed), ("b", .completed)]), [SessionChange(id: "a", status: .completed)])
    }
}
