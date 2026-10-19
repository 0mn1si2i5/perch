import XCTest
import PerchCore
@testable import Perch

final class ProviderUsagePresentationTests: XCTestCase {
    func testProviderRemainingQuotaConvertsToExistingUsedWindowsInDurationOrder() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyReset = now.addingTimeInterval(7 * 86400)
        let shortReset = now.addingTimeInterval(3600)
        let windows = ProviderUsagePresentation.windows(usage([
            .init(label: "Gemini Models · 每周", remainingPercent: 96.8, resetsAt: weeklyReset),
            .init(label: "Gemini Models · 5 小时", remainingPercent: 96.6, resetsAt: shortReset)
        ]))
        XCTAssertEqual(windows.map(\.minutes), [300, 10080])
        XCTAssertEqual(windows.map(\.label), ["5h", "周"])
        XCTAssertEqual(windows[0].usedPercent, 3.4, accuracy: 0.000001)
        XCTAssertEqual(windows[1].usedPercent, 3.2, accuracy: 0.000001)
        XCTAssertEqual(windows.map(\.resetsAt), [shortReset, weeklyReset])
        XCTAssertFalse(windows[0].hasReset(now: now))
        XCTAssertTrue(windows[0].hasReset(now: shortReset))
    }

    func testSeparatePoolKeepsItsNameAfterMainWindowOfSameDuration() {
        let windows = ProviderUsagePresentation.windows(usage([
            .init(label: "Argon · 每周", remainingPercent: 98),
            .init(label: "Gemini Models · 每周", remainingPercent: 96),
            .init(label: "Gemini Models · 5 小时", remainingPercent: 100)
        ]))
        XCTAssertEqual(windows.map(\.label), ["5h", "周", "Argon 周"])
        XCTAssertEqual(windows.map(\.usedPercent), [0, 4, 2])
    }

    func testUnknownModelDurationIsNotInventedAndTimeWindowsDoNotDuplicateAsSummaryRows() {
        let sample = usage([
            .init(label: "Gemini Models · 每周", remainingPercent: 100),
            .init(label: "Gemini Models · 5 小时", remainingPercent: 0),
            .init(label: "gemini-model", remainingPercent: 70)
        ])
        XCTAssertEqual(ProviderUsagePresentation.windows(sample).map(\.usedPercent), [100, 0])
        XCTAssertEqual(ProviderUsagePresentation.rows(sample), [.init(label: "gemini-model", value: "30%", unit: nil)])
    }

    func testProviderFailureUsesExistingCacheFreshnessWithoutChangingObservedTime() {
        let sample = usage([.init(label: "Gemini Models · 每周", remainingPercent: 96.8)])
        let fresh = ProviderUsagePresentation.display(usage: sample, error: nil)
        XCTAssertFalse(fresh.cached)
        XCTAssertFalse(fresh.liveFailed)
        let stale = ProviderUsagePresentation.display(usage: sample, error: "Fixture connection failure")
        XCTAssertTrue(stale.cached)
        XCTAssertEqual(stale.liveFailure, "Fixture connection failure")
        XCTAssertEqual(stale.observedAt, sample.observedAt)
        XCTAssertEqual(stale.value, fresh.value)
        XCTAssertFalse(stale.isClaude)
        let failedWithoutData = ProviderUsagePresentation.display(usage: nil, error: "Fixture failure")
        XCTAssertNil(failedWithoutData.value)
        XCTAssertNil(failedWithoutData.observedAt)
        XCTAssertTrue(failedWithoutData.liveFailed)
    }

    func testPaidAndGrantedBalancesUseDecimalSumAndHideUnusedCurrencies() {
        let rows = ProviderUsagePresentation.rows(usage([
            .init(label: "充值余额", value: "USD 0"),
            .init(label: "充值余额", value: "CNY 42.99"),
            .init(label: "赠送余额", value: "CNY 0.2")
        ]))
        XCTAssertEqual(rows, [.init(label: "余额", value: "43.19", unit: "CNY")])
    }

    func testAPITotalDoesNotDoubleCountPaidAndGrantedBreakdown() {
        let rows = ProviderUsagePresentation.rows(usage([
            .init(label: "API 余额", value: "CNY 43.19"),
            .init(label: "充值余额", value: "CNY 42.99"),
            .init(label: "赠送余额", value: "CNY 0.2"),
            .init(label: "API 余额", value: "USD 1.25")
        ]))
        XCTAssertEqual(rows, [.init(label: "余额", value: "43.19", unit: "CNY"), .init(label: "余额", value: "1.25", unit: "USD")])
    }

    func testZeroBalancesRemainVisibleAndMalformedMoneyIsNotInvented() {
        XCTAssertEqual(ProviderUsagePresentation.rows(usage([
            .init(label: "充值余额", value: "CNY 0"), .init(label: "赠送余额", value: "USD 0")
        ])), [.init(label: "余额", value: "0.00", unit: "CNY"), .init(label: "余额", value: "0.00", unit: "USD")])
        XCTAssertEqual(ProviderUsagePresentation.rows(usage([
            .init(label: "API 余额", value: "CNY 12oops")
        ])), [.init(label: "API 余额", value: "CNY 12oops", unit: nil)])
    }

    func testBalanceDetailsPreserveExactComponentsAndNeverBecomePercentageWindows() {
        let sample = usage([
            .init(label: "充值余额", value: "CNY 42.991234"),
            .init(label: "赠送余额", value: "CNY 0.2")
        ])
        XCTAssertTrue(ProviderUsagePresentation.windows(sample).isEmpty)
        let details = ProviderUsagePresentation.details(sample)
        XCTAssertTrue(details.contains("充值余额：CNY 42.991234"))
        XCTAssertTrue(details.contains("赠送余额：CNY 0.2"))
        XCTAssertTrue(details.contains("Fixture details"))
        XCTAssertTrue(details.contains("记录时间："))
    }

    private func usage(_ metrics: [ProviderUsageMetric]) -> ProviderUsage {
        .init(metrics: metrics, summary: "Fixture details", observedAt: Date(timeIntervalSince1970: 100), authenticationVerified: true)
    }
}
