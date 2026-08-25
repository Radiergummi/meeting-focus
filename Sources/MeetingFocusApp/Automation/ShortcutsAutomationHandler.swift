import Foundation
import MeetingFocusCore

/// Runs user-configured Shortcuts when meeting state changes.
///
/// Uses the `shortcuts` command line tool rather than the `shortcuts://run-shortcut` URL scheme.
/// The URL scheme reports nothing back, so a misspelled shortcut name would fail silently and the
/// user would simply believe the app is broken; the tool returns an exit status we can surface.
/// App Intents was also considered, but offers no public way to run an arbitrary *user* shortcut
/// by name.
///
/// Note this requires the application to be non-sandboxed, which it already is — the Accessibility
/// API requires the same.
struct ShortcutsAutomationHandler: AutomationHandler {
    enum Failure: Error, LocalizedError {
        case notConfigured
        case toolMissing
        case exited(code: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No shortcut name is configured."
            case .toolMissing: "The shortcuts command line tool is unavailable."
            case .exited(let code, let message):
                "Shortcut failed (exit \(code))" + (message.isEmpty ? "" : ": \(message)")
            }
        }
    }

    static let toolURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

    var startShortcutName: String?
    var endShortcutName: String?
    var onFailure: (@Sendable (String, Error) -> Void)?

    func meetingStarted(_ meeting: Meeting) async {
        await run(named: startShortcutName, reason: "meeting started")
    }

    func meetingEnded(_ meeting: Meeting) async {
        await run(named: endShortcutName, reason: "meeting ended")
    }

    private func run(named name: String?, reason: String) async {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            Log.automation.debug("\(reason): no shortcut configured, skipping")
            return
        }
        do {
            try await Self.run(shortcutNamed: name)
            Log.automation.info("\(reason): ran shortcut")
        } catch {
            Log.automation.error("\(reason): shortcut failed: \(error.localizedDescription)")
            onFailure?(name, error)
        }
    }

    static func run(shortcutNamed name: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else { throw Failure.toolMissing }

        let process = Process()
        process.executableURL = toolURL
        process.arguments = ["run", name]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // Do not let a hung shortcut wedge the automation queue.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if process.isRunning { process.terminate() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        timeout.cancel()

        guard process.terminationStatus == 0 else {
            let data = try? errorPipe.fileHandleForReading.readToEnd()
            let message = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.exited(code: process.terminationStatus, message: message)
        }
    }

    /// Used by Settings to offer real shortcut names instead of asking the user to type one.
    static func availableShortcutNames() async -> [String] {
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else { return [] }
        let process = Process()
        process.executableURL = toolURL
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted() ?? []
    }
}
