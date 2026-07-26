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
    @Published var configError: String?
    @Published var recoveryNotice: String?   // dangling-entry recovery, user-dismissable

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
        return s
    }

    static let personalConfigURL = URL(fileURLWithPath:
        NSString(string: "~/.config/clocktopus/config.toml").expandingTildeInPath)
    static let dbURL = URL(fileURLWithPath: NSString(
        string: "~/Library/Application Support/Clocktopus/clocktopus.sqlite").expandingTildeInPath)

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
                keeper.restore(openBlock: recent)
            }
            self.keeper = keeper
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

    /// Persist an entry resized by dragging its edge in the timeline. The
    /// timeline clamps the drag to neighbours, so this can't create an overlap.
    func saveResizedEntry(_ entry: TimeEntry) {
        guard store != nil else { return }
        try? store.save(entry)
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
            clockIn(projectId: projectId, backfillFrom: block.start)  // starts the timer + refreshes
            return
        }

        let entry = TimeEntry(projectId: projectId, start: block.start, end: block.end,
                              source: .backfill)
        try? store.save(entry)
        refreshDerived()
    }

    func dismissBlock(_ block: ProvisionalBlock) {
        guard store != nil else { return }
        var dismissed = block
        dismissed.status = .dismissed
        try? store.save(dismissed)
        keeper?.resolveBlock(id: block.id)
        refreshDerived()
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
        let now = Date()
        todayTotal = total(in: workday.dayInterval(for: now), now: now)
        weekTotal = total(in: workday.weekInterval(for: now), now: now)
        try? store.pruneObservations(olderThan: now.addingTimeInterval(-30 * 86_400))
    }

    private func total(in interval: DateInterval, now: Date) -> TimeInterval {
        ((try? store.entries(in: interval)) ?? []).reduce(0) { sum, entry in
            let start = max(entry.start, interval.start)
            let end = min(entry.end ?? now, interval.end)
            return sum + max(0, end.timeIntervalSince(start))
        }
    }
}
