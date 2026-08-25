import AppKit
import Foundation
import MeetingFocusCore

/// Detects Microsoft Teams meetings by inspecting the application's own accessibility tree.
///
/// Matching is done exclusively on `AXDOMIdentifier` — the underlying HTML element id that
/// Chromium exposes. Never on titles, descriptions or role descriptions: the development machine
/// ran a German UI, where the meeting controls read "Besprechungssteuerung" and the leave button
/// "Verlassen". Any string-based detector would work only in English.
///
/// Evidence from this detector is `definitive`, because it observes the meeting UI directly and is
/// therefore unaffected by whether the microphone happens to be muted.
actor TeamsAccessibilityDetector: MeetingDetector {
    let id = "teams.accessibility"

    private struct Scan {
        var verdict: Verdict = .notInMeeting
        var title: String?
        var startedAt: Date?
        var nodesVisited = 0
        var matchedMarkers: [String] = []
        /// True when a window looked like a meeting but produced no markers — the signature of
        /// Microsoft having renamed their element ids.
        var suspectedMarkerBreakage = false
    }

    private let markers: TeamsMarkers
    private let pollIntervalIdle: Duration
    private let pollIntervalActive: Duration
    private let stream: AsyncStream<MeetingEvidence>
    private var continuation: AsyncStream<MeetingEvidence>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var observer: AXChangeObserver?
    private var lastVerdict: Verdict = .notInMeeting

    /// Bounded generously on purpose. Observed whole-application node counts ranged from 250 to
    /// 3,479 depending on what the main window displayed; a cap tuned to the small case truncates
    /// the large one and produces a false negative. Cost is controlled by early exit instead.
    private let maxNodes = 25_000
    private let maxDepth = 70

    init(
        markers: TeamsMarkers,
        pollIntervalIdle: Duration = .seconds(5),
        pollIntervalActive: Duration = .seconds(2)
    ) {
        self.markers = markers
        self.pollIntervalIdle = pollIntervalIdle
        self.pollIntervalActive = pollIntervalActive
        var escaped: AsyncStream<MeetingEvidence>.Continuation?
        stream = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    nonisolated var evidence: AsyncStream<MeetingEvidence> { stream }

    var bundleIdentifiers: [String] { markers.bundleIdentifiers }

    func start() async throws {
        guard pollTask == nil else { return }
        Log.detector.info("teams accessibility detector starting")
        await attachObserver()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        if let observer { await MainActor.run { observer.stop() } }
        observer = nil
        continuation?.finish()
        Log.detector.info("teams accessibility detector stopped")
    }

    /// Called by the accessibility observer to shorten the gap before a change is noticed.
    func rescanSoon() {
        Task { _ = self.pollOnce() }
    }

    private func attachObserver() async {
        guard let pid = runningApplication()?.processIdentifier else { return }
        let observer = AXChangeObserver()
        self.observer = observer
        await MainActor.run {
            observer.start(pid: pid) { [weak self] in
                guard let self else { return }
                Task { await self.rescanSoon() }
            }
        }
    }

    private func runningApplication() -> NSRunningApplication? {
        markers.bundleIdentifiers
            .lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .first
    }

    /// Returns the interval before the next poll, so an active meeting is watched more closely.
    @discardableResult
    private func pollOnce() -> Duration {
        let now = Date()

        guard let application = runningApplication() else {
            emit(verdict: .notInMeeting, title: nil, startedAt: nil, at: now)
            return pollIntervalIdle
        }

        guard AccessibilityAuthorization.isTrusted else {
            // Not knowing is not the same as knowing there is no meeting.
            emit(verdict: .indeterminate, title: nil, startedAt: nil, at: now)
            return pollIntervalIdle
        }

        let scan = scanTree(pid: application.processIdentifier, now: now)

        if scan.suspectedMarkerBreakage {
            Log.detector.warning(
                "Teams window looks like a meeting but no markers matched — element ids may have changed"
            )
        }
        // Element ids and counts are not user data, so they are logged publicly. The meeting
        // title is: it stays redacted so meeting subjects never reach a sysdiagnose.
        let markerList = scan.matchedMarkers.joined(separator: ",")
        Log.detector.debug("teams scan: verdict \(String(describing: scan.verdict), privacy: .public), nodes \(scan.nodesVisited, privacy: .public), markers [\(markerList, privacy: .public)], hasTitle \(scan.title != nil, privacy: .public)")
        if scan.verdict != lastVerdict {
            Log.state.info("teams verdict \(String(describing: self.lastVerdict), privacy: .public) -> \(String(describing: scan.verdict), privacy: .public), markers [\(markerList, privacy: .public)], nodes \(scan.nodesVisited, privacy: .public)")
            lastVerdict = scan.verdict
        }

        emit(verdict: scan.verdict, title: scan.title, startedAt: scan.startedAt, at: now)
        return scan.verdict == .inMeeting ? pollIntervalActive : pollIntervalIdle
    }

    private func emit(verdict: Verdict, title: String?, startedAt: Date?, at now: Date) {
        guard let subject = markers.bundleIdentifiers.first else { return }
        continuation?.yield(
            MeetingEvidence(
                detectorID: id,
                subjectID: subject,
                verdict: verdict,
                confidence: .definitive,
                applicationName: markers.applicationName,
                title: title,
                startedAt: startedAt,
                observedAt: now
            )
        )
    }

    // MARK: Tree scanning

    private func scanTree(pid: pid_t, now: Date) -> Scan {
        var scan = Scan()
        let application = AXElement(pid: pid)

        guard let windows = application.windows else {
            scan.verdict = .indeterminate
            return scan
        }

        let inMeetingMarkers = markers.inMeeting.all
        let joiningMarkers = markers.joining.all
        var joiningSeen = false
        var nodes = 0

        for window in windows {
            var matchedInWindow: [String] = []
            var durationText: String?

            func walk(_ element: AXElement, depth: Int) {
                if nodes >= maxNodes || depth > maxDepth { return }
                nodes += 1

                if let identifier = element.string("AXDOMIdentifier") {
                    if inMeetingMarkers.contains(identifier) {
                        matchedInWindow.append(identifier)
                    }
                    if joiningMarkers.contains(identifier) {
                        joiningSeen = true
                    }
                    if identifier == markers.durationElementID {
                        durationText = Self.numericDuration(in: element)
                    }
                }
                for child in element.children { walk(child, depth: depth + 1) }
            }
            walk(window, depth: 0)

            if !matchedInWindow.isEmpty {
                scan.verdict = .inMeeting
                scan.matchedMarkers.append(contentsOf: matchedInWindow)
                scan.title = Self.meetingTitle(from: window.string(kAXTitleAttribute), markers: markers)
                if let durationText, let elapsed = Self.seconds(fromDuration: durationText) {
                    scan.startedAt = now.addingTimeInterval(-elapsed)
                }
            }
        }

        scan.nodesVisited = nodes
        if scan.verdict != .inMeeting && joiningSeen {
            scan.verdict = .joining
        }
        return scan
    }

    /// The duration element's own title is localized ("Verstrichene Zeit 47:13"), so the bare
    /// numeric value is read from its descendant text instead.
    private static func numericDuration(in element: AXElement) -> String? {
        var found: String?
        func walk(_ node: AXElement, depth: Int) {
            if found != nil || depth > 6 { return }
            if let value = node.string(kAXValueAttribute), seconds(fromDuration: value) != nil {
                found = value
                return
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(element, depth: 0)
        return found
    }

    /// Parses `mm:ss` or `hh:mm:ss` without touching locale-dependent text.
    static func seconds(fromDuration text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard part.count <= 2, let value = Int(part), value >= 0, value < 60 || part == parts.first else {
                return nil
            }
            total = total * 60 + TimeInterval(value)
        }
        return total
    }

    static func meetingTitle(from windowTitle: String?, markers: TeamsMarkers) -> String? {
        guard var title = windowTitle else { return nil }
        for suffix in markers.titleSuffixesToStrip where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
