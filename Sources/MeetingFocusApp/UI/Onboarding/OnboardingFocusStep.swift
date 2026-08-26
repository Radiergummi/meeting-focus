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
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                Button(installed ? "Continue" : "Install Shortcuts") {
                    if installed { advance() } else { install() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(installing)
            }
        )
        // Seeds `installed` from what's actually configured rather than assuming a fresh `false`:
        // that's true both when we installed our own pair, and when the user already has some
        // automation of their own — so we never offer to overwrite a working setup, whether that's
        // ours from before a back-navigation, or one they configured by hand before onboarding
        // existed. Trade-off, stated honestly: someone with *some* automation configured will not be
        // offered our Do Not Disturb pair from onboarding. Settings → Automation is where they would
        // change it. That's the right default — silently replacing a working configuration is worse
        // than not offering an optional convenience.
        .task { installed = settings.isAutomationConfigured }
    }

    private func install() {
        failure = nil
        installing = true
        let names = [
            FocusShortcutInstaller.shortcutName(for: .turnOn),
            FocusShortcutInstaller.shortcutName(for: .turnOff),
        ]
        Task {
            let existing = await ShortcutsAutomationHandler.availableShortcuts()
            do {
                // Install only what is actually missing. Shortcuts does not replace by name, it
                // appends " 1" — so a retry after one direction timed out used to add a second copy
                // of the direction that had already succeeded, and ask the user to confirm an Add
                // they had already given.
                if !isPresent(names[0], storedIdentifier: settings.startShortcutIdentifier, among: existing) {
                    try FocusShortcutInstaller.install(direction: .turnOn)
                }
                if !isPresent(names[1], storedIdentifier: settings.endShortcutIdentifier, among: existing) {
                    try FocusShortcutInstaller.install(direction: .turnOff)
                }
            } catch {
                failure = error.localizedDescription
                installing = false
                return
            }
            if await FocusShortcutInstaller.awaitInstalled(names: names) {
                let listings = await ShortcutsAutomationHandler.availableShortcuts()
                // The whole point: the user never types a shortcut name.
                settings.startShortcutName = names[0]
                settings.endShortcutName = names[1]
                // Identity recorded separately from the display name, so that renaming either
                // shortcut in Shortcuts — or running the app in another language — does not
                // silently break the automation. See `AppSettings.startShortcutIdentifier`.
                settings.startShortcutIdentifier = listings.identifier(forName: names[0]) ?? ""
                settings.endShortcutIdentifier = listings.identifier(forName: names[1]) ?? ""
                installed = true
            } else {
                failure = String(localized: "The shortcuts were not added. You can try again, or set them up in Settings.")
            }
            installing = false
        }
    }

    /// Whether one direction's shortcut is already in the user's library.
    ///
    /// The identifier is checked first and the name second, because the name is the half that
    /// moves: it is localized, so the pair installed under a different system language carries
    /// names this launch would never recognise, and the user is free to rename either in Shortcuts.
    private func isPresent(
        _ name: String,
        storedIdentifier: String,
        among listings: [ShortcutListing]
    ) -> Bool {
        if !storedIdentifier.isEmpty, listings.contains(where: { $0.identifier == storedIdentifier }) {
            return true
        }
        return listings.contains { $0.name == name }
    }
}
