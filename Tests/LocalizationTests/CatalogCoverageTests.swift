import Foundation
import Testing

/// Guards the rule `project.yml` states beside the settings that make it true: a String Catalogue key
/// must match its Swift literal character-for-character, or the German silently falls back to English.
/// Nothing warns — not the compiler, and not `xcodebuild`, which with `SWIFT_EMIT_LOC_STRINGS: NO`
/// does not extract keys at all.
///
/// Both directions are checked, because they fail differently. A literal with no key renders English
/// under a German locale; a key with no literal is dead weight that makes the catalogue look like it
/// covers more than it does. Neither is visible to anyone testing in English.
///
/// Lives in a test target rather than a script so `make test` enforces it, and in Swift because this
/// repo does not do Python.
/// Internal, not private: `CatalogIntegrityTests` walks the same tree from the same anchor, and a
/// second copy of this expression is a second thing to get wrong when the suite moves.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A localizable literal and a catalogue key are compared as SHAPES: every interpolation on one side
/// and every format specifier on the other collapses to this sentinel. `\(count)` becomes `%lld` and
/// `\(name)` becomes `%@`, and which one is a matter of the interpolated TYPE — knowable to the
/// compiler, not to a source scan. Comparing shapes sidesteps that without weakening anything else:
/// the surrounding characters still have to agree exactly.
///
/// App Intents' `Summary`/`IntentDialog` interpolations (`\(\.$state)`) extract to a third spelling,
/// `${state}` rather than a printf specifier — the parameter's own name, not its type. Collapsed the
/// same way, for the same reason.
private let placeholder = "\u{1}"

private func shape(catalogKey key: String) -> String {
    var out = key
    for specifier in ["%lld", "%lf", "%@", "%d", "%f"] {
        out = out.replacingOccurrences(of: specifier, with: placeholder)
    }
    out = out.replacingOccurrences(of: "\\$\\{[^}]*\\}", with: placeholder, options: .regularExpression)
    return out
}

// MARK: - Which literals are localizable

/// The call sites whose string argument is localized. Deliberately a list rather than "every string
/// literal": most literals in this codebase are bundle identifiers, log messages and marker ids, none
/// of which belong in a catalogue.
///
/// A name missing from this list means its literals are never *required* to have a key, so they pass
/// silently — not, as an earlier version of this comment claimed, that they surface as a dead key.
/// Adding a localizing helper here is the only thing that enforces its callers.
private let localizingContexts = [
    "Text", "Label", "Button", "Toggle", "Picker", "Section", "Link", "Menu", "Stepper", "Tab",
    "TextField", "SecureField", "LabeledContent", "ContentUnavailableView", "LocalizedStringKey",
    "LocalizedStringResource", "LocalizationValue", "Summary", "IntentDescription", "IntentDialog",
]
private let localizingLabels = [
    "localized", "titleKey", "title", "prompt", "header", "footer", "value", "message", "detail",
]
/// This project's own helpers that take a `LocalizedStringKey`. Such a helper is a localizing site
/// every bit as much as `Text(` is, and without it named here its callers' literals would look like
/// plain strings to this scan.
private let localizingHelpers = ["shortcutPicker"]
private let localizingModifiers = [
    "help", "navigationTitle", "navigationSubtitle", "accessibilityLabel", "confirmationDialog",
    "alert", "searchable",
]
/// `static let title: LocalizedStringResource = "…"` — a literal assigned to a localized TYPE rather
/// than passed to any initializer.
private let localizingTypes = ["LocalizedStringResource", "LocalizedStringKey"]

/// `before` ends with `pattern`, and — when the pattern starts with an identifier character — what
/// precedes it does not continue that identifier.
///
/// The boundary check is the whole point, and its absence was a real bug rather than a hypothetical
/// one. A bare `hasSuffix("Picker(")` matches `shortcutPicker(`, so a helper taking a plain `String`
/// read as a localizing site: its callers' literals were required to have keys, the keys existed, the
/// suite was green, and the strings rendered English under every locale. A false *pass* is the one
/// direction this scan must never fail in, because nothing downstream catches it.
///
/// Patterns that begin with punctuation — `.help(`, `: LocalizedStringKey = ` — need no check: a `.`
/// or a `:` cannot be the middle of an identifier, and requiring a non-identifier before the dot
/// would reject the `foo.help(` that modifiers are always written as.
private func endsWithToken(_ before: Substring, _ pattern: String) -> Bool {
    guard before.hasSuffix(pattern) else { return false }
    guard let first = pattern.first, first.isLetter || first == "_" else { return true }
    let patternStart = before.index(before.endIndex, offsetBy: -pattern.count)
    guard patternStart > before.startIndex else { return true }
    let previous = before[before.index(before: patternStart)]
    return !(previous.isLetter || previous.isNumber || previous == "_")
}

