import MeetingFocusCore
import SwiftUI

struct MenuBarLabel: View {
    let state: MeetingState

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .inMeeting: "video.fill"
        case .joining: "video.badge.ellipsis"
        case .idle: "video"
        }
    }

    /// `LocalizedStringKey`, not `String`: `accessibilityLabel` resolves a `String` verbatim, so as
    /// plain text this would have stayed English for every VoiceOver user. Each case below therefore
    /// needs a catalogue key.
    private var label: LocalizedStringKey {
        switch state {
        case .inMeeting: "In a meeting"
        case .joining: "Joining a meeting"
        case .idle: "Not in a meeting"
        }
    }
}

/// Menu items, not a laid-out view. `.menuBarExtraStyle(.menu)` maps each child of this body onto an
/// `NSMenuItem`, which is what gives the rows a hover highlight, the separators their hairline, and
/// the buttons below their real key equivalents — ⌘, does nothing at all in a `.window`-style menu,
/// where the content is just SwiftUI in a panel. The cost is that nothing here may be a container:
/// a `VStack` would arrive as one item holding a stack, and layout modifiers are ignored. Content
/// that needs more than a line of text belongs in Settings.
struct MenuBarView: View {
    @Bindable var monitor: MeetingMonitor
    @Bindable var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(statusText, systemImage: statusSymbol)
        activeMeeting
        Divider()
        state
        debugEvents
        Divider()
        actions
    }

    @ViewBuilder private var activeMeeting: some View {
        if let meeting = monitor.activeMeetings.first {
            Divider()
            // A title is whatever the meeting is called, so it is shown verbatim rather than as a
            // catalogue key.
            Text(meeting.title ?? meeting.applicationName)
            Text("\(meeting.applicationName) · started \(Self.time(meeting.startedAt))")
            if monitor.activeMeetings.count > 1 {
                Text("+\(monitor.activeMeetings.count - 1) more")
            }
        }
    }

    /// Switches rather than read-outs. A row carrying a tick nobody can click reads as a broken
    /// checkbox, and both of these states have something behind them the user is allowed to change:
    /// `Toggle` renders as a native checkmark item and actually means it.
    @ViewBuilder private var state: some View {
        Toggle("Monitoring", isOn: Binding(
            get: { monitor.isMonitoring },
            set: { enabled in Task { enabled ? await monitor.start() : await monitor.stop() } }
        ))
        Toggle("Automation", isOn: $settings.automationEnabled)
        // Automation can be on and still do nothing, which the old tick reported as a cross and left
        // the user to work out. Naming the missing piece is more use than reporting it.
        if settings.automationEnabled, !settings.isAutomationConfigured {
            Button("Choose Shortcuts…") { showSettings() }
        }
        if let error = monitor.lastAutomationError {
            Text(error)
        }
        if !monitor.accessibilityTrusted {
            // The paragraph explaining why the permission matters cannot live in a menu item; it is
            // in Settings, beside the detector this permission feeds.
            Button {
                AccessibilityAuthorization.openSystemSettings()
            } label: {
                Label("Grant Accessibility permission…", systemImage: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder private var debugEvents: some View {
        if settings.debugMode, !monitor.recentEvents.isEmpty {
            // A submenu, so a stream of log lines cannot push the actions below off the bottom of
            // the screen.
            Menu("Recent detections") {
                ForEach(monitor.recentEvents.prefix(10), id: \.self) { Text($0) }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Set Up MeetingFocus…") { showOnboarding() }
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Button("Settings…") { showSettings() }
            .keyboardShortcut(",")
        Button("Quit MeetingFocus") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// `openSettings()` on its own opens the window behind whatever the user was looking at, and
    /// leaves an already-open one buried: `LSUIElement` puts the app under the accessory activation
    /// policy, where opening a window never activates the app. Activating has to follow the window
    /// existing, hence the hop to the next run-loop pass.
    private func showSettings() {
        openSettings()
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    private func showOnboarding() {
        openWindow(id: MeetingFocusApp.onboardingWindowID)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    /// `LocalizedStringKey` for the same reason as `MenuBarLabel.label`: `Text(String)` renders
    /// verbatim, and this is the most prominent string in the menu.
    private var statusText: LocalizedStringKey {
        switch monitor.aggregateState {
        case .inMeeting: "In a meeting"
        case .joining: "Joining…"
        case .idle: "Not in a meeting"
        }
    }

    /// Shape, not colour: a menu item's image is drawn as a template, so the green dot the old
    /// popover used would arrive as a grey one. Filled, dashed and hollow read apart in monochrome.
    private var statusSymbol: String {
        switch monitor.aggregateState {
        case .inMeeting: "circle.fill"
        case .joining: "circle.dashed"
        case .idle: "circle"
        }
    }

    private static func time(_ date: Date) -> String {
        MeetingMonitor.timeFormatter.string(from: date).prefix(5).description
    }
}
