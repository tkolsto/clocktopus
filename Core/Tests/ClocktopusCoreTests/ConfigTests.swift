import XCTest
@testable import ClocktopusCore

final class ConfigTests: XCTestCase {
    func testTeamConfigParsesProjects() throws {
        let toml = """
        rounding_increment_hours = 0.5

        [[project]]
        name = "Initech"
        xledger_project = "10432"
        xledger_activity = "DEV"
        dirs = ["~/src/initech*"]
        keywords = ["initech"]

        [[project]]
        name = "Meetings"
        xledger_project = "10001"
        xledger_activity = "MEET"
        apps = ["us.zoom.xos"]
        """
        let team = try ConfigLoader.team(fromTOML: toml)
        XCTAssertEqual(team.roundingIncrementHours, 0.5)
        XCTAssertEqual(team.projects.count, 2)
        XCTAssertEqual(team.projects[0].id, "initech")
        XCTAssertEqual(team.projects[0].dirs, ["~/src/initech*"])
        XCTAssertEqual(team.projects[1].apps, ["us.zoom.xos"])
    }

    func testTeamConfigDefaultsIncrement() throws {
        let team = try ConfigLoader.team(fromTOML: "")
        XCTAssertEqual(team.roundingIncrementHours, 0.25)
        XCTAssertTrue(team.projects.isEmpty)
    }

    func testPersonalConfigDefaults() throws {
        let personal = try ConfigLoader.personal(fromTOML: """
        employee = "TK"
        team_config_path = "~/src/team-config/clocktopus.toml"
        """)
        XCTAssertEqual(personal.employee, "TK")
        XCTAssertEqual(personal.idleThresholdSeconds, 300)
        XCTAssertEqual(personal.nudgesPerHour, 2)
        XCTAssertEqual(personal.aiTools, ["claude", "codex", "gemini"])
        XCTAssertFalse(personal.includeExactColumn)
    }

    func testPersonalConfigMissingEmployeeThrows() {
        XCTAssertThrowsError(try ConfigLoader.personal(fromTOML: "team_config_path = \"x\""))
    }

    func testInvalidTOMLThrows() {
        XCTAssertThrowsError(try ConfigLoader.team(fromTOML: "[[project"))
    }

    func testOverridesMergeByName() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Initech"
        xledger_project = "10432"
        xledger_activity = "DEV"
        dirs = ["~/src/initech"]
        """)
        let override = ProjectOverride(name: "Initech", dirs: ["~/work/initech-fork"],
                                       keywords: ["initechmd"], emoji: "🩺")
        let merged = ConfigLoader.merge(team: team, overrides: [override])
        XCTAssertEqual(merged[0].dirs, ["~/src/initech", "~/work/initech-fork"])
        XCTAssertEqual(merged[0].keywords, ["initechmd"])
        XCTAssertEqual(merged[0].emoji, "🩺")
    }

    func testOverrideAppsParseAndAppend() throws {
        let team = try ConfigLoader.team(fromTOML: """
        [[project]]
        name = "Initech"
        xledger_project = "10432"
        xledger_activity = "DEV"
        apps = ["Slack"]
        """)
        let personal = try ConfigLoader.personal(fromTOML: """
        employee = "TK"
        team_config_path = "x"

        [[override]]
        name = "Initech"
        apps = ["Linear"]
        """)
        let merged = ConfigLoader.merge(team: team, overrides: personal.overrides)
        XCTAssertEqual(merged[0].apps, ["Slack", "Linear"])
    }

    func testBareIntegerNumericFieldsCoerce() throws {
        let personal = try ConfigLoader.personal(fromTOML: """
        employee = "TK"
        team_config_path = "~/src/team-config/clocktopus.toml"
        idle_threshold_seconds = 600
        nudges_per_hour = 3.0
        """)
        XCTAssertEqual(personal.idleThresholdSeconds, 600.0)
        XCTAssertEqual(personal.nudgesPerHour, 3)

        let team = try ConfigLoader.team(fromTOML: """
        rounding_increment_hours = 1
        """)
        XCTAssertEqual(team.roundingIncrementHours, 1.0)
    }

    func testMalformedProjectEntryThrows() {
        let toml = """
        project = [ "oops" ]
        """
        XCTAssertThrowsError(try ConfigLoader.team(fromTOML: toml)) { error in
            XCTAssertEqual(error as? ConfigError, ConfigError.malformedEntry("project"))
        }
    }
}
