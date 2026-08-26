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

/// Where the coordinator remembers what automation is currently running, so that the decision to
/// end it can outlive the process that decided to start it.
///
/// Without this the entire end decision lives in one object's memory, and a quit, a crash, a
/// Sparkle update or a reboot mid-meeting leaves the user's Focus mode on with nothing left in the
/// system that could ever turn it off. A Focus mode is a system-wide fact; our belief about it must
/// be persisted like one.
@MainActor
public protocol AutomationStateStore: AnyObject {
    var runningMeeting: Meeting? { get set }
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
        public init(endCooldown: TimeInterval = 20) { self.endCooldown = endCooldown }
    }

    private enum State { case idle, active }

    private let configuration: Configuration
    private let timeSource: TimeSource
    private let store: AutomationStateStore
    private let onCommand: @MainActor (AutomationCommand) -> Void

    private var state: State = .idle
    private var lastMeeting: Meeting?
    private var pendingEnd: (meeting: Meeting, since: Date)?

    /// Adopts whatever automation the last launch left running, rather than starting from idle.
    ///
    /// Both halves of that matter. An end becomes possible again for a meeting this process never
    /// saw begin — the failure this store exists for. And a relaunch that lands *during* the same
    /// call no longer runs the start a second time over a Focus mode that is already on.
    public init(
        configuration: Configuration = Configuration(),
        timeSource: TimeSource,
        store: AutomationStateStore,
        onCommand: @escaping @MainActor (AutomationCommand) -> Void
    ) {
        self.configuration = configuration
        self.timeSource = timeSource
        self.store = store
        self.onCommand = onCommand
        if let running = store.runningMeeting {
            state = .active
            lastMeeting = running
        }
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
                    emit(.meetingStarted(meeting))
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
        emit(.meetingEnded(pending.meeting))
    }

    /// Ends automation now, bypassing `endCooldown`.
    ///
    /// The cooldown exists to absorb the gap between back-to-back meetings, which is a detector
    /// artefact. An explicit instruction from the user is not that artefact, and a Focus mode that
    /// stays on for another cooldown after the switch is flipped reads as broken.
    /// Authoritative in the same way `MeetingStateMachine.applicationTerminated` is.
    public func endImmediately() {
        pendingEnd = nil
        guard state == .active, let meeting = lastMeeting else { return }
        state = .idle
        emit(.meetingEnded(meeting))
    }

    /// The one place a command leaves this object, so that what is persisted and what is run can
    /// never disagree: the store is written before the command is handed on, never beside it.
    private func emit(_ command: AutomationCommand) {
        switch command {
        case .meetingStarted(let meeting): store.runningMeeting = meeting
        case .meetingEnded: store.runningMeeting = nil
        }
        onCommand(command)
    }

    public var isAutomationActive: Bool { state == .active }
    public var hasPendingEnd: Bool { pendingEnd != nil }
}
