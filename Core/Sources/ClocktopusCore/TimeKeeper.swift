import Foundation

public struct TimeKeeperSettings: Equatable, Sendable {
    public var idleThresholdSeconds: Double
    public var nudgesPerHour: Int
    public var clockInLeadMinutes: Double
    public var switchLeadMinutes: Double
    /// leader must beat runner-up by this factor to count as unambiguous
    public var ambiguityRatio: Double
    /// how long an open provisional block may go untouched before it's
    /// detached, letting the next activity episode open a fresh block
    /// (and earn a fresh clock-in nudge)
    public var blockStalenessSeconds: Double
    /// idle span after which a running timer is stopped at the moment idleness
    /// began (an overnight can't silently bill 17 hours). 0 disables the cap.
    public var idleAutoStopSeconds: Double

    public init(idleThresholdSeconds: Double = 300, nudgesPerHour: Int = 2,
                clockInLeadMinutes: Double = 2, switchLeadMinutes: Double = 10,
                ambiguityRatio: Double = 1.5, blockStalenessSeconds: Double = 600,
                idleAutoStopSeconds: Double = 7200) {
        self.idleThresholdSeconds = idleThresholdSeconds
        self.nudgesPerHour = nudgesPerHour
        self.clockInLeadMinutes = clockInLeadMinutes
        self.switchLeadMinutes = switchLeadMinutes
        self.ambiguityRatio = ambiguityRatio
        self.blockStalenessSeconds = blockStalenessSeconds
        self.idleAutoStopSeconds = idleAutoStopSeconds
    }
}

public enum TimeKeeperEffect: Equatable, Sendable {
    case entryStarted(TimeEntry)
    case entryStopped(TimeEntry)
    case nudgeClockIn(projectId: String, since: Date)
    case nudgeSwitch(toProjectId: String, detectedAt: Date)
    case provisionalOpened(ProvisionalBlock)
    case provisionalUpdated(ProvisionalBlock)
    case askIdleGap(from: Date, to: Date)
    /// The running timer was stopped because idleness exceeded the auto-stop
    /// cap. The paired `entryStopped` persists the entry; this one is for
    /// telling the user what happened and why.
    case autoClockedOut(projectId: String, at: Date)
}

public struct TimeKeeper {
    /// A sustained, unambiguous different-project leader detected while a
    /// timer runs. Persists until the user acts on it, dismisses it, or the
    /// clocked-in project takes the lead back — unlike the one-shot switch
    /// notification, which is easy to miss.
    public struct SwitchCandidate: Equatable, Sendable {
        public var projectId: String
        /// When the leadership streak began — the natural backfill anchor for
        /// an accepted switch. Fixed at candidate formation so the suggestion
        /// doesn't drift as the scoring window slides.
        public var since: Date
    }

    /// An idle span (while clocked in) awaiting the user's keep/discard call.
    public struct IdleGap: Equatable, Sendable {
        public var from: Date
        public var to: Date
    }

    public private(set) var settings: TimeKeeperSettings
    public private(set) var runningEntry: TimeEntry?
    public private(set) var switchCandidate: SwitchCandidate?
    public private(set) var pendingIdleGap: IdleGap?

    var scorer: Scorer
    var openBlock: ProvisionalBlock?
    var nudgeTimes: [Date] = []          // for the per-hour budget
    var nudgedBlockIds: Set<UUID> = []   // one nudge per block, ever
    /// A dismissed switch suggestion stays dismissed while that project keeps
    /// leading; cleared when the clocked-in project regains the lead.
    var dismissedSwitchProjectId: String?
    var idleSince: Date?

    public init(projects: [Project], settings: TimeKeeperSettings) {
        self.settings = settings
        self.scorer = Scorer(projects: projects)
    }

    /// Replace the tunable settings in place, preserving all in-flight state
    /// (running entry, open block, nudge history, scorer). Lets the app apply
    /// a settings change from Preferences without rebuilding the keeper and
    /// dropping the current timer/episode.
    public mutating func updateSettings(_ new: TimeKeeperSettings) {
        settings = new
    }

