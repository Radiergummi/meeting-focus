import AppKit
import Foundation
import MeetingFocusCore

/// The `application` class the sdef describes. Cocoa Scripting resolves `<cocoa key="…"/>` by KVC
/// against `NSApp`, so the properties live here rather than on the delegate.
///
/// `assumeIsolated` throughout: Apple Events are delivered on the main thread, but nothing in the
/// type system says so, and the alternative under complete concurrency checking is to make every
/// accessor async — which KVC cannot call.
extension NSApplication {
    @objc var scriptingInMeeting: NSNumber {
        get { MainActor.assumeIsolated { NSNumber(value: IntentBridge.monitor?.aggregateState == .inMeeting) } }
        set {
            MainActor.assumeIsolated {
                IntentBridge.monitor?.setInMeeting(
                    newValue.boolValue,
                    for: newValue.boolValue ? ManualMeetingDuration.default : nil,
                    source: "applescript"
                )
            }
        }
    }

    @objc var scriptingMeetingState: String {
        MainActor.assumeIsolated { IntentBridge.monitor?.aggregateState.rawValue ?? MeetingState.idle.rawValue }
    }

    @objc var scriptingMeetingTitle: String {
        MainActor.assumeIsolated {
            guard let meeting = IntentBridge.monitor?.activeMeetings.first else { return "" }
            return meeting.title ?? meeting.applicationName
        }
    }

    @objc var scriptingManual: NSNumber {
        MainActor.assumeIsolated { NSNumber(value: IntentBridge.monitor?.manualMeeting ?? false) }
    }

    @objc var scriptingOverrideExpires: Date? {
        MainActor.assumeIsolated { IntentBridge.monitor?.manualMeetingExpiresAt }
    }
}

/// `set meeting state to true for 30` — the form that can name a duration. The writable
/// `in meeting` property above is the form anyone tries first, and takes the default hour.
final class SetMeetingStateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Read from `self` before entering the isolated closure: `self` is a plain NSScriptCommand,
        // not Sendable, so capturing it inside the MainActor-isolated closure below would be flagged
        // as an isolation violation even though everything here actually runs on the main thread.
        let inMeeting = (directParameter as? NSNumber)?.boolValue ?? false
        let arguments = evaluatedArguments ?? [:]
        let minutes = (arguments["minutes"] as? NSNumber)?.doubleValue
        let title = arguments["meetingTitle"] as? String

        // Nil twice over, and the two mean opposite things: no monitor is a failure, while a
        // dismissal legitimately has no expiry to report. Hence the nested optional rather than a
        // bare `Date?` — collapsing them is what made this command report success having done
        // nothing.
        let outcome: Date?? = MainActor.assumeIsolated {
            guard let monitor = IntentBridge.monitor else { return nil }
            if inMeeting {
                monitor.setInMeeting(
                    true,
                    for: minutes.map { $0 * 60 } ?? ManualMeetingDuration.default,
                    source: "applescript",
                    title: title
                )
                return .some(monitor.manualMeetingExpiresAt)
            } else {
                monitor.setInMeeting(false, source: "applescript")
                return .some(nil)
            }
        }
        guard let expiresAt = outcome else { return reportNotReady() }
        return expiresAt
    }
}

final class ClearMeetingOverrideCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let ready = MainActor.assumeIsolated {
            guard let monitor = IntentBridge.monitor else { return false }
            monitor.withdrawManualMeeting(source: "applescript")
            return true
        }
        return ready ? nil : reportNotReady()
    }
}

extension NSScriptCommand {
    /// Fails the command rather than returning quietly.
    ///
    /// The window is small — Apple Events queue until `applicationDidFinishLaunching` has run — but
    /// a script that is told nothing assumes it worked, and the App Intents on the same operations
    /// throw here. Silence was the odd one out.
    func reportNotReady() -> Any? {
        scriptErrorNumber = Int(errAEEventFailed)
        scriptErrorString = "MeetingFocus is still starting up."
        return nil
    }
}
