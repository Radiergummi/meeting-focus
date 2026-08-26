import XCTest
@testable import MeetingFocusCore

@MainActor
final class AutomationCoordinatorTests: XCTestCase {
    private var clock: TestClock!
    private var commands: [AutomationCommand]!
    private var store: TestAutomationStore!
    private var coordinator: AutomationCoordinator!

    override func setUp() async throws {
        clock = TestClock()
        commands = []
        store = TestAutomationStore()
        coordinator = makeCoordinator(store: store)
    }

    /// Every coordinator in this file reports into the same `commands`, so a restored one can be
    /// built mid-test without losing what the first said.
    private func makeCoordinator(store: TestAutomationStore) -> AutomationCoordinator {
        AutomationCoordinator(
            configuration: .init(endCooldown: 45),
            timeSource: clock,
            store: store
        ) { [self] in commands.append($0) }
    }

    private func meeting(_ title: String) -> Meeting {
        Meeting(
            applicationName: "Microsoft Teams",
            applicationBundleID: Subjects.teams,
            detectorID: "teams.ax",
            startedAt: clock.now,
            title: title,
            confidence: .definitive
        )
    }

    private var startedTitles: [String?] {
        commands.compactMap { if case .meetingStarted(let meeting) = $0 { meeting.title } else { nil } }
    }
    private var endedTitles: [String?] {
        commands.compactMap { if case .meetingEnded(let meeting) = $0 { meeting.title } else { nil } }
    }

    // 8 — exactly one call per aggregate edge, regardless of how often we are polled
    func testFiresExactlyOncePerEdge() {
        let call = meeting("Standup")
        for _ in 0..<10 { coordinator.update(isInMeeting: true, activeMeeting: call) }
        XCTAssertEqual(commands.count, 1)

        for _ in 0..<10 { coordinator.update(isInMeeting: false, activeMeeting: nil) }
        XCTAssertEqual(commands.count, 1, "the end is still inside the cooldown")

        clock.advance(46)
        coordinator.tick()
        XCTAssertEqual(commands, [.meetingStarted(call), .meetingEnded(call)])
    }

    // 11 — the measured case: two real meetings 12 seconds apart
    func testBackToBackMeetingsProduceNoAutomationInTheGap() {
        let first = meeting("Daily")
        coordinator.update(isInMeeting: true, activeMeeting: first)
        XCTAssertEqual(startedTitles, ["Daily"])

        // First meeting ends.
        coordinator.update(isInMeeting: false, activeMeeting: nil)
        clock.advance(12)
        coordinator.tick()
        XCTAssertTrue(endedTitles.isEmpty, "must not release Focus during a 12-second gap")

        // Second meeting begins inside the cooldown.
        let second = meeting("1:1")
        coordinator.update(isInMeeting: true, activeMeeting: second)

        clock.advance(600)
        coordinator.tick()

        XCTAssertEqual(commands.count, 1, "one start, no end, no second start")
        XCTAssertTrue(coordinator.isAutomationActive)
        XCTAssertFalse(coordinator.hasPendingEnd)
    }

    // 12 — a genuine gap does produce a clean end, then a clean start
    func testGapLongerThanCooldownEndsThenStarts() {
        let first = meeting("Daily")
        coordinator.update(isInMeeting: true, activeMeeting: first)
        coordinator.update(isInMeeting: false, activeMeeting: nil)

        clock.advance(46)
        coordinator.tick()
        XCTAssertEqual(endedTitles, ["Daily"])
        XCTAssertFalse(coordinator.isAutomationActive)

        let second = meeting("Retro")
        coordinator.update(isInMeeting: true, activeMeeting: second)
        XCTAssertEqual(startedTitles, ["Daily", "Retro"])
        XCTAssertEqual(commands.count, 3)
    }

    /// Repeated ticks must not re-fire an end that has already been delivered.
    func testEndIsNotRepeated() {
        let call = meeting("Standup")
        coordinator.update(isInMeeting: true, activeMeeting: call)
        coordinator.update(isInMeeting: false, activeMeeting: nil)
        clock.advance(50)
        for _ in 0..<10 { coordinator.tick() }
        XCTAssertEqual(endedTitles.count, 1)
    }