    @discardableResult
    public mutating func clockIn(projectId: String, at now: Date,
                                 backfillFrom: Date?, source: EntrySource) -> [TimeKeeperEffect] {
        if runningEntry?.projectId == projectId { return [] }
        var effects: [TimeKeeperEffect] = []
        effects += clockOut(at: now)
        let entry = TimeEntry(projectId: projectId, start: backfillFrom ?? now, source: source)
        runningEntry = entry
        switchCandidate = nil
        dismissedSwitchProjectId = nil
        pendingIdleGap = nil
        // clocking in resolves any open provisional block
        if var block = openBlock {
            block.status = .accepted
            openBlock = nil
            effects.append(.provisionalUpdated(block))
        }
        effects.append(.entryStarted(entry))
        return effects
    }

    /// Restore a previously persisted running entry (e.g. after a config
    /// reload rebuilds the keeper). Preserves the entry's identity; emits no
    /// effects and touches no provisional state.
    public mutating func restore(runningEntry entry: TimeEntry) {
        runningEntry = entry
    }

    /// Re-adopt a persisted, still-open provisional block after the keeper is
    /// rebuilt (config reload / app relaunch), so an ongoing activity episode
    /// continues the same block instead of fragmenting into a fresh one on
    /// every restart. The block keeps its identity; it's recorded as
    /// already-nudged so a restart doesn't re-fire its clock-in nudge, and no
    /// effect is emitted. The caller decides recency (only adopt a block still
    /// within its live window).
    public mutating func restore(openBlock block: ProvisionalBlock) {
        openBlock = block
        nudgedBlockIds.insert(block.id)
    }

    @discardableResult
    public mutating func clockOut(at now: Date) -> [TimeKeeperEffect] {
        guard var entry = runningEntry else { return [] }
        entry.end = now
        runningEntry = nil
        switchCandidate = nil
        dismissedSwitchProjectId = nil
        pendingIdleGap = nil
        return [.entryStopped(entry)]
    }

    /// Hide the current switch suggestion. It stays hidden while that project
    /// keeps leading; once the clocked-in project regains the lead (or the
    /// timer changes), a later sustained switch earns a fresh suggestion.
    public mutating func dismissSwitchCandidate() {
        dismissedSwitchProjectId = switchCandidate?.projectId
        switchCandidate = nil
    }

    /// Replace the running entry's fields in place — the "this timer was
    /// actually project X all along" edit. The entry keeps its identity and
    /// keeps running (`end` must be nil). A switch suggestion (or an earlier
    /// dismissal) for the newly assigned project is thereby satisfied; one for
    /// a different project stays, since the mismatch it flags still stands.
    @discardableResult
    public mutating func updateRunningEntry(_ entry: TimeEntry) -> [TimeKeeperEffect] {
        guard runningEntry != nil, entry.end == nil else { return [] }
        runningEntry = entry
        if switchCandidate?.projectId == entry.projectId { switchCandidate = nil }
        if dismissedSwitchProjectId == entry.projectId { dismissedSwitchProjectId = nil }
        return [.entryStarted(entry)]
    }

