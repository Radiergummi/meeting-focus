import Foundation
@testable import MeetingFocusCore

/// A clock the tests move by hand, so no test ever sleeps.
final class TestClock: TimeSource, @unchecked Sendable {
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    var now: Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// The coordinator's persistence, in memory. Standing in for `UserDefaults` here is the point:
/// what these tests are about is a coordinator reading a record it did not write.
@MainActor
final class TestAutomationStore: AutomationStateStore {
    var runningMeeting: Meeting?
    init(runningMeeting: Meeting? = nil) { self.runningMeeting = runningMeeting }
}

enum Subjects {
    static let teams = "com.microsoft.teams2"
    static let zoom = "us.zoom.xos"
}

func evidence(
    _ verdict: Verdict,
    subject: String = Subjects.teams,
    detector: String = "teams.ax",
    confidence: Confidence = .definitive,
    title: String? = nil,
    startedAt: Date? = nil,
    at now: Date
) -> MeetingEvidence {
    MeetingEvidence(
        detectorID: detector,
        subjectID: subject,
        verdict: verdict,
        confidence: confidence,
        applicationName: subject == Subjects.teams ? "Microsoft Teams" : "Zoom",
        title: title,
        startedAt: startedAt,
        observedAt: now
    )
}
