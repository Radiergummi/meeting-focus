import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var monitor: MeetingMonitor
    @State private var shortcutNames: [String] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Detection", systemImage: "eye") { detection }
            Tab("Automation", systemImage: "wand.and.rays") { automation }
            Tab("About", systemImage: "info.circle") { about }
        }
        // The window keeps one width across the tabs and takes its height from whichever is showing,
        // which is the convention every tabbed settings window on the system follows. Loading the
        // shortcut names here rather than on the Automation tab fetches them once per window instead
        // of on every visit to that tab.
        .task {
            shortcutNames = await ShortcutsAutomationHandler.availableShortcutNames()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    private var general: some View {
        Form {
            // No header: a "General" heading inside the General tab says nothing the tab has not.
            Section {
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

                Toggle("Show the menu bar icon", isOn: $settings.showMenuBarIcon)
                // Says the way back explicitly. Hiding the icon removes the app's only visible
                // surface, and a user who cannot find their way back reasonably concludes it broke.
                Text("""
                    Detection and automation keep running with the icon hidden. To bring it back, \
                    open MeetingFocus again from your Applications folder.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                // The gesture is invisible by design — it is the Wi-Fi menu's — so this is the one
                // place that says it out loud. Without the line, the read-out may as well not exist.
                Text("""
                    Hold ⌥ Option while opening the menu bar item to see which detectors are running \
                    and the last few detections.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private var detection: some View {
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
                    // Two calls rather than a ternary inside one: the coverage scan keys on the text
                    // immediately before a literal, and `Text(cond ? "a" : "b")` hides both from it.
                    if monitor.accessibilityTrusted {
                        Text("Accessibility granted")
                    } else {
                        Text("Accessibility not granted")
                    }
                    Spacer()
                    if !monitor.accessibilityTrusted {
                        Button("Open Settings…") { AccessibilityAuthorization.openSystemSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private var automation: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private var about: some View {
        Form {
            Section("This build") {
                LabeledContent("Version", value: BuildInfo.summary)
                if BuildInfo.isOfficialBuild, let url = BuildInfo.buildRunURL {
                    HStack {
                        Text("Built publicly from source")
                        Spacer()
                        Link("View build log", destination: url)
                    }
                    Text("""
                        This copy was built by a public GitHub Actions run from the commit above, and \
                        that run recorded a signed provenance attestation over the artifact. You can \
                        check it yourself:
                        """)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(BuildInfo.verificationCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("Locally built — no public build log or attestation for this copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Source code")
                    Spacer()
                    Link("GitHub", destination: BuildInfo.repositoryURL)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// Offers real shortcut names where possible; typing is still allowed, since Shortcuts may be
    /// unavailable or the user may want to name one they have not created yet.
    /// `LocalizedStringKey`, not `String`: `Text(String)` renders verbatim, so as a plain string the
    /// two row labels here had catalogue keys that were never looked up — green tests, English UI.
    private func shortcutPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
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
