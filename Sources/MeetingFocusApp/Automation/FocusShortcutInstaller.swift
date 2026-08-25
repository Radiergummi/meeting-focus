import AppKit
import Foundation
import MeetingFocusCore

/// Generates a Focus shortcut, signs it with the user's own copy of Apple's tool, and hands it to
/// Shortcuts for the one confirmation macOS requires. Nothing here can add a shortcut silently —
/// there is no API to write to the Shortcuts library — so "install" is the honest word, not "done".
enum FocusShortcutInstaller {
    enum Failure: LocalizedError {
        case signing(String)
        case couldNotOpen

        var errorDescription: String? {
            switch self {
            case .signing(let message):
                message.isEmpty
                    ? String(localized: "The shortcut could not be signed.")
                    : message
            case .couldNotOpen:
                String(localized: "Shortcuts would not open the generated file.")
            }
        }
    }

    /// The imported shortcut takes its name from the filename, so these strings end up in the
    /// user's library permanently — which is why they are localized rather than fixed English.
    static func shortcutName(for direction: FocusShortcutDirection) -> String {
        switch direction {
        case .turnOn: String(localized: "MeetingFocus – Focus On")
        case .turnOff: String(localized: "MeetingFocus – Focus Off")
        }
    }

    static func install(direction: FocusShortcutDirection) throws {
        let recipe = loadRecipe()
        let data = try FocusShortcut.plistData(recipe: recipe, direction: direction)

        let directory = URL.temporaryDirectory.appending(path: "MeetingFocus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Both paths end in `.shortcut` because the signer rejects any other input extension with
        // the same error it gives for an XML plist. The output's *name* is the shortcut's name.
        let name = shortcutName(for: direction)
        let unsigned = directory.appending(path: "\(name).unsigned.shortcut")
        let signed = directory.appending(path: "\(name).shortcut")

        try data.write(to: unsigned)
        try sign(input: unsigned, output: signed)

        guard NSWorkspace.shared.open(signed) else { throw Failure.couldNotOpen }
        Log.automation.info("opened generated shortcut \(name, privacy: .public) for import")
    }

    /// Polls the library, because the import completes when the *user* confirms it and nothing
    /// notifies us. Bounded: a user who cancels must not leave a spinner running forever.
    static func awaitInstalled(names: [String], timeout: Duration = .seconds(90)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let available = Set(await ShortcutsAutomationHandler.availableShortcutNames())
            if names.allSatisfy(available.contains) { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private static func loadRecipe(from bundle: Bundle = .main) -> FocusShortcutRecipe {
        guard let url = bundle.url(forResource: "focus-shortcut", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FocusShortcutRecipe.self, from: data)
        else {
            Log.automation.error("focus-shortcut.json missing or unreadable; using built-in fallback")
            return .fallback
        }
        return decoded
    }

    private static func sign(input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = ShortcutsAutomationHandler.toolURL
        process.arguments = ["sign", "--mode", "anyone", "--input", input.path, "--output", output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = try? errors.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.automation.error("shortcuts sign failed: \(message, privacy: .public)")
            throw Failure.signing(message)
        }
    }
}
