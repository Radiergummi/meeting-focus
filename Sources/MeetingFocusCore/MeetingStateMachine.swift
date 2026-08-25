import Foundation

/// Turns a stream of detector evidence into debounced, de-duplicated meeting events.
///
/// The machine is driven entirely by `ingest(_:)` and `tick()`, and reads time only from its
/// injected `TimeSource`. It starts no timers of its own, which is what makes every behaviour
/// here testable without sleeping.
@MainActor
public final class MeetingStateMachine {
    public struct Configuration: Sendable {
        /// How long a definitive `inMeeting` must persist before a meeting is declared.
        public var definitiveStartGrace: TimeInterval
        /// Corroborating evidence alone waits longer, to absorb brief microphone activity.
        public var corroboratingStartGrace: TimeInterval
        /// How long absence must persist before a meeting is ended.
        public var endGrace: TimeInterval
        /// Evidence older than this is treated as absent rather than authoritative.
        public var evidenceTTL: TimeInterval

        public init(
            definitiveStartGrace: TimeInterval = 1,
            corroboratingStartGrace: TimeInterval = 3,
            endGrace: TimeInterval = 5,
            evidenceTTL: TimeInterval = 30
        ) {
            self.definitiveStartGrace = definitiveStartGrace
            self.corroboratingStartGrace = corroboratingStartGrace
            self.endGrace = endGrace
            self.evidenceTTL = evidenceTTL
        }
    }

    private struct Subject {
        var evidenceByDetector: [String: MeetingEvidence] = [:]
        var state: MeetingState = .idle
        var meeting: Meeting?
        var pendingState: MeetingState?
        var pendingSince: Date?
    }

    private let configuration: Configuration
    private let timeSource: TimeSource
    private let onEvent: @MainActor (MeetingEvent) -> Void
    private var subjects: [String: Subject] = [:]

    public init(
        configuration: Configuration = Configuration(),
        timeSource: TimeSource,
        onEvent: @escaping @MainActor (MeetingEvent) -> Void
    ) {
        self.configuration = configuration
        self.timeSource = timeSource
        self.onEvent = onEvent
    }

    // MARK: Inputs

    public func ingest(_ evidence: MeetingEvidence) {
        var subject = subjects[evidence.subjectID] ?? Subject()
        subject.evidenceByDetector[evidence.detectorID] = evidence
        subjects[evidence.subjectID] = subject
        evaluate()
    }

    /// An application quitting is authoritative: no grace period applies, because there is no
    /// longer any process that could be hosting a meeting.
    public func applicationTerminated(subjectID: String) {
        guard var subject = subjects[subjectID] else { return }
        subject.evidenceByDetector.removeAll()
        subject.pendingState = nil
        subject.pendingSince = nil
        if subject.state == .inMeeting, var meeting = subject.meeting {
            meeting.endedAt = timeSource.now
            subject.state = .idle
            subject.meeting = nil
            subjects[subjectID] = subject
            onEvent(.ended(meeting))
        } else {
            subject.state = .idle
            subject.meeting = nil
            subjects[subjectID] = subject
        }
    }

    /// Re-evaluates debounces. Call periodically; nothing here depends on being called on time.
    public func tick() { evaluate() }

    // MARK: Outputs

    public var isInMeeting: Bool { subjects.values.contains { $0.state == .inMeeting } }

    public var activeMeetings: [Meeting] {
        subjects.values.compactMap { $0.state == .inMeeting ? $0.meeting : nil }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public var aggregateState: MeetingState {
        if isInMeeting { return .inMeeting }
        if subjects.values.contains(where: { $0.state == .joining }) { return .joining }
        return .idle
    }

    public func state(forSubject subjectID: String) -> MeetingState {
        subjects[subjectID]?.state ?? .idle
    }

    // MARK: Evaluation

    private func evaluate() {
        let now = timeSource.now
        for (id, original) in subjects {
            var subject = original
            let resolved = EvidenceFusion.resolve(
                evidence: Array(subject.evidenceByDetector.values),
                now: now,
                evidenceTTL: configuration.evidenceTTL
            )

            // No usable evidence: hold the previous state. This is the "temporary loss of
            // accessibility information" case, and it must never end a meeting.
            guard let resolved else {
                subject.pendingState = nil
                subject.pendingSince = nil
                subjects[id] = subject
                continue
            }

            let target: MeetingState = switch resolved.verdict {
            case .inMeeting: .inMeeting
            case .joining: .joining
            case .notInMeeting, .indeterminate: .idle
            }

            if target == subject.state {
                subject.pendingState = nil
                subject.pendingSince = nil
                subjects[id] = subject
                continue
            }

            if subject.pendingState != target {
                subject.pendingState = target
                subject.pendingSince = now
                subjects[id] = subject
                continue
            }

            let grace = requiredGrace(from: subject.state, to: target, confidence: resolved.confidence)
            guard let since = subject.pendingSince, now.timeIntervalSince(since) >= grace else {
                subjects[id] = subject
                continue
            }

            subject.pendingState = nil
            subject.pendingSince = nil
            let events = commit(subject: &subject, to: target, using: resolved, now: now)
            subjects[id] = subject
            for event in events { onEvent(event) }
        }
    }

    private func requiredGrace(
        from current: MeetingState,
        to target: MeetingState,
        confidence: Confidence
    ) -> TimeInterval {
        switch target {
        case .inMeeting:
            confidence == .definitive
                ? configuration.definitiveStartGrace
                : configuration.corroboratingStartGrace
        case .joining:
            configuration.definitiveStartGrace
        case .idle:
            current == .inMeeting ? configuration.endGrace : configuration.definitiveStartGrace
        }
    }

    private func commit(
        subject: inout Subject,
        to target: MeetingState,
        using evidence: MeetingEvidence,
        now: Date
    ) -> [MeetingEvent] {
        var events: [MeetingEvent] = []
        let wasInMeeting = subject.state == .inMeeting
        subject.state = target

        switch (wasInMeeting, target) {
        case (false, .inMeeting):
            let meeting = Meeting(
                applicationName: evidence.applicationName ?? evidence.subjectID,
                applicationBundleID: evidence.subjectID,
                detectorID: evidence.detectorID,
                startedAt: evidence.startedAt ?? now,
                title: evidence.title,
                externalID: evidence.externalID,
                confidence: evidence.confidence
            )
            subject.meeting = meeting
            events.append(.started(meeting))

        case (true, .idle), (true, .joining):
            if var meeting = subject.meeting {
                meeting.endedAt = now
                subject.meeting = nil
                events.append(.ended(meeting))
            }

        default:
            break
        }
        return events
    }
}
