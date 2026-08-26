import AppKit
import ApplicationServices
import Foundation

// A diagnostic tool for re-deriving accessibility markers when detection breaks.
//
// This is the tool the Teams investigation was done with. It is kept in the repository because
// vendor element ids change: when detection stops working, dumping the live tree is how the new
// ids get found, and guessing is how weeks get wasted.
//
//   axprobe dump      <bundle-id> [maxDepth]  print the accessibility tree
//   axprobe ids       <bundle-id>             print every element exposing an AXDOMIdentifier
//   axprobe watch     <bundle-id> [markers…]  poll and report when the marker set changes
//   axprobe correlate <bundle-id> [seconds]   sample AX in-call state against microphone capture

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let text = value as? String, !text.isEmpty
    else { return nil }
    return text
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
    else { return [] }
    return (value as? [AXUIElement]) ?? []
}

/// `quiet` suppresses the diagnostics for callers that poll: correlate samples once a second for
/// minutes at a time, and a per-sample complaint would bury the measurement it is taking.
func windows(of bundleID: String, quiet: Bool = false) -> (pid: pid_t, windows: [AXUIElement])? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        if !quiet { FileHandle.standardError.write(Data("\(bundleID) is not running\n".utf8)) }
        return nil
    }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement]
    else {
        if !quiet {
            FileHandle.standardError.write(
                Data("could not read windows — is Accessibility permission granted?\n".utf8))
        }
        return nil
    }
    return (app.processIdentifier, list)
}

func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, visit: (AXUIElement, Int) -> Void) {
    guard depth <= maxDepth else { return }
    visit(element, depth)
    for child in children(element) { walk(child, depth: depth + 1, maxDepth: maxDepth, visit: visit) }
}

/// How many elements under these windows expose an `AXDOMIdentifier` of any kind.
///
/// This is the measurement that tells a *dormant* Chromium web tree apart from an application that
/// simply has no call on screen. Zero is not "no meeting", it is "cannot see" — the distinction the
/// app itself draws by reporting `indeterminate`, and the one this tool used to miss entirely.
func domIdentifierCount(_ list: [AXUIElement], maxDepth: Int = 80) -> Int {
    var count = 0
    for window in list {
        walk(window, depth: 0, maxDepth: maxDepth) { element, _ in
            if string(element, "AXDOMIdentifier") != nil { count += 1 }
        }
    }
    return count
}

/// Reads an application's windows, waking a dormant web tree first if there is one.
///
/// For the commands that scan exactly once. `AccessibilityWake.request` returns before the tree
/// fills in, so waking and immediately re-reading still sees nothing — hence the wait, and hence
/// this being separate from the polling callers, which get the same effect for free on their next
/// tick and must not stall for three seconds mid-measurement.
func windowsWakingIfDormant(of bundleID: String) -> (pid: pid_t, windows: [AXUIElement])? {
    guard let first = windows(of: bundleID) else { return nil }
    guard domIdentifierCount(first.windows) == 0 else { return first }

    note("""
        no element exposes an AXDOMIdentifier — the web tree is dormant, not empty.
        Requesting accessibility and re-reading in \(Int(AccessibilityWake.settlingTime))s…
        """)
    AccessibilityWake.request(pid: first.pid)
    Thread.sleep(forTimeInterval: AccessibilityWake.settlingTime)

    guard let second = windows(of: bundleID) else { return first }
    if domIdentifierCount(second.windows) == 0 {
        note("""
            still nothing. Either this application does not publish a web tree, or it refused.
            Anything reported below describes a tree that cannot be seen — do not read an empty
            result as an absence of markers.
            """)
    }
    return second
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func dump(bundleID: String, maxDepth: Int) {
    guard let (pid, list) = windowsWakingIfDormant(of: bundleID) else { exit(1) }
    print("\(bundleID) pid \(pid), \(list.count) window(s)")
    for (index, window) in list.enumerated() {
        print("\n### window[\(index)] \"\(string(window, kAXTitleAttribute) ?? "-")\"")
        walk(window, depth: 0, maxDepth: maxDepth) { element, depth in
            let role = string(element, kAXRoleAttribute) ?? "?"
            var line = String(repeating: "  ", count: depth) + role
            if let subrole = string(element, kAXSubroleAttribute) { line += "[\(subrole)]" }
            // AXDOMIdentifier is the useful part: it is the HTML id, and it is not localized.
            if let identifier = string(element, "AXDOMIdentifier") { line += "  #\(identifier)" }
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let value = string(element, attribute) {
                    line += "  \(attribute.dropFirst(2))=\"\(value.prefix(80))\""
                }
            }
            print(line)
        }
    }
}

