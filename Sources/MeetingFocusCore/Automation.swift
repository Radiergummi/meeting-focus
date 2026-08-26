import Foundation

/// A side-effecting automation backend. Implementations live in the app layer.
public protocol AutomationHandler: Sendable {
    func meetingStarted(_ meeting: Meeting) async
    func meetingEnded(_ meeting: Meeting) async
}

/// What the coordinator decided should happen. Emitting commands rather than calling the handler
/// directly keeps the decision logic synchronous and therefore trivially testable.
public enum AutomationCommand: Sendable, Equatable {
    case meetingStarted(Meeting)
    case meetingEnded(Meeting)
}

/// Decides *when* automation runs, which is not the same question as when a meeting starts.
///
/// Detection state must track reality immediately so the UI is honest. Automation must not,
/// because back-to-back meetings are normal: a measured 12-second gap between two real meetings
/// would otherwise disable and re-enable the user's Focus mode, flooding them with notifications
/// in the gap. So an end is held for `endCooldown`, and a meeting starting inside that window
/// cancels it — the automation never learns the gap happened.
@MainActor
public final class AutomationCoordinator {
    public struct Configuration: Sendable {
        public var endCooldown: TimeInterval
        public init(endCooldown: TimeInterval = 45) { self.endCooldown = endCooldown }
    }

    private enum State { case idle, active }

    private let configuration: Configuration
    private let timeSource: TimeSource
    private let onCommand: @MainActor (AutomationCommand) -> Void

    private var state: State = .idle
    private var lastMeeting: Meeting?
    private var pendingEnd: (meeting: Meeting, since: Date)?

    public init(
        configuration: Configuration = Configuration(),
        timeSource: TimeSource,
        onCommand: @escaping @MainActor (AutomationCommand) -> Void
    ) {
        self.configuration = configuration
        self.timeSource = timeSource
        self.onCommand = onCommand
    }

    /// Feed the aggregate state after every state-machine evaluation.
    public func update(isInMeeting: Bool, activeMeeting: Meeting?) {
        if let activeMeeting { lastMeeting = activeMeeting }

        if isInMeeting {
            // A new meeting inside the cooldown cancels the pending end outright.
            pendingEnd = nil
            if state == .idle {
                state = .active
                if let meeting = activeMeeting ?? lastMeeting {
                    onCommand(.meetingStarted(meeting))
                }
            }
        } else if state == .active, pendingEnd == nil, let meeting = lastMeeting {
            pendingEnd = (meeting, timeSource.now)
        }
        tick()
    }

    public func tick() {
        guard let pending = pendingEnd else { return }
        guard timeSource.now.timeIntervalSince(pending.since) >= configuration.endCooldown else { return }
        pendingEnd = nil
        state = .idle
        onCommand(.meetingEnded(pending.meeting))
    }

    /// Ends automation now, bypassing `endCooldown`.
    ///
    /// The cooldown exists to absorb the gap between back-to-back meetings, which is a detector
    /// artefact. An explicit instruction from the user is not that artefact, and a Focus mode that
    /// stays on for three quarters of a minute after the switch is flipped reads as broken.
    /// Authoritative in the same way `MeetingStateMachine.applicationTerminated` is.
    public func endImmediately() {
        pendingEnd = nil
        guard state == .active, let meeting = lastMeeting else { return }
        state = .idle
        onCommand(.meetingEnded(meeting))
    }

    public var isAutomationActive: Bool { state == .active }
    public var hasPendingEnd: Bool { pendingEnd != nil }
}
