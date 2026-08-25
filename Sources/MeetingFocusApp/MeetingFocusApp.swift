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
        Task { await monitor.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await monitor.stop() }
    }
}

@main
struct MeetingFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: delegate.monitor, settings: delegate.settings)
        } label: {
            MenuBarLabel(state: delegate.monitor.aggregateState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: delegate.settings, monitor: delegate.monitor)
        }
    }
}
