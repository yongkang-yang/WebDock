import Foundation
import XCTest
@testable import WebDockPolicies

final class SessionRestorationPolicyTests: XCTestCase {
    /// Regression for auto-release -> hover (no click) -> speculative expiry -> reopen.
    /// Both hover completion and expiration must leave the saved snapshot untouched.
    func testHoverWithoutSelectionDoesNotConsumeSavedSession() {
        let original = Data("last-page:scroll:form-state".utf8)
        var cache: Data? = original

        XCTAssertTrue(SessionRestorationPolicy.shouldDeferLoad(
            hasSavedState: cache != nil, speculative: true, explicitURL: false))
        XCTAssertFalse(SessionRestorationPolicy.shouldRestore(
            hasSavedState: cache != nil, speculative: true, explicitURL: false))
        if !SessionRestorationPolicy.shouldKeepCachedStateWhenClosing(speculative: true) {
            cache = nil
        }
        XCTAssertEqual(cache, original, "hover expiry must not erase the original session")
        XCTAssertTrue(SessionRestorationPolicy.shouldRestore(
            hasSavedState: cache != nil, speculative: false, explicitURL: false))
    }

    func testHoverReplacementAndPanelHidePreserveCachedState() {
        for reason in ["replaced preload", "panel hidden", "memory pressure"] {
            XCTAssertTrue(SessionRestorationPolicy.shouldKeepCachedStateWhenClosing(
                speculative: true), reason)
        }
        XCTAssertFalse(SessionRestorationPolicy.shouldKeepCachedStateWhenClosing(
            speculative: false))
    }

    /// Regression for successful navigation commit with hanging media/ads.
    /// A slow page can take >8 seconds to finish; no fallback is permitted after commit.
    func testCommittedRestoreDoesNotTriggerEightSecondFallback() {
        var phase: SessionRestorationPhase? = .awaitingCommit
        XCTAssertTrue(SessionRestorationPolicy.shouldFallbackAfterTimeout(phase: phase))
        phase = .committed
        XCTAssertFalse(SessionRestorationPolicy.shouldFallbackAfterTimeout(phase: phase))
        phase = nil
        XCTAssertFalse(SessionRestorationPolicy.shouldFallbackAfterTimeout(phase: phase))
    }

    func testExplicitNavigationBypassesSavedInteractionState() {
        XCTAssertFalse(SessionRestorationPolicy.shouldRestore(
            hasSavedState: true, speculative: false, explicitURL: true))
        XCTAssertFalse(SessionRestorationPolicy.shouldDeferLoad(
            hasSavedState: true, speculative: true, explicitURL: true))
        XCTAssertFalse(SessionRestorationPolicy.shouldRestore(
            hasSavedState: false, speculative: false, explicitURL: false))
    }
}
