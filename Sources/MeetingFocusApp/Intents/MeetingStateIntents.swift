import AppIntents
import MeetingFocusCore

enum MeetingStateChoice: String, AppEnum {
    case inMeeting
    case notInMeeting

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meeting State" }
    static var caseDisplayRepresentations: [MeetingStateChoice: DisplayRepresentation] {
        [.inMeeting: "In a meeting", .notInMeeting: "Not in a meeting"]
    }
}

enum MeetingFocusIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "MeetingFocus is still starting up. Try again in a moment."
    }
}

/// One action rather than separate Start and End actions: a shortcut that computes the state passes
/// it through, and a fixed button simply presets the parameter.
struct SetMeetingStateIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Meeting State" }
    static var description: IntentDescription {
        IntentDescription("Tells MeetingFocus whether you are in a meeting, overruling what it has detected.")
    }

    @Parameter(title: "State")
    var state: MeetingStateChoice

    @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 480))
    var minutes: Int

    @Parameter(title: "Title")
    var meetingTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Set meeting state to \(\.$state) for \(\.$minutes) minutes") {
            \.$meetingTitle
        }
    }

    /// Returns when the claim lapses, so a caller that asked for more than the cap can see what it
    /// actually got rather than being silently corrected. Nil for "not in a meeting", which has no
    /// duration: it lasts exactly as long as the call it was said about.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Date?> {
        guard let monitor = IntentBridge.monitor else { throw MeetingFocusIntentError.notReady }
        switch state {
        case .inMeeting:
            monitor.setInMeeting(
                true,
                for: TimeInterval(minutes) * 60,
                source: "shortcuts",
                title: meetingTitle
            )
            return .result(value: monitor.manualMeetingExpiresAt)
        case .notInMeeting:
            monitor.setInMeeting(false, source: "shortcuts")
            return .result(value: nil)
        }
    }
}

/// Withdrawal, not dismissal — see `MeetingMonitor.withdrawManualMeeting(isInstruction:)`.
struct ClearMeetingOverrideIntent: AppIntent {
    static var title: LocalizedStringResource { "Clear Meeting Override" }
    static var description: IntentDescription {
        IntentDescription("Withdraws a manual claim and lets MeetingFocus go back to detecting. Leaves a detected meeting running.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let monitor = IntentBridge.monitor else { throw MeetingFocusIntentError.notReady }
        monitor.withdrawManualMeeting(isInstruction: true)
        return .result()
    }
}

/// `isInMeeting` is a plain `Bool` because that is what makes a Shortcuts `If` block work without
/// string comparison, and it is the property most callers want.
struct MeetingStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Meeting Status" }
    static var description: IntentDescription {
        IntentDescription("Reports whether MeetingFocus believes you are in a meeting.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard let monitor = IntentBridge.monitor else { throw MeetingFocusIntentError.notReady }
        let inMeeting = monitor.aggregateState == .inMeeting
        let name = monitor.activeMeetings.first.map { $0.title ?? $0.applicationName }
        let dialog: IntentDialog = if let name {
            IntentDialog("In a meeting: \(name)")
        } else {
            IntentDialog("Not in a meeting")
        }
        return .result(value: inMeeting, dialog: dialog)
    }
}
