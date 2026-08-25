import AppKit
import Foundation
import MeetingFocusCore
import Observation

/// Wires detectors, the state machine and automation together, and exposes state to the UI.
@MainActor
@Observable
final class MeetingMonitor {
    /// Applications whose microphone use is treated as evidence of a meeting. Scoped deliberately:
    /// an unfiltered "is the microphone in use" check matches dictation and speech services —
    /// `com.electron.wispr-flow` and `com.apple.CoreSpeech` were both observed holding the
    /// microphone on the development machine, and neither is a meeting.
    static let defaultAudioAllowlist: Set<String> = [
        "com.microsoft.teams2",
        "us.zoom.xos",
        "com.tinyspeck.slackmacgap",
        "Cisco-Systems.Spark",
        "com.webex.meetingmanager",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
    ]

    private(set) var aggregateState: MeetingState = .idle
    private(set) var activeMeetings: [Meeting] = []
    private(set) var isMonitoring = false
    private(set) var accessibilityTrusted = AccessibilityAuthorization.isTrusted
    private(set) var lastAutomationError: String?
    private(set) var recentEvents: [String] = []

    private let settings: AppSettings
    private let timeSource: TimeSource = SystemTimeSource()
    private var machine: MeetingStateMachine!
    private var coordinator: AutomationCoordinator!
    private var teamsDetector: TeamsAccessibilityDetector?
    private var audioDetector: AudioProcessDetector?
    private var tasks: [Task<Void, Never>] = []
    private var tickTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        machine = MeetingStateMachine(timeSource: timeSource) { [weak self] event in
            self?.handle(event)
        }
        coordinator = AutomationCoordinator(
            configuration: .init(endCooldown: settings.endCooldownSeconds),
            timeSource: timeSource
        ) { [weak self] command in
            self?.perform(command)
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        accessibilityTrusted = AccessibilityAuthorization.isTrusted

        if settings.teamsDetectorEnabled {
            let detector = TeamsAccessibilityDetector(markers: TeamsMarkers.load())
            teamsDetector = detector
            consume(detector.evidence)
            try? await detector.start()
        }
        if settings.audioDetectorEnabled {
            let detector = AudioProcessDetector(allowlist: Self.defaultAudioAllowlist)
            audioDetector = detector
            consume(detector.evidence)
            try? await detector.start()
        }

        observeApplicationTermination()
        startTicking()
        Log.detector.info(
            "monitoring started, accessibility trusted: \(self.accessibilityTrusted), teams detector: \(self.settings.teamsDetectorEnabled), audio detector: \(self.settings.audioDetectorEnabled)"
        )
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        tickTask?.cancel()
        tickTask = nil
        await teamsDetector?.stop()
        await audioDetector?.stop()
        teamsDetector = nil
        audioDetector = nil
        isMonitoring = false
        Log.detector.info("monitoring stopped")
    }

    func restart() async {
        await stop()
        await start()
    }

    private func consume(_ stream: AsyncStream<MeetingEvidence>) {
        tasks.append(Task { [weak self] in
            for await evidence in stream {
                guard let self else { return }
                self.machine.ingest(evidence)
                self.refresh()
            }
        })
    }

    /// Debounces and cooldowns are evaluated on a tick rather than with per-transition timers, so
    /// the same code path is exercised by the unit tests.
    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.machine.tick()
                self.coordinator.tick()
                self.refresh()
            }
        }
    }

    private func observeApplicationTermination() {
        let center = NSWorkspace.shared.notificationCenter
        tasks.append(Task { [weak self] in
            let notifications = center.notifications(named: NSWorkspace.didTerminateApplicationNotification)
            for await notification in notifications {
                guard let self else { return }
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { continue }
                // Authoritative: no process, no meeting. No grace period applies.
                self.machine.applicationTerminated(subjectID: bundleID)
                self.refresh()
            }
        })
    }

    // MARK: State

    private func refresh() {
        aggregateState = machine.aggregateState
        activeMeetings = machine.activeMeetings
        accessibilityTrusted = AccessibilityAuthorization.isTrusted
        coordinator.update(isInMeeting: machine.isInMeeting, activeMeeting: machine.activeMeetings.first)
    }

    private func handle(_ event: MeetingEvent) {
        switch event {
        case .started(let meeting):
            Log.state.info("meeting started via \(meeting.detectorID)")
            note("Started: \(meeting.title ?? meeting.applicationName)")
        case .ended(let meeting):
            Log.state.info("meeting ended via \(meeting.detectorID)")
            note("Ended: \(meeting.title ?? meeting.applicationName)")
        }
    }

    private func note(_ message: String) {
        guard settings.debugMode else { return }
        recentEvents.insert("\(Self.timeFormatter.string(from: Date()))  \(message)", at: 0)
        recentEvents = Array(recentEvents.prefix(20))
    }

    private func perform(_ command: AutomationCommand) {
        guard settings.automationEnabled else { return }
        let handler = ShortcutsAutomationHandler(
            startShortcutName: settings.startShortcutName,
            endShortcutName: settings.endShortcutName,
            onFailure: { [weak self] name, error in
                Task { @MainActor [weak self] in
                    self?.lastAutomationError = "\(name): \(error.localizedDescription)"
                }
            }
        )
        Task {
            switch command {
            case .meetingStarted(let meeting): await handler.meetingStarted(meeting)
            case .meetingEnded(let meeting): await handler.meetingEnded(meeting)
            }
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
