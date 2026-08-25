import MeetingFocusCore
import SwiftUI

/// `MenuBarExtra`'s content is only instantiated when the menu is opened, so monitoring cannot be
/// started from a view without tying it to the user clicking the icon. The application delegate
/// owns the long-lived objects and starts monitoring exactly once at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) lazy var monitor = MeetingMonitor(settings: settings)
    /// Decided once per launch, before any scene reads it.
    private(set) lazy var presentsOnboarding = settings.claimOnboardingPresentation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliberately does not ask for Accessibility. A permission dialog with no explanation in
        // front of it gets refused; the onboarding window's permission step asks instead, and the
        // menu and Settings both offer it afterwards.
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

    // Without this, AppKit's default is to quit once the onboarding window closes — which the
    // menu bar icon and background monitoring must survive. That default went unnoticed until now
    // because the onboarding window's own dismissal was silently broken (see `OnboardingPage`).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Opening itself on a fresh install is the whole point; on a configured one it must stay
        // shut, and `.suppressed` is what keeps a `Window` scene from being created at launch.
        .defaultLaunchBehavior(delegate.presentsOnboarding ? .presented : .suppressed)
    }
}
