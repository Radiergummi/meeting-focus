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

    private var label: String {
        switch state {
        case .inMeeting: "In a meeting"
        case .joining: "Joining a meeting"
        case .idle: "Not in a meeting"
        }
    }
}

struct MenuBarView: View {
    @Bindable var monitor: MeetingMonitor
    @Bindable var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow

            if !monitor.accessibilityTrusted {
                Divider()
                permissionWarning
            }

            if let meeting = monitor.activeMeetings.first {
                Divider()
                Text(meeting.title ?? meeting.applicationName)
                    .font(.system(size: 12, weight: .medium))
                Text("\(meeting.applicationName) · started \(Self.time(meeting.startedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if monitor.activeMeetings.count > 1 {
                    Text("+\(monitor.activeMeetings.count - 1) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            row("Monitoring", monitor.isMonitoring)
            row("Automation", settings.isAutomationConfigured)

            if let error = monitor.lastAutomationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if settings.debugMode, !monitor.recentEvents.isEmpty {
                Divider()
                ForEach(monitor.recentEvents.prefix(5), id: \.self) { line in
                    Text(line).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",")
            Button("Quit MeetingFocus") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText).font(.system(size: 13, weight: .semibold))
        }
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Accessibility permission required")
                .font(.system(size: 12, weight: .medium))
            Text("MeetingFocus reads Teams' own window contents to tell whether you are in a meeting. Without this it falls back to microphone activity only.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open Privacy & Security…") {
                AccessibilityAuthorization.openSystemSettings()
            }
        }
    }

    private var statusColor: Color {
        switch monitor.aggregateState {
        case .inMeeting: .green
        case .joining: .orange
        case .idle: .secondary
        }
    }

    private var statusText: String {
        switch monitor.aggregateState {
        case .inMeeting: "In a meeting"
        case .joining: "Joining…"
        case .idle: "Not in a meeting"
        }
    }

    private func row(_ title: String, _ enabled: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Image(systemName: enabled ? "checkmark" : "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        }
    }

    private static func time(_ date: Date) -> String {
        MeetingMonitor.timeFormatter.string(from: date).prefix(5).description
    }
}
