import XCTest
@testable import MeetingFocusCore

final class ShortcutListingTests: XCTestCase {
    func testParsesNameAndIdentifier() {
        let listings = ShortcutListing.parse("Fokus festlegen (BE0F32C3-A630-493B-AA2C-4264CF32012B)")
        XCTAssertEqual(listings.count, 1)
        XCTAssertEqual(listings.first?.name, "Fokus festlegen")
        XCTAssertEqual(listings.first?.identifier, "BE0F32C3-A630-493B-AA2C-4264CF32012B")
    }

    /// The reason this is parsed from the right rather than split on the first parenthesis: a user's
    /// own shortcut may well be called something like this, and taking the first bracket would both
    /// truncate the name and read "old" as an identifier.
    func testNameMayItselfContainParentheses() {
        let listings = ShortcutListing.parse("Backup (old) (6AFFC494-B9DF-4FE4-8164-E0E9C4B33A69)")
        XCTAssertEqual(listings.first?.name, "Backup (old)")
        XCTAssertEqual(listings.first?.identifier, "6AFFC494-B9DF-4FE4-8164-E0E9C4B33A69")
    }

    /// `shortcuts list` without `--show-identifiers` prints bare names, and so does an older tool.
    /// Those are still usable shortcuts — they just cannot be addressed by identifier.
    func testALineWithNoIdentifierIsStillAShortcut() {
        let listings = ShortcutListing.parse("Set Focus")
        XCTAssertEqual(listings.first?.name, "Set Focus")
        XCTAssertNil(listings.first?.identifier)
    }

    /// Anything shaped like a trailing bracket is not an identifier unless it is actually a UUID.
    func testTrailingParenthesesThatAreNotAUUIDStayPartOfTheName() {
        let listings = ShortcutListing.parse("Morning routine (v2)")
        XCTAssertEqual(listings.first?.name, "Morning routine (v2)")
        XCTAssertNil(listings.first?.identifier)
    }

    func testParsesSeveralLinesAndSkipsBlankOnes() {
        let output = """
            MeetingFocus – Fokus ein (006D6028-8C1A-4B60-BC4F-88E2F45E2E15)

            MeetingFocus – Fokus aus (6AFFC494-B9DF-4FE4-8164-E0E9C4B33A69)

            """
        let listings = ShortcutListing.parse(output)
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings.map(\.name), ["MeetingFocus – Fokus ein", "MeetingFocus – Fokus aus"])
    }

    func testIdentifierLookupIsByExactName() {
        let listings = ShortcutListing.parse("""
            MeetingFocus – Fokus ein (006D6028-8C1A-4B60-BC4F-88E2F45E2E15)
            MeetingFocus – Fokus aus (6AFFC494-B9DF-4FE4-8164-E0E9C4B33A69)
            """)
        XCTAssertEqual(
            listings.identifier(forName: "MeetingFocus – Fokus aus"),
            "6AFFC494-B9DF-4FE4-8164-E0E9C4B33A69"
        )
        XCTAssertNil(listings.identifier(forName: "MeetingFocus – Fokus"))
    }
}
