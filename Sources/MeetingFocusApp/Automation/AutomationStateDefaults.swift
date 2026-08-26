import Foundation
import MeetingFocusCore

/// Remembers across launches that automation turned the user's Focus on.
///
/// `UserDefaults` rather than a file for the same reason `AppSettings` uses it, but deliberately
/// not *in* `AppSettings`: this is not configuration. Nobody chose it, nothing in Settings shows
/// it, and it is written and cleared by the coordinator as a meeting comes and goes.
///
/// Stored as JSON so the record carries the whole `Meeting`. The end shortcut does not care which
/// meeting it is ending, but the detection log and any future automation payload will, and a
/// bare boolean could not tell them.
@MainActor
final class AutomationStateDefaults: AutomationStateStore {
    private static let key = "runningAutomationMeeting"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var runningMeeting: Meeting? {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return nil }
            return try? JSONDecoder().decode(Meeting.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.key)
                return
            }
            defaults.set(data, forKey: Self.key)
        }
    }
}
