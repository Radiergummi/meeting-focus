import XCTest
@testable import MeetingFocusCore

@MainActor
final class MeetingStateMachineTests: XCTestCase {
    private var clock: TestClock!
    private var events: [MeetingEvent]!
    private var machine: MeetingStateMachine!

    override func setUp() async throws {
        clock = TestClock()
        events = []
        machine = MeetingStateMachine(timeSource: clock) { [self] in events.append($0) }
    }

    private var started: [Meeting] { events.compactMap { if case .started(let meeting) = $0 { meeting } else { nil } } }
    private var ended: [Meeting] { events.compactMap { if case .ended(let meeting) = $0 { meeting } else { nil } } }

    /// Drives the machine to a confirmed in-meeting state for `subject`.
    private func enterMeeting(subject: String = Subjects.teams, title: String? = "Standup") {
        machine.ingest(evidence(.inMeeting, subject: subject, title: title, at: clock.now))
        clock.advance(1.0)
        machine.tick()
    }

    // 1
    func testIdleToInMeeting() {
        XCTAssertFalse(machine.isInMeeting)
        enterMeeting()
        XCTAssertTrue(machine.isInMeeting)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.title, "Standup")
        XCTAssertEqual(started.first?.applicationBundleID, Subjects.teams)
    }

    /// A start must not be declared before the grace period has elapsed.
    func testStartIsDebounced() {
        machine.ingest(evidence(.inMeeting, at: clock.now))
        XCTAssertFalse(machine.isInMeeting, "should not fire before the grace period")
        clock.advance(0.5)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting)
        clock.advance(0.6)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting)
    }

    // 2
    func testInMeetingToIdle() {
        enterMeeting()
        machine.ingest(evidence(.notInMeeting, at: clock.now))
        clock.advance(4.0)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting, "must still be in a meeting inside the end grace")
        clock.advance(1.5)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(ended.count, 1)
        XCTAssertNotNil(ended.first?.endedAt)
    }

    // 3 — the case that justifies having a separate `indeterminate` verdict at all
    func testTransientDetectionLossDoesNotEndMeeting() {
        enterMeeting()
        machine.ingest(evidence(.indeterminate, at: clock.now))
        clock.advance(120)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting, "unreadable accessibility data is not evidence of absence")
        XCTAssertTrue(ended.isEmpty)

        // ...and recovery emits no duplicate start.
        machine.ingest(evidence(.inMeeting, at: clock.now))
        clock.advance(2)
        machine.tick()
        XCTAssertEqual(started.count, 1)
    }

    // 4
    func testDuplicateEvidenceProducesOneTransition() {
        for _ in 0..<20 {
            machine.ingest(evidence(.inMeeting, at: clock.now))
            clock.advance(0.5)
            machine.tick()
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(ended.count, 0)
    }

    // 5 — overlapping meetings in two applications
    func testOverlappingMeetingsStayInMeetingUntilLastEnds() {
        enterMeeting(subject: Subjects.teams, title: "Teams call")
        enterMeeting(subject: Subjects.zoom, title: "Zoom call")
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(machine.activeMeetings.count, 2)

        machine.ingest(evidence(.notInMeeting, subject: Subjects.teams, at: clock.now))
        clock.advance(6)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting, "Zoom is still in a meeting")
        XCTAssertEqual(ended.count, 1)

        machine.ingest(evidence(.notInMeeting, subject: Subjects.zoom, at: clock.now))
        clock.advance(6)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(ended.count, 2)
    }

    // 6 — termination is authoritative, so no grace period applies
    func testApplicationTerminationEndsMeetingImmediately() {
        enterMeeting()
        machine.applicationTerminated(subjectID: Subjects.teams)
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(ended.count, 1)
    }

    // 7
    func testDetectorRestartDoesNotDuplicateEvents() {
        enterMeeting()
        // Detector dies: no evidence at all for longer than the TTL.
        clock.advance(120)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting)
        // Detector comes back and re-reports the same reality.
        for _ in 0..<5 {
            machine.ingest(evidence(.inMeeting, at: clock.now))
            clock.advance(1)
            machine.tick()
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(ended.count, 0)
    }

    // 9 — the mute case: this is why Confidence exists
    func testDefinitiveInMeetingOverridesCorroboratingAbsence() {
        enterMeeting()
        // Microphone tier sees nothing (user muted) but Teams' own UI still shows a call.
        machine.ingest(evidence(.notInMeeting, detector: "audio", confidence: .corroborating, at: clock.now))
        machine.ingest(evidence(.inMeeting, detector: "teams.ax", confidence: .definitive, at: clock.now))
        clock.advance(30)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting, "muting must not end the meeting")
        XCTAssertTrue(ended.isEmpty)
    }

    func testDefinitiveAbsenceOverridesCorroboratingPresence() {
        // Teams is capturing audio for some other reason, but its UI shows no call.
        machine.ingest(evidence(.inMeeting, detector: "audio", confidence: .corroborating, at: clock.now))
        machine.ingest(evidence(.notInMeeting, detector: "teams.ax", confidence: .definitive, at: clock.now))
        clock.advance(10)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertTrue(started.isEmpty)
    }

    /// The counterpart to the test above, and the reason a blind detector must not claim absence.
    /// Teams' accessibility tree can go dormant mid-call, at which point the Teams detector can
    /// see nothing at all — while the microphone tier still can. Definitive evidence outranks
    /// corroborating evidence only when it says something; `indeterminate` says nothing.
    func testDefinitiveIndeterminateLeavesCorroboratingPresenceInCharge() {
        machine.ingest(evidence(.inMeeting, detector: "audio", confidence: .corroborating, at: clock.now))
        machine.ingest(evidence(.indeterminate, detector: "teams.ax", confidence: .definitive, at: clock.now))
        clock.advance(10)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting, "a detector that cannot see must not veto one that can")
        XCTAssertEqual(started.count, 1)
    }

    // 10 — audio alone can establish a meeting, but has to wait longer
    func testCorroboratingEvidenceAloneUsesLongerGrace() {
        machine.ingest(evidence(.inMeeting, subject: Subjects.zoom, detector: "audio",
                                confidence: .corroborating, at: clock.now))
        clock.advance(1.5)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting, "corroborating evidence must not fire on the short grace")
        clock.advance(2.0)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting)
        XCTAssertEqual(started.first?.confidence, .corroborating)
    }

    /// The lobby is a real, long-lived state (26 seconds measured), and must not read as a meeting.
    func testJoiningIsNotAMeeting() {
        machine.ingest(evidence(.joining, at: clock.now))
        clock.advance(30)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(machine.aggregateState, .joining)
        XCTAssertTrue(started.isEmpty)
    }

    /// Meeting start time comes from the signal when it can report one, not from when we noticed.
    func testStartedAtComesFromEvidence() {
        let actualStart = clock.now.addingTimeInterval(-600)
        machine.ingest(evidence(.inMeeting, startedAt: actualStart, at: clock.now))
        clock.advance(1)
        machine.tick()
        XCTAssertEqual(started.first?.startedAt, actualStart)
    }

    // MARK: Retraction

    /// Turning off the only detector that can see a meeting must end it, and must end it *here* —
    /// letting the evidence expire instead would hold the meeting open forever, because absent
    /// evidence deliberately holds the previous state. A held meeting means the end shortcut never
    /// runs and the user's Focus never releases.
    func testRetractingTheOnlyDetectorEndsTheMeeting() {
        enterMeeting()
        machine.retractEvidence(fromDetector: "teams.ax")
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(ended.count, 1)
        XCTAssertNotNil(ended.first?.endedAt)
    }

    /// Ending is authoritative, not debounced: the user turned the signal off, so there is nothing
    /// left to wait for.
    func testRetractionIgnoresTheEndGrace() {
        enterMeeting()
        machine.retractEvidence(fromDetector: "teams.ax")
        XCTAssertEqual(ended.count, 1, "must not wait out endGrace")
    }

    /// The other tier still says the meeting is happening, so it is still happening.
    func testRetractingOneOfTwoDetectorsLeavesTheOtherInCharge() {
        machine.ingest(evidence(.inMeeting, detector: "teams.ax", at: clock.now))
        machine.ingest(evidence(.inMeeting, detector: "audio.process", confidence: .corroborating, at: clock.now))
        clock.advance(1)
        machine.tick()
        XCTAssertTrue(machine.isInMeeting)

        machine.retractEvidence(fromDetector: "teams.ax")
        XCTAssertTrue(machine.isInMeeting, "the audio tier still sees it")
        XCTAssertTrue(ended.isEmpty)
    }

    /// Turning off a detector that never said anything about this subject is not an event.
    func testRetractingASilentDetectorChangesNothing() {
        enterMeeting()
        machine.retractEvidence(fromDetector: "audio.process")
        XCTAssertTrue(machine.isInMeeting)
        XCTAssertTrue(ended.isEmpty)
    }

    /// Retracting while idle must not manufacture an `ended` for a meeting that never started.
    func testRetractingWhileIdleEmitsNothing() {
        machine.ingest(evidence(.notInMeeting, detector: "teams.ax", at: clock.now))
        machine.retractEvidence(fromDetector: "teams.ax")
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Dismissal

    /// The user saying they are not in a meeting ends it at once — no end grace, as with a quit
    /// application.
    func testDismissalEndsTheMeetingImmediately() {
        enterMeeting()
        machine.dismissActiveMeetings()
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(ended.count, 1)
        XCTAssertNotNil(ended.first?.endedAt)
    }

    /// The point of the dismissal, and the reason it cannot simply end the meeting: the detector goes
    /// on reporting the call the user just dismissed, and must not be allowed to restart it.
    func testDismissedSubjectStaysIdleWhileItsEvidenceStillClaimsAMeeting() {
        enterMeeting()
        machine.dismissActiveMeetings()

        for _ in 0..<5 {
            machine.ingest(evidence(.inMeeting, at: clock.now))
            clock.advance(2.0)
            machine.tick()
        }
        XCTAssertFalse(machine.isInMeeting, "the detector must not undo the dismissal")
        XCTAssertEqual(started.count, 1, "and must not report a second start")
    }

    /// And the reason it cannot last forever: once the call the user dismissed genuinely ends, the
    /// next one has to register like any other.
    func testTheNextRealMeetingStartsNormallyAfterADismissal() {
        enterMeeting()
        machine.dismissActiveMeetings()

        // The real meeting ends, which is what releases the subject.
        machine.ingest(evidence(.notInMeeting, at: clock.now))
        clock.advance(6.0)
        machine.tick()
        XCTAssertFalse(machine.isInMeeting)

        enterMeeting(title: "Retro")
        XCTAssertTrue(machine.isInMeeting)
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(started.last?.title, "Retro")
    }

    /// Dismissing when there is nothing to dismiss is not an event, and must not leave a subject
    /// deaf to the meeting that starts a moment later.
    func testDismissingWhileIdleEmitsNothingAndBlocksNothing() {
        machine.dismissActiveMeetings()
        XCTAssertTrue(events.isEmpty)

        enterMeeting()
        XCTAssertTrue(machine.isInMeeting)
        XCTAssertEqual(started.count, 1)
    }

    /// One dismissal covers everything in progress: "I am not in a meeting" is a statement about the
    /// user, not about one application.
    func testDismissalCoversEverySubjectAtOnce() {
        enterMeeting(subject: Subjects.teams, title: "Standup")
        enterMeeting(subject: Subjects.zoom, title: "Client call")
        XCTAssertEqual(started.count, 2)

        machine.dismissActiveMeetings()
        XCTAssertFalse(machine.isInMeeting)
        XCTAssertEqual(ended.count, 2)
    }

    /// A dismissal must not outlive the evidence it was about: switching the detector off settles the
    /// subject, so a later meeting there starts normally.
    func testRetractionReleasesADismissedSubject() {
        enterMeeting()
        machine.dismissActiveMeetings()
        machine.retractEvidence(fromDetector: "teams.ax")

        enterMeeting()
        XCTAssertTrue(machine.isInMeeting)
        XCTAssertEqual(started.count, 2)
    }
}
