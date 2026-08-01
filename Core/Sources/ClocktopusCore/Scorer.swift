import Foundation

public enum Glob {
    /// Minimal glob for dir patterns: `~` expands, `*` matches any run of
    /// characters. A pattern also matches any path UNDER a matching prefix
    /// (cwd deep inside a repo still counts).
    public static func matches(pattern: String, path: String) -> Bool {
        let expanded = NSString(string: pattern).expandingTildeInPath
        let regexBody = NSRegularExpression.escapedPattern(for: expanded)
            .replacingOccurrences(of: "\\*", with: "[^/]*")
        guard let regex = try? NSRegularExpression(pattern: "^" + regexBody + "(/.*)?$") else {
            return false
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }
}

public struct Scorer {
    public struct Leader: Equatable {
        public var projectId: String
        public var score: Double
        public var runnerUpScore: Double
        public var leadingSince: Date?
    }

    static let weights: [DirKind: Double] = [
        .frontmostShell: 1.0, .tmuxActivePane: 0.8, .aiTool: 0.6,
        .backgroundShell: 0.4, .tmuxPane: 0.4,
    ]
    static let appWeight = 0.5
    static let keywordWeight = 0.3
    static let urlWeight = 0.5   // active browser-tab URL substring match
    /// Signals for what you're actually looking at. Everything else
    /// (background shells, background tmux panes, parked AI-tool sessions) is
    /// background and only counts as reinforcement for a foreground project.
    static let foregroundDirKinds: Set<DirKind> = [.frontmostShell, .tmuxActivePane]
    static let halfLife: TimeInterval = 10 * 60
    static let windowMax: TimeInterval = 15 * 60
    public static let scoreFloor = 2.0   // min decayed score before leader counts
    /// Max gap between consecutive observations mentioning the same project
    /// before the contiguous "leading streak" is considered broken.
    static let streakGapTolerance: TimeInterval = 90

    let projects: [Project]
    private(set) var history: [(timestamp: Date, scores: [String: Double])] = []

    public init(projects: [Project]) {
        self.projects = projects
    }

    /// Instantaneous score of one observation against project rules.
    public static func matchProjects(dirs: [ObservedDir], windowTitle: String?,
                                     frontmostApp: String?, activeTabURL: String? = nil,
                                     frontmostAppName: String? = nil,
                                     projects: [Project]) -> [String: Double] {
        let url = activeTabURL?.lowercased()
        // A project's `apps` list matches the frontmost app by EITHER its
        // human name ("Slack") or its bundle id ("com.tinyspeck.slackmacgap"),
        // case-insensitively — config authors write the name they see.
        let appIdentifiers = Set([frontmostApp, frontmostAppName].compactMap { $0?.lowercased() })
        var fg: [String: Double] = [:]   // foreground: what you're looking at now
        var bg: [String: Double] = [:]   // background: parked panes / AI elsewhere

        // Attribute each observed directory to the project whose matching dir
        // pattern is MOST SPECIFIC (longest), so a specific rule beats a
        // catch-all (e.g. "~/src/ttt" wins over "~/src/" for a path under ttt).
        for dir in dirs {
            var bestProject: String?
            var bestLength = -1
            for project in projects {
                for pattern in project.dirs where Glob.matches(pattern: pattern, path: dir.path) {
                    let length = NSString(string: pattern).expandingTildeInPath.count
                    if length > bestLength { bestLength = length; bestProject = project.id }
                }
            }
            if let pid = bestProject {
                let w = weights[dir.kind] ?? 0
                if foregroundDirKinds.contains(dir.kind) { fg[pid] = max(fg[pid] ?? 0, w) }
                else { bg[pid] = max(bg[pid] ?? 0, w) }
            }
        }

        for project in projects {
            if project.apps.contains(where: { appIdentifiers.contains($0.lowercased()) }) {
                fg[project.id] = max(fg[project.id] ?? 0, appWeight)
            }
            if let title = windowTitle?.lowercased(),
               project.keywords.contains(where: { title.contains($0.lowercased()) }) {
                fg[project.id] = max(fg[project.id] ?? 0, keywordWeight)
            }
            if let url, project.urls.contains(where: { url.contains($0.lowercased()) }) {
                fg[project.id] = max(fg[project.id] ?? 0, urlWeight)
            }
        }

        var scores: [String: Double] = [:]
        for project in projects {
            let f = fg[project.id] ?? 0
            let b = bg[project.id] ?? 0
            // Foreground gate: a project only scores when it has a foreground
            // signal. Background signals reinforce it but never score alone, so
            // parked panes / background AI sessions can't drive detection.
            if f > 0 { scores[project.id] = max(f, b) }
        }
        return scores
    }

    public mutating func ingest(_ obs: Observation) {
        let scores = Self.matchProjects(dirs: obs.dirs, windowTitle: obs.windowTitle,
                                        frontmostApp: obs.frontmostApp,
                                        activeTabURL: obs.activeTabURL,
                                        frontmostAppName: obs.frontmostAppName,
                                        projects: projects)
        history.append((obs.timestamp, scores))
        history.removeAll { obs.timestamp.timeIntervalSince($0.timestamp) > Self.windowMax }
    }

    public func leader(at now: Date) -> Leader? {
        let totals = decayedTotals(at: now)
        let sorted = totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        guard let top = sorted.first, top.value >= Self.scoreFloor else { return nil }
        return Leader(projectId: top.key, score: top.value,
                      runnerUpScore: sorted.dropFirst().first?.value ?? 0,
                      leadingSince: leadingSince(for: top.key, now: now))
    }

    /// Start of the current contiguous streak of observations mentioning
    /// `projectId`, walking backward from the newest observation. Gaps of
    /// up to `streakGapTolerance` between mentions don't break the streak;
    /// larger gaps do. If the leader's most recent mention is itself older
    /// than the tolerance relative to `now`, the streak is considered
    /// already broken and this returns nil.
    private func leadingSince(for projectId: String, now: Date) -> Date? {
        var runStart: Date?
        var lastMention: Date?
        for entry in history.reversed() where entry.scores[projectId] != nil {
            if let lastMention, lastMention.timeIntervalSince(entry.timestamp) > Self.streakGapTolerance {
                break
            }
            if lastMention == nil, now.timeIntervalSince(entry.timestamp) > Self.streakGapTolerance {
                return nil
            }
            runStart = entry.timestamp
            lastMention = entry.timestamp
        }
        return runStart
    }

    private func decayedTotals(at now: Date) -> [String: Double] {
        var totals: [String: Double] = [:]
        for (timestamp, scores) in history {
            let age = now.timeIntervalSince(timestamp)
            guard age <= Self.windowMax, age >= 0 else { continue }
            let decay = pow(0.5, age / Self.halfLife)
            for (id, score) in scores {
                totals[id, default: 0] += score * decay
            }
        }
        return totals
    }
}
