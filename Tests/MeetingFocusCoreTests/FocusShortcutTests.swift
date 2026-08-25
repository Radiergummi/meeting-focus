import XCTest
@testable import MeetingFocusCore

/// The shape of a Shortcuts workflow plist is private, undocumented, and only reported wrong by the
/// signer refusing the file — so it is pinned here rather than discovered by running the app.
final class FocusShortcutTests: XCTestCase {
    private let recipe = FocusShortcutRecipe.fallback
    private let work = FocusMode(identifier: "com.apple.focus.work", name: "Arbeiten")

    private func parameters(_ data: Data) throws -> [String: Any] {
        let root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let actions = try XCTUnwrap(root?["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.dnd.set")
        return try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
    }

    func testOnCarriesTheFocusAndHoldsUntilTurnedOff() throws {
        let params = try parameters(
            FocusShortcut.plistData(recipe: recipe, focus: work, direction: .turnOn)
        )
        XCTAssertEqual(params["Enabled"] as? Int, 1)
        XCTAssertEqual(params["AssertionType"] as? String, "Turned Off")
        let modes = try XCTUnwrap(params["FocusModes"] as? [String: String])
        XCTAssertEqual(modes["Identifier"], "com.apple.focus.work")
        XCTAssertEqual(modes["DisplayString"], "Arbeiten")
    }

    /// An `AssertionType` on the off action would mean "turn it off until turned off", which
    /// Shortcuts shows as a nonsense summary.
    func testOffOmitsTheAssertion() throws {
        let params = try parameters(
            FocusShortcut.plistData(recipe: recipe, focus: work, direction: .turnOff)
        )
        XCTAssertEqual(params["Enabled"] as? Int, 0)
        XCTAssertNil(params["AssertionType"])
    }

    /// `shortcuts sign` rejects an XML plist with the same error it gives for a wrong file
    /// extension, so a format regression here is expensive to diagnose from the outside.
    func testOutputIsABinaryPlist() throws {
        let data = try FocusShortcut.plistData(recipe: recipe, focus: work, direction: .turnOn)
        let header = try XCTUnwrap(String(bytes: data.prefix(6), encoding: .utf8))
        XCTAssertEqual(header, "bplist")
    }

    func testShippedRecipeDecodesAndMatchesTheFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Resources/focus-shortcut.json")
        let decoded = try JSONDecoder().decode(FocusShortcutRecipe.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.actionIdentifier, FocusShortcutRecipe.fallback.actionIdentifier)
        XCTAssertEqual(decoded.assertionTypeWhenOn, FocusShortcutRecipe.fallback.assertionTypeWhenOn)
        XCTAssertEqual(decoded.parameterKeys.enabled, FocusShortcutRecipe.fallback.parameterKeys.enabled)
    }

    /// Swift's synthesized `Decodable` ignores property defaults, which is how `teams-markers.json`
    /// silently failed to decode on first run. A recipe naming only the action must still decode.
    func testRecipeDecodesFromAMinimalObject() throws {
        let json = Data(#"{"actionIdentifier": "is.workflow.actions.dnd.other"}"#.utf8)
        let decoded = try JSONDecoder().decode(FocusShortcutRecipe.self, from: json)
        XCTAssertEqual(decoded.actionIdentifier, "is.workflow.actions.dnd.other")
        XCTAssertEqual(decoded.assertionTypeWhenOn, FocusShortcutRecipe.fallback.assertionTypeWhenOn)
    }
}
