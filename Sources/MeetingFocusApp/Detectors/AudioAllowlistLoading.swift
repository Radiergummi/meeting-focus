import Foundation
import MeetingFocusCore

/// Reading the allowlist off disk. The *rule* for combining the two files lives in
/// `MeetingFocusCore.AudioAllowlist`, where it is tested; this is the part that needs a bundle and
/// a home directory.
extension AudioAllowlist {
    static let resourceName = "audio-allowlist"

    /// The file a user can write to teach the audio tier about an application we do not ship.
    ///
    /// Application Support rather than inside the bundle, because the bundle is signed: editing the
    /// shipped copy breaks the signature and macOS refuses to launch the app. There is no UI for
    /// this, which is a real limitation — it is documented in the README, and a Settings list is the
    /// answer if it turns out people need one.
    static var userOverrideURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MeetingFocus", isDirectory: true)
            .appendingPathComponent("\(resourceName).json")
    }

    /// The identifiers the audio detector should treat as meetings, shipped list plus the user's.
    ///
    /// Read at every `MeetingMonitor.start()`, so editing the override takes effect on the next
    /// relaunch — or immediately on toggling the microphone detector off and on again, which now
    /// restarts monitoring.
    static func loadResolved(bundle: Bundle = .main) -> Set<String> {
        let shipped: AudioAllowlist?
        if let url = bundle.url(forResource: resourceName, withExtension: "json"),
           let decoded = decode(contentsOf: url) {
            shipped = decoded
        } else {
            Log.detector.error("\(resourceName).json missing or unreadable; using built-in fallback")
            shipped = nil
        }

        var additions: AudioAllowlist?
        if let overrideURL = userOverrideURL, FileManager.default.fileExists(atPath: overrideURL.path) {
            additions = decode(contentsOf: overrideURL)
            if additions == nil {
                // Named rather than swallowed: someone who wrote this file and sees no effect needs
                // to be able to find out why, and the log is the only surface there is.
                Log.detector.error("user audio allowlist at \(overrideURL.path, privacy: .public) could not be read")
            } else {
                Log.detector.info(
                    "user audio allowlist added \(additions?.bundleIdentifiers.count ?? 0, privacy: .public) entries"
                )
            }
        }

        return resolve(shipped: shipped, userAdditions: additions)
    }

    private static func decode(contentsOf url: URL) -> AudioAllowlist? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AudioAllowlist.self, from: data)
    }
}