private func isLocalizingSite(_ before: Substring) -> Bool {
    if localizingContexts.contains(where: { endsWithToken(before, "\($0)(") }) { return true }
    if localizingHelpers.contains(where: { endsWithToken(before, "\($0)(") }) { return true }
    if localizingModifiers.contains(where: { endsWithToken(before, ".\($0)(") }) { return true }
    if localizingTypes.contains(where: { endsWithToken(before, ": \($0) = ") }) { return true }
    return localizingLabels.contains { endsWithToken(before, "\($0): ") || endsWithToken(before, "\($0):") }
}

// MARK: - Reading Swift string literals

/// Hand-written rather than regex because the literals that matter here defeat one: interpolations
/// nest parentheses and can themselves contain quotes (`\(x, format: .foo("bar"))`), and several
/// strings in this codebase are multi-line literals joined by trailing backslashes.
private struct LiteralScanner {
    let characters: [Character]

    /// Past a `\(…)` interpolation, including any string literals nested inside it.
    func endOfInterpolation(from start: Int) -> Int {
        var cursor = start, depth = 0
        while cursor < characters.count {
            switch characters[cursor] {
            case "(": depth += 1
            case ")": depth -= 1; if depth == 0 { return cursor + 1 }
            case "\"":
                cursor += 1
                while cursor < characters.count, characters[cursor] != "\"" {
                    cursor += characters[cursor] == "\\" ? 2 : 1
                }
            default: break
            }
            cursor += 1
        }
        return cursor
    }

    /// An escape sequence's contribution to the literal's value, and where scanning resumes.
    func escape(at index: Int) -> (text: String, next: Int) {
        let escaped = characters[index + 1]
        if escaped == "(" { return (placeholder, endOfInterpolation(from: index + 1)) }
        if escaped == "\n" {
            // A continuation joins two source lines; the indentation that follows is layout, not copy.
            var cursor = index + 2
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            return ("", cursor)
        }
        return (escaped == "n" ? "\n" : String(escaped), index + 2)
    }

    /// The literal beginning at `start` (already past its opening quote), and where it ends.
    func literal(from start: Int, isMultiline: Bool) -> (value: String, next: Int) {
        var index = start, value = ""
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                let (text, next) = escape(at: index)
                value += text
                index = next
                continue
            }
            if characters[index] == "\"" {
                guard isMultiline else { return (value, index + 1) }
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    return (value, index + 3)
                }
            }
            if !isMultiline, characters[index] == "\n" { return (value, index) }   // unterminated
            value.append(characters[index])
            index += 1
        }
        return (value, index)
    }
}

/// Every string literal in `source`, paired with the text preceding it.
private func literals(in source: String) -> [(before: Substring, value: String)] {
    let scanner = LiteralScanner(characters: Array(source))
    var results: [(Substring, String)] = []
    var index = 0
    while index < scanner.characters.count {
        guard scanner.characters[index] == "\"" else { index += 1; continue }
        let start = index
        let isMultiline = index + 2 < scanner.characters.count
            && scanner.characters[index + 1] == "\"" && scanner.characters[index + 2] == "\""
        let (value, next) = scanner.literal(from: index + (isMultiline ? 3 : 1), isMultiline: isMultiline)
        results.append((source.prefix(start), isMultiline ? collapsed(value) : value))
        index = next
    }
    return results
}

