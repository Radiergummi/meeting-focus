import MeetingFocusCore
import SwiftUI

/// `MenuBarExtra`'s content is only instantiated when the menu is opened, so monitoring cannot be
/// started from a view without tying it to the user clicking the icon. The application delegate
/// owns the long-lived objects and starts monitoring exactly once at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) lazy var monitor = MeetingMonitor(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask once at launch; if it is refused the app degrades to microphone-only detection and
        // the menu explains how to grant it later.
        if !AccessibilityAuthorization.isTrusted {
            AccessibilityAuthorization.requestIfNeeded()
        }
        // Instantiating the updater starts its scheduled background checks.
        _ = Updater.shared
        Task { await monitor.start() }
    }

    /// The way back from a hidden menu bar icon. An `LSUIElement` app with the icon hidden has no
    /// Dock tile and no window, so opening it again from Finder — which lands here, because it is
    /// already running — is the only gesture a user has left. Restoring the icon is what makes
    /// hiding it a safe thing to offer at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !settings.showMenuBarIcon {
            settings.showMenuBarIcon = true
            Log.state.info("menu bar icon restored by reopen")
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await monitor.stop() }
    }
}

@main
struct MeetingFocusApp: App {
    static let onboardingWindowID = "onboarding"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        @Bindable var settings = delegate.settings

        MenuBarExtra(isInserted: $settings.showMenuBarIcon) {
            MenuBarView(monitor: delegate.monitor, settings: delegate.settings)
        } label: {
            MenuBarLabel(state: delegate.monitor.aggregateState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: delegate.settings, monitor: delegate.monitor)
        }

        Window("Set Up MeetingFocus", id: Self.onboardingWindowID) {
            OnboardingView(settings: delegate.settings, monitor: delegate.monitor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Opening itself on a fresh install is the whole point; on a configured one it must stay
        // shut, and `.suppressed` is what keeps a `Window` scene from being created at launch.
        .defaultLaunchBehavior(delegate.settings.onboardingCompleted ? .suppressed : .presented)
    }
}
