import XCTest
import Security
@testable import PerchCore

final class KeychainAccessTests: XCTestCase {
    func testBackgroundAccessDisablesInteractionAndRestoresPreviousValue() throws {
        for initial in [true, false] {
            var allowed = initial
            var changes: [Bool] = []
            let access = KeychainAccess(getInteractionAllowed: { (errSecSuccess, allowed) }, setInteractionAllowed: {
                allowed = $0; changes.append($0); return errSecSuccess
            })
            let value = try access.withInteraction(allowed: false) {
                XCTAssertFalse(allowed)
                return "synthetic-result"
            }
            XCTAssertEqual(value, "synthetic-result")
            XCTAssertEqual(allowed, initial)
            XCTAssertEqual(changes, [false, initial])
        }
    }

    func testManualAccessTemporarilyEnablesConsent() throws {
        var allowed = false
        let access = KeychainAccess(getInteractionAllowed: { (errSecSuccess, allowed) }, setInteractionAllowed: {
            allowed = $0; return errSecSuccess
        })
        try access.withInteraction(allowed: true) { XCTAssertTrue(allowed) }
        XCTAssertFalse(allowed)
    }

    func testThrownOperationRestoresFlagAndReleasesLock() {
        var allowed = true
        let access = KeychainAccess(getInteractionAllowed: { (errSecSuccess, allowed) }, setInteractionAllowed: {
            allowed = $0; return errSecSuccess
        })
        XCTAssertThrowsError(try access.withInteraction(allowed: false) {
            throw KeychainAccess.Failure(status: errSecAuthFailed)
        }) { error in
            XCTAssertEqual(error as? KeychainAccess.Failure, .init(status: errSecAuthFailed))
        }
        XCTAssertTrue(allowed)
        XCTAssertEqual(access.serialized { 42 }, 42)
    }

    func testFailureToReadInteractionFlagNeverAccessesCredentials() {
        let access = KeychainAccess(getInteractionAllowed: { (errSecNotAvailable, true) }, setInteractionAllowed: { _ in
            XCTFail("The prior state is unknown and must not be overwritten")
            return errSecSuccess
        })
        XCTAssertThrowsError(try access.withInteraction(allowed: false) {
            XCTFail("Cannot access credentials unless background interaction is disabled")
        }) { error in
            XCTAssertEqual(error as? KeychainAccess.Failure, .init(status: errSecNotAvailable))
        }
    }

    func testFailureToSuppressInteractionSkipsAccessAndAttemptsRestoration() {
        var changes: [Bool] = []
        let access = KeychainAccess(getInteractionAllowed: { (errSecSuccess, true) }, setInteractionAllowed: {
            changes.append($0)
            return $0 ? errSecSuccess : errSecNotAvailable
        })
        XCTAssertThrowsError(try access.withInteraction(allowed: false) {
            XCTFail("Failed suppression must not fall through to a prompting operation")
        }) { error in
            XCTAssertEqual(error as? KeychainAccess.Failure, .init(status: errSecNotAvailable))
        }
        XCTAssertEqual(changes, [false, true])
    }

    func testRestorationFailureIsReportedRatherThanClaimingSuccess() {
        let access = KeychainAccess(getInteractionAllowed: { (errSecSuccess, true) }, setInteractionAllowed: {
            $0 ? errSecNotAvailable : errSecSuccess
        })
        XCTAssertThrowsError(try access.withInteraction(allowed: false) { "synthetic-result" }) { error in
            XCTAssertEqual(error as? KeychainAccess.Failure, .init(status: errSecNotAvailable))
        }
        XCTAssertEqual(access.serialized { 42 }, 42)
    }

    func testOtherCredentialOperationsWaitUntilScopedInteractionIsRestored() {
        var allowed = true
        let access = KeychainAccess(getInteractionAllowed: { (errSecSuccess, allowed) }, setInteractionAllowed: {
            allowed = $0; return errSecSuccess
        })
        let backgroundEntered = DispatchSemaphore(value: 0)
        let releaseBackground = DispatchSemaphore(value: 0)
        let otherStarted = DispatchSemaphore(value: 0)
        let otherEntered = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Both serialized operations finished")
        finished.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try access.withInteraction(allowed: false) {
                    XCTAssertFalse(allowed)
                    backgroundEntered.signal()
                    XCTAssertEqual(releaseBackground.wait(timeout: .now() + 2), .success)
                }
            } catch { XCTFail("Unexpected synthetic guard error: \(error)") }
        }
        XCTAssertEqual(backgroundEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            otherStarted.signal()
            access.serialized {
                XCTAssertTrue(allowed, "Perch API credentials must not inherit Claude's temporary background flag")
                otherEntered.signal()
            }
        }
        XCTAssertEqual(otherStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(otherEntered.wait(timeout: .now() + 0.05), .timedOut)
        releaseBackground.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(otherEntered.wait(timeout: .now() + 1), .success)
    }
}
