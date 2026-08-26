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
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingStep = "onboardingStep"
        static let onboardingLaunchCount = "onboardingLaunchCount"
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
            Key.onboardingCompleted: false,
            Key.onboardingStep: 0,
            Key.onboardingLaunchCount: 0,
        ])
        // Initialised directly so the `didSet` observers below do not fire during init.
        teamsDetectorEnabled = defaults.bool(forKey: Key.teamsDetectorEnabled)
        audioDetectorEnabled = defaults.bool(forKey: Key.audioDetectorEnabled)
        automationEnabled = defaults.bool(forKey: Key.automationEnabled)
        startShortcutName = defaults.string(forKey: Key.startShortcutName) ?? ""
        endShortcutName = defaults.string(forKey: Key.endShortcutName) ?? ""
        endCooldownSeconds = defaults.double(forKey: Key.endCooldownSeconds)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        onboardingStep = defaults.integer(forKey: Key.onboardingStep)
        onboardingLaunchCount = defaults.integer(forKey: Key.onboardingLaunchCount)
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
    /// False on a fresh install *and* on an existing one, which is deliberate: someone upgrading from
    /// before onboarding existed might not have a shortcut configured, so offering the same walk is a
    /// reasonable default. But it's a default, not a guarantee — `OnboardingFocusStep` does not trust
    /// this flag alone; it seeds its own `installed` state from `isAutomationConfigured` so an
    /// existing configuration is never silently overwritten.
    var onboardingCompleted: Bool = false {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }
    /// Where to resume. Quitting halfway through setup should not start it over.
    var onboardingStep: Int = 0 {
        didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep) }
    }
    /// How many launches have offered to present onboarding by themselves. See
    /// `claimOnboardingPresentation()`.
    var onboardingLaunchCount: Int = 0 {
        didSet { defaults.set(onboardingLaunchCount, forKey: Key.onboardingLaunchCount) }
    }

    /// How many launches may open onboarding by themselves before it goes quiet. The HIG advises
    /// against re-presenting a flow someone skipped; one repeat is the compromise — it catches a
    /// person who quit halfway through setup without nagging one who closed it on purpose. The menu's
    /// `Set Up MeetingFocus…` item is always there regardless, which is the other half of the same
    /// guidance.
    static let onboardingLaunchLimit = 2

    /// Answers "should the window open itself this launch?" and records that it did. Call exactly
    /// once per launch: it is a question with a side effect, which is why it reads as a claim rather
    /// than a getter.
    func claimOnboardingPresentation() -> Bool {
        guard !onboardingCompleted, onboardingLaunchCount < Self.onboardingLaunchLimit else {
            return false
        }
        onboardingLaunchCount += 1
        return true
    }

    /// Automation counts as configured only if it is enabled *and* at least one shortcut is named,
    /// so the menu bar can tell the user the truth rather than just echoing the toggle.
    var isAutomationConfigured: Bool {
        automationEnabled &&
        !(startShortcutName.trimmingCharacters(in: .whitespaces).isEmpty &&
          endShortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
