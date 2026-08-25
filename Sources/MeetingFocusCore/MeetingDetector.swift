import Foundation

/// A source of meeting evidence.
///
/// Detectors never decide state — they report what they can see and how much it should be
/// trusted. `MeetingStateMachine` does the deciding. This is what allows a new signal (another
/// application, a cloud presence API) to be added without touching the state machine.
public protocol MeetingDetector: Sendable {
    var id: String { get }
    /// Emits evidence until the stream is cancelled.
    var evidence: AsyncStream<MeetingEvidence> { get }
    func start() async throws
    func stop() async
}
