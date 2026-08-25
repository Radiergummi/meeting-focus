import AppKit
import ApplicationServices
import CoreAudio
import Foundation

// Correlates the two detection tiers against each other, once a second, so the project's
// highest-leverage unknown can be settled by measurement rather than argument:
//
//   does muting release the microphone input stream?
//
// If it does, every application worth supporting needs its own Accessibility detector, because the
// audio tier would report `notInMeeting` for any muted participant. If it does not, the audio tier
// covers Zoom, Slack, Meet and Discord correctly with no per-application work.
//
// The experiment: join a real call, run this, mute for ~15 seconds, unmute, leave. Teams is the
// subject because it is the only application whose Accessibility evidence is definitive — that is
// what makes "AX says in-call" a trustworthy control to measure the audio signal against.
//
// This replaces a one-off correlator that lived in a scratch directory and was lost. It lives here
// so that does not happen twice.

/// Set from a signal handler, so ctrl-c still prints the summary the run was taken for.
nonisolated(unsafe) var correlateInterrupted: Int32 = 0

/// One sampling tick: what each tier said at the same instant.
private struct Sample {
    var inCall: Bool
    var capturing: Bool
    var markers: Set<String>
    /// Capturing pids and the bundle identifier each resolved to, for the transcript.
    var capturingBy: [String]
    /// The mute control's own label. Localized, so it is a note in the log and never a signal —
    /// but it is what makes the transcript readable without relying on memory of the timeline.
    var micLabel: String?
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func audioProcessObjects() -> [AudioObjectID] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { $0 != 0 }
}

private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

private func processPID(_ object: AudioObjectID) -> pid_t? {
    var addr = address(kAudioProcessPropertyPID)
    var value: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
    return value
}

/// Deliberately shares `BundleIdentifierResolver` with the app rather than reimplementing the
/// lookup. CoreAudio reports Teams' helper (`com.microsoft.teams2.modulehost`), so without the
/// same walk-to-the-outermost-`.app` normalisation the two tiers would appear to disagree about
/// which application is capturing — which is precisely the thing being measured.
private func capturing(bundleID: String, resolver: inout BundleIdentifierResolver) -> [String] {
    var live: Set<pid_t> = []
    var matched: [String] = []
    for process in audioProcessObjects() {
        guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
        guard let pid = processPID(process) else { continue }
        live.insert(pid)
        guard resolver.owningBundleIdentifier(pid: pid) == bundleID else { continue }
        matched.append("\(pid)")
    }
    resolver.invalidate(keeping: live)
    return matched.sorted()
}

private func sample(
    bundleID: String,
    markers: Set<String>,
    micMarker: String,
    resolver: inout BundleIdentifierResolver
) -> Sample {
    var found: Set<String> = []
    var micLabel: String?
    if let (_, list) = windows(of: bundleID, quiet: true) {
        for window in list {
            walk(window, depth: 0, maxDepth: 80) { element, _ in
                guard let identifier = string(element, "AXDOMIdentifier") else { return }
                if markers.contains(identifier) { found.insert(identifier) }
                if identifier == micMarker {
                    micLabel = string(element, kAXDescriptionAttribute)
                        ?? string(element, kAXTitleAttribute)
                }
            }
        }
    }
    let capturingPIDs = capturing(bundleID: bundleID, resolver: &resolver)
    return Sample(
        inCall: !found.isEmpty,
        capturing: !capturingPIDs.isEmpty,
        markers: found,
        capturingBy: capturingPIDs,
        micLabel: micLabel
    )
}

/// What the run measured. Four cells rather than a boolean: "in a call but not capturing" is the
/// answer being looked for, and "capturing but not in a call" is the false positive the audio tier
/// can produce.
private struct Tally {
    var counts: [String: Int] = [:]
    var longestInCallIdle = 0
    var samples = 0

    var inCallSamples: Int { (counts["in-call/running"] ?? 0) + (counts["in-call/idle"] ?? 0) }
}

