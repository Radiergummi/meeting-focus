import ApplicationServices

/// Persuades Chromium to publish an application's web content to the accessibility API.
///
/// Chromium keeps that tree switched off until it believes an assistive client needs it, and
/// *reading* does not convince it — the application's native chrome answers while everything below
/// stays empty, so the `AXDOMIdentifier` markers detection matches on simply are not there.
/// Writing to the application element does convince it. Both attributes are refused (`-25205`
/// `attributeUnsupported` and `-25208` `illegalArgument`), which is not a failure to work around:
/// the attempt is the signal, and the refusal is what Chromium answers after acting on it.
///
/// Measured against Teams 26213.1006.5011.1671 during a live call — 42 nodes and 0 identifiers
/// before, 193 and 32 within three seconds afterwards.
///
/// Shared with `axprobe` rather than reimplemented there, and the reason is the bug this file was
/// extracted for: the probe read the tree without waking it, so every measurement taken during a
/// live call would have seen the dormant tree and reported an absence of markers. A tool used to
/// verify detection must be at least as sighted as detection is.
enum AccessibilityWake {
    /// How long the publish takes to land. `AXUIElementSetAttributeValue` returns immediately and
    /// the tree fills in afterwards, so anything that scans exactly once must wait before looking
    /// again. Three seconds is the measured figure above.
    static let settlingTime: TimeInterval = 3

    /// Deliberately silent: this file is compiled into both the app and the probe, which log in
    /// entirely different ways. The caller says what happened.
    static func request(pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            _ = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
        }
    }
}
