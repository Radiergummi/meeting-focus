import Foundation

/// Combines evidence from several detectors about one subject into a single verdict.
///
/// The rules are deliberately few, so they can be reasoned about and tested exhaustively:
///
/// 1. Evidence older than `evidenceTTL` is ignored — a detector that has died must not pin state.
/// 2. `indeterminate` evidence is discarded rather than counted as absence.
/// 3. Among what remains, the highest `Confidence` present wins. This is what lets a Teams
///    Accessibility detector override the microphone tier when the user mutes.
/// 4. Within that confidence, the most active verdict wins, so a stale "not in a meeting" from one
///    detector cannot cancel a live "in a meeting" from another at the same confidence.
public enum EvidenceFusion {
    public static func activityRank(_ verdict: Verdict) -> Int {
        switch verdict {
        case .inMeeting: 2
        case .joining: 1
        case .notInMeeting: 0
        case .indeterminate: -1
        }
    }

    /// Resolves a subject's verdict, or `nil` when there is no usable evidence at all — in which
    /// case the caller must hold the previous state rather than assume idleness.
    public static func resolve(
        evidence: [MeetingEvidence],
        now: Date,
        evidenceTTL: TimeInterval
    ) -> MeetingEvidence? {
        let usable = evidence.filter {
            $0.verdict != .indeterminate && now.timeIntervalSince($0.observedAt) <= evidenceTTL
        }
        guard !usable.isEmpty else { return nil }
        guard let bestConfidence = usable.map(\.confidence).max() else { return nil }
        return usable
            .filter { $0.confidence == bestConfidence }
            .max { activityRank($0.verdict) < activityRank($1.verdict) }
    }
}
