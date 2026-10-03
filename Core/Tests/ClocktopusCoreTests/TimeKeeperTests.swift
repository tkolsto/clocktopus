import XCTest
@testable import ClocktopusCore

final class TimeKeeperTests: XCTestCase {
    let initech = Project(name: "Initech", xledgerProject: "1", xledgerActivity: "DEV",
                      dirs: ["~/src/initech*"])
    let ops = Project(name: "CanopyOps", xledgerProject: "2", xledgerActivity: "DEV",
                      dirs: ["~/src/canopyops"])
    var keeper: TimeKeeper!
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        keeper = TimeKeeper(projects: [initech, ops], settings: TimeKeeperSettings())
    }

    func testClockInStartsEntry() {
        let effects = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        XCTAssertEqual(keeper.runningEntry?.projectId, "initech")
        XCTAssertEqual(keeper.runningEntry?.start, t0)
        guard case .entryStarted(let entry)? = effects.first else {
            return XCTFail("expected entryStarted, got \(effects)")
        }
        XCTAssertEqual(entry.projectId, "initech")
    }

    func testClockInWithBackfillStartsEarlier() {
        let backfill = t0.addingTimeInterval(-1800)
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: backfill, source: .backfill)
        XCTAssertEqual(keeper.runningEntry?.start, backfill)
        XCTAssertEqual(keeper.runningEntry?.source, .backfill)
    }

    func testSwitchingProjectsStopsCurrentFirst() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let effects = keeper.clockIn(projectId: "canopyops", at: t0.addingTimeInterval(3600),
                                     backfillFrom: nil, source: .manual)
        // single running entry invariant
        XCTAssertEqual(keeper.runningEntry?.projectId, "canopyops")
        guard case .entryStopped(let stopped)? = effects.first else {
            return XCTFail("expected entryStopped first, got \(effects)")
        }
        XCTAssertEqual(stopped.projectId, "initech")
        XCTAssertEqual(stopped.end, t0.addingTimeInterval(3600))
        guard case .entryStarted? = effects.dropFirst().first else {
            return XCTFail("expected entryStarted second")
        }
    }

    func testClockOut() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let effects = keeper.clockOut(at: t0.addingTimeInterval(600))
        XCTAssertNil(keeper.runningEntry)
        guard case .entryStopped(let entry)? = effects.first else {
            return XCTFail("expected entryStopped, got \(effects)")
        }
        XCTAssertEqual(entry.duration(asOf: entry.end!), 600)
    }

    func testRestorePreservesEntryIdentity() {
        let entry = TimeEntry(id: UUID(), projectId: "initech", start: t0, source: .manual)
        keeper.restore(runningEntry: entry)
        XCTAssertEqual(keeper.runningEntry, entry)
        let effects = keeper.clockOut(at: t0.addingTimeInterval(600))
        guard case .entryStopped(let stopped)? = effects.first else {
            return XCTFail("expected entryStopped, got \(effects)")
        }
        XCTAssertEqual(stopped.id, entry.id)
        XCTAssertEqual(stopped.start, entry.start)
    }

    func testRestoreOpenBlockContinuesAcrossRelaunch() {
        // Original keeper: 6 minutes of initech activity opens one provisional block.
        var opened: [ProvisionalBlock] = []
        for i in 0..<12 {
            for e in keeper.handle(obs(Double(i) * 30, dir: "/src/initech")) {
                if case .provisionalOpened(let b) = e { opened.append(b) }
            }
        }
        XCTAssertEqual(opened.count, 1, "sanity: exactly one block opened")
        let block = opened[0]                 // ends ~t0+330

        // Simulate a relaunch: a brand-new keeper re-adopts the still-open block
        // (as AppState does from the store), then activity resumes ~2.5 min later.
        var restarted = TimeKeeper(projects: [initech, ops], settings: TimeKeeperSettings())
        restarted.restore(openBlock: block)

        var effects: [TimeKeeperEffect] = []
        for i in 0..<6 {
            effects += restarted.handle(obs(480 + Double(i) * 30, dir: "/src/initech"))
        }

        // Continued activity must EXTEND the same block, not fragment into a new
        // one, and a restart must not re-fire the clock-in nudge.
        XCTAssertFalse(effects.contains { if case .provisionalOpened = $0 { return true }; return false },
                       "restored block must continue, not open a second block")
        let updated = effects.compactMap { e -> ProvisionalBlock? in
            if case .provisionalUpdated(let b) = e { return b }; return nil
        }
        XCTAssertFalse(updated.isEmpty, "resumed activity should extend the block")
        XCTAssertTrue(updated.allSatisfy { $0.id == block.id }, "same block identity preserved")
        XCTAssertGreaterThan(updated.last!.end, block.end, "block end advanced past its original end")
        XCTAssertFalse(effects.contains { if case .nudgeClockIn = $0 { return true }; return false },
                       "a restored block must not re-nudge on restart")
    }

    func testClockOutWhenNotRunningIsNoop() {
        XCTAssertTrue(keeper.clockOut(at: t0).isEmpty)
    }

    func testClockInSameProjectIsNoop() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let effects = keeper.clockIn(projectId: "initech", at: t0.addingTimeInterval(60),
                                     backfillFrom: nil, source: .manual)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(keeper.runningEntry?.start, t0)
    }

    // MARK: - Observation handling

    private func obs(_ offset: TimeInterval, dir: String? = nil,
                     kind: DirKind = .frontmostShell, idle: TimeInterval = 0) -> Observation {
        let home = NSString(string: "~").expandingTildeInPath
        return Observation(
            timestamp: t0.addingTimeInterval(offset),
            dirs: dir.map { [ObservedDir(path: home + $0, kind: kind)] } ?? [],
            idleSeconds: idle)
    }

    func testSustainedActivityNudgesClockInWithBackfill() {
        var all: [TimeKeeperEffect] = []
        for i in 0..<12 {   // 6 minutes of initech activity, 30s ticks
            all += keeper.handle(obs(Double(i) * 30, dir: "/src/initech"))
        }
        let nudges = all.compactMap { effect -> (String, Date)? in
            if case .nudgeClockIn(let p, let since) = effect { return (p, since) }
            return nil
        }
        XCTAssertEqual(nudges.count, 1, "exactly one nudge per block")
        XCTAssertEqual(nudges.first?.0, "initech")
        // backfill anchor reaches back to activity start
        XCTAssertLessThanOrEqual(nudges.first!.1.timeIntervalSince(t0), 31)
        // a provisional block was opened
        XCTAssertTrue(all.contains { if case .provisionalOpened = $0 { return true }; return false })
    }

    func testNoNudgeWhileClockedInAndSignalsAgree() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        var all: [TimeKeeperEffect] = []
        for i in 0..<20 {
            all += keeper.handle(obs(Double(i) * 30, dir: "/src/initech"))
        }
        XCTAssertTrue(all.isEmpty, "silence is a feature, got \(all)")
    }

    func testSwitchNudgeAfterTenMinutesOnOtherProject() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        var all: [TimeKeeperEffect] = []
        for i in 0..<24 {   // 12 minutes in canopyops while clocked into initech
            all += keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops"))
        }
        let switches = all.filter { if case .nudgeSwitch = $0 { return true }; return false }
        XCTAssertEqual(switches.count, 1)
        guard case .nudgeSwitch(let to, _) = switches[0] else { return XCTFail() }
        XCTAssertEqual(to, "canopyops")
    }

    // MARK: - Switch candidate (persistent suggestion)

    func testSwitchCandidatePersistsAndNudgesOncePerEpisode() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        var all: [TimeKeeperEffect] = []
        // 40 minutes on canopyops: well past the point where the scoring
        // window slides and `leadingSince` starts drifting every observation —
        // the old dedup key. Still exactly one nudge, and a stable candidate.
        for i in 0..<80 {
            all += keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops"))
        }
        let switches = all.filter { if case .nudgeSwitch = $0 { return true }; return false }
        XCTAssertEqual(switches.count, 1, "one nudge per episode, not one per budget refill")
        let candidate = try! XCTUnwrap(keeper.switchCandidate)
        XCTAssertEqual(candidate.projectId, "canopyops")
        // The anchor is frozen at formation, not sliding with the window.
        XCTAssertLessThanOrEqual(candidate.since.timeIntervalSince(t0), 60)
    }

    func testSwitchCandidateClearsWhenRunningProjectLeadsAgain() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        for i in 0..<24 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops")) }
        XCTAssertNotNil(keeper.switchCandidate)
        // Back on the clocked-in project long enough to outscore the leftovers.
        for i in 24..<80 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/initech")) }
        XCTAssertNil(keeper.switchCandidate, "returning to the running project retires the suggestion")
    }

    func testDismissedSwitchCandidateStaysDismissedWhileLeadingButReturns() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        for i in 0..<24 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops")) }
        XCTAssertNotNil(keeper.switchCandidate)
        keeper.dismissSwitchCandidate()
        XCTAssertNil(keeper.switchCandidate)

        // Continued canopyops lead must NOT resurrect the dismissed suggestion.
        var after: [TimeKeeperEffect] = []
        for i in 24..<48 { after += keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops")) }
        XCTAssertNil(keeper.switchCandidate)
        XCTAssertFalse(after.contains { if case .nudgeSwitch = $0 { return true }; return false })

        // Lead returns to initech (forgives the dismissal), then a NEW
        // canopyops episode earns a fresh suggestion.
        for i in 48..<110 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/initech")) }
        for i in 110..<160 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops")) }
        XCTAssertEqual(keeper.switchCandidate?.projectId, "canopyops",
                       "a fresh episode after a dismissal earns a fresh suggestion")
    }

    func testUpdateRunningEntryReassignsWithoutStopping() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let originalId = keeper.runningEntry!.id
        // Sustained canopyops lead raises a switch suggestion…
        for i in 0..<24 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops")) }
        XCTAssertEqual(keeper.switchCandidate?.projectId, "canopyops")

        // …and the user reassigns the whole running block instead of splitting.
        var edited = keeper.runningEntry!
        edited.projectId = "canopyops"
        let effects = keeper.updateRunningEntry(edited)

        XCTAssertEqual(keeper.runningEntry?.projectId, "canopyops")
        XCTAssertEqual(keeper.runningEntry?.id, originalId, "identity survives the reassign")
        XCTAssertEqual(keeper.runningEntry?.start, t0, "still backdated to the original start")
        XCTAssertNil(keeper.runningEntry?.end, "still running")
        XCTAssertNil(keeper.switchCandidate, "the reassign satisfies the suggestion")
        guard case .entryStarted(let saved)? = effects.first else {
            return XCTFail("expected a persistence effect, got \(effects)")
        }
        XCTAssertEqual(saved.projectId, "canopyops")
    }

    func testUpdateRunningEntryRejectsStoppedOrAbsentTimers() {
        // No running timer: nothing to update.
        let ghost = TimeEntry(projectId: "initech", start: t0, source: .manual)
        XCTAssertTrue(keeper.updateRunningEntry(ghost).isEmpty)

        // An entry with an end would silently stop the timer through the back
        // door — refuse it.
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        var closed = keeper.runningEntry!
        closed.end = t0.addingTimeInterval(600)
        XCTAssertTrue(keeper.updateRunningEntry(closed).isEmpty)
        XCTAssertNil(keeper.runningEntry?.end)
    }

    func testSwitchCandidateClearedByClockActions() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        for i in 0..<24 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/canopyops")) }
        XCTAssertNotNil(keeper.switchCandidate)
        _ = keeper.clockIn(projectId: "canopyops", at: t0.addingTimeInterval(800),
                           backfillFrom: nil, source: .manual)
        XCTAssertNil(keeper.switchCandidate, "acting on the suggestion resolves it")
    }

    func testAmbiguousSignalsNeverNudge() {
        var all: [TimeKeeperEffect] = []
        for i in 0..<20 {
            // both projects observed each tick with comparable weight
            let home = NSString(string: "~").expandingTildeInPath
            all += keeper.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell),
                       ObservedDir(path: home + "/src/canopyops", kind: .frontmostShell)]))
        }
        XCTAssertFalse(all.contains { if case .nudgeClockIn = $0 { return true }; return false })
        // but an ambiguous provisional block IS opened for later review
        let opened = all.compactMap { e -> ProvisionalBlock? in
            if case .provisionalOpened(let b) = e { return b }
            return nil
        }
        XCTAssertFalse(opened.isEmpty)
        XCTAssertNil(opened[0].guessedProjectId)
    }

    func testNudgeBudgetCapsPerHour() {
        var all: [TimeKeeperEffect] = []
        // three separate 6-min bursts on alternating projects within one hour,
        // separated by 16-min gaps (> blockStalenessSeconds, so each burst
        // detaches the prior stale block and opens a fresh one)
        for burst in 0..<3 {
            let dir = burst % 2 == 0 ? "/src/initech" : "/src/canopyops"
            let base = Double(burst) * (22 * 60)
            for i in 0..<12 {
                all += keeper.handle(obs(base + Double(i) * 30, dir: dir))
            }
        }
        let nudges = all.filter { if case .nudgeClockIn = $0 { return true }; return false }
        XCTAssertEqual(nudges.count, 2, "budget is 2/hour and must actually be exercised")
        let openedIds = all.compactMap { e -> UUID? in
            if case .provisionalOpened(let b) = e { return b.id }
            return nil
        }
        XCTAssertEqual(openedIds.count, 3, "each burst gets a fresh block after staleness detach")
        XCTAssertEqual(Set(openedIds).count, 3, "the three blocks must be distinct")
    }

    func testNewEpisodeAfterLapseGetsFreshNudge() {
        var all: [TimeKeeperEffect] = []
        // 6 minutes of initech activity -> one block, one nudge
        for i in 0..<12 {
            all += keeper.handle(obs(Double(i) * 30, dir: "/src/initech"))
        }
        // quiet gap: ticks with empty dirs so the scorer window (15 min)
        // drains and the block staleness window (10 min) passes
        for offset in stride(from: 400.0, through: 1300.0, by: 300.0) {
            all += keeper.handle(obs(offset))
        }
        // 6 minutes of canopyops activity -> should be a wholly new episode
        for i in 0..<12 {
            all += keeper.handle(obs(1400 + Double(i) * 30, dir: "/src/canopyops"))
        }

        let opened = all.compactMap { e -> ProvisionalBlock? in
            if case .provisionalOpened(let b) = e { return b }
            return nil
        }
        XCTAssertEqual(opened.count, 2, "the lapse must produce a second, fresh block")
        XCTAssertNotEqual(opened[0].id, opened[1].id)

        let nudges = all.compactMap { e -> String? in
            if case .nudgeClockIn(let p, _) = e { return p }
            return nil
        }
        XCTAssertEqual(nudges, ["initech", "canopyops"], "each episode earns its own nudge")
    }

    func testResolveBlockPreventsResurrection() {
        var all: [TimeKeeperEffect] = []
        // 6 minutes of initech activity -> opens a provisional block
        for i in 0..<12 {
            all += keeper.handle(obs(Double(i) * 30, dir: "/src/initech"))
        }
        let opened = all.compactMap { e -> ProvisionalBlock? in
            if case .provisionalOpened(let b) = e { return b }
            return nil
        }
        XCTAssertEqual(opened.count, 1, "sanity: exactly one block opened")
        let resolvedId = opened[0].id

        // Resolved out-of-band (accepted/dismissed via review UI)
        keeper.resolveBlock(id: resolvedId)

        // Drive one more in-window observation for the same project
        let more = keeper.handle(obs(12 * 30, dir: "/src/initech"))

        // Must never re-touch the resolved block's id
        let touchesResolvedId = more.contains { effect -> Bool in
            switch effect {
            case .provisionalOpened(let b), .provisionalUpdated(let b):
                return b.id == resolvedId
            default:
                return false
            }
        }
        XCTAssertFalse(touchesResolvedId, "resolved block must not resurrect, got \(more)")

        // If a new block is opened instead, it must have a different id.
        for effect in more {
            if case .provisionalOpened(let b) = effect {
                XCTAssertNotEqual(b.id, resolvedId)
                XCTAssertGreaterThanOrEqual(b.start, t0.addingTimeInterval(330))
            }
        }
    }

    func testClippedBlockCannotResumeAcrossLoggedTimeAfterReload() {
        let original = ProvisionalBlock(guessedProjectId: "initech", start: t0,
                                        end: t0.addingTimeInterval(300), confidence: 1, evidence: "terminal")
        let logged = TimeEntry(projectId: "canopyops", start: t0.addingTimeInterval(180),
                               end: t0.addingTimeInterval(360), source: .manual)
        let clipped = Overlap.clipBlocks([original], around: DateInterval(start: logged.start, end: logged.end!))
            .compactMap { action -> ProvisionalBlock? in
                if case .save(let block) = action { return block }; return nil
            }
        let head = try! XCTUnwrap(clipped.first)
        keeper.restore(openBlock: head, excluding: [logged], asOf: logged.end!)
        XCTAssertNil(keeper.openBlock)
        var effects: [TimeKeeperEffect] = []
        for i in 0..<12 { effects += keeper.handle(obs(360 + Double(i) * 30, dir: "/src/initech")) }
        let blocks = effects.compactMap { effect -> ProvisionalBlock? in
            switch effect {
            case .provisionalOpened(let b), .provisionalUpdated(let b): return b
            default: return nil
            }
        }
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertTrue(blocks.allSatisfy { $0.start >= logged.end! && $0.id != head.id })
    }

    func testClippedLiveBlockCannotBackfillOverLoggedRange() {
        for i in 0..<12 { _ = keeper.handle(obs(Double(i) * 30, dir: "/src/initech")) }
        let block = try! XCTUnwrap(keeper.openBlock)
        let loggedEnd = t0.addingTimeInterval(400)
        keeper.resolveBlock(id: block.id, through: loggedEnd)
        var effects: [TimeKeeperEffect] = []
        for i in 12..<22 { effects += keeper.handle(obs(Double(i) * 30, dir: "/src/initech")) }
        let opened = effects.compactMap { effect -> ProvisionalBlock? in
            if case .provisionalOpened(let b) = effect { return b }; return nil
        }
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.start, loggedEnd)
        XCTAssertTrue(opened.allSatisfy { $0.end > $0.start })
    }

    func testProvisionalBlockEvidenceTracksLatestActivity() {
        // A block that stays open while the browser tab changes must reflect the
        // CURRENT activity, not the snapshot from when it first opened.
        let home = NSString(string: "~").expandingTildeInPath
        func ob(_ offset: TimeInterval, url: String) -> Observation {
            Observation(timestamp: t0.addingTimeInterval(offset),
                        dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)],
                        activeTabURL: url)
        }
        var all: [TimeKeeperEffect] = []
        // 6 min on initech with a proton tab open -> block opens with proton evidence
        for i in 0..<12 { all += keeper.handle(ob(Double(i) * 30, url: "https://account.proton.me/u/0")) }
        // still on initech, but the tab is now a github/initech page
        for i in 12..<16 { all += keeper.handle(ob(Double(i) * 30, url: "https://github.com/initech/initech")) }

        let blocks = all.compactMap { effect -> ProvisionalBlock? in
            switch effect {
            case .provisionalOpened(let b), .provisionalUpdated(let b): return b
            default: return nil
            }
        }
        let latest = try! XCTUnwrap(blocks.last)
        XCTAssertTrue(latest.evidence.contains("github.com"),
                      "evidence should track current activity, got: \(latest.evidence)")
        XCTAssertFalse(latest.evidence.contains("proton"),
                       "stale first-open evidence should be gone, got: \(latest.evidence)")
    }

    func testEvidenceIgnoresObservationsThatDidNotScoreTheLeader() {
        // The scorer's decay keeps initech leading for a while after the user
        // wanders off to an unrelated site. That unrelated observation must not
        // become the block's evidence — it never matched anything.
        let home = NSString(string: "~").expandingTildeInPath
        var all: [TimeKeeperEffect] = []
        for i in 0..<12 {
            all += keeper.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)],
                frontmostAppName: "Ghostty"))
        }
        for i in 12..<16 {
            all += keeper.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                activeTabURL: "https://news.example.org/story", frontmostAppName: "Google Chrome"))
        }
        let blocks = all.compactMap { effect -> ProvisionalBlock? in
            switch effect {
            case .provisionalOpened(let b), .provisionalUpdated(let b): return b
            default: return nil
            }
        }
        let latest = try! XCTUnwrap(blocks.last)
        XCTAssertEqual(latest.guessedProjectId, "initech")
        XCTAssertTrue(latest.evidence.contains("initech"), "got: \(latest.evidence)")
        XCTAssertFalse(latest.evidence.contains("news.example.org"), "got: \(latest.evidence)")
        XCTAssertFalse(latest.signals.contains(.browser), "got: \(latest.signals)")
    }

    func testEvidenceUsesFriendlyAppNameAndDedupesBrowser() {
        let home = NSString(string: "~").expandingTildeInPath
        func lastEvidence(_ effects: [TimeKeeperEffect]) -> String {
            effects.compactMap { e -> String? in
                switch e {
                case .provisionalOpened(let b), .provisionalUpdated(let b): return b.evidence
                default: return nil
                }
            }.last ?? ""
        }

        // Non-browser app: the friendly name appears, never the bundle id.
        var slack = TimeKeeper(projects: [initech], settings: TimeKeeperSettings())
        var slackEffects: [TimeKeeperEffect] = []
        for i in 0..<12 {
            slackEffects += slack.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                frontmostApp: "com.tinyspeck.slackmacgap",
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)],
                frontmostAppName: "Slack"))
        }
        let slackEv = lastEvidence(slackEffects)
        XCTAssertTrue(slackEv.contains("Slack"), slackEv)
        XCTAssertFalse(slackEv.contains("com.tinyspeck"), slackEv)

        // Browser: the host wins and the app name is suppressed (no redundancy).
        var chrome = TimeKeeper(projects: [initech], settings: TimeKeeperSettings())
        var chromeEffects: [TimeKeeperEffect] = []
        for i in 0..<12 {
            chromeEffects += chrome.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                frontmostApp: "com.google.Chrome",
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)],
                activeTabURL: "https://github.com/initech/initech",
                frontmostAppName: "Google Chrome"))
        }
        let chromeEv = lastEvidence(chromeEffects)
        XCTAssertTrue(chromeEv.contains("browser github.com"), chromeEv)
        XCTAssertFalse(chromeEv.contains("Google Chrome"), chromeEv)
    }

    func testEvidencePrefersActiveTmuxPane() {
        let home = NSString(string: "~").expandingTildeInPath
        func ob(_ offset: TimeInterval) -> Observation {
            Observation(timestamp: t0.addingTimeInterval(offset),
                        dirs: [ObservedDir(path: home + "/other/parked", kind: .tmuxPane),   // background, listed first
                               ObservedDir(path: home + "/src/initech", kind: .tmuxActivePane)])  // active
        }
        var effects: [TimeKeeperEffect] = []
        for i in 0..<12 { effects += keeper.handle(ob(Double(i) * 30)) }
        let ev = effects.compactMap { e -> String? in
            switch e {
            case .provisionalOpened(let b), .provisionalUpdated(let b): return b.evidence
            default: return nil
            }
        }.last ?? ""
        XCTAssertTrue(ev.contains("active tmux pane in ~/src/initech"), ev)
        XCTAssertFalse(ev.contains("parked"), ev)
    }

    func testActivePaneUnderCatchAllDirOpensBlock() {
        // Reproduces the live setup: home shell in the foreground (matches no
        // project) + an active tmux pane under a project's catch-all "~/src/".
        let home = NSString(string: "~").expandingTildeInPath
        let priv = Project(name: "Priv", xledgerProject: "9", xledgerActivity: "PRIV",
                           dirs: ["~/src/"])
        var k = TimeKeeper(projects: [priv], settings: TimeKeeperSettings())
        var effects: [TimeKeeperEffect] = []
        for i in 0..<14 {
            effects += k.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                frontmostApp: "com.mitchellh.ghostty",
                dirs: [ObservedDir(path: home, kind: .frontmostShell),
                       ObservedDir(path: home + "/src/ttt", kind: .tmuxActivePane)],
                frontmostAppName: "Ghostty"))
        }
        let openedPriv = effects.contains {
            if case .provisionalOpened(let b) = $0 { return b.guessedProjectId == "priv" }
            return false
        }
        XCTAssertTrue(openedPriv, "active pane under a catch-all dir should open a Priv block; got \(effects)")
    }

    func testEvidenceShowsForegroundAIToolNotBackground() {
        // Active pane in ~/src/ttt with a Claude session there; a parked Claude
        // in canopyops should NOT be what evidence reports.
        let home = NSString(string: "~").expandingTildeInPath
        let priv = Project(name: "Priv", xledgerProject: "9", xledgerActivity: "PRIV",
                           dirs: ["~/src/"])
        var k = TimeKeeper(projects: [priv], settings: TimeKeeperSettings())
        var effects: [TimeKeeperEffect] = []
        for i in 0..<12 {
            effects += k.handle(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/Documents/src/canopyops", kind: .aiTool),  // background, listed first
                       ObservedDir(path: home + "/src/ttt", kind: .tmuxActivePane),      // active pane
                       ObservedDir(path: home + "/src/ttt", kind: .aiTool)]))            // foreground AI
        }
        let ev = effects.compactMap { e -> String? in
            switch e {
            case .provisionalOpened(let b), .provisionalUpdated(let b): return b.evidence
            default: return nil
            }
        }.last ?? ""
        XCTAssertTrue(ev.contains("AI tool in ~/src/ttt"), ev)
        XCTAssertFalse(ev.contains("canopyops"), ev)
    }

    func testProvisionalBlockCapturesSignalKinds() {
        let home = NSString(string: "~").expandingTildeInPath
        func ob(_ offset: TimeInterval) -> Observation {
            Observation(timestamp: t0.addingTimeInterval(offset),
                        frontmostApp: "com.google.Chrome",
                        dirs: [ObservedDir(path: home + "/src/initech", kind: .tmuxActivePane),
                               ObservedDir(path: home + "/src/initech", kind: .frontmostShell),
                               ObservedDir(path: home + "/src/initech", kind: .aiTool)],
                        activeTabURL: "https://initech.example.com/x",
                        frontmostAppName: "Google Chrome")
        }
        var all: [TimeKeeperEffect] = []
        for i in 0..<12 { all += keeper.handle(ob(Double(i) * 30)) }
        let signals = all.compactMap { e -> ProvisionalBlock? in
            switch e {
            case .provisionalOpened(let b), .provisionalUpdated(let b): return b
            default: return nil
            }
        }.last?.signals ?? []
        XCTAssertTrue(signals.contains(.terminal))
        XCTAssertTrue(signals.contains(.tmux))
        XCTAssertTrue(signals.contains(.aiTool))
        XCTAssertTrue(signals.contains(.browser))
        XCTAssertFalse(signals.contains(.app))   // browser present -> app not double-counted
    }

    // MARK: - Settings updates

    func testUpdateSettingsPreservesStateAndAppliesLive() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let runningId = keeper.runningEntry?.id

        // Lower the idle threshold in place (as Preferences would).
        var s = keeper.settings
        s.idleThresholdSeconds = 120
        keeper.updateSettings(s)

        // In-flight state survives the swap; the new value is stored.
        XCTAssertEqual(keeper.runningEntry?.id, runningId)
        XCTAssertEqual(keeper.settings.idleThresholdSeconds, 120)

        // The new threshold applies live: 150s idle exceeds 120 (but would not
        // have exceeded the default 300), so returning now asks about the gap.
        _ = keeper.handle(obs(0, dir: "/src/initech"))
        _ = keeper.handle(obs(200, dir: "/src/initech", idle: 150))
        let back = keeper.handle(obs(230, dir: "/src/initech", idle: 5))
        let asked = back.contains { if case .askIdleGap = $0 { return true }; return false }
        XCTAssertTrue(asked, "updated idle threshold should apply live, got \(back)")
    }

    // MARK: - Idle

    func testIdleBeyondThresholdAsksAboutGap() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        var all: [TimeKeeperEffect] = []
        all += keeper.handle(obs(0, dir: "/src/initech"))
        all += keeper.handle(obs(600, dir: "/src/initech", idle: 590))   // 590s idle > 300s threshold
        all += keeper.handle(obs(630, dir: "/src/initech", idle: 5))     // user is back
        let asks = all.compactMap { e -> (Date, Date)? in
            if case .askIdleGap(let from, let to) = e { return (from, to) }
            return nil
        }
        XCTAssertEqual(asks.count, 1)
        // gap start = when idleness began (timestamp - idleSeconds)
        XCTAssertEqual(asks[0].0.timeIntervalSince(t0), 10, accuracy: 1)
        XCTAssertEqual(asks[0].1.timeIntervalSince(t0), 630, accuracy: 1)
    }

    func testResolveIdleGapDiscardSplitsEntry() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let from = t0.addingTimeInterval(10)
        let to = t0.addingTimeInterval(630)
        let effects = keeper.resolveIdleGap(keep: false, from: from, to: to)
        // running entry is split: closed at gap start, new one from gap end
        guard case .entryStopped(let closed)? = effects.first else {
            return XCTFail("expected entryStopped, got \(effects)")
        }
        XCTAssertEqual(closed.end, from)
        XCTAssertEqual(keeper.runningEntry?.start, to)
        XCTAssertEqual(keeper.runningEntry?.projectId, "initech")
    }

    func testResolveIdleGapKeepIsNoop() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let effects = keeper.resolveIdleGap(keep: true,
                                            from: t0.addingTimeInterval(10),
                                            to: t0.addingTimeInterval(630))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(keeper.runningEntry?.start, t0)
    }

    func testIdleGapStaysPendingUntilResolved() {
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        _ = keeper.handle(obs(0, dir: "/src/initech"))
        _ = keeper.handle(obs(600, dir: "/src/initech", idle: 590))
        _ = keeper.handle(obs(630, dir: "/src/initech", idle: 5))     // back
        let gap = try! XCTUnwrap(keeper.pendingIdleGap, "the ask must persist, not fire-and-forget")
        XCTAssertEqual(gap.from.timeIntervalSince(t0), 10, accuracy: 1)
        XCTAssertEqual(gap.to.timeIntervalSince(t0), 630, accuracy: 1)

        _ = keeper.resolveIdleGap(keep: true, from: gap.from, to: gap.to)
        XCTAssertNil(keeper.pendingIdleGap)
    }

    // MARK: - Idle auto-stop cap

    func testLongIdleAutoStopsAtIdleStart() {
        var s = TimeKeeperSettings()
        s.idleAutoStopSeconds = 3600
        keeper.updateSettings(s)
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        _ = keeper.handle(obs(0, dir: "/src/initech"))

        // 65 minutes idle in one observation (overnight in miniature).
        let effects = keeper.handle(obs(4200, idle: 3900))
        XCTAssertNil(keeper.runningEntry)
        let stopped = effects.compactMap { e -> TimeEntry? in
            if case .entryStopped(let entry) = e { return entry }; return nil
        }
        XCTAssertEqual(stopped.count, 1)
        // Stopped at the honest end: when idleness began (4200 - 3900 = 300s).
        XCTAssertEqual(stopped[0].end!.timeIntervalSince(t0), 300, accuracy: 1)
        let notices = effects.filter { if case .autoClockedOut = $0 { return true }; return false }
        XCTAssertEqual(notices.count, 1, "the user must be told why the timer stopped")
        XCTAssertNil(keeper.pendingIdleGap, "the stop resolves the gap; no dangling question")
    }

    func testAutoStopDisabledWhenCapIsZero() {
        var s = TimeKeeperSettings()
        s.idleAutoStopSeconds = 0
        keeper.updateSettings(s)
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        _ = keeper.handle(obs(0, dir: "/src/initech"))
        _ = keeper.handle(obs(50_000, idle: 49_000))
        XCTAssertNotNil(keeper.runningEntry, "0 disables the cap (ask-only mode)")
    }

    func testAutoStopNeverEndsBeforeEntryStart() {
        var s = TimeKeeperSettings()
        s.idleAutoStopSeconds = 3600
        keeper.updateSettings(s)
        // Clock in while ALREADY long idle (e.g. via a notification action):
        // the honest end would precede the start — clamp to the start.
        _ = keeper.clockIn(projectId: "initech", at: t0, backfillFrom: nil, source: .manual)
        let effects = keeper.handle(obs(60, idle: 7200))
        let stopped = effects.compactMap { e -> TimeEntry? in
            if case .entryStopped(let entry) = e { return entry }; return nil
        }
        XCTAssertEqual(stopped.first?.end, stopped.first.map { _ in t0 })
    }
}
