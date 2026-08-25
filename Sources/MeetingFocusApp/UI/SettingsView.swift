import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var monitor: MeetingMonitor
    @State private var shortcutNames: [String] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Detectors") {
                Toggle("Microsoft Teams (Accessibility)", isOn: $settings.teamsDetectorEnabled)
                Text("Reads Teams' own meeting UI. The most accurate signal, and unaffected by muting.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Microphone activity (all apps)", isOn: $settings.audioDetectorEnabled)
                Text("""
                    Covers Zoom, Slack, Webex and browser meetings with no per-app setup. Coarser: \
                    it cannot read a meeting title, and a muted participant may not register.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permission") {
                HStack {
                    Image(systemName: monitor.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(monitor.accessibilityTrusted ? Color.green : Color.orange)
                    Text(monitor.accessibilityTrusted ? "Accessibility granted" : "Accessibility not granted")
                    Spacer()
                    if !monitor.accessibilityTrusted {
                        Button("Open Settings…") { AccessibilityAuthorization.openSystemSettings() }
                    }
                }
            }

            Section("Automation") {
                Toggle("Run Shortcuts on meeting changes", isOn: $settings.automationEnabled)
                shortcutPicker("When a meeting starts", selection: $settings.startShortcutName)
                shortcutPicker("When the last meeting ends", selection: $settings.endShortcutName)

                HStack {
                    // There is no public API to set a Focus mode, so a Shortcut is the only
                    // supported route. The least we can do is take the user to where they make one.
                    Text("To toggle a Focus, make a shortcut using the Set Focus action.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Shortcuts") {
                        if let url = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "com.apple.shortcuts"
                        ) {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }
                }

                VStack(alignment: .leading) {
                    Text("Wait \(Int(settings.endCooldownSeconds))s before running the end shortcut")
                    Slider(value: $settings.endCooldownSeconds, in: 0...180, step: 5)
                    Text("Back-to-back meetings are normal. Waiting avoids releasing your Focus during a short gap between two calls.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                ))
                if LaunchAtLogin.needsApproval {
                    HStack {
                        Text("Waiting for approval in Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open…") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Diagnostics") {
                Toggle("Debug mode (show recent detections in the menu)", isOn: $settings.debugMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task {
            shortcutNames = await ShortcutsAutomationHandler.availableShortcutNames()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// Offers real shortcut names where possible; typing is still allowed, since Shortcuts may be
    /// unavailable or the user may want to name one they have not created yet.
    private func shortcutPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            if shortcutNames.isEmpty {
                TextField("Shortcut name", text: selection).frame(width: 200)
            } else {
                Picker("", selection: selection) {
                    Text("None").tag("")
                    ForEach(shortcutNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }
}
