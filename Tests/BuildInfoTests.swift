import XCTest
@testable import FreeFlow

final class BuildInfoTests: XCTestCase {
    func testRepositorySlugDefaultsToMarcbodeaFork() {
        let buildInfo = BuildInfo(infoDictionary: [:])

        XCTAssertEqual(buildInfo.githubRepositorySlug, "marcbodea/freeflow")
    }

    func testDevChannelDisablesUpdater() {
        let buildInfo = BuildInfo(infoDictionary: [
            "FreeFlowUpdateChannel": "dev"
        ])

        XCTAssertFalse(buildInfo.updaterEnabled)
        XCTAssertTrue(buildInfo.isDevelopmentBuild)
    }

    func testReleaseChannelEnablesUpdater() {
        let buildInfo = BuildInfo(infoDictionary: [
            "FreeFlowUpdateChannel": "release"
        ])

        XCTAssertTrue(buildInfo.updaterEnabled)
        XCTAssertFalse(buildInfo.isDevelopmentBuild)
    }
}
