import XCTest
@testable import FreeFlow

@MainActor
final class UpdateManagerTests: XCTestCase {
    func testLatestReleaseParsingStillWorks() throws {
        let data = Data(
            """
            {
              "tag_name": "main-20260319-120000-abcdef",
              "name": "FreeFlow main-20260319-120000-abcdef",
              "html_url": "https://github.com/marcbodea/freeflow/releases/tag/main-20260319-120000-abcdef",
              "published_at": "2026-03-19T12:00:00Z",
              "assets": [
                {
                  "name": "FreeFlow.app.zip",
                  "browser_download_url": "https://example.com/FreeFlow.app.zip",
                  "size": 123
                },
                {
                  "name": "FreeFlow.dmg",
                  "browser_download_url": "https://example.com/FreeFlow.dmg",
                  "size": 456
                }
              ]
            }
            """.utf8
        )

        let release = try UpdateManager.decodeLatestRelease(from: data)

        XCTAssertEqual(release.tagName, "main-20260319-120000-abcdef")
        XCTAssertEqual(release.assets.count, 2)
    }

    func testDMGAssetSelectionPrefersDiskImage() {
        let release = GitHubRelease(
            tagName: "main-20260319-120000-abcdef",
            name: nil,
            htmlUrl: "https://github.com/marcbodea/freeflow/releases/tag/main-20260319-120000-abcdef",
            publishedAt: "2026-03-19T12:00:00Z",
            assets: [
                GitHubReleaseAsset(name: "FreeFlow.app.zip", browserDownloadUrl: "https://example.com/FreeFlow.app.zip", size: 123),
                GitHubReleaseAsset(name: "FreeFlow.dmg", browserDownloadUrl: "https://example.com/FreeFlow.dmg", size: 456)
            ]
        )

        XCTAssertEqual(UpdateManager.preferredInstallerAsset(in: release)?.name, "FreeFlow.dmg")
    }

    func testDevBuildDisablesUpdaterBehavior() {
        let buildInfo = BuildInfo(infoDictionary: [
            "FreeFlowUpdateChannel": "dev"
        ])
        let manager = UpdateManager(buildInfo: buildInfo)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.autoCheckEnabled)
    }
}
