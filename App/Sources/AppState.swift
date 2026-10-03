import Foundation
import ClocktopusCore
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var runningEntry: TimeEntry?
    @Published var pendingBlocks: [ProvisionalBlock] = []
    @Published var todayTotal: TimeInterval = 0
    @Published var weekTotal: TimeInterval = 0
    /// Current-week snapshot behind the popover chart, rebuilt in
    /// `refreshDerived` — never a computed property (see WeekView lesson).
    @Published var popoverWeekReport: WeekReport?
    /// One-shot deep link: a time inside the day the review window should
    /// jump to. Consumed (reset to nil) by ReviewWindow when adopted.
    @Published var reviewFocusDay: Date?
    @Published var configError: String?
    @Published var recoveryNotice: String?   // dangling-entry recovery, user-dismissable
    /// Sustained different-project leader while a timer runs — shown in the
    /// popover until acted on, dismissed, or overtaken (mirrors the keeper).
    @Published var switchSuggestion: TimeKeeper.SwitchCandidate?
    /// Idle span awaiting the user's keep/discard decision (mirrors the keeper).
    @Published var pendingIdleGap: TimeKeeper.IdleGap?

    private(set) var store: Store!
    private(set) var personal: PersonalConfig?
    private(set) var team: TeamConfig?
    private var keeper: TimeKeeper?
    private var configWatchers: [DispatchSourceFileSystemObject] = []
    let settings = SettingsStore()

    static let defaultAITools = ["claude", "codex", "gemini"]

    // MARK: - Effective runtime settings (in-app override > TOML > default)

    var effectiveIdleThreshold: Double {
        settings.idleThresholdSeconds ?? personal?.idleThresholdSeconds ?? 300
    }
    var effectiveNudgesPerHour: Int {
        settings.nudgesPerHour ?? personal?.nudgesPerHour ?? 2
    }
    var effectiveAITools: [String] {
        settings.aiTools ?? personal?.aiTools ?? Self.defaultAITools
    }
    var effectiveIncludeExactColumn: Bool {
        settings.includeExactColumn ?? personal?.includeExactColumn ?? false
    }
    var browserDetectionEnabled: Bool {
        settings.browserDetectionEnabled ?? false
    }
    static let defaultClockInLeadMinutes = 2.0
    var effectiveClockInLeadMinutes: Double {
        settings.clockInLeadMinutes ?? Self.defaultClockInLeadMinutes
    }
    static let defaultDayStartHour = 4
    var effectiveDayStartHour: Int {
        settings.dayStartHour ?? Self.defaultDayStartHour
    }
    static let defaultSwitchLeadMinutes = 10.0
    var effectiveSwitchLeadMinutes: Double {
        settings.switchLeadMinutes ?? Self.defaultSwitchLeadMinutes
    }
    static let defaultIdleAutoStopMinutes = 120
    var effectiveIdleAutoStopMinutes: Int {
        settings.idleAutoStopMinutes ?? Self.defaultIdleAutoStopMinutes
    }
    var effectiveDailyTargetHours: Double {
        settings.dailyTargetHours ?? personal?.dailyTargetHours ?? 7.5
    }
    /// Work-day calendar for grouping time into days that start at the
    /// configured hour rather than midnight.
    var workday: WorkdayCalendar {
        WorkdayCalendar(dayStartHour: effectiveDayStartHour, timeZone: .current)
    }

    /// TimeKeeper settings built from the effective runtime values. Used both
    /// when (re)building the keeper on config load and when applying a live
    /// Preferences change.
    private func makeKeeperSettings() -> TimeKeeperSettings {
        var s = TimeKeeperSettings()
        s.idleThresholdSeconds = effectiveIdleThreshold
        s.nudgesPerHour = effectiveNudgesPerHour
        s.clockInLeadMinutes = effectiveClockInLeadMinutes
        s.switchLeadMinutes = effectiveSwitchLeadMinutes
        s.idleAutoStopSeconds = Double(effectiveIdleAutoStopMinutes) * 60
        return s
    }

    // Launch arguments `-clocktopus-config PATH` / `-clocktopus-db PATH`
    // (macOS parses `-key value` into the defaults argument domain) point a
    // second instance at demo files — for screenshots and for trying a config
    // without touching your real data. Unset in normal use.
    static let personalConfigURL = URL(fileURLWithPath: NSString(string:
        UserDefaults.standard.string(forKey: "clocktopus-config")
            ?? "~/.config/clocktopus/config.toml").expandingTildeInPath)
    static let dbURL = URL(fileURLWithPath: NSString(string:
        UserDefaults.standard.string(forKey: "clocktopus-db")
            ?? "~/Library/Application Support/Clocktopus/clocktopus.sqlite").expandingTildeInPath)

    func bootstrap() {
        do {
            try FileManager.default.createDirectory(
                at: Self.dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            store = try Store(path: Self.dbURL.path)
            // Recovery for a running timer left open by a previous session: if
            // the app was only briefly away (a normal relaunch), keep it running
            // across the restart; if it was gone longer than the grace window,
            // close it at the last-seen time (honest end) so a crash doesn't
            // silently bill the downtime. The notice is built after reloadConfig
            // (it needs the human project name). See SessionRecovery.
            var closed: TimeEntry?
            if let running = try store.runningEntry() {
                let lastSeen = try? store.lastObservationTimestamp()
                switch SessionRecovery.decide(
                    runningStart: running.start, lastSeen: lastSeen, now: Date(),
                    graceSeconds: makeKeeperSettings().blockStalenessSeconds) {
                case .keepRunning:
                    break  // leave it open; reloadConfig restores it into the keeper
                case .close(let at):
                    closed = try store.closeDanglingEntry(at: min(at, Date()))
                }
            }
            reloadConfig()
            if let closed {
                let name = project(closed.projectId)?.name ?? closed.projectId
                recoveryNotice = "Closed a running \(name) timer from a previous "
                    + "session at \(closed.end!.formatted(date: .abbreviated, time: .shortened)) "
                    + "— adjust it in Review if that's wrong."
            }
            refreshDerived()
        } catch {
            configError = "Store init failed: \(error)"
        }
        watchConfigFiles()
    }

    func watchConfigFiles() {
        configWatchers.forEach { $0.cancel() }
        configWatchers = []
        var paths = [Self.personalConfigURL.path]
        if let teamPath = personal?.teamConfigPath {
            paths.append(NSString(string: teamPath).expandingTildeInPath)
        }
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                self?.reloadConfig()
                self?.watchConfigFiles()   // re-arm: editors often replace files
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            configWatchers.append(source)
        }
    }

    func reloadConfig() {
        do {
            let personalTOML = try String(contentsOf: Self.personalConfigURL, encoding: .utf8)
            let personal = try ConfigLoader.personal(fromTOML: personalTOML)
            self.personal = personal

            let teamURL = URL(fileURLWithPath:
                NSString(string: personal.teamConfigPath).expandingTildeInPath)
            do {
                let teamTOML = try String(contentsOf: teamURL, encoding: .utf8)
                let team = try ConfigLoader.team(fromTOML: teamTOML)
                // Parsing succeeded; the config is good regardless of whether the
                // cache write below succeeds, so it must not affect control flow.
                try? store.cacheTeamConfigTOML(teamTOML)
                self.team = team
                configError = nil
            } catch {
                // fall back to last-known-good team config; keep tracking alive
                if let cached = try store.lastKnownGoodTeamConfigTOML() {
                    self.team = try ConfigLoader.team(fromTOML: cached)
                    configError = "Team config unreadable, using cached copy: \(error.localizedDescription)"
                } else {
                    throw error
                }
            }
            projects = ConfigLoader.merge(team: team ?? TeamConfig(projects: [], roundingIncrementHours: 0.25),
                                          overrides: personal.overrides)
            let settings = makeKeeperSettings()
            var keeper = TimeKeeper(projects: projects, settings: settings)
            let running = try? store.runningEntry()
            if let running {
                keeper.restore(runningEntry: running)
            } else if let recent = (try? store.pendingBlocks(asOf: Date()))?.max(by: { $0.end < $1.end }),
                      Date().timeIntervalSince(recent.end) < settings.blockStalenessSeconds {
                // No running timer: continue the most recent still-open block
                // across this relaunch/reload instead of fragmenting the same
                // activity into a new block. Only adopt it while it's still
                // within its live window; older blocks stay finished and the
                // next activity episode opens a fresh one.
                let now = Date()
                let continuation = DateInterval(start: recent.start, end: max(now, recent.end))
                if let entries = try? store.entries(in: continuation) {
                    keeper.restore(openBlock: recent, excluding: entries, asOf: now)
                }
            }
            self.keeper = keeper
            // The rebuilt keeper starts with no switch/idle episode state —
            // clear the published mirrors so the popover doesn't show a
            // suggestion the keeper no longer knows about.
            switchSuggestion = nil
            pendingIdleGap = nil
        } catch {
            configError = "Config error: \(error.localizedDescription)"
        }
    }

    // MARK: - Actions

    func clockIn(projectId: String, backfillFrom: Date? = nil) {
        guard keeper != nil else { return }
        apply(effects: keeper!.clockIn(projectId: projectId, at: Date(),
                                       backfillFrom: backfillFrom,
                                       source: backfillFrom == nil ? .manual : .backfill))
    }

    func clockOut() {
        guard keeper != nil else { return }
        apply(effects: keeper!.clockOut(at: Date()))
    }

    /// Act on the persistent switch suggestion: stop the running timer at the
    /// detected switch point and start the suggested project from there.
    func acceptSwitchSuggestion() {
        guard let suggestion = switchSuggestion else { return }
        let switchPoint = max(suggestion.since, runningEntry?.start ?? suggestion.since)
        stopRunningEntry(at: switchPoint)
        clockIn(projectId: suggestion.projectId, backfillFrom: switchPoint)
    }

    func dismissSwitchSuggestion() {
        keeper?.dismissSwitchCandidate()
        refreshDerived()
    }

    /// Save edits to the still-running entry (project/start/note) without
    /// stopping it. The keeper owns the running entry, so the change goes
    /// through it; the emitted effect persists to the store.
    func updateRunningEntry(_ entry: TimeEntry) {
        guard keeper != nil, entry.end == nil else { return }
        apply(effects: keeper!.updateRunningEntry(entry))
    }

    /// Move the running timer to another project wholesale, keeping its start —
    /// "this whole block was actually X" (vs. the switch banner, which splits
    /// at the detected switch point).
    func reassignRunningEntry(to projectId: String) {
        guard var entry = runningEntry, entry.projectId != projectId else { return }
        entry.projectId = projectId
        updateRunningEntry(entry)
    }

    func stopRunningEntry(at end: Date) {
        guard keeper != nil else { return }
        apply(effects: keeper!.clockOut(at: end))
    }

    // MARK: - Editable runtime settings

    /// Idle threshold and nudge budget live inside the keeper; update them in
    /// place so the change takes effect immediately without dropping the
    /// running timer or the current provisional episode.
    func setIdleThresholdSeconds(_ seconds: Double) {
        settings.idleThresholdSeconds = seconds
        keeper?.updateSettings(makeKeeperSettings())
    }

    func setNudgesPerHour(_ count: Int) {
        settings.nudgesPerHour = count
        keeper?.updateSettings(makeKeeperSettings())
    }

    /// Consumed live by SignalEngine each tick and by the exporter at export
    /// time, so persisting is all that's needed.
    func setAITools(_ tools: [String]) {
        settings.aiTools = tools.isEmpty ? nil : tools
    }

    func setIncludeExactColumn(_ include: Bool) {
        settings.includeExactColumn = include
    }

    func setBrowserDetectionEnabled(_ enabled: Bool) {
        settings.browserDetectionEnabled = enabled
    }

    func setClockInLeadMinutes(_ minutes: Double) {
        settings.clockInLeadMinutes = minutes
        keeper?.updateSettings(makeKeeperSettings())
    }

    func setDayStartHour(_ hour: Int) {
        settings.dayStartHour = hour
        refreshDerived()   // recompute today/week totals against the new boundary
    }

    func setSwitchLeadMinutes(_ minutes: Double) {
        settings.switchLeadMinutes = minutes
        keeper?.updateSettings(makeKeeperSettings())
    }

    func setIdleAutoStopMinutes(_ minutes: Int) {
        settings.idleAutoStopMinutes = minutes
        keeper?.updateSettings(makeKeeperSettings())
    }

    func setDailyTargetHours(_ hours: Double) {
        settings.dailyTargetHours = hours
        refreshDerived()   // republish so an open popover redraws its guide line
    }

    /// Persist an entry resized by dragging its edge in the timeline. The
    /// timeline clamps the drag to neighbouring entries, so this can't create
    /// an entry overlap.
    func saveResizedEntry(_ entry: TimeEntry) {
        guard store != nil else { return }
        try? store.save(entry)
        // The keeper carries its own copy of the running entry; without this,
        // the next clock-out would re-save the stale pre-resize start.
        if entry.end == nil { keeper?.restore(runningEntry: entry) }
        // Resizing is clamped at other entries but may sweep over ghosts.
        clearRange(DateInterval(start: entry.start, end: entry.end ?? Date()),
                   excludingEntry: entry.id)
        refreshDerived()
    }

    /// Persist an unverified block resized by dragging its edge in the timeline.
    func saveResizedBlock(_ block: ProvisionalBlock) {
        guard store != nil else { return }
        try? store.save(block)
        refreshDerived()
    }

    func acceptBlock(_ block: ProvisionalBlock, projectId: String) {
        guard store != nil else { return }
        var accepted = block
        accepted.status = .accepted
        try? store.save(accepted)
        keeper?.resolveBlock(id: block.id)

        // If this is the still-live block (the ongoing episode driving the
        // menubar "?" — the most recent one, still within its staleness window,
        // and no timer already running), confirming it *continues* it as a
        // running timer from its start. That swaps the "?" for an actual running
        // runtime instead of filing a finished entry. Older/finished blocks, or
        // any block confirmed while another timer runs, log a completed entry.
        let isLiveOngoing = runningEntry == nil
            && Date().timeIntervalSince(block.end) < makeKeeperSettings().blockStalenessSeconds
            && block.id == pendingBlocks.max(by: { $0.end < $1.end })?.id
        if isLiveOngoing {
            clearRange(DateInterval(start: block.start, end: Date()), excludingBlock: block.id)
            clockIn(projectId: projectId, backfillFrom: block.start)  // starts the timer + refreshes
            return
        }

        let entry = TimeEntry(projectId: projectId, start: block.start, end: block.end,
                              source: .backfill)
        clearRange(DateInterval(start: block.start, end: block.end), excludingBlock: block.id)
        try? store.save(entry)
        refreshDerived()
    }

    func dismissBlock(_ block: ProvisionalBlock) {
        guard store != nil else { return }
        markDismissed(block)
        refreshDerived()
    }

    /// Bulk-dismiss unverified blocks that ended before `cutoff` (nil = all).
    /// One triage click instead of thirty-four.
    func dismissBlocks(endedBefore cutoff: Date?) {
        guard store != nil else { return }
        for block in pendingBlocks where cutoff.map({ block.end < $0 }) ?? true {
            markDismissed(block)
        }
        refreshDerived()
    }

    /// Unverified blocks touching a work-day (what the day timeline shows).
    func pendingBlocks(in interval: DateInterval) -> [ProvisionalBlock] {
        pendingBlocks.filter {
            $0.end > $0.start && interval.intersects(DateInterval(start: $0.start, end: $0.end))
        }
    }

    /// Clear a whole day's suggestions so it can be drawn in from memory.
    func dismissBlocks(in interval: DateInterval) {
        guard store != nil else { return }
        pendingBlocks(in: interval).forEach { markDismissed($0) }
        refreshDerived()
    }

    /// Same-project ghosts closer than this collapse into one on "Merge".
    static let mergeGapSeconds: TimeInterval = 30 * 60

    /// Shared by the menu count and merge action, with logged time as barriers.
    func mergeableBlockRuns(in interval: DateInterval) -> [[ProvisionalBlock]] {
        let blocks = pendingBlocks(in: interval)
        guard let start = blocks.map(\.start).min(), let end = blocks.map(\.end).max(), end > start,
              let entries = try? store.entries(in: DateInterval(start: start, end: end)) else { return [] }
        let occupied = entries.map { DateInterval(start: $0.start, end: $0.end ?? .distantFuture) }
        return BlockMerging.runs(blocks, maxGap: Self.mergeGapSeconds, excluding: occupied)
            .filter { $0.count > 1 }
    }

    /// Collapse nearby ghosts, dismissing the originals after saving each run.
    func mergeBlocks(in interval: DateInterval) {
        guard store != nil else { return }
        let runs = mergeableBlockRuns(in: interval)
        for run in runs {
            try? store.save(BlockMerging.merged(run))
            run.forEach { markDismissed($0) }
        }
        refreshDerived()
    }

    /// Persist a block as dismissed and detach it from the keeper if it was
    /// the live open block. Callers refresh derived state afterwards.
    private func markDismissed(_ block: ProvisionalBlock, through end: Date? = nil) {
        var dismissed = block
        dismissed.status = .dismissed
        try? store.save(dismissed)
        keeper?.resolveBlock(id: block.id, through: end)
    }

    /// Make room for a logged range (`Overlap`): finished entries that overlap
    /// it shrink, split or go; ghost blocks it covers are dismissed, partially
    /// covered ones clipped. Callers refresh derived state afterwards.
    func clearRange(_ range: DateInterval, excludingEntry entryId: UUID? = nil,
                    excludingBlock blockId: UUID? = nil) {
        guard store != nil else { return }
        let pad: TimeInterval = 86_400
        let window = DateInterval(start: range.start.addingTimeInterval(-pad),
                                  end: range.end.addingTimeInterval(pad))
        let neighbors = (try? store.entries(in: window)) ?? []
        for action in Overlap.clipEntries(neighbors, excluding: entryId, around: range) {
            switch action {
            case .save(let entry): try? store.save(entry)
            case .delete(let id): try? store.delete(entryId: id)
            }
        }
        let blocks = pendingBlocks.filter { $0.id != blockId }
        for action in Overlap.clipBlocks(blocks, around: range) {
            switch action {
            case .save(let block):
                try? store.save(block)
                // If this was the keeper's live block, detach it: the keeper's
                // copy still has the pre-clip edges and would write them back.
                keeper?.resolveBlock(id: block.id, through: range.end)
            case .dismiss(let id):
                if let block = blocks.first(where: { $0.id == id }) { markDismissed(block, through: range.end) }
            }
        }
    }

    func resolveIdleGap(keep: Bool, from: Date, to: Date) {
        guard keeper != nil else { return }
        apply(effects: keeper!.resolveIdleGap(keep: keep, from: from, to: to))
    }

    func handle(observation: Observation) {
        guard keeper != nil else { return }
        // Score the full observation (incl. the active-tab URL), but persist a
        // redacted copy so the observation log only ever keeps the host.
        try? store.append(observation.redactedForStorage())
        apply(effects: keeper!.handle(observation))
    }

    func apply(effects: [TimeKeeperEffect]) {
        for effect in effects {
            switch effect {
            case .entryStarted(let entry), .entryStopped(let entry):
                try? store.save(entry)
            case .provisionalOpened(let block), .provisionalUpdated(let block):
                try? store.save(block)
            case .nudgeClockIn(let projectId, let since):
                Notifier.shared.nudgeClockIn(project: project(projectId), since: since)
            case .nudgeSwitch(let projectId, let detectedAt):
                Notifier.shared.nudgeSwitch(project: project(projectId), detectedAt: detectedAt)
            case .askIdleGap(let from, let to):
                Notifier.shared.askIdleGap(from: from, to: to)
            case .autoClockedOut(let projectId, let at):
                let name = project(projectId)?.name ?? projectId
                recoveryNotice = "Stopped the \(name) timer at "
                    + "\(at.formatted(date: .abbreviated, time: .shortened)) after a long "
                    + "idle stretch — adjust it in Review if that's wrong."
                Notifier.shared.autoClockedOut(project: project(projectId), at: at)
            }
        }
        refreshDerived()
    }

    func project(_ id: String) -> Project? {
        projects.first { $0.id == id }
    }

    func refreshDerived() {
        runningEntry = try? store.runningEntry()
        pendingBlocks = (try? store.pendingBlocks(asOf: Date())) ?? []
        switchSuggestion = keeper?.switchCandidate
        pendingIdleGap = keeper?.pendingIdleGap
        let now = Date()
        let week = workday.weekInterval(for: now)
        // Today's logical day always lies inside the current week interval
        // (both use the same day-start boundary), so one week query feeds
        // both totals and the popover chart.
        let weekEntries = (try? store.entries(in: week)) ?? []
        todayTotal = total(of: weekEntries, in: workday.dayInterval(for: now), now: now)
        weekTotal = total(of: weekEntries, in: week, now: now)
        let cal = workday.calendar
        let weekStartMidnight = workday.logicalDayMidnight(for: week.start)
        let days = (0..<7).compactMap {
            cal.date(byAdding: .day, value: $0, to: weekStartMidnight)
        }
        popoverWeekReport = WeekReport(
            entries: weekEntries, projects: projects, days: days,
            workday: workday, incrementHours: team?.roundingIncrementHours ?? 0.25,
            asOf: now, splitAtDayBoundaries: true)
        try? store.pruneObservations(olderThan: now.addingTimeInterval(-30 * 86_400))
    }

    private func total(of entries: [TimeEntry], in interval: DateInterval,
                       now: Date) -> TimeInterval {
        entries.reduce(0) { sum, entry in
            let start = max(entry.start, interval.start)
            let end = min(entry.end ?? now, interval.end)
            return sum + max(0, end.timeIntervalSince(start))
        }
    }
}
