import XCTest
@testable import WebDockPolicies

final class SpeculativePagePolicyTests: XCTestCase {
    /// Regression: a page can request camera/microphone immediately on load.
    /// A hover-created view must not turn that request into permission.
    func testMediaOnLoadCannotBeGrantedDuringHover() {
        XCTAssertFalse(SpeculativePagePolicy.allowsMediaRequest(
            isSpeculative: true, isSelectedAndVisible: false, isDetachedWindow: false))
        // A stale selected/visible flag must not override speculative status.
        XCTAssertFalse(SpeculativePagePolicy.allowsMediaRequest(
            isSpeculative: true, isSelectedAndVisible: true, isDetachedWindow: false))
    }

    func testMediaAllowedOnlyForSelectedPageOrDetachedWindow() {
        XCTAssertFalse(SpeculativePagePolicy.allowsMediaRequest(
            isSpeculative: false, isSelectedAndVisible: false, isDetachedWindow: false))
        XCTAssertTrue(SpeculativePagePolicy.allowsMediaRequest(
            isSpeculative: false, isSelectedAndVisible: true, isDetachedWindow: false))
        XCTAssertTrue(SpeculativePagePolicy.allowsMediaRequest(
            isSpeculative: false, isSelectedAndVisible: false, isDetachedWindow: true))
    }

    func testHoverLoadCannotStartSideEffects() {
        XCTAssertFalse(SpeculativePagePolicy.allowsInteractiveSideEffects(isSpeculative: true))
        XCTAssertTrue(SpeculativePagePolicy.allowsInteractiveSideEffects(isSpeculative: false))
    }
}
