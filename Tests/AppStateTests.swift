import XCTest
@testable import FreeFlow

final class AppStateTests: XCTestCase {
    func testPreviewModeConstructsWithoutSystemIntegrations() {
        let state = AppState(runtimeMode: .preview)

        XCTAssertEqual(state.runtimeMode, .preview)
        XCTAssertFalse(state.supportsSystemIntegrations)
        XCTAssertFalse(state.loginItemRequiresApproval)
        XCTAssertEqual(state.availableMicrophones, [])
    }
}
