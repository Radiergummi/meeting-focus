import Foundation

/// How long a manual meeting claim stands when something other than the menu switch makes it.
///
/// The switch needs no duration: a person at the keyboard flipped it and can flip it back. An
/// automation may not be watching, so an external caller gets an hour unless it says otherwise —
/// and a caller-settable duration invites `minutes: 100000`, which would reintroduce through the
/// back door exactly the forgotten override the duration exists to close.
///
/// Clamped rather than rejected, so a slightly wrong automation keeps working. What it actually got
/// is returned to it, so it is corrected rather than silently overruled.
public enum ManualMeetingDuration {
    /// What an external caller gets when it names no duration.
    public static let `default`: TimeInterval = 60 * 60
    /// A working day. Longer than this is a forgotten override, not an intention.
    public static let maximum: TimeInterval = 8 * 60 * 60

    public static func clamped(_ requested: TimeInterval) -> TimeInterval {
        min(max(requested, 1), maximum)
    }
}

/// What a manual claim decided should happen to the state machine.
///
/// Emitted rather than executed, for the reason `AutomationCoordinator` gives for the same shape:
/// it keeps the decision synchronous and therefore testable without a running app. The distinction
/// between `withdraw` and `dismiss` is the one this whole type exists to protect — see `ManualClaim`.
public enum ManualClaimCommand: Sendable, Equatable {
    /// Assert a definitive manual meeting. Re-emitted on every tick, because evidence has a TTL.
    ///
    /// `source` names who declared it, and is nil on those re-assertions — which is what keeps the
    /// detection log to one line per claim. An automation that renews its claim every thirty seconds
    /// would otherwise flush all twenty entries in ten minutes, evicting the very lines someone
    /// reading the log came for.
    case assert(title: String?, source: String?)
    /// Retract the manual claim and nothing else, leaving a detected meeting running.
    /// `source` is nil when a duration simply ran out, because a timer has no source.
    case withdraw(isInstruction: Bool, source: String?)
    /// Retract the claim *and* overrule whatever the detectors are asserting.
    case dismiss(source: String)
}

/// Owns "the user says so" — whether a meeting has been declared by hand, and for how long.
///
/// Three operations, and keeping two of them apart is the point of the type:
///
/// - **assert** — "I am in a meeting", which enters the machine as definitive evidence.
/// - **withdraw** — "stop claiming", which retracts that evidence and says nothing about the
///   detectors.
/// - **dismiss** — "I am *not* in a meeting", which also overrules them.
///
/// A lapsing duration must withdraw, never dismiss. Dismissal suppresses a detector's claim for as
/// long as that claim persists, so an expiry routed through it would silently swallow a real,
/// detected call for the rest of its length. `ManualClaimTests` pins that.
@MainActor
public final class ManualClaim {
    private let timeSource: TimeSource
    private let onCommand: @MainActor (ManualClaimCommand) -> Void

    private var claimed = false

    public init(timeSource: TimeSource, onCommand: @escaping @MainActor (ManualClaimCommand) -> Void) {
        self.timeSource = timeSource
        self.onCommand = onCommand
    }

    /// Nil when the claim stands indefinitely, which only the menu switch asks for.
    public private(set) var expiresAt: Date?
    public private(set) var title: String?
    public var isClaimed: Bool { claimed }

    /// Says whether the user is in a meeting, in the user's own voice.
    ///
    /// `inMeeting: false` dismisses even when nothing was claimed: it is a statement about the user
    /// rather than about a claim, which is what lets the menu switch turn a detected call off.
    public func declare(inMeeting: Bool, for duration: TimeInterval?, source: String, title: String?) {
        if inMeeting {
            claimed = true
            self.title = title
            expiresAt = duration.map {
                timeSource.now.addingTimeInterval(ManualMeetingDuration.clamped($0))
            }
            onCommand(.assert(title: title, source: source))
        } else {
            reset()
            onCommand(.dismiss(source: source))
        }
    }

    /// Withdraws by instruction. Unlike `declare(inMeeting: false, …)` this does nothing when there
    /// is no claim to withdraw — clearing an override that was never set is not a statement about
    /// the detectors.
    public func withdraw(source: String) {
        guard claimed else { return }
        reset()
        onCommand(.withdraw(isInstruction: true, source: source))
    }

    /// Call once per tick. Re-asserts a standing claim, and withdraws a lapsed one.
    public func tick() {
        guard claimed else { return }
        if let expiresAt, timeSource.now >= expiresAt {
            reset()
            onCommand(.withdraw(isInstruction: false, source: nil))
        } else {
            // No source: this is a renewal of a claim already logged, not a new declaration.
            onCommand(.assert(title: title, source: nil))
        }
    }

    private func reset() {
        claimed = false
        expiresAt = nil
        title = nil
    }
}
