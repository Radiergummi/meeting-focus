import XCTest
@testable import MeetingFocusCore

/// Covers the rule behind constraint D1. CoreAudio names the helper process that is capturing, and
/// evidence is grouped by subject — so a helper that resolves to its own identifier makes one
/// application look like several unrelated meetings, and stops definitive evidence overriding
/// corroborating evidence for the same app.
final class ExecutablePathTests: XCTestCase {
    private func bundle(_ path: String) -> String? {
        ExecutablePath.outermostApplicationBundle(forExecutableAt: path)?.path
    }

    /// The case the constraint was written for. Teams' helpers are themselves registered `.app`
    /// bundles, so stopping at the first one found while walking up returns the helper — which is
    /// exactly the bug. The outermost bundle is the application the user would name.
    func testNestedHelperResolvesToTheOutermostApplication() {
        let helper = "/Applications/Microsoft Teams.app/Contents/Frameworks"
            + "/Microsoft Teams WebView.app/Contents/MacOS/Microsoft Teams WebView"
        XCTAssertEqual(bundle(helper), "/Applications/Microsoft Teams.app")
    }

    func testPlainApplicationResolvesToItself() {
        XCTAssertEqual(
            bundle("/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"),
            "/Applications/Wispr Flow.app"
        )
    }

    /// Daemons are not applications, and returning nil is what keeps them off the audio allowlist —
    /// `com.apple.CoreSpeech` holding the microphone is not a meeting.
    func testNonApplicationProcessHasNoBundle() {
        XCTAssertNil(bundle("/usr/libexec/corespeechd"))
        XCTAssertNil(bundle("/bin/zsh"))
    }

    func testApplicationAtTheFilesystemRoot() {
        XCTAssertEqual(bundle("/Foo.app/Contents/MacOS/Foo"), "/Foo.app")
    }

    /// Three levels deep still resolves to the top, not to the middle.
    func testDeeplyNestedHelpersStillResolveToTheTop() {
        XCTAssertEqual(
            bundle("/Applications/Outer.app/Contents/Helpers/Middle.app/Contents/Helpers/Inner.app/Contents/MacOS/Inner"),
            "/Applications/Outer.app"
        )
    }

    func testEmptyPathIsNotAnApplication() {
        XCTAssertNil(bundle(""))
    }
}