    @discardableResult
    public mutating func handle(_ obs: Observation) -> [TimeKeeperEffect] {
        var effects: [TimeKeeperEffect] = []
        let now = obs.timestamp

        // ---- Idle auto-stop cap ----
        // Past the cap, keeping the timer alive stops being a "suggestion" and
        // becomes silently billing an absence (the overnight case). Stop at the
        // moment idleness began — the honest end — and say so.
        if let entry = runningEntry, settings.idleAutoStopSeconds > 0,
           obs.idleSeconds >= settings.idleAutoStopSeconds {
            let end = max(entry.start, now.addingTimeInterval(-obs.idleSeconds))
            var stopped = entry
            stopped.end = end
            runningEntry = nil
            switchCandidate = nil
            dismissedSwitchProjectId = nil
            pendingIdleGap = nil
            idleSince = nil
            effects.append(.entryStopped(stopped))
            effects.append(.autoClockedOut(projectId: stopped.projectId, at: end))
        }

        // ---- Idle tracking (only meaningful while clocked in) ----
        if runningEntry != nil {
            if obs.idleSeconds >= settings.idleThresholdSeconds {
                if idleSince == nil {
                    idleSince = now.addingTimeInterval(-obs.idleSeconds)
                }
            } else if let since = idleSince {
                pendingIdleGap = IdleGap(from: since, to: now)
                effects.append(.askIdleGap(from: since, to: now))
                idleSince = nil
            }
        } else {
            idleSince = nil
        }

        // Idle periods contribute no activity evidence.
        guard obs.idleSeconds < settings.idleThresholdSeconds else { return effects }

        // A stale open block has been sitting untouched (no clock-in, no
        // further activity) past the staleness window: detach it so the
        // next activity episode opens a fresh block with a fresh id,
        // restoring nudge opportunities. It stays exactly as persisted
        // (`.pending`, already reported via provisionalOpened/Updated) —
        // no effect is emitted here and its id remains in `nudgedBlockIds`.
        if let block = openBlock,
           obs.timestamp.timeIntervalSince(block.end) > settings.blockStalenessSeconds {
            openBlock = nil
        }

        scorer.ingest(obs)
        guard let leader = scorer.leader(at: now) else {
            // no meaningful activity: nothing further to decide
            return effects
        }

        let unambiguous = leader.runnerUpScore == 0
            || leader.score >= leader.runnerUpScore * settings.ambiguityRatio
        let sustainedMinutes = leader.leadingSince.map { now.timeIntervalSince($0) / 60 } ?? 0

        if let running = runningEntry {
            // ---- Clocked in: watch for a decisive different leader ----
            if unambiguous, leader.projectId == running.projectId {
                // The clocked-in project has the lead again: retire any open
                // suggestion and forgive an earlier dismissal, so the next
                // genuine switch starts a fresh episode.
                switchCandidate = nil
                dismissedSwitchProjectId = nil
            } else if unambiguous, leader.projectId != running.projectId,
                      sustainedMinutes >= settings.switchLeadMinutes,
                      leader.projectId != dismissedSwitchProjectId,
                      leader.projectId != switchCandidate?.projectId {
                // A new sustained leader: raise (or replace) the persistent
                // suggestion and notify once per episode. The candidate — not
                // the sliding `leadingSince` — is the dedup anchor, so the
                // nudge can't re-fire itself into the budget cap.
                let since = leader.leadingSince ?? now
                switchCandidate = SwitchCandidate(projectId: leader.projectId, since: since)
                effects += nudgeIfBudgetAllows(now: now,
                    make: { .nudgeSwitch(toProjectId: leader.projectId, detectedAt: since) },
                    blockAnchor: nil)
            }
        } else {
            // ---- Not clocked in: provisional block + one nudge ----
            if sustainedMinutes >= settings.clockInLeadMinutes || !unambiguous {
                let guess = unambiguous ? leader.projectId : nil
                let start = leader.leadingSince ?? now
                if var block = openBlock {
                    block.end = now
                    block.guessedProjectId = guess
                    // Refresh evidence + signals so an extending block reflects
                    // current activity, not the snapshot from when it opened.
                    block.evidence = evidenceSummary(obs, leader: leader)
                    block.signals = signalKinds(obs)
                    openBlock = block
                    effects.append(.provisionalUpdated(block))
                } else {
                    let block = ProvisionalBlock(
                        guessedProjectId: guess, start: start, end: now,
                        confidence: min(1.0, leader.score / (Scorer.scoreFloor * 2)),
                        evidence: evidenceSummary(obs, leader: leader),
                        signals: signalKinds(obs))
                    openBlock = block
                    effects.append(.provisionalOpened(block))
                }
                if unambiguous, let block = openBlock, !nudgedBlockIds.contains(block.id) {
                    effects += nudgeIfBudgetAllows(now: now,
                        make: { .nudgeClockIn(projectId: leader.projectId, since: start) },
                        blockAnchor: block.id)
                }
            }
        }
        return effects
    }

