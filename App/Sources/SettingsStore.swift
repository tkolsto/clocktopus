import Foundation

/// User-editable runtime settings, persisted to `UserDefaults`. Each value is
/// optional: `nil` means "not overridden in-app", so callers fall back to the
/// personal TOML value and then the built-in default. Once the user edits a
/// setting in Preferences, the stored value wins for that setting.
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let idle = "clocktopus.idleThresholdSeconds"
        static let nudges = "clocktopus.nudgesPerHour"
        static let aiTools = "clocktopus.aiTools"
        static let includeExact = "clocktopus.includeExactColumn"
        static let browserDetection = "clocktopus.browserDetectionEnabled"
        static let clockInLead = "clocktopus.clockInLeadMinutes"
        static let dayStartHour = "clocktopus.dayStartHour"
        static let switchLead = "clocktopus.switchLeadMinutes"
        static let idleAutoStop = "clocktopus.idleAutoStopMinutes"
    }

    var idleThresholdSeconds: Double? {
        get { defaults.object(forKey: Key.idle) as? Double }
        set { setOrClear(newValue, Key.idle) }
    }

    var nudgesPerHour: Int? {
        get { defaults.object(forKey: Key.nudges) as? Int }
        set { setOrClear(newValue, Key.nudges) }
    }

    var aiTools: [String]? {
        get { defaults.object(forKey: Key.aiTools) as? [String] }
        set { setOrClear(newValue, Key.aiTools) }
    }

    var includeExactColumn: Bool? {
        get { defaults.object(forKey: Key.includeExact) as? Bool }
        set { setOrClear(newValue, Key.includeExact) }
    }

    var browserDetectionEnabled: Bool? {
        get { defaults.object(forKey: Key.browserDetection) as? Bool }
        set { setOrClear(newValue, Key.browserDetection) }
    }

    var clockInLeadMinutes: Double? {
        get { defaults.object(forKey: Key.clockInLead) as? Double }
        set { setOrClear(newValue, Key.clockInLead) }
    }

    var dayStartHour: Int? {
        get { defaults.object(forKey: Key.dayStartHour) as? Int }
        set { setOrClear(newValue, Key.dayStartHour) }
    }

    var switchLeadMinutes: Double? {
        get { defaults.object(forKey: Key.switchLead) as? Double }
        set { setOrClear(newValue, Key.switchLead) }
    }

    /// 0 means "never auto-stop"; nil falls back to the default.
    var idleAutoStopMinutes: Int? {
        get { defaults.object(forKey: Key.idleAutoStop) as? Int }
        set { setOrClear(newValue, Key.idleAutoStop) }
    }

    private func setOrClear(_ value: Any?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
