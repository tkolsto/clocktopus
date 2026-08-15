import AppKit
import XCTest
@testable import Clocktopus

@MainActor
final class WindowPolicyTests: XCTestCase {
    func testTestHostEnvironmentDisablesAppStartup() {
        XCTAssertFalse(ClocktopusApp.shouldStart(environment: [
            "XCTestConfigurationFilePath": "/tmp/ClocktopusTests.xctestconfiguration",
        ]))
        XCTAssertTrue(ClocktopusApp.shouldStart(environment: [:]))
    }

    func testManagedWindowSelectsRequestedSceneOnly() {
        let popover = NSWindow()
        popover.title = ""
        let preferences = NSWindow()
        preferences.identifier = NSUserInterfaceItemIdentifier("preferences-main")
        preferences.title = "Clocktopus Preferences"
        let review = NSWindow()
        review.identifier = NSUserInterfaceItemIdentifier("review-main")
        review.title = "Clocktopus Review"

        let windows = [popover, preferences, review]

        XCTAssertTrue(WindowPolicy.managedWindow(id: "review", among: windows) === review)
        XCTAssertTrue(WindowPolicy.managedWindow(id: "preferences", among: windows) === preferences)
    }

    func testManagedWindowFallsBackToSceneTitle() {
        let review = NSWindow()
        review.title = "Clocktopus Review"

        XCTAssertTrue(WindowPolicy.managedWindow(id: "review", among: [review]) === review)
    }

    func testBringToFrontRestoresAndOrdersWindow() {
        let window = WindowSpy()
        window.pretendMiniaturized = true

        WindowPolicy.bringToFront(window)

        XCTAssertTrue(window.didDeminiaturize)
        XCTAssertTrue(window.didMakeKeyAndOrderFront)
    }
}

private final class WindowSpy: NSWindow {
    var pretendMiniaturized = false
    var didDeminiaturize = false
    var didMakeKeyAndOrderFront = false

    override var isMiniaturized: Bool { pretendMiniaturized }

    override func deminiaturize(_ sender: Any?) {
        didDeminiaturize = true
        pretendMiniaturized = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        didMakeKeyAndOrderFront = true
    }
}