    /// Resolve a provisional block out-of-band (accepted/dismissed via the
    /// review UI). If it is the keeper's current open block, detach it so a
    /// later observation opens a fresh block instead of re-persisting this one
    /// as pending. The id stays in nudgedBlockIds so the resolved block is
    /// never re-nudged.
    public mutating func resolveBlock(id: UUID) {
        if openBlock?.id == id {
            nudgedBlockIds.insert(id)
            openBlock = nil
        }
    }

    @discardableResult
    public mutating func resolveIdleGap(keep: Bool, from: Date, to: Date) -> [TimeKeeperEffect] {
        pendingIdleGap = nil
        guard !keep, var entry = runningEntry else { return [] }
        entry.end = from
        let resumed = TimeEntry(projectId: entry.projectId, start: to, source: entry.source)
        runningEntry = resumed
        return [.entryStopped(entry), .entryStarted(resumed)]
    }

    private mutating func nudgeIfBudgetAllows(now: Date,
                                              make: () -> TimeKeeperEffect,
                                              blockAnchor: UUID?) -> [TimeKeeperEffect] {
        nudgeTimes.removeAll { now.timeIntervalSince($0) > 3600 }
        guard nudgeTimes.count < settings.nudgesPerHour else { return [] }
        nudgeTimes.append(now)
        if let id = blockAnchor { nudgedBlockIds.insert(id) }
        return [make()]
    }

    /// The kinds of signal present in an observation, for glanceable icons.
    private func signalKinds(_ obs: Observation) -> Set<SignalKind> {
        var s: Set<SignalKind> = []
        if obs.dirs.contains(where: { $0.kind == .frontmostShell || $0.kind == .backgroundShell }) { s.insert(.terminal) }
        if obs.dirs.contains(where: { $0.kind == .tmuxActivePane || $0.kind == .tmuxPane }) { s.insert(.tmux) }
        if obs.dirs.contains(where: { $0.kind == .aiTool }) { s.insert(.aiTool) }
        if obs.activeTabURL != nil { s.insert(.browser) }
        else if obs.frontmostAppName != nil { s.insert(.app) }
        return s
    }

    private func evidenceSummary(_ obs: Observation, leader: Scorer.Leader) -> String {
        var parts: [String] = []
        if let dir = obs.dirs.first(where: { $0.kind == .frontmostShell }) {
            parts.append("terminal in \(abbreviate(dir.path))")
        }
        // Only surface an AI tool that's in the foreground (same dir as the
        // active pane / frontmost shell). A parked AI session elsewhere didn't
        // drive the detection, so showing it is misleading.
        let foregroundPaths = Set(obs.dirs
            .filter { Scorer.foregroundDirKinds.contains($0.kind) }
            .map(\.path))
        if let dir = obs.dirs.first(where: { $0.kind == .aiTool && foregroundPaths.contains($0.path) }) {
            parts.append("AI tool in \(abbreviate(dir.path))")
        }
        // Prefer the active pane; only fall back to a background one.
        if let dir = obs.dirs.first(where: { $0.kind == .tmuxActivePane })
            ?? obs.dirs.first(where: { $0.kind == .tmuxPane }) {
            let label = dir.kind == .tmuxActivePane ? "active tmux pane" : "tmux pane"
            parts.append("\(label) in \(abbreviate(dir.path))")
        }
        // Host only — evidence is persisted, so never keep the full URL/path.
        // A browser's host supersedes its app name (no "browser x · Chrome").
        if let url = obs.activeTabURL, let host = Observation.host(fromURL: url) {
            parts.append("browser \(host)")
        } else if let app = obs.frontmostAppName {
            parts.append(app)
        }
        return parts.joined(separator: " · ")
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSString(string: "~").expandingTildeInPath
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
