import XCTest
@testable import MeetingFocusCore

final class ManualMeetingTests: XCTestCase {
    func testKeepsAReasonableDuration() {
        XCTAssertEqual(ManualMeetingDuration.clamped(30 * 60), 30 * 60)
    }

    /// A caller-settable duration invites `minutes: 100000`, which would reintroduce the forgotten
    /// override the duration exists to prevent.
    func testClampsToAWorkingDay() {
        XCTAssertEqual(ManualMeetingDuration.clamped(100_000 * 60), ManualMeetingDuration.maximum)
    }

    /// Zero or negative would expire the claim the instant it was made, which is not what any caller
    /// asking for a manual meeting means.
    func testClampsZeroAndNegativeToTheFloor() {
        XCTAssertEqual(ManualMeetingDuration.clamped(0), 1)
        XCTAssertEqual(ManualMeetingDuration.clamped(-5), 1)
    }
}
