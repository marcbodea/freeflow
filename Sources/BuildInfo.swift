import Foundation

enum UpdateChannel: String {
    case dev
    case release

    var updaterEnabled: Bool {
        self == .release
    }

    var isDevelopmentBuild: Bool {
        self == .dev
    }
}

struct BuildInfo: Equatable {
    static let defaultBundleIdentifier = "com.marcbodea.freeflow"
    static let defaultRepositorySlug = "marcbodea/freeflow"
    static let current = BuildInfo(bundle: .main)

    let githubRepositorySlug: String
    let buildTag: String?
    let updateChannel: UpdateChannel
    let version: String
    let buildNumber: String
    let bundleIdentifier: String
    let productName: String

    init(bundle: Bundle) {
        self.init(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    init(infoDictionary: [String: Any], bundleIdentifier: String? = nil) {
        let repository = (infoDictionary["FreeFlowGitHubRepository"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channelString = (infoDictionary["FreeFlowUpdateChannel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBuildTag = (infoDictionary["FreeFlowBuildTag"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.githubRepositorySlug = repository?.isEmpty == false ? repository! : Self.defaultRepositorySlug
        self.buildTag = rawBuildTag?.isEmpty == false ? rawBuildTag : nil
        self.updateChannel = UpdateChannel(rawValue: channelString ?? "") ?? .dev
        self.version = (infoDictionary["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        self.buildNumber = (infoDictionary["CFBundleVersion"] as? String) ?? "1"
        self.bundleIdentifier = bundleIdentifier
            ?? (infoDictionary["CFBundleIdentifier"] as? String)
            ?? Self.defaultBundleIdentifier
        self.productName = (infoDictionary["CFBundleDisplayName"] as? String)
            ?? (infoDictionary["CFBundleName"] as? String)
            ?? "FreeFlow"
    }

    var repositoryURL: URL {
        URL(string: "https://github.com/\(githubRepositorySlug)")!
    }

    var repositoryAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubRepositorySlug)")!
    }

    var releasesAPIURL: URL {
        repositoryAPIURL.appendingPathComponent("releases")
    }

    var latestReleaseAPIURL: URL {
        releasesAPIURL.appendingPathComponent("latest")
    }

    var releasesPageURL: URL {
        repositoryURL.appendingPathComponent("releases")
    }

    var currentVersionBuildDisplay: String {
        var components = ["\(version) (\(buildNumber))"]
        if let buildTag {
            components.append(buildTag)
        }
        return components.joined(separator: " • ")
    }

    var updaterEnabled: Bool {
        updateChannel.updaterEnabled
    }

    var isDevelopmentBuild: Bool {
        updateChannel.isDevelopmentBuild
    }
}
