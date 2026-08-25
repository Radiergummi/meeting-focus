import Foundation

/// How much a detector's evidence is allowed to influence the outcome.
///
/// `definitive` evidence comes from inspecting an application's own meeting UI: if it says a
/// meeting is running, it is. `corroborating` evidence is indirect — microphone activity, remote
/// presence — and can be overridden by definitive evidence for the same subject.
public enum Confidence: Int, Sendable, Codable, Comparable, CaseIterable {
    case corroborating = 0
    case definitive = 1

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a detector currently believes about one subject.
///
/// `indeterminate` is deliberately distinct from `notInMeeting`: it means "I could not read the
/// signal", not "there is no meeting". Only the latter may end a meeting.
public enum Verdict: String, Sendable, Codable {
    case inMeeting
    case joining
    case notInMeeting
    case indeterminate
}

/// The lifecycle state of a single subject, or of the application overall.
public enum MeetingState: String, Sendable, Codable {
    case idle
    case joining
    case inMeeting
}

/// A single observation from a single detector.
public struct MeetingEvidence: Sendable, Equatable {
    /// Identifies the detector that produced this, for logging and precedence debugging.
    public let detectorID: String
    /// What the evidence is *about*. Normally an application bundle identifier, already normalised
    /// to the owning application (never a helper process). Remote tiers use their own namespace,
    /// e.g. `"remote:msgraph"`.
    public let subjectID: String
    public let verdict: Verdict
    public let confidence: Confidence
    public let applicationName: String?
    public let title: String?
    public let externalID: String?
    /// When the meeting began, where the signal can report it (Teams exposes an elapsed timer).
    public let startedAt: Date?
    public let observedAt: Date

    public init(
        detectorID: String,
        subjectID: String,
        verdict: Verdict,
        confidence: Confidence,
        applicationName: String? = nil,
        title: String? = nil,
        externalID: String? = nil,
        startedAt: Date? = nil,
        observedAt: Date
    ) {
        self.detectorID = detectorID
        self.subjectID = subjectID
        self.verdict = verdict
        self.confidence = confidence
        self.applicationName = applicationName
        self.title = title
        self.externalID = externalID
        self.startedAt = startedAt
        self.observedAt = observedAt
    }
}

/// A meeting the application believes the user is participating in.
public struct Meeting: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let applicationName: String
    public let applicationBundleID: String
    public let detectorID: String
    public let startedAt: Date
    public var endedAt: Date?
    public var title: String?
    public var externalID: String?
    public var confidence: Confidence

    public init(
        id: UUID = UUID(),
        applicationName: String,
        applicationBundleID: String,
        detectorID: String,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        externalID: String? = nil,
        confidence: Confidence
    ) {
        self.id = id
        self.applicationName = applicationName
        self.applicationBundleID = applicationBundleID
        self.detectorID = detectorID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.externalID = externalID
        self.confidence = confidence
    }
}

public enum MeetingEvent: Sendable, Equatable {
    case started(Meeting)
    case ended(Meeting)
}

/// Injectable time, so the state machine's debouncing is testable without sleeping.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}
