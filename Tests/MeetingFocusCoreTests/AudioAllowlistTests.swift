import XCTest
@testable import MeetingFocusCore

final class AudioAllowlistTests: XCTestCase {
    private let shipped = AudioAllowlist(bundleIdentifiers: ["us.zoom.xos", "com.microsoft.teams2"])

    func testShippedListIsUsedWhenThereIsNoOverride() {
        XCTAssertEqual(
            AudioAllowlist.resolve(shipped: shipped, userAdditions: nil),
            ["us.zoom.xos", "com.microsoft.teams2"]
        )
    }

    /// The point of the override: a meeting application we have never heard of, added by the person
    /// whose meetings it is, without waiting for a release.
    func testUserAdditionsAreAdded() {
        let extra = AudioAllowlist(bundleIdentifiers: ["com.example.newconf"])
        XCTAssertEqual(
            AudioAllowlist.resolve(shipped: shipped, userAdditions: extra),
            ["us.zoom.xos", "com.microsoft.teams2", "com.example.newconf"]
        )
    }

    /// Adding something already shipped is a no-op rather than a duplicate, so a user copying the
    /// bundled file as a starting point gets what they expect.
    func testOverlappingEntriesCollapse() {
        let extra = AudioAllowlist(bundleIdentifiers: ["us.zoom.xos", "com.example.newconf"])
        XCTAssertEqual(AudioAllowlist.resolve(shipped: shipped, userAdditions: extra).count, 3)
    }

    /// An override cannot remove a shipped entry. Stated as a test because it is a decision, not an
    /// oversight: the shipped list is what makes the audio tier work out of the box, and a file
    /// nobody can see in the UI is the wrong place to silently switch detection off.
    func testAnOverrideCannotRemoveAShippedEntry() {
        let extra = AudioAllowlist(bundleIdentifiers: [])
        XCTAssertTrue(AudioAllowlist.resolve(shipped: shipped, userAdditions: extra).contains("us.zoom.xos"))
    }

    /// A missing or unreadable bundled resource must not disable the audio tier altogether.
    func testFallbackIsUsedWhenTheShippedListIsMissing() {
        let resolved = AudioAllowlist.resolve(shipped: nil, userAdditions: nil)
        XCTAssertEqual(resolved, Set(AudioAllowlist.fallback.bundleIdentifiers))
        XCTAssertTrue(resolved.contains("com.microsoft.teams2"))
    }

    func testUserAdditionsStillApplyWhenTheShippedListIsMissing() {
        let extra = AudioAllowlist(bundleIdentifiers: ["com.example.newconf"])
        XCTAssertTrue(AudioAllowlist.resolve(shipped: nil, userAdditions: extra).contains("com.example.newconf"))
    }

    func testBlankAndWhitespaceEntriesAreIgnored() {
        let extra = AudioAllowlist(bundleIdentifiers: ["  ", "", " com.example.padded "])
        let resolved = AudioAllowlist.resolve(shipped: shipped, userAdditions: extra)
        XCTAssertEqual(resolved, ["us.zoom.xos", "com.microsoft.teams2", "com.example.padded"])
    }

    /// The fallback is only for a damaged install, so it must not drift from what actually ships —
    /// two copies of one list is precisely the thing that diverges unnoticed. Decoding the real file
    /// also proves the explanatory `_comment` key in it is ignored rather than fatal.
    func testShippedListDecodesAndMatchesTheFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Resources/audio-allowlist.json")
        let decoded = try JSONDecoder().decode(AudioAllowlist.self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(decoded.bundleIdentifiers), Set(AudioAllowlist.fallback.bundleIdentifiers))
    }

    func testDecodesFromJSON() throws {
        let json = Data(#"{"bundleIdentifiers": ["com.example.one", "com.example.two"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AudioAllowlist.self, from: json)
        XCTAssertEqual(decoded.bundleIdentifiers, ["com.example.one", "com.example.two"])
    }
}
