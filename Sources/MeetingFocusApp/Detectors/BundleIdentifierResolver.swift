import AppKit
import Darwin
// Conditional because this file is compiled two ways on purpose. In the app it is a member of
// MeetingFocusApp and ExecutablePath arrives from another module; in `make axprobe` swiftc compiles
// it and ExecutablePath.swift into one flat module, where there is no module to import. Sharing the
// file is deliberate — see the Makefile: a second copy of this normalisation would be free to drift
// from the one detection actually uses.
#if canImport(MeetingFocusCore)
import MeetingFocusCore
#endif

/// Maps a process id to the bundle identifier of the application that *owns* it.
///
/// This normalisation is mandatory, not cosmetic. CoreAudio reports the helper process — Teams
/// appears as `com.microsoft.teams2.modulehost` — while the Accessibility detector reports
/// `com.microsoft.teams2`. Since evidence is grouped by subject, un-normalised identifiers make
/// one application look like several unrelated meetings, and prevent definitive evidence from
/// overriding corroborating evidence for the same app.
///
/// The order matters. `NSRunningApplication(processIdentifier:)` is *not* the primary lookup:
/// Teams' helpers are themselves registered `.app` bundles, so it returns the helper's own
/// identifier and silently defeats the normalisation. Walking to the outermost enclosing `.app`
/// is what actually works. Verified against a live Teams install on 2026-08-25:
///
///     ModuleHost    pid 71771 -> com.microsoft.teams2     (outermost: Microsoft Teams.app)
///     Teams WebView pid 71743 -> com.microsoft.teams2     (outermost: Microsoft Teams.app)
///     wispr helper  pid 4290  -> com.electron.wispr-flow  (outermost: Wispr Flow.app)
///     CoreSpeech    pid 2821  -> nil                      (not an app at all)
///
/// Returning `nil` for non-application processes is desirable: system daemons such as
/// `com.apple.CoreSpeech` can then never match a meeting-application allowlist.
struct BundleIdentifierResolver {
    private var cache: [pid_t: String?] = [:]

    mutating func owningBundleIdentifier(pid: pid_t) -> String? {
        if let cached = cache[pid] { return cached }
        let resolved = Self.resolve(pid: pid)
        cache[pid] = resolved
        return resolved
    }

    /// Processes come and go; drop entries for pids that no longer exist.
    mutating func invalidate(keeping livePids: Set<pid_t>) {
        cache = cache.filter { livePids.contains($0.key) }
    }

    private static func resolve(pid: pid_t) -> String? {
        if let path = executablePath(pid: pid),
           let appURL = ExecutablePath.outermostApplicationBundle(forExecutableAt: path),
           let bundle = Bundle(url: appURL),
           let identifier = bundle.bundleIdentifier {
            return identifier
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
