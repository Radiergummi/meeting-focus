import MeetingFocusCore
import SwiftUI

struct OnboardingView: View {
    /// The steps, in order. `permission` and `focus` are skippable; the two copy-only ends are not,
    /// because there is nothing on them to skip.
    enum Step: Int {
        case welcome, permission, focus, finish
    }

    @Bindable var settings: AppSettings
    @Bindable var monitor: MeetingMonitor
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var step: Step {
        Step(rawValue: settings.onboardingStep) ?? .welcome
    }

    var body: some View {
        content
            .background(WindowChrome())
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .permission: permission
        case .focus: OnboardingFocusStep(settings: settings, advance: advance, back: back)
        case .finish: finish
        }
    }

    private var welcome: some View {
        OnboardingPage(
            glyph: .appIcon,
            title: "Welcome to MeetingFocus",
            message: "It notices when you join a meeting and turns on a Focus for you, then turns it off again when the meeting ends.",
            rows: [
                OnboardingRow(
                    symbol: "eye",
                    title: "Detects meetings on its own",
                    detail: "Watches your meeting apps and your microphone, with no calendar and no account."
                ),
                OnboardingRow(
                    symbol: "moon.fill",
                    title: "Silences distractions",
                    detail: "Runs a Shortcut when a meeting starts and ends. MeetingFocus can set one up for you."
                ),
                OnboardingRow(
                    symbol: "lock.fill",
                    title: "Stays on this Mac",
                    detail: "Nothing it detects is uploaded, stored or shared."
                ),
            ]
        ) {
            Spacer()
            Button("Get Started") { advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }

    private var permission: some View {
        // Deliberately does not name Teams, or any other meeting app: per-app detectors are the next
        // piece of work, and once a second one lands this copy would need rewriting the moment it
        // singled one out.
        OnboardingPage(
            glyph: .symbol("accessibility"),
            title: "Let MeetingFocus see your meetings",
            message: """
                Accessibility permission lets MeetingFocus read the windows of your meeting apps, \
                which is how it can tell a real meeting from an open app. Without it, detection \
                falls back to microphone activity alone.
                """,
            back: { back() },
            actions: {
                if monitor.accessibilityTrusted {
                    Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Spacer()
                    Button("Continue") { advance() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                } else {
                    Button("Later") { advance() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    Spacer()
                    Button("Open Privacy & Security…") { AccessibilityAuthorization.openSystemSettings() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    Button("Grant Accessibility…") { AccessibilityAuthorization.requestIfNeeded() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
            }
        )
    }

    private var finish: some View {
        OnboardingPage(
            glyph: .symbol("checkmark.circle.fill"),
            title: "You are set up",
            message: "MeetingFocus lives in your menu bar and starts working straight away.",
            rows: [
                // This is an `LSUIElement` app with no Dock tile, so the menu bar icon is the only
                // thing a user can look at to tell what state it's in — worth spelling out here.
                OnboardingRow(
                    symbol: "menubar.arrow.up.rectangle",
                    title: "Watch the menu bar icon",
                    detail: "Hollow when you are not in a meeting, dotted while you are joining, filled during one."
                ),
                OnboardingRow(
                    symbol: "gearshape",
                    title: "Change anything later",
                    detail: "Detectors and automation are in Settings; this setup is in the menu bar."
                ),
            ],
            back: { back() },
            actions: {
                // On failure the toggle simply bounces back rather than growing an error label: the
                // value is re-read from the service instead of assumed, and Settings → General
                // reports the reason, so this rare case doesn't need its own explanation here.
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        try? LaunchAtLogin.setEnabled(newValue)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Done") {
                    settings.onboardingCompleted = true
                    dismissWindow()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        )
    }

    private func advance() {
        settings.onboardingStep = min(step.rawValue + 1, Step.finish.rawValue)
    }

    private func back() {
        settings.onboardingStep = max(0, step.rawValue - 1)
    }
}
