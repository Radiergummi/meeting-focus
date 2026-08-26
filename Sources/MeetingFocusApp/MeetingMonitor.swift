import AppKit
import Foundation
import MeetingFocusCore
import Observation

/// Wires detectors, the state machine and automation together, and exposes state to the UI.
@MainActor
@Observable
final class MeetingMonitor {
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
        observeDetectorSettings()
    }

    // MARK: Lifecycle

    func start() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        accessibilityTrusted = AccessibilityAuthorization.isTrusted

        // Each disabled detector retracts what it previously said. Merely not starting it would
        // leave its last evidence in the machine to go stale, and stale evidence holds the previous
        // state rather than clearing it — see `MeetingStateMachine.retractEvidence`.
        if settings.teamsDetectorEnabled {
            let detector = TeamsAccessibilityDetector(markers: TeamsMarkers.load())
            teamsDetector = detector
            consume(detector.evidence)
            try? await detector.start()
        } else {
            machine.retractEvidence(fromDetector: TeamsAccessibilityDetector.detectorID)
        }
        if settings.audioDetectorEnabled {
            // Read here rather than once at launch, so that a user editing the override file only
            // has to toggle the detector rather than relaunch. See `AudioAllowlist.loadResolved`.
            let detector = AudioProcessDetector(allowlist: AudioAllowlist.loadResolved())
            audioDetector = detector
            consume(detector.evidence)
            try? await detector.start()
        } else {
            machine.retractEvidence(fromDetector: AudioProcessDetector.detectorID)
        }
        refresh()

        observeApplicationTermination()
        startTicking()
        Log.detector.info(
            "monitoring started, accessibility trusted: \(self.accessibilityTrusted, privacy: .public)"
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

    /// Makes the detector switches in Settings take effect when they are flipped, rather than at the
    /// next launch. Done here rather than in `SettingsView` so that it holds for *any* caller —
    /// onboarding is expected to grow the same switches, and a fix that lives in one view would not
    /// cover them.
    ///
    /// `withObservationTracking` reports only the first change, so this re-registers itself each
    /// time. The hop through a task is not incidental either: `onChange` runs *before* the new value
    /// is stored, so reacting synchronously would restart the detectors against the old setting.
    private func observeDetectorSettings() {
        withObservationTracking {
            _ = settings.teamsDetectorEnabled
            _ = settings.audioDetectorEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeDetectorSettings()
                guard self.isMonitoring else { return }
                await self.restart()
            }
        }
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
                // Kept fresh rather than asserted once: evidence has a TTL, and a claim that expires
                // leaves the machine holding a state nothing is saying any more.
                if self.manualMeeting { self.assertManualMeeting() }
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

    // MARK: The switch

    /// Whether the user has declared a meeting by hand. Not persisted: a meeting someone switched on
    /// is over by the time the app is next launched.
    private(set) var manualMeeting = false

    private static let manualDetectorID = "manual"

    /// Says whether the user is in a meeting, in the user's own voice.
    ///
    /// On is evidence rather than a second opinion: a definitive claim goes into the same machine the
    /// detectors feed, so automation, the status row and the detection log treat it exactly as they
    /// treat a detected call, and `aggregateState` stays the one answer to the question.
    ///
    /// Off both withdraws that claim and dismisses whatever the detectors are still asserting, which
    /// is why this is a method rather than a settable flag: turning the switch off while Teams is
    /// mid-call has to do something even though no *manual* meeting exists to withdraw. "Not in a
    /// meeting" is a statement about the user, and it outranks every detector for exactly as long as
    /// the call it was said about — see `MeetingStateMachine.dismissActiveMeetings`.
    func setInMeeting(_ inMeeting: Bool) {
        manualMeeting = inMeeting
        if inMeeting {
            assertManualMeeting()
        } else {
            machine.retractEvidence(fromDetector: Self.manualDetectorID)
            machine.dismissActiveMeetings()
            // Dismissing ends the meeting, but automation would still hold that end for `endCooldown`
            // and leave the user's Focus mode on for another 45 seconds. The cooldown is there for the
            // gap between back-to-back meetings; it is not for someone saying they are done.
            coordinator.endImmediately()
        }
        refresh()
    }

    private func assertManualMeeting() {
        machine.ingest(MeetingEvidence(
            detectorID: Self.manualDetectorID,
            subjectID: Self.manualDetectorID,
            verdict: .inMeeting,
            confidence: .definitive,
            // Named, because this is what the menu and the detection log call it.
            applicationName: String(localized: "Manual meeting"),
            observedAt: Date()
        ))
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

    /// Recorded unconditionally: twenty strings cost nothing, and the alternative — a setting that
    /// has to be switched on before the log starts filling — means the one detection someone wants to
    /// explain has already happened by the time they go looking for it.
    private func note(_ message: String) {
        recentEvents.insert("\(Self.timeFormatter.string(from: Date()))  \(message)", at: 0)
        recentEvents = Array(recentEvents.prefix(20))
    }

    private func perform(_ command: AutomationCommand) {
        guard settings.automationEnabled else { return }
        let handler = ShortcutsAutomationHandler(
            startShortcutName: settings.startShortcutName,
            endShortcutName: settings.endShortcutName,
            startShortcutIdentifier: settings.startShortcutIdentifier,
            endShortcutIdentifier: settings.endShortcutIdentifier,
            onFailure: { [weak self] name, error in
                Task { @MainActor [weak self] in
                    self?.lastAutomationError = "\(name): \(error.localizedDescription)"
                }
            },
            // Otherwise one transient failure stays on screen until the app is relaunched.
            onSuccess: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.lastAutomationError = nil
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