func identifiers(bundleID: String) {
    guard let (_, list) = windowsWakingIfDormant(of: bundleID) else { exit(1) }
    var seen: [String: String] = [:]
    for window in list {
        walk(window, depth: 0, maxDepth: 80) { element, _ in
            guard let identifier = string(element, "AXDOMIdentifier") else { return }
            let label = string(element, kAXDescriptionAttribute)
                ?? string(element, kAXTitleAttribute)
                ?? string(element, kAXRoleAttribute) ?? ""
            seen[identifier] = label
        }
    }
    print("\(seen.count) element(s) exposing AXDOMIdentifier:\n")
    for key in seen.keys.sorted() { print("  \(key)  —  \(seen[key] ?? "")") }
}

func watch(bundleID: String, markers: Set<String>) {
    print("watching \(bundleID) for \(markers.sorted().joined(separator: ", ")) — ctrl-c to stop")
    var previous = ""
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    while true {
        var found: Set<String> = []
        var nodes = 0
        var identifiers = 0
        if let (pid, list) = windows(of: bundleID) {
            for window in list {
                walk(window, depth: 0, maxDepth: 80) { element, _ in
                    nodes += 1
                    guard let identifier = string(element, "AXDOMIdentifier") else { return }
                    identifiers += 1
                    if markers.contains(identifier) { found.insert(identifier) }
                }
            }
            // No wait here, deliberately: the next tick reads the woken tree.
            if identifiers == 0 { AccessibilityWake.request(pid: pid) }
        }
        let line = "nodes \(nodes)  dom \(identifiers)  found [\(found.sorted().joined(separator: ","))]"
        if line != previous {
            previous = line
            print("[\(formatter.string(from: Date()))] \(line)")
        }
        Thread.sleep(forTimeInterval: 2)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard AXIsProcessTrusted() else {
    print("""
        Accessibility permission is not granted to this tool's parent process.
        Grant it in System Settings → Privacy & Security → Accessibility, then retry.
        """)
    exit(1)
}
switch arguments.first {
case "dump":
    guard arguments.count >= 2 else { print("usage: axprobe dump <bundle-id> [maxDepth]"); exit(2) }
    dump(bundleID: arguments[1], maxDepth: arguments.count > 2 ? Int(arguments[2]) ?? 60 : 60)
case "ids":
    guard arguments.count >= 2 else { print("usage: axprobe ids <bundle-id>"); exit(2) }
    identifiers(bundleID: arguments[1])
case "watch":
    guard arguments.count >= 2 else { print("usage: axprobe watch <bundle-id> [markers…]"); exit(2) }
    let markers = arguments.count > 2
        ? Set(arguments.dropFirst(2))
        : ["call-duration-custom", "hangup-button", "microphone-button", "video-button"]
    watch(bundleID: arguments[1], markers: markers)
case "correlate":
    guard arguments.count >= 2 else { print("usage: axprobe correlate <bundle-id> [seconds]"); exit(2) }
    // The in-call marker set only, deliberately: correlate needs a trustworthy "is in a call"
    // control, and the pre-join markers are still unverified.
    correlate(
        bundleID: arguments[1],
        markers: ["call-duration-custom", "hangup-button", "microphone-button", "video-button"],
        micMarker: "microphone-button",
        seconds: arguments.count > 2 ? Int(arguments[2]) ?? 300 : 300
    )
default:
    print("""
        axprobe — accessibility diagnostics for MeetingFocus

          axprobe dump      <bundle-id> [maxDepth]  print the accessibility tree
          axprobe ids       <bundle-id>             list every AXDOMIdentifier exposed
          axprobe watch     <bundle-id> [markers…]  report when the marker set changes
          axprobe correlate <bundle-id> [seconds]   AX in-call state vs microphone capture

        Example: axprobe ids com.microsoft.teams2
                 axprobe correlate com.microsoft.teams2 300
        """)
}
