import Foundation

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let xledgerProject: String
    public let xledgerActivity: String
    public var dirs: [String]
    public var apps: [String]
    public var keywords: [String]
    public var urls: [String]          // matched as substrings of the active browser tab URL
    public var isPrivate: Bool         // tracked locally but excluded from the xledger export
    public var emoji: String?

    /// Stable id derived from the name: lowercase, non-alphanumerics collapsed to "-".
    public var id: String {
        name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
    }

    public init(name: String, xledgerProject: String, xledgerActivity: String,
                dirs: [String] = [], apps: [String] = [], keywords: [String] = [],
                urls: [String] = [], isPrivate: Bool = false, emoji: String? = nil) {
        self.name = name
        self.xledgerProject = xledgerProject
        self.xledgerActivity = xledgerActivity
        self.dirs = dirs
        self.apps = apps
        self.keywords = keywords
        self.urls = urls
        self.isPrivate = isPrivate
        self.emoji = emoji
    }
}

public enum EntrySource: String, Codable, Sendable {
    case manual, acceptedSuggestion, backfill
}

public struct TimeEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: String
    public var start: Date
    public var end: Date?          // nil = running
    public var source: EntrySource
    public var note: String?
    public var exportedAt: Date?

    public init(id: UUID = UUID(), projectId: String, start: Date, end: Date? = nil,
                source: EntrySource, note: String? = nil, exportedAt: Date? = nil) {
        self.id = id
        self.projectId = projectId
        self.start = start
        self.end = end
        self.source = source
        self.note = note
        self.exportedAt = exportedAt
    }

    public func duration(asOf now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

public enum BlockStatus: String, Codable, Sendable {
    case pending, accepted, dismissed, expired
}

/// The kinds of signal that contributed to a detected block, for at-a-glance
/// icons in the timeline. `displayOrder` gives a stable icon ordering.
public enum SignalKind: String, Codable, Sendable, CaseIterable {
    case terminal, tmux, aiTool, browser, app
    public static let displayOrder: [SignalKind] = [.terminal, .tmux, .aiTool, .browser, .app]
}

public struct ProvisionalBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var guessedProjectId: String?  // nil = ambiguous evidence
    public var start: Date
    public var end: Date
    public var confidence: Double         // 0...1
    public var evidence: String           // human-readable summary
    public var signals: Set<SignalKind>   // signal kinds seen, for glanceable icons
    public var status: BlockStatus

    public init(id: UUID = UUID(), guessedProjectId: String?, start: Date, end: Date,
                confidence: Double, evidence: String, signals: Set<SignalKind> = [],
                status: BlockStatus = .pending) {
        self.id = id
        self.guessedProjectId = guessedProjectId
        self.start = start
        self.end = end
        self.confidence = confidence
        self.evidence = evidence
        self.signals = signals
        self.status = status
    }
}

public enum DirKind: String, Codable, Sendable {
    case frontmostShell   // cwd of a shell in the frontmost terminal app
    case backgroundShell  // cwd of any other shell
    case tmuxActivePane
    case tmuxPane
    case aiTool           // cwd of a running claude/codex/gemini process
}

public struct ObservedDir: Codable, Equatable, Sendable {
    public var path: String
    public var kind: DirKind
    public init(path: String, kind: DirKind) {
        self.path = path
        self.kind = kind
    }
}

public struct Observation: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var frontmostApp: String?   // bundle id, e.g. "com.googlecode.iterm2"
    public var windowTitle: String?
    public var dirs: [ObservedDir]
    public var idleSeconds: TimeInterval
    /// Full URL of the frontmost browser's active tab. Held in memory only for
    /// scoring; `redactedForStorage()` reduces it to a host before it is ever
    /// persisted, so the observation log never keeps browsing paths.
    public var activeTabURL: String?
    /// Human-readable name of the frontmost app (e.g. "Slack"), for evidence.
    /// Nil when the frontmost app is Clocktopus itself, so we don't record
    /// ourselves as evidence.
    public var frontmostAppName: String?

    public init(timestamp: Date, frontmostApp: String? = nil, windowTitle: String? = nil,
                dirs: [ObservedDir] = [], idleSeconds: TimeInterval = 0,
                activeTabURL: String? = nil, frontmostAppName: String? = nil) {
        self.timestamp = timestamp
        self.frontmostApp = frontmostApp
        self.windowTitle = windowTitle
        self.dirs = dirs
        self.idleSeconds = idleSeconds
        self.activeTabURL = activeTabURL
        self.frontmostAppName = frontmostAppName
    }

    /// A copy safe to persist: the full active-tab URL is reduced to its host.
    public func redactedForStorage() -> Observation {
        var copy = self
        copy.activeTabURL = activeTabURL.flatMap(Observation.host(fromURL:))
        return copy
    }

    /// Host of a URL string, e.g. "https://github.com/initech/x" -> "github.com".
    /// Returns nil when there is no parseable host.
    public static func host(fromURL url: String) -> String? {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host
    }
}
