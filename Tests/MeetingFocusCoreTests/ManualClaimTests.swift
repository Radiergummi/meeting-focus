import XCTest
@testable import MeetingFocusCore

@MainActor
final class ManualClaimTests: XCTestCase {
    private var clock: TestClock!
    private var commands: [ManualClaimCommand]!
    private var claim: ManualClaim!

    override func setUp() async throws {
        clock = TestClock()
        commands = []
        claim = ManualClaim(timeSource: clock) { [self] in commands.append($0) }
    }

    // MARK: Declaring

    func testDeclaringAMeetingAsserts() {
        claim.declare(inMeeting: true, for: 3600, source: "shortcuts", title: "Deep work")
        XCTAssertEqual(commands, [.assert(title: "Deep work", source: "shortcuts")])
        XCTAssertTrue(claim.isClaimed)
    }

    func testDeclaringNoMeetingDismisses() {
        claim.declare(inMeeting: false, for: nil, source: "menu", title: nil)
        XCTAssertEqual(commands, [.dismiss(source: "menu")])
        XCTAssertFalse(claim.isClaimed)
    }

    /// "I am not in a meeting" is a statement about the user, not about a claim, so it stands even
    /// when there is no manual claim to withdraw — that is why the menu switch can turn a detected
    /// call off at all.
    func testDismissingWithoutAClaimStillDismisses() {
        claim.declare(inMeeting: false, for: nil, source: "applescript", title: nil)
        XCTAssertEqual(commands, [.dismiss(source: "applescript")])
    }

    // MARK: Expiry — the distinction this type exists to make

    /// The one that matters. A lapsing duration must withdraw the claim, never dismiss: dismissal
    /// suppresses whatever the detectors are asserting, so an expiry routed through it would
    /// silently swallow a real, detected call for as long as that call ran.
    func testExpiryWithdrawsAndNeverDismisses() {
        claim.declare(inMeeting: true, for: 60, source: "shortcuts", title: nil)
        commands.removeAll()

        clock.advance(61)
        claim.tick()

        XCTAssertEqual(commands, [.withdraw(isInstruction: false, source: nil)])
        XCTAssertFalse(commands.contains { if case .dismiss = $0 { true } else { false } },
                       "a lapsing timer must never overrule a detector")
        XCTAssertFalse(claim.isClaimed)
    }

    /// Re-asserted rather than asserted once: evidence in the state machine has a TTL, and a claim
    /// that goes stale leaves the machine holding a state nothing is saying any more.
    func testTickReassertsWhileTheClaimStands() {
        claim.declare(inMeeting: true, for: 60, source: "menu", title: "Standup")
        commands.removeAll()

        clock.advance(30)
        claim.tick()
        clock.advance(10)
        claim.tick()

        XCTAssertEqual(commands, [.assert(title: "Standup", source: nil), .assert(title: "Standup", source: nil)])
        XCTAssertTrue(claim.isClaimed)
    }

    /// Only the menu switch asks for this: a person at the keyboard can flip the switch back, where
    /// an automation may never look again.
    func testAnIndefiniteClaimNeverLapses() {
        claim.declare(inMeeting: true, for: nil, source: "menu", title: nil)
        commands.removeAll()

        clock.advance(100_000)
        claim.tick()

        XCTAssertEqual(commands, [.assert(title: nil, source: nil)])
        XCTAssertTrue(claim.isClaimed)
        XCTAssertNil(claim.expiresAt)
    }

    func testExpiryIsReportedOnlyOnce() {
        claim.declare(inMeeting: true, for: 60, source: "menu", title: nil)
        clock.advance(61)
        commands.removeAll()

        for _ in 0..<10 { claim.tick() }

        XCTAssertEqual(commands, [.withdraw(isInstruction: false, source: nil)])
    }

    func testTickWithoutAClaimEmitsNothing() {
        clock.advance(100)
        claim.tick()
        XCTAssertTrue(commands.isEmpty)
    }

    /// Only a fresh declaration names a source, and the detection log writes a line only when one is
    /// named. Without this, an automation renewing its claim every half minute would flush all twenty
    /// entries in ten minutes — evicting the lines someone opening the log came to read.
    func testOnlyAFreshClaimNamesItsSource() {
        claim.declare(inMeeting: true, for: 3600, source: "shortcuts", title: nil)
        for _ in 0..<20 {
            clock.advance(30)
            claim.tick()
        }

        let sourced = commands.filter { if case .assert(_, .some) = $0 { true } else { false } }
        XCTAssertEqual(sourced.count, 1, "one log line per claim, however often it is renewed")
        XCTAssertEqual(commands.count, 21, "but every tick still re-asserts, because evidence has a TTL")
    }

    // MARK: Withdrawing by instruction

    func testWithdrawingByInstructionCarriesItsSource() {
        claim.declare(inMeeting: true, for: 3600, source: "shortcuts", title: nil)
        commands.removeAll()

        claim.withdraw(source: "applescript")

        XCTAssertEqual(commands, [.withdraw(isInstruction: true, source: "applescript")])
        XCTAssertFalse(claim.isClaimed)
    }

    /// Clearing an override that was never set is not a statement about the detectors, so unlike
    /// `declare(inMeeting: false, …)` it must do nothing at all.
    func testWithdrawingWithoutAClaimEmitsNothing() {
        claim.withdraw(source: "shortcuts")
        XCTAssertTrue(commands.isEmpty)
    }

    // MARK: Duration

    func testDurationIsClamped() {
        claim.declare(inMeeting: true, for: 100_000 * 60, source: "shortcuts", title: nil)
        XCTAssertEqual(claim.expiresAt, clock.now.addingTimeInterval(ManualMeetingDuration.maximum))
    }

    func testReplacingAClaimReplacesItsExpiry() {
        claim.declare(inMeeting: true, for: 60, source: "menu", title: "First")
        claim.declare(inMeeting: true, for: 3600, source: "shortcuts", title: "Second")

        XCTAssertEqual(claim.expiresAt, clock.now.addingTimeInterval(3600))
        XCTAssertEqual(claim.title, "Second")
    }
}
