import Foundation

/// One row of `shortcuts list --show-identifiers`, which prints `Name (UUID)` per line.
///
/// Parsing lives here, away from the process plumbing that produces the text, because the awkward
/// part is the string rather than the subprocess: a shortcut's *name* may contain parentheses too,
/// so the identifier has to be recognised from the right and confirmed to be a UUID rather than
/// assumed from the first bracket.
public struct ShortcutListing: Sendable, Equatable {
    public let name: String
    /// Nil when the line carried no identifier — a bare `shortcuts list`, or a tool old enough not
    /// to offer `--show-identifiers`. Such a shortcut is still perfectly runnable, just only by
    /// name, which is what the fallback in `ShortcutsAutomationHandler` exists for.
    public let identifier: String?

    public init(name: String, identifier: String?) {
        self.name = name
        self.identifier = identifier
    }

    public static func parse(_ output: String) -> [ShortcutListing] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(parseLine)
    }

    private static func parseLine(_ line: String) -> ShortcutListing {
        guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else {
            return ShortcutListing(name: line, identifier: nil)
        }
        let inner = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        // The UUID check is what keeps "Morning routine (v2)" a name rather than half a name and a
        // nonsense identifier.
        guard UUID(uuidString: inner) != nil else {
            return ShortcutListing(name: line, identifier: nil)
        }
        let name = line[line.startIndex..<open].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return ShortcutListing(name: line, identifier: nil) }
        return ShortcutListing(name: name, identifier: inner)
    }
}

public extension Array where Element == ShortcutListing {
    /// Exact-match only. A prefix or case-insensitive match would be a guess, and picking the wrong
    /// shortcut silently runs the wrong automation.
    func identifier(forName name: String) -> String? {
        first { $0.name == name }?.identifier
    }
}
