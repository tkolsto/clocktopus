import XCTest
@testable import ClocktopusCore

final class ScorerTests: XCTestCase {
    let initech = Project(name: "Initech", xledgerProject: "1", xledgerActivity: "DEV",
                      dirs: ["~/src/initech*"], keywords: ["initech"])
    let ops = Project(name: "CanopyOps", xledgerProject: "2", xledgerActivity: "DEV",
                      dirs: ["~/src/canopyops"])
    let meet = Project(name: "Meetings", xledgerProject: "3", xledgerActivity: "MEET",
                       apps: ["us.zoom.xos"])

    func testGlobMatchesPrefixAndSubdirs() {
        XCTAssertTrue(Glob.matches(pattern: "~/src/initech*", path: NSString(string: "~/src/initech").expandingTildeInPath))
        XCTAssertTrue(Glob.matches(pattern: "~/src/initech*", path: NSString(string: "~/src/initech-web").expandingTildeInPath))
        XCTAssertTrue(Glob.matches(pattern: "~/src/canopyops", path: NSString(string: "~/src/canopyops/lib/deep").expandingTildeInPath))
        XCTAssertFalse(Glob.matches(pattern: "~/src/initech*", path: NSString(string: "~/src/other").expandingTildeInPath))
    }

    func testInstantScoresWeighting() {
        let home = NSString(string: "~").expandingTildeInPath
        let scores = Scorer.matchProjects(
            dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell),
                   ObservedDir(path: home + "/src/canopyops", kind: .tmuxPane)],
            windowTitle: nil, frontmostApp: nil,
            projects: [initech, ops, meet])
        XCTAssertEqual(scores["initech"]!, 1.0, accuracy: 0.001)   // frontmost shell = foreground
        XCTAssertNil(scores["canopyops"])                      // background-only pane is gated out
        XCTAssertNil(scores["meetings"])
    }

    func testGlobWithTrailingSlashMatchesSubdirs() {
        let home = NSString(string: "~").expandingTildeInPath
        // A dir pattern written with a trailing slash (a common way to mean
        // "everything under here") must still match paths beneath it.
        XCTAssertTrue(Glob.matches(pattern: "~/src/", path: home + "/src/ttt"))
        XCTAssertTrue(Glob.matches(pattern: "~/src/", path: home + "/src"))
    }

    func testMoreSpecificDirRuleWins() {
        let home = NSString(string: "~").expandingTildeInPath
        // Priv catch-all "~/src/" and Abel specific "~/src/ttt" both match the
        // active pane in ~/src/ttt — the specific rule must win, not tie.
        let priv = Project(name: "Priv", xledgerProject: "1", xledgerActivity: "P", dirs: ["~/src/"])
        let abel = Project(name: "Abel", xledgerProject: "2", xledgerActivity: "A", dirs: ["~/src/ttt/"])
        let scores = Scorer.matchProjects(
            dirs: [ObservedDir(path: home + "/src/ttt", kind: .tmuxActivePane)],
            windowTitle: nil, frontmostApp: nil, projects: [priv, abel])
        XCTAssertEqual(scores["abel"]!, 0.8, accuracy: 0.001)   // specific rule wins
        XCTAssertNil(scores["priv"])                            // catch-all suppressed for this dir
    }

    func testCatchAllStillMatchesUnclaimedDirs() {
        let home = NSString(string: "~").expandingTildeInPath
        // A path under the catch-all but not under any specific rule still maps
        // to the catch-all project.
        let priv = Project(name: "Priv", xledgerProject: "1", xledgerActivity: "P", dirs: ["~/src/"])
        let abel = Project(name: "Abel", xledgerProject: "2", xledgerActivity: "A", dirs: ["~/src/ttt/"])
        let scores = Scorer.matchProjects(
            dirs: [ObservedDir(path: home + "/src/scratch", kind: .frontmostShell)],
            windowTitle: nil, frontmostApp: nil, projects: [priv, abel])
        XCTAssertEqual(scores["priv"]!, 1.0, accuracy: 0.001)
        XCTAssertNil(scores["abel"])
    }

    func testBackgroundOnlyProjectIsGatedOut() {
        let home = NSString(string: "~").expandingTildeInPath
        // canopyops appears only as parked background signals -> never scores.
        let scores = Scorer.matchProjects(
            dirs: [ObservedDir(path: home + "/src/canopyops", kind: .tmuxPane),
                   ObservedDir(path: home + "/src/canopyops", kind: .backgroundShell)],
            windowTitle: nil, frontmostApp: nil, projects: [initech, ops])
        XCTAssertTrue(scores.isEmpty)
    }

    func testForegroundProjectStillScoresWithBackgroundPresent() {
        let home = NSString(string: "~").expandingTildeInPath
        // initech is the active pane (foreground) plus extra background panes -> scores.
        let scores = Scorer.matchProjects(
            dirs: [ObservedDir(path: home + "/src/initech", kind: .tmuxActivePane),
                   ObservedDir(path: home + "/src/initech", kind: .tmuxPane)],
            windowTitle: nil, frontmostApp: nil, projects: [initech])
        XCTAssertEqual(scores["initech"]!, 0.8, accuracy: 0.001)   // active pane weight
    }

    func testAppAndKeywordMatch() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: "initech — issue #42", frontmostApp: "us.zoom.xos",
            projects: [initech, ops, meet])
        XCTAssertEqual(scores["meetings"]!, 0.5, accuracy: 0.001)
        XCTAssertEqual(scores["initech"]!, 0.3, accuracy: 0.001)
    }

    func testLeaderRequiresSustainedLead() {
        let home = NSString(string: "~").expandingTildeInPath
        var scorer = Scorer(projects: [initech, ops])
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 6 minutes of initech observations every 30s
        for i in 0..<12 {
            scorer.ingest(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)]))
        }
        let now = t0.addingTimeInterval(6 * 60)
        let leader = scorer.leader(at: now)
        XCTAssertEqual(leader?.projectId, "initech")
        // leadingSince should reach back to (near) the first observation
        XCTAssertNotNil(leader?.leadingSince)
        XCTAssertLessThanOrEqual(leader!.leadingSince!.timeIntervalSince(t0), 31)
    }

    func testOneStrayCdDoesNotFlipLeader() {
        let home = NSString(string: "~").expandingTildeInPath
        var scorer = Scorer(projects: [initech, ops])
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<10 {
            scorer.ingest(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)]))
        }
        // one stray observation in canopyops
        scorer.ingest(Observation(
            timestamp: t0.addingTimeInterval(300),
            dirs: [ObservedDir(path: home + "/src/canopyops", kind: .frontmostShell)]))
        XCTAssertEqual(scorer.leader(at: t0.addingTimeInterval(330))?.projectId, "initech")
    }

    func testLeadingSinceResetsAfterInterruption() {
        let home = NSString(string: "~").expandingTildeInPath
        var scorer = Scorer(projects: [initech, ops])
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Run 1: initech (A), ~3 min, t0...t0+180, every 30s.
        for i in 0...6 {
            scorer.ingest(Observation(
                timestamp: t0.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)]))
        }
        // Run 2: canopyops (B) alone, A completely absent, ~4 min,
        // t0+210...t0+450, every 30s.
        for i in 0...8 {
            scorer.ingest(Observation(
                timestamp: t0.addingTimeInterval(210 + Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/canopyops", kind: .frontmostShell)]))
        }
        // A returns at t0+480 and stays for ~6 min, ending at `now`.
        let returnTime = t0.addingTimeInterval(480)
        for i in 0...12 {
            scorer.ingest(Observation(
                timestamp: returnTime.addingTimeInterval(Double(i) * 30),
                dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)]))
        }
        let now = returnTime.addingTimeInterval(360) // t0+840

        let leader = scorer.leader(at: now)
        XCTAssertEqual(leader?.projectId, "initech")
        XCTAssertGreaterThanOrEqual(leader!.score, Scorer.scoreFloor)
        XCTAssertGreaterThan(leader!.score, leader!.runnerUpScore)
        XCTAssertNotNil(leader?.leadingSince)
        // leadingSince should reflect A's return, not the stale first run.
        XCTAssertLessThanOrEqual(abs(leader!.leadingSince!.timeIntervalSince(returnTime)), 31)
    }

    func testOldObservationsExpire() {
        let home = NSString(string: "~").expandingTildeInPath
        var scorer = Scorer(projects: [initech])
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        scorer.ingest(Observation(timestamp: t0,
            dirs: [ObservedDir(path: home + "/src/initech", kind: .frontmostShell)]))
        // 20 minutes later the window is empty
        XCTAssertNil(scorer.leader(at: t0.addingTimeInterval(20 * 60)))
    }

    func testAppsMatchFriendlyNameOrBundleIdCaseInsensitively() {
        // Config authors write the app name they see ("Slack"), but the
        // observation's frontmostApp is a bundle id — both must match.
        let comms = Project(name: "Comms", xledgerProject: "3", xledgerActivity: "MEET",
                            apps: ["Slack"])
        let byName = Scorer.matchProjects(
            dirs: [], windowTitle: nil,
            frontmostApp: "com.tinyspeck.slackmacgap",
            frontmostAppName: "slack",                    // case differs
            projects: [comms])
        XCTAssertEqual(byName["comms"], Scorer.appWeight)

        let zoom = Project(name: "Comms", xledgerProject: "3", xledgerActivity: "MEET",
                           apps: ["us.zoom.xos"])
        let byBundleId = Scorer.matchProjects(
            dirs: [], windowTitle: nil,
            frontmostApp: "us.zoom.xos", frontmostAppName: "zoom.us",
            projects: [zoom])
        XCTAssertEqual(byBundleId["comms"], Scorer.appWeight)

        let noMatch = Scorer.matchProjects(
            dirs: [], windowTitle: nil,
            frontmostApp: "com.apple.finder", frontmostAppName: "Finder",
            projects: [comms])
        XCTAssertNil(noMatch["comms"])
    }
}
