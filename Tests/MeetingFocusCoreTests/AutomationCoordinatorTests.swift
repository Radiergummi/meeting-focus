import XCTest
@testable import MeetingFocusCore

@MainActor
final class AutomationCoordinatorTests: XCTestCase {
    private var clock: TestClock!
    private var commands: [AutomationCommand]!
    private var coordinator: AutomationCoordinator!

    override func setUp() async throws {
        clock = TestClock()
        commands = []
        coordinator = AutomationCoordinator(
            configuration: .init(endCooldown: 45),
            timeSource: clock
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
        commands.compactMap { if case .meetingStarted(let m) = $0 { m.title } else { nil } }
    }
    private var endedTitles: [String?] {
        commands.compactMap { if case .meetingEnded(let m) = $0 { m.title } else { nil } }
    }

    // 8 — exactly one call per aggregate edge, regardless of how often we are polled
    func testFiresExactlyOncePerEdge() {
        let m = meeting("Standup")
        for _ in 0..<10 { coordinator.update(isInMeeting: true, activeMeeting: m) }
        XCTAssertEqual(commands.count, 1)

        for _ in 0..<10 { coordinator.update(isInMeeting: false, activeMeeting: nil) }
        XCTAssertEqual(commands.count, 1, "the end is still inside the cooldown")

        clock.advance(46)
        coordinator.tick()
        XCTAssertEqual(commands, [.meetingStarted(m), .meetingEnded(m)])
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
        let m = meeting("Standup")
        coordinator.update(isInMeeting: true, activeMeeting: m)
        coordinator.update(isInMeeting: false, activeMeeting: nil)
        clock.advance(50)
        for _ in 0..<10 { coordinator.tick() }
        XCTAssertEqual(endedTitles.count, 1)
    }
}
