import MeetingFocusCore
import SwiftUI

struct OnboardingFocusStep: View {
    @Bindable var settings: AppSettings
    let advance: () -> Void

    @State private var installing = false
    @State private var installed = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn on Do Not Disturb for meetings")
                .font(.title2.weight(.semibold))

            if installed {
                Label("Shortcuts installed and selected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                // Said before the first sheet appears, because two confirmations in a row with no
                // warning reads as a glitch.
                Text("""
                    MeetingFocus will add two shortcuts — one to turn Do Not Disturb on when a \
                    meeting starts, one to turn it off when it ends — and Shortcuts will ask you to \
                    confirm each.
                    """)
                    .foregroundStyle(.secondary)
                // There is no way to read which Focus modes exist without Full Disk Access, so the
                // shortcut ships set to Do Not Disturb. Saying where to change it is the honest
                // alternative to pretending we offered a choice.
                Text("Prefer a different Focus? Open Shortcuts afterwards and tap the Focus name in either shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
                if installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to add them…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Later") { advance() }
                Spacer()
                Button(installed ? "Continue" : "Install Shortcuts") {
                    if installed { advance() } else { install() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(installing)
            }
        }
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