    /// The user saying "I am not in a meeting" is not the back-to-back-meeting artefact the cooldown
    /// exists to absorb, so it must not be held for one.
    func testEndImmediatelySkipsTheCooldown() {
        let call = meeting("Standup")
        coordinator.update(isInMeeting: true, activeMeeting: call)

        coordinator.endImmediately()

        XCTAssertEqual(endedTitles, ["Standup"])
        XCTAssertFalse(coordinator.isAutomationActive)
    }

    /// An end already waiting out the cooldown is replaced by the immediate one, not delivered twice.
    func testEndImmediatelyCancelsAPendingEnd() {
        let call = meeting("Standup")
        coordinator.update(isInMeeting: true, activeMeeting: call)
        coordinator.update(isInMeeting: false, activeMeeting: nil)
        XCTAssertTrue(coordinator.hasPendingEnd)

        coordinator.endImmediately()
        clock.advance(600)
        coordinator.tick()

        XCTAssertEqual(endedTitles.count, 1)
        XCTAssertFalse(coordinator.hasPendingEnd)
    }

    /// Flipping the switch off when nothing was running must not invent an end for a meeting that
    /// automation never started.
    func testEndImmediatelyDoesNothingWhenIdle() {
        coordinator.endImmediately()
        XCTAssertTrue(commands.isEmpty)
    }

    // MARK: Surviving the process

    /// What is recorded has to match what was run, or a relaunch acts on a Focus mode that is not on.
    func testTheRunningMeetingIsRecordedAtTheStartAndClearedAtTheEnd() {
        coordinator.update(isInMeeting: true, activeMeeting: meeting("Standup"))
        XCTAssertEqual(store.runningMeeting?.title, "Standup")

        coordinator.update(isInMeeting: false, activeMeeting: nil)
        XCTAssertNotNil(store.runningMeeting, "an end inside the cooldown has not run yet")

        clock.advance(46)
        coordinator.tick()
        XCTAssertNil(store.runningMeeting)
    }

    func testEndImmediatelyClearsTheRecord() {
        coordinator.update(isInMeeting: true, activeMeeting: meeting("Standup"))
        coordinator.endImmediately()
        XCTAssertNil(store.runningMeeting)
    }

    /// The failure this store exists for: the app went away mid-meeting — quit, crashed, updated,
    /// rebooted — and the Focus mode it turned on outlived it. A fresh coordinator has to be able to
    /// end a meeting it never saw begin.
    func testAdoptsAutomationLeftRunningByThePreviousLaunch() {
        let store = TestAutomationStore(runningMeeting: meeting("Standup"))
        let relaunched = makeCoordinator(store: store)
        XCTAssertTrue(relaunched.isAutomationActive)

        relaunched.update(isInMeeting: false, activeMeeting: nil)
        clock.advance(46)
        relaunched.tick()

        XCTAssertEqual(endedTitles, ["Standup"])
        XCTAssertNil(store.runningMeeting)
    }

    /// The observed fingerprint of the bug: relaunches during a call re-firing the start shortcut
    /// three seconds later, over a Focus mode already on, with no end between them.
    func testRelaunchingDuringTheSameMeetingDoesNotStartTwice() {
        let call = meeting("Standup")
        let store = TestAutomationStore(runningMeeting: call)
        let relaunched = makeCoordinator(store: store)

        // The detectors have not reported yet, then they do.
        relaunched.update(isInMeeting: false, activeMeeting: nil)
        clock.advance(3)
        relaunched.update(isInMeeting: true, activeMeeting: call)
        clock.advance(600)
        relaunched.tick()

        XCTAssertTrue(commands.isEmpty, "the Focus mode was already on; nothing needed running")
        XCTAssertFalse(relaunched.hasPendingEnd)
        XCTAssertEqual(store.runningMeeting?.title, "Standup")
    }

    /// An empty record is the ordinary case, and must not invent an end at every launch.
    func testAnEmptyRecordStartsIdle() {
        let relaunched = makeCoordinator(store: TestAutomationStore())
        relaunched.update(isInMeeting: false, activeMeeting: nil)
        clock.advance(600)
        relaunched.tick()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(relaunched.isAutomationActive)
    }
}
