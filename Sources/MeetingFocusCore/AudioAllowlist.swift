import Foundation

/// Applications whose microphone use counts as evidence of a meeting.
///
/// Scoped deliberately rather than trusting "is the microphone in use" on its own: dictation and
/// speech services hold the input too — `com.electron.wispr-flow` and `com.apple.CoreSpeech` were
/// both observed doing so on the development machine, and neither is a meeting.
///
/// Data rather than a Swift constant so that covering another meeting application is an edit to a
/// file, reviewable by anyone, instead of a code change. The shipped list still requires a release,
/// because it lives inside a signed bundle — which is what the user override exists for.
public struct AudioAllowlist: Decodable, Sendable, Equatable {
    public var bundleIdentifiers: [String]

    public init(bundleIdentifiers: [String]) {
        self.bundleIdentifiers = bundleIdentifiers
    }

    /// Combines the list we ship with the one the user keeps, if any.
    ///
    /// Additive only. An override can teach the app about an application we have never heard of; it
    /// cannot switch off one we ship, because the shipped list is what makes the audio tier work out
    /// of the box and a file with no presence in the UI is the wrong place to silently disable
    /// detection. Removing one is a Settings concern, if it ever becomes one.
    public static func resolve(shipped: AudioAllowlist?, userAdditions: AudioAllowlist?) -> Set<String> {
        let base = shipped ?? .fallback
        let entries = base.bundleIdentifiers + (userAdditions?.bundleIdentifiers ?? [])
        return Set(
            entries
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Used only when the bundled resource cannot be read, so a damaged install still detects
    /// meetings rather than silently detecting none. Mirrors `Resources/audio-allowlist.json`.
    public static let fallback = AudioAllowlist(bundleIdentifiers: [
        "com.microsoft.teams2",
        "us.zoom.xos",
        "com.tinyspeck.slackmacgap",
        "Cisco-Systems.Spark",
        "com.webex.meetingmanager",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
    ])
}