private func measure(
    bundleID: String,
    markers: Set<String>,
    micMarker: String,
    seconds: Int
) -> Tally {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    var resolver = BundleIdentifierResolver()
    var tally = Tally()
    var currentInCallIdle = 0
    var previousLine = ""

    for _ in 0..<seconds {
        if correlateInterrupted != 0 { break }
        let now = sample(bundleID: bundleID, markers: markers, micMarker: micMarker, resolver: &resolver)
        tally.samples += 1

        let cell = "\(now.inCall ? "in-call" : "no-call")/\(now.capturing ? "running" : "idle")"
        tally.counts[cell, default: 0] += 1
        if now.inCall && !now.capturing {
            currentInCallIdle += 1
            tally.longestInCallIdle = max(tally.longestInCallIdle, currentInCallIdle)
        } else {
            currentInCallIdle = 0
        }

        var line = "ax=\(now.inCall ? "in-call" : "no-call ")  input=\(now.capturing ? "running" : "idle   ")"
        if !now.capturingBy.isEmpty { line += "  pid=\(now.capturingBy.joined(separator: ","))" }
        if let label = now.micLabel { line += "  mic=\"\(label)\"" }
        line += "  markers=[\(now.markers.sorted().joined(separator: ","))]"
        // Only transitions, so a 15-second mute reads as two lines rather than fifteen.
        if line != previousLine {
            previousLine = line
            print("[\(formatter.string(from: Date()))] \(line)")
        }
        Thread.sleep(forTimeInterval: 1)
    }
    return tally
}

private func report(_ tally: Tally, bundleID: String) {
    print("\n─── \(tally.samples) sample(s), one per second ───")
    for cell in ["in-call/running", "in-call/idle", "no-call/running", "no-call/idle"] {
        print("  \(cell.padding(toLength: 16, withPad: " ", startingAt: 0))\(tally.counts[cell] ?? 0)")
    }

    print("")
    // Gated on having seen a call at all. Reporting "muting does not release the stream" from a run
    // that never saw a call would be a confident answer drawn from no evidence, which is worse than
    // no answer — and it is the exact mistake the unverified `joining` markers already record.
    if tally.inCallSamples == 0 {
        print("""
              INCONCLUSIVE: no sample saw an active call, so nothing was measured.
              Was a call actually joined, and do the markers still match?
              Check the ids with: axprobe ids \(bundleID)
              """)
    } else if tally.longestInCallIdle == 0 {
        print("""
              Input never went idle across \(tally.inCallSamples)s of confirmed call.
              If a mute of ~15s falls inside that window, muting does NOT release the input
              stream: the audio tier is then sound on its own, and per-application Accessibility
              detectors are optional polish rather than required.
              """)
    } else {
        print("""
              Input went idle while Accessibility reported an active call — longest run
              \(tally.longestInCallIdle)s, across \(tally.inCallSamples)s of confirmed call. If that run lines up
              with the mute, muting DOES release the stream, and every application worth
              supporting needs its own detector.
              """)
    }
    if let stray = tally.counts["no-call/running"], stray > 0 {
        print("""

              Note: \(stray) sample(s) captured with no call detected. Either the markers missed a
              state, or the application holds the microphone outside calls.
              """)
    }
}

func correlate(bundleID: String, markers: Set<String>, micMarker: String, seconds: Int) {
    print("""
        correlating \(bundleID) for up to \(seconds)s — ctrl-c to stop and print the summary

          ax     : any of \(markers.sorted().joined(separator: ", "))
          input  : kAudioProcessPropertyIsRunningInput, attributed to \(bundleID)

        Join a call, mute for ~15 seconds, unmute, then leave. What matters is whether `input`
        ever reads `idle` while `ax` reads `in-call`.
        """)

    signal(SIGINT) { _ in correlateInterrupted = 1 }
    report(measure(bundleID: bundleID, markers: markers, micMarker: micMarker, seconds: seconds),
           bundleID: bundleID)
}
