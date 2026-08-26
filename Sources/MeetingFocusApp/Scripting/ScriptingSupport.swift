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

        MainActor.assumeIsolated {
            guard let monitor = IntentBridge.monitor else { return }
            if inMeeting {
                monitor.setInMeeting(
                    true,
                    for: minutes.map { $0 * 60 } ?? ManualMeetingDuration.default,
                    source: "applescript",
                    title: title
                )
            } else {
                monitor.setInMeeting(false, source: "applescript")
            }
        }
        return nil
    }
}

final class ClearMeetingOverrideCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            IntentBridge.monitor?.withdrawManualMeeting(isInstruction: true)
        }
        return nil
    }
}
