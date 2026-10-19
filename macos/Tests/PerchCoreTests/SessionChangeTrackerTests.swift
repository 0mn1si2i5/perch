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

final class DraftWatchTests: XCTestCase {
    func testDraftStillBeingWrittenIsNotReported() {
        var watch = DraftWatch()
        XCTAssertFalse(watch.observe(size: nil, sourceBusy: true))
        XCTAssertFalse(watch.observe(size: 0, sourceBusy: true))
        XCTAssertFalse(watch.observe(size: 0, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: 120, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: 480, sourceBusy: false))
    }

    func testFinishedDraftIsReportedOnceAfterTheSourceStops() {
        var watch = DraftWatch()
        XCTAssertFalse(watch.observe(size: 900, sourceBusy: true))
        // Same size, but the source is still replying with the path: wait.
        XCTAssertFalse(watch.observe(size: 900, sourceBusy: true))
        XCTAssertTrue(watch.observe(size: 900, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: 900, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: 1200, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: 1200, sourceBusy: false))
    }

    func testDraftRemovedAndRewrittenNeedsTwoStablePolls() {
        var watch = DraftWatch()
        XCTAssertFalse(watch.observe(size: 300, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: nil, sourceBusy: false))
        XCTAssertFalse(watch.observe(size: 300, sourceBusy: false))
        XCTAssertTrue(watch.observe(size: 300, sourceBusy: false))
    }
}

final class HandoffTargetOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func display(_ windows: [(Int, Double, TimeInterval?)]) -> QuotaDisplay {
        QuotaDisplay(value: .windows(windows.map {
            QuotaWindow(minutes: $0.0, usedPercent: $0.1, resetsAt: $0.2.map { now.addingTimeInterval($0) })
        }), observedAt: now, cached: false, liveFailure: nil)
    }

    func testTightestWindowDecidesAndResetWindowsCountAsFull() {
        XCTAssertEqual(display([(300, 20, 3600), (10080, 70, 86400)]).remainingPercent(now: now), 30)
        XCTAssertEqual(display([(300, 95, -60), (10080, 40, 86400)]).remainingPercent(now: now), 60)
        XCTAssertEqual(QuotaDisplay(value: .unlimited("企业版"), observedAt: now, cached: false, liveFailure: nil)
                        .remainingPercent(now: now), .infinity)
        XCTAssertNil(QuotaDisplay.empty.remainingPercent(now: now))
        XCTAssertNil(QuotaDisplay(value: .signedOut, observedAt: now, cached: false, liveFailure: nil).remainingPercent(now: now))
        XCTAssertNil(display([]).remainingPercent(now: now))
    }

    func testProviderUsageUsesPercentMetricsOnly() {
        let usage = ProviderUsage(metrics: [
            .init(label: "Gemini Models · 5 小时", remainingPercent: 45, resetsAt: now.addingTimeInterval(600)),
            .init(label: "Argon · 每周", remainingPercent: 10, resetsAt: now.addingTimeInterval(-600)),
        ], summary: "", observedAt: now, authenticationVerified: true)
        XCTAssertEqual(usage.remainingPercent(now: now), 45)
        let balance = ProviderUsage(metrics: [.init(label: "余额", value: "¥12.00")], summary: "", authenticationVerified: true)
        XCTAssertNil(balance.remainingPercent(now: now))
    }

    func testMostQuotaFirstAndAccountsWithoutDataKeepTheirOrderAtTheEnd() {
        let left: [String: Double] = ["low": 12, "high": 80, "free": .infinity, "mid": 50]
        let ordered = HandoffTargetOrder.ordered(["none-1", "low", "high", "none-2", "free", "mid"]) { left[$0] }
        XCTAssertEqual(ordered, ["free", "high", "mid", "low", "none-1", "none-2"])
        XCTAssertEqual(HandoffTargetOrder.label(remaining: 61.6), "剩 62%")
        XCTAssertEqual(HandoffTargetOrder.label(remaining: .infinity), "不限")
        XCTAssertNil(HandoffTargetOrder.label(remaining: nil))
    }
}
