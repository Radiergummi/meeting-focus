import MeetingFocusCore
import SwiftUI

struct OnboardingFocusStep: View {
    @Bindable var settings: AppSettings
    let advance: () -> Void
    let back: () -> Void

    @State private var installing = false
    @State private var installed = false
    @State private var failure: String?

    /// Kept as a stored constant rather than inlined in a ternary: the catalogue coverage scan keys
    /// off the text immediately before a literal, and `? ` / `: ` match no localizing site, so an
    /// inline ternary would make both branches look like dead keys to the scan.
    private let pendingMessage: LocalizedStringKey = """
        MeetingFocus will add two shortcuts — one to turn Do Not Disturb on when a \
        meeting starts, one to turn it off when it ends — and Shortcuts will ask you to \
        confirm each.
        """

    private let installedMessage: LocalizedStringKey =
        "Both shortcuts are ready. MeetingFocus will run them when a meeting starts and ends."

    var body: some View {
        OnboardingPage(
            symbol: "moon.fill",
            title: "Turn on Do Not Disturb for meetings",
            message: installed ? installedMessage : pendingMessage,
            // There is no way to read which Focus modes exist without Full Disk Access, so the
            // shortcut ships set to Do Not Disturb. Saying where to change it is the honest
            // alternative to pretending we offered a choice. Once installed there is nothing left
            // to prefer, so the row goes away with the rest of the setup copy.
            rows: installed ? [] : [
                OnboardingRow(
                    symbol: "slider.horizontal.3",
                    title: "Prefer a different Focus?",
                    detail: "Open Shortcuts afterwards and tap the Focus name in either shortcut."
                ),
            ],
            back: back,
            actions: {
                if installing {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to add them…").font(.caption).foregroundStyle(.secondary)
                } else if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                } else if installed {
                    Label("Shortcuts installed and selected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Spacer()
                Button("Later") { advance() }
                Button(installed ? "Continue" : "Install Shortcuts") {
                    if installed { advance() } else { install() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(installing)
            }
        )
    }

    private func install() {
        failure = nil
        installing = true
        let names = [
            FocusShortcutInstaller.shortcutName(for: .turnOn),
            FocusShortcutInstaller.shortcutName(for: .turnOff),
        ]
        Task {
            do {
                try FocusShortcutInstaller.install(direction: .turnOn)
                try FocusShortcutInstaller.install(direction: .turnOff)
            } catch {
                failure = error.localizedDescription
                installing = false
                return
            }
            if await FocusShortcutInstaller.awaitInstalled(names: names) {
                // The whole point: the user never types a shortcut name.
                settings.startShortcutName = names[0]
                settings.endShortcutName = names[1]
                installed = true
            } else {
                failure = String(localized: "The shortcuts were not added. You can try again, or set them up in Settings.")
            }
            installing = false
        }
    }
}
