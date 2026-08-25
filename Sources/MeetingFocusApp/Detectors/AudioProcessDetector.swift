import AppKit
import CoreAudio
import Foundation
import MeetingFocusCore

/// Detects meetings from microphone capture, attributed per process.
///
/// This is the tier that generalises: it covers Zoom, Slack, Discord and browser-based meetings
/// such as Google Meet with no per-application work, because it asks CoreAudio which processes
/// are capturing rather than inspecting anybody's UI.
///
/// Its evidence is `corroborating`, never `definitive`, for two reasons. Capturing the microphone
/// is not proof of a meeting, and — more importantly — *not* capturing is not proof of absence: a
/// muted participant may release the input stream. Where an application-specific detector exists,
/// its definitive verdict overrides this one.
///
/// The allowlist is what keeps always-on dictation and speech services out of the results. Both
/// `com.electron.wispr-flow` and `com.apple.CoreSpeech` were observed holding the microphone on
/// the development machine; neither is a meeting.
actor AudioProcessDetector: MeetingDetector {
    let id = "audio.process"

    private let allowlist: Set<String>
    private let pollInterval: Duration
    private var resolver = BundleIdentifierResolver()
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<MeetingEvidence>.Continuation?
    private let stream: AsyncStream<MeetingEvidence>
    /// Subjects reported as capturing last cycle, so absence can be reported explicitly.
    private var previouslyCapturing: Set<String> = []

    init(allowlist: Set<String>, pollInterval: Duration = .seconds(2)) {
        self.allowlist = allowlist
        self.pollInterval = pollInterval
        var escaped: AsyncStream<MeetingEvidence>.Continuation?
        stream = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    nonisolated var evidence: AsyncStream<MeetingEvidence> { stream }

    func start() async throws {
        guard task == nil else { return }
        Log.detector.info("audio detector starting, allowlist size \(self.allowlist.count)")
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(2))
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        Log.detector.info("audio detector stopped")
    }

    private func poll() {
        let now = Date()
        let capturing = capturingBundleIdentifiers()
        let matched = capturing.intersection(allowlist)

        for subject in matched {
            emit(subject: subject, verdict: .inMeeting, at: now)
        }
        // Anything that was capturing and no longer is gets an explicit absence, so the state
        // machine can act on it rather than waiting for evidence to go stale.
        for subject in previouslyCapturing.subtracting(matched) {
            emit(subject: subject, verdict: .notInMeeting, at: now)
        }
        previouslyCapturing = matched
    }

    private func emit(subject: String, verdict: Verdict, at now: Date) {
        continuation?.yield(
            MeetingEvidence(
                detectorID: id,
                subjectID: subject,
                verdict: verdict,
                confidence: .corroborating,
                applicationName: Self.displayName(forBundleIdentifier: subject),
                observedAt: now
            )
        )
    }

    // MARK: CoreAudio

    private func capturingBundleIdentifiers() -> Set<String> {
        let processes = Self.audioProcessObjects()
        var livePids: Set<pid_t> = []
        var result: Set<String> = []

        for process in processes {
            guard Self.uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            guard let pid = Self.pid(process) else { continue }
            livePids.insert(pid)
            if let bundleID = resolver.owningBundleIdentifier(pid: pid) {
                result.insert(bundleID)
            }
        }
        resolver.invalidate(keeping: livePids)
        return result
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The per-process audio API is public from macOS 14.4 onwards, and — verified — keeps working
    /// inside App Sandbox, which is what would make a future App Store build possible.
    private static func audioProcessObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { $0 != 0 }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    private static func displayName(forBundleIdentifier identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