/// A multi-line literal as the catalogue stores it: one line, indentation dropped.
private func collapsed(_ value: String) -> String {
    value.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - Gathering

private func swiftFiles(under directory: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func catalogKeys(at url: URL) throws -> Set<String> {
    let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
    return Set((root?["strings"] as? [String: Any] ?? [:]).keys)
}

/// Every literal in the target's sources, localizable or not. The DEAD-key direction uses this rather
/// than the localizing-site filter: a key whose text appears nowhere is dead beyond argument, while
/// one built by a runtime mapping is perfectly alive and simply not attributable to a call site.
private func allLiteralShapes(inSourcesUnder directory: URL) -> Set<String> {
    var shapes: Set<String> = []
    for file in swiftFiles(under: directory) {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for (_, value) in literals(in: source) where !value.isEmpty { shapes.insert(value) }
    }
    return shapes
}

private func localizedShapes(inSourcesUnder directory: URL) -> Set<String> {
    var shapes: Set<String> = []
    for file in swiftFiles(under: directory) {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        // A shape with no letters is punctuation or bare interpolation — "…", "\(a)\(b)" — and has no
        // copy to translate. Requiring a catalogue entry for those would be noise, not coverage.
        for (before, value) in literals(in: source)
        where isLocalizingSite(before) && value.contains(where: \.isLetter) {
            shapes.insert(value)
        }
    }
    return shapes
}

// MARK: - The checks

/// Internal, not private: Swift Testing's `arguments:` puts the type in the test function's signature,
/// and a private type there is a compile error.
struct CatalogTarget: Sendable {
    let name: String
    let sources: String
    let catalog: String
    /// Keys deliberately in the catalogue with no literal, or literals deliberately uncatalogued. Each
    /// needs a reason — an allowlist without one becomes the place findings go to be forgotten.
    let allowedDeadKeys: Set<String>
    let allowedMissingKeys: Set<String>
}

/// Internal, not private: `CatalogIntegrityTests` checks a different set of invariants over exactly
/// these targets, and two lists of catalogues would drift the moment a second target appears.
let catalogTargets = [
    CatalogTarget(
        name: "MeetingFocusApp",
        sources: "Sources/MeetingFocusApp",
        catalog: "Sources/MeetingFocusApp/Localizable.xcstrings",
        allowedDeadKeys: [],
        allowedMissingKeys: []
    ),
]

@Test(arguments: catalogTargets)
func everyCatalogKeyIsRenderedBySomeLiteral(target: CatalogTarget) throws {
    let keys = try catalogKeys(at: repositoryRoot.appendingPathComponent(target.catalog))
    let present = allLiteralShapes(inSourcesUnder: repositoryRoot.appendingPathComponent(target.sources))
    // Same vacuity guard as the sibling test, in the other direction: `dead` is also empty when the
    // literal scan finds nothing.
    #expect(!keys.isEmpty, """
        \(target.name): read 0 keys from \(target.catalog) — the catalogue reader is broken, not the catalogue
        """)
    #expect(!present.isEmpty, """
        \(target.name): the literal scan found 0 shapes — the scan is broken, not the source
        """)

    let dead = Set(keys.map(shape(catalogKey:))).subtracting(present)
        .subtracting(target.allowedDeadKeys.map(shape(catalogKey:)))
    #expect(dead.isEmpty, """
        \(target.name): \(dead.count) catalogue key(s) render nowhere — delete them, or add to \
        allowedDeadKeys with a reason: \(dead.sorted())
        """)
}

@Test(arguments: catalogTargets)
func everyRenderedLiteralHasACatalogKey(target: CatalogTarget) throws {
    let keys = try catalogKeys(at: repositoryRoot.appendingPathComponent(target.catalog))
    let rendered = localizedShapes(inSourcesUnder: repositoryRoot.appendingPathComponent(target.sources))
    // Guard the guard. `missing` is a set subtraction, so it is empty both when every literal has a key
    // AND when the SCAN found no literals at all — a refactor that moved views, renamed a directory, or
    // broke the literal scanner would turn this into a permanently green no-op. Assert the inputs exist
    // before trusting the difference between them.
    #expect(!keys.isEmpty, """
        \(target.name): read 0 keys from \(target.catalog) — the catalogue reader is broken, not the catalogue
        """)
    #expect(!rendered.isEmpty, """
        \(target.name): the literal scan under \(target.sources) found 0 shapes — the scan is broken, not the source
        """)

    let missing = rendered.subtracting(keys.map(shape(catalogKey:)))
        .subtracting(target.allowedMissingKeys)
    #expect(missing.isEmpty, """
        \(target.name): \(missing.count) literal(s) have no catalogue key and will render English under \
        every locale: \(missing.sorted())
        """)
}
