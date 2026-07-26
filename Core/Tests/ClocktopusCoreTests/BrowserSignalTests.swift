import XCTest
@testable import ClocktopusCore

final class BrowserSignalTests: XCTestCase {

    // MARK: - URL host extraction / redaction

    func testHostFromURL() {
        XCTAssertEqual(Observation.host(fromURL: "https://github.com/initech/initech/pull/42"), "github.com")
        XCTAssertEqual(Observation.host(fromURL: "https://initech.atlassian.net/browse/X-1"), "initech.atlassian.net")
        XCTAssertNil(Observation.host(fromURL: "not a url"))
        XCTAssertNil(Observation.host(fromURL: "github.com/initech"))   // no scheme -> no host
    }

    func testRedactedForStorageReducesURLToHost() {
        let obs = Observation(timestamp: Date(),
                              activeTabURL: "https://github.com/initech/initech/pull/42")
        let stored = obs.redactedForStorage()
        XCTAssertEqual(stored.activeTabURL, "github.com")
        // everything else is untouched
        XCTAssertEqual(stored.timestamp, obs.timestamp)
    }

    func testRedactedForStorageDropsUnparseableURL() {
        let obs = Observation(timestamp: Date(), activeTabURL: "garbage")
        XCTAssertNil(obs.redactedForStorage().activeTabURL)
    }

    func testRedactedForStorageLeavesNilAlone() {
        let obs = Observation(timestamp: Date())
        XCTAssertNil(obs.redactedForStorage().activeTabURL)
    }

    // MARK: - Scoring

    let initech = Project(name: "Initech", xledgerProject: "1", xledgerActivity: "DEV",
                      urls: ["github.com/initech", "initech.atlassian.net"])
    let ops = Project(name: "CanopyOps", xledgerProject: "2", xledgerActivity: "DEV",
                      urls: ["github.com/canopyops"])

    func testURLSubstringMatchScoresUrlWeight() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: nil, frontmostApp: nil,
            activeTabURL: "https://github.com/initech/initech/pull/42",
            projects: [initech, ops])
        XCTAssertEqual(scores["initech"], Scorer.urlWeight)
        XCTAssertNil(scores["canopyops"])
    }

    func testURLMatchIsCaseInsensitive() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: nil, frontmostApp: nil,
            activeTabURL: "https://INITECH.atlassian.net/browse/X",
            projects: [initech])
        XCTAssertEqual(scores["initech"], Scorer.urlWeight)
    }

    func testUnrelatedURLDoesNotMatch() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: nil, frontmostApp: nil,
            activeTabURL: "https://github.com/other/repo",
            projects: [initech, ops])
        XCTAssertTrue(scores.isEmpty)
    }

    func testNoURLIsHarmless() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: nil, frontmostApp: nil,
            activeTabURL: nil, projects: [initech])
        XCTAssertTrue(scores.isEmpty)
    }

    // MARK: - Config

    func testTeamConfigParsesURLs() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Initech"
        xledger_project = "1"
        xledger_activity = "DEV"
        urls = ["github.com/initech", "initech.atlassian.net"]
        """)
        XCTAssertEqual(team.projects[0].urls, ["github.com/initech", "initech.atlassian.net"])
    }

    func testTeamConfigDefaultsURLsEmpty() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Initech"
        xledger_project = "1"
        xledger_activity = "DEV"
        """)
        XCTAssertEqual(team.projects[0].urls, [])
    }

    func testOverrideAppendsURLs() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Initech"
        xledger_project = "1"
        xledger_activity = "DEV"
        urls = ["github.com/initech"]
        """)
        let override = ProjectOverride(name: "Initech", urls: ["localhost:4000"])
        let merged = ConfigLoader.merge(team: team, overrides: [override])
        XCTAssertEqual(merged[0].urls, ["github.com/initech", "localhost:4000"])
    }
}
