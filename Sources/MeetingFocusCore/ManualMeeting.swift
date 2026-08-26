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
