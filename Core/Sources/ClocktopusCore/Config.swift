import Foundation
import TOMLKit

public struct ProjectOverride: Codable, Equatable, Sendable {
    public var name: String
    public var dirs: [String]
    public var apps: [String]
    public var keywords: [String]
    public var urls: [String]
    public var browserProfiles: [String]
    public var emoji: String?

    public init(name: String, dirs: [String] = [], apps: [String] = [],
                keywords: [String] = [], urls: [String] = [],
                browserProfiles: [String] = [], emoji: String? = nil) {
        self.name = name
        self.dirs = dirs
        self.apps = apps
        self.keywords = keywords
        self.urls = urls
        self.browserProfiles = browserProfiles
        self.emoji = emoji
    }
}

public struct PersonalConfig: Equatable, Sendable {
    public var employee: String
    public var teamConfigPath: String
    public var idleThresholdSeconds: Double
    public var nudgesPerHour: Int
    public var aiTools: [String]
    public var overrides: [ProjectOverride]
    public var includeExactColumn: Bool
    public var launchAtLogin: Bool
    public var dailyTargetHours: Double
}

public struct TeamConfig: Equatable, Sendable {
    public var projects: [Project]
    public var roundingIncrementHours: Double

    public init(projects: [Project], roundingIncrementHours: Double) {
        self.projects = projects
        self.roundingIncrementHours = roundingIncrementHours
    }
}

public enum ConfigError: Error, Equatable {
    case missingField(String)
    case malformedEntry(String)
}

public enum ConfigLoader {
    public static func team(fromTOML toml: String) throws -> TeamConfig {
        let table = try TOMLTable(string: toml)
        let increment = number(table["rounding_increment_hours"]) ?? 0.25
        var projects: [Project] = []
        if let array = table["project"]?.array {
            for item in array {
                guard let t = item.table else { throw ConfigError.malformedEntry("project") }
                guard let name = t["name"]?.string else { throw ConfigError.missingField("project.name") }
                guard let xp = t["xledger_project"]?.string else { throw ConfigError.missingField("xledger_project") }
                guard let xa = t["xledger_activity"]?.string else { throw ConfigError.missingField("xledger_activity") }
                projects.append(Project(
                    name: name, xledgerProject: xp, xledgerActivity: xa,
                    dirs: stringArray(t["dirs"]),
                    apps: stringArray(t["apps"]),
                    keywords: stringArray(t["keywords"]),
                    urls: stringArray(t["urls"]),
                    browserProfiles: stringArray(t["browser_profiles"]),
                    isPrivate: t["private"]?.bool ?? false,
                    emoji: t["emoji"]?.string
                ))
            }
        }
        return TeamConfig(projects: projects, roundingIncrementHours: increment)
    }

    public static func personal(fromTOML toml: String) throws -> PersonalConfig {
        let table = try TOMLTable(string: toml)
        guard let employee = table["employee"]?.string else {
            throw ConfigError.missingField("employee")
        }
        guard let teamPath = table["team_config_path"]?.string else {
            throw ConfigError.missingField("team_config_path")
        }
        var overrides: [ProjectOverride] = []
        if let array = table["override"]?.array {
            for item in array {
                guard let t = item.table else { throw ConfigError.malformedEntry("override") }
                guard let name = t["name"]?.string else { throw ConfigError.missingField("override.name") }
                overrides.append(ProjectOverride(
                    name: name,
                    dirs: stringArray(t["dirs"]),
                    apps: stringArray(t["apps"]),
                    keywords: stringArray(t["keywords"]),
                    urls: stringArray(t["urls"]),
                    browserProfiles: stringArray(t["browser_profiles"]),
                    emoji: t["emoji"]?.string
                ))
            }
        }
        return PersonalConfig(
            employee: employee,
            teamConfigPath: teamPath,
            idleThresholdSeconds: number(table["idle_threshold_seconds"]) ?? 300,
            nudgesPerHour: table["nudges_per_hour"]?.int ?? table["nudges_per_hour"]?.double.map(Int.init) ?? 2,
            aiTools: table["ai_tools"].map(stringArray) ?? ["claude", "codex", "gemini"],
            overrides: overrides,
            includeExactColumn: table["include_exact_column"]?.bool ?? false,
            launchAtLogin: table["launch_at_login"]?.bool ?? true,
            dailyTargetHours: number(table["daily_target_hours"]) ?? 7.5
        )
    }

    /// Merge personal overrides into team projects by name. Override dirs,
    /// apps, urls and browser_profiles append; keywords/emoji replace when
    /// non-empty.
    public static func merge(team: TeamConfig, overrides: [ProjectOverride]) -> [Project] {
        team.projects.map { project in
            guard let o = overrides.first(where: { $0.name == project.name }) else { return project }
            var merged = project
            merged.dirs += o.dirs
            merged.apps += o.apps
            merged.urls += o.urls
            merged.browserProfiles += o.browserProfiles
            if !o.keywords.isEmpty { merged.keywords = o.keywords }
            if let emoji = o.emoji { merged.emoji = emoji }
            return merged
        }
    }

    private static func stringArray(_ value: TOMLValueConvertible?) -> [String] {
        value?.array?.compactMap { $0.string } ?? []
    }

    /// TOMLKit's `.double` accessor is strict: a bare TOML integer (e.g. `300`)
    /// has type `.int`, so `.double` returns nil for it. Fall back to `.int`
    /// so numeric fields coerce regardless of whether the author wrote an
    /// integer or float literal.
    private static func number(_ value: TOMLValueConvertible?) -> Double? {
        value?.double ?? value?.int.map(Double.init)
    }
}
