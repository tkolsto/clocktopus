import XCTest
@testable import ClocktopusCore

final class BrowserProfileTests: XCTestCase {

    // MARK: - Profile extraction from the AX window title

    func testParsesChromeProfileSuffix() {
        XCTAssertEqual(Observation.browserProfile(
            fromWindowTitle: "Google Translate - Google Chrome - Alex (acme.test)"),
            "Alex (acme.test)")
        XCTAssertEqual(Observation.browserProfile(
            fromWindowTitle: "data-migration - Chat - Google Chrome - Alex (globex.test)"),
            "Alex (globex.test)")
        // A profile whose name equals the account name has no parenthesis part.
        XCTAssertEqual(Observation.browserProfile(
            fromWindowTitle: "New Tab - Google Chrome - Alex"),
            "Alex")
    }

    func testIncognitoAndSingleProfileTitlesHaveNoProfile() {
        XCTAssertNil(Observation.browserProfile(
            fromWindowTitle: "BankID - Google Chrome (Incognito)"))
        // Single-profile Chrome appends no suffix at all.
        XCTAssertNil(Observation.browserProfile(fromWindowTitle: "Docs - Google Chrome"))
    }

    func testNonBrowserTitlesHaveNoProfile() {
        XCTAssertNil(Observation.browserProfile(fromWindowTitle: "initech — issue #42"))
        XCTAssertNil(Observation.browserProfile(fromWindowTitle: nil))
    }

    func testTabTitleContainingBrowserMarkerUsesLastOccurrence() {
        // A pathological tab title mentioning the marker itself: the real
        // suffix is at the end, so the last occurrence must win.
        XCTAssertEqual(Observation.browserProfile(
            fromWindowTitle: "A - Google Chrome - B - Google Chrome - Alex (acme.test)"),
            "Alex (acme.test)")
    }

    func testParsesEdgeProfileSuffix() {
        XCTAssertEqual(Observation.browserProfile(
            fromWindowTitle: "Docs - Microsoft Edge - Work"), "Work")
    }

    // MARK: - Scoring

    let acme = Project(name: "Acme", xledgerProject: "1", xledgerActivity: "DEV",
                       browserProfiles: ["acme.test"])
    let globex = Project(name: "Globex", xledgerProject: "2", xledgerActivity: "DEV",
                         browserProfiles: ["globex.test"])

    func testProfileMatchScoresProfileWeight() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: "YouTube - Google Chrome - Alex (acme.test)",
            frontmostApp: "com.google.Chrome",
            projects: [acme, globex])
        XCTAssertEqual(scores["acme"], Scorer.profileWeight)
        XCTAssertNil(scores["globex"])
    }

    func testProfileMatchIsCaseInsensitive() {
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: "YouTube - Google Chrome - Alex (ACME.TEST)",
            frontmostApp: "com.google.Chrome",
            projects: [acme])
        XCTAssertEqual(scores["acme"], Scorer.profileWeight)
    }

    func testProfilePatternOnlyMatchesTheSuffixNotTheTabTitle() {
        // "acme.test" appearing in the tab title of another profile's window must
        // not fire the profile rule (that's what keywords are for).
        let scores = Scorer.matchProjects(
            dirs: [], windowTitle: "acme.test pricing - Google Chrome - Alex",
            frontmostApp: "com.google.Chrome",
            projects: [acme])
        XCTAssertTrue(scores.isEmpty)
    }

    // MARK: - Config

    func testTeamConfigParsesBrowserProfiles() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Acme"
        xledger_project = "1"
        xledger_activity = "DEV"
        browser_profiles = ["acme.test"]
        """)
        XCTAssertEqual(team.projects[0].browserProfiles, ["acme.test"])
    }

    func testBrowserProfilesDefaultEmpty() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Acme"
        xledger_project = "1"
        xledger_activity = "DEV"
        """)
        XCTAssertEqual(team.projects[0].browserProfiles, [])
    }

    func testOverrideAppendsBrowserProfiles() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Acme"
        xledger_project = "1"
        xledger_activity = "DEV"
        browser_profiles = ["acme.test"]
        """)
        let override = ProjectOverride(name: "Acme", browserProfiles: ["Work"])
        let merged = ConfigLoader.merge(team: team, overrides: [override])
        XCTAssertEqual(merged[0].browserProfiles, ["acme.test", "Work"])
    }
}
