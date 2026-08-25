import ApplicationServices
import AppKit

/// `AXUIElement` is a CoreFoundation type with no `Sendable` conformance, but the Accessibility
/// API is safe to call from a single consistent context. This box lets elements cross isolation
/// boundaries so scanning can happen off the main actor; all use stays inside one actor.
struct AXElement: @unchecked Sendable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }

    init(pid: pid_t) { self.raw = AXUIElementCreateApplication(pid) }

    func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, attribute as CFString, &value) == .success,
              let string = value as? String, !string.isEmpty
        else { return nil }
        return string
    }

    var children: [AXElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, kAXChildrenAttribute as CFString, &value) == .success,
              let raw = value as? [AXUIElement]
        else { return [] }
        return raw.map(AXElement.init)
    }

    /// `nil` means the window list could not be read at all, which is materially different from an
    /// application that genuinely has no windows.
    var windows: [AXElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, kAXWindowsAttribute as CFString, &value) == .success,
              let raw = value as? [AXUIElement]
        else { return nil }
        return raw.map(AXElement.init)
    }
}

/// Wraps the Accessibility permission, which is the only permission this application needs.
enum AccessibilityAuthorization {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Only meaningful once per launch; afterwards the user must use
    /// System Settings, which is why the UI also offers `openSystemSettings()`.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        // The `kAXTrustedCheckOptionPrompt` global is not concurrency-safe to reference; its
        // value is this documented, stable key string.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
