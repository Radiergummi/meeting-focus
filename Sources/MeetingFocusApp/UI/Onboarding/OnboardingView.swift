import MeetingFocusCore
import SwiftUI

struct OnboardingView: View {
    /// The steps, in order. `permission` and `focus` are skippable; the two copy-only ends are not,
    /// because there is nothing on them to skip.
    enum Step: Int, CaseIterable {
        case welcome, permission, focus, finish
    }

    @Bindable var settings: AppSettings
    @Bindable var monitor: MeetingMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var step: Step {
        Step(rawValue: settings.onboardingStep) ?? .welcome
    }

    var body: some View {
        VStack(spacing: 0) {
            indicator
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
        }
        .frame(width: 460, height: 380)
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { each in
                Circle()
                    .fill(each.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .permission: permission
        case .focus: OnboardingFocusStep(settings: settings, advance: advance)
        case .finish: finish
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to MeetingFocus")
                .font(.title2.weight(.semibold))
            Text("""
                It notices when you join a meeting and turns on a Focus for you, then turns it off \
                again when the meeting ends. Setting that up takes three short steps.
                """)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Get Started") { advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let MeetingFocus see your meetings")
                .font(.title2.weight(.semibold))
            // Deliberately not naming one app: per-app detectors are next, and copy naming Teams
            // would need rewriting the moment the second one lands.
            Text("""
                Accessibility permission lets MeetingFocus read the windows of your meeting apps, \
                which is how it can tell a real meeting from an open app. Without it, detection \
                falls back to microphone activity alone.
                """)
                .foregroundStyle(.secondary)
            if monitor.accessibilityTrusted {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Accessibility…") { AccessibilityAuthorization.requestIfNeeded() }
                Text("macOS asks you to confirm in System Settings. This window will tick when it is done.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy & Security…") { AccessibilityAuthorization.openSystemSettings() }
                    .buttonStyle(.link)
            }
            Spacer()
            HStack {
                Button("Later") { advance() }
                Spacer()
                Button("Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!monitor.accessibilityTrusted)
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You are set up")
                .font(.title2.weight(.semibold))
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    // A failure shows as the toggle bouncing back, because the value is re-read from
                    // the service rather than assumed. Settings → General reports the reason; this
                    // step deliberately does not grow an error label for the rare case.
                    try? LaunchAtLogin.setEnabled(newValue)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            ))
            Text("A meeting detector that is not running cannot detect anything.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            // An LSUIElement app has no Dock tile, so the icon is the only thing the user can look
            // for. Saying what its three states mean is cheaper than a support question.
            Text("""
                MeetingFocus lives in your menu bar. Its icon is hollow when you are not in a meeting, \
                dotted while you are joining, and filled during one.
                """)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done") {
                    settings.onboardingCompleted = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() {
        settings.onboardingStep = min(step.rawValue + 1, Step.finish.rawValue)
    }
}
