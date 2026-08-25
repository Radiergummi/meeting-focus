import Foundation
import Observation

/// User configuration. `UserDefaults` only — the brief explicitly rules out a database, and there
/// is nothing here that needs one.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let teamsDetectorEnabled = "teamsDetectorEnabled"
        static let audioDetectorEnabled = "audioDetectorEnabled"
        static let automationEnabled = "automationEnabled"
        static let startShortcutName = "startShortcutName"
        static let endShortcutName = "endShortcutName"
        static let endCooldownSeconds = "endCooldownSeconds"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let debugMode = "debugMode"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingStep = "onboardingStep"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.teamsDetectorEnabled: true,
            Key.audioDetectorEnabled: true,
            Key.automationEnabled: true,
            Key.endCooldownSeconds: 45.0,
            Key.showMenuBarIcon: true,
            Key.debugMode: false,
            Key.onboardingCompleted: false,
            Key.onboardingStep: 0,
        ])
        // Initialised directly so the `didSet` observers below do not fire during init.
        teamsDetectorEnabled = defaults.bool(forKey: Key.teamsDetectorEnabled)
        audioDetectorEnabled = defaults.bool(forKey: Key.audioDetectorEnabled)
        automationEnabled = defaults.bool(forKey: Key.automationEnabled)
        startShortcutName = defaults.string(forKey: Key.startShortcutName) ?? ""
        endShortcutName = defaults.string(forKey: Key.endShortcutName) ?? ""
        endCooldownSeconds = defaults.double(forKey: Key.endCooldownSeconds)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        debugMode = defaults.bool(forKey: Key.debugMode)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        onboardingStep = defaults.integer(forKey: Key.onboardingStep)
    }

    var teamsDetectorEnabled: Bool = true {
        didSet { defaults.set(teamsDetectorEnabled, forKey: Key.teamsDetectorEnabled) }
    }
    var audioDetectorEnabled: Bool = true {
        didSet { defaults.set(audioDetectorEnabled, forKey: Key.audioDetectorEnabled) }
    }
    var automationEnabled: Bool = true {
        didSet { defaults.set(automationEnabled, forKey: Key.automationEnabled) }
    }
    var startShortcutName: String = "" {
        didSet { defaults.set(startShortcutName, forKey: Key.startShortcutName) }
    }
    var endShortcutName: String = "" {
        didSet { defaults.set(endShortcutName, forKey: Key.endShortcutName) }
    }
    var endCooldownSeconds: Double = 45 {
        didSet { defaults.set(endCooldownSeconds, forKey: Key.endCooldownSeconds) }
    }
    /// Hiding the icon leaves an `LSUIElement` app with no visible UI at all, so
    /// `AppDelegate.applicationShouldHandleReopen` sets this back to `true` — launching the app
    /// again from Finder is the documented way back. Without that hatch the only route to Settings
    /// would be Activity Monitor.
    var showMenuBarIcon: Bool = true {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }
    var debugMode: Bool = false {
        didSet { defaults.set(debugMode, forKey: Key.debugMode) }
    }
    /// False on a fresh install *and* on an existing one, which is deliberate: an installation that
    /// predates onboarding has no shortcut configured either, so it benefits from the same walk.
    var onboardingCompleted: Bool = false {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }
    /// Where to resume. Quitting halfway through setup should not start it over.
    var onboardingStep: Int = 0 {
        didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep) }
    }

    /// Automation counts as configured only if it is enabled *and* at least one shortcut is named,
    /// so the menu bar can tell the user the truth rather than just echoing the toggle.
    var isAutomationConfigured: Bool {
        automationEnabled &&
        !(startShortcutName.trimmingCharacters(in: .whitespaces).isEmpty &&
          endShortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
