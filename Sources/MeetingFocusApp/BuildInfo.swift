import Foundation

/// Where this particular bundle came from.
///
/// This app reads the contents of other applications' windows and watches microphone state, so
/// "can I trust this binary" is a fair question to ask of it. Official builds are produced by a
/// public GitHub Actions run from a public commit, and the run records a build provenance
/// attestation over the artifact. Surfacing the commit and the build URL inside the app is what
/// lets someone holding a copy check that claim rather than take it on faith.
///
/// A locally built copy reports `isOfficialBuild == false`. That is not a warning — it is the
/// honest answer, and the distinction is the point.
enum BuildInfo {
    static let version = string("CFBundleShortVersionString") ?? "unknown"
    static let build = string("CFBundleVersion") ?? "unknown"

    /// The git commit the release workflow built from, or "local" for a developer build.
    static let commit = string("MFBuildCommit") ?? "local"

    /// URL of the public build that produced this bundle, empty for a local build.
    static let buildRunURL: URL? = {
        guard let value = string("MFBuildRunURL"), !value.isEmpty else { return nil }
        return URL(string: value)
    }()

    static var isOfficialBuild: Bool { buildRunURL != nil && commit != "local" }

    static let repositoryURL = URL(string: "https://github.com/Radiergummi/meeting-focus")!

    /// Short form for display: `0.1.0 (42) · a1b2c3d`
    static var summary: String {
        let shortCommit = commit == "local" ? "local build" : String(commit.prefix(7))
        return "\(version) (\(build)) · \(shortCommit)"
    }

    /// The command a user can run to verify this artifact's provenance themselves.
    static var verificationCommand: String {
        "gh attestation verify MeetingFocus-\(version).dmg --repo Radiergummi/meeting-focus"
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
