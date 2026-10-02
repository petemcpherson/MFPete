import XCTest

/// Activity log and onboarding (plan Phase 6). Uses the `--ui-testing`
/// fixture: rules "Alpha", "Beta" (disabled), and "Gamma" on a temporary
/// folder with two `.txt` files.
final class ActivityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(element("toggle-Alpha").waitForExistence(timeout: 10), "Rules window did not open")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testRunNowShowsInActivityForThatRule() throws {
        element("run-Alpha").click()
        let lastRun = element("lastRun-Alpha")
        let ran = NSPredicate { _, _ in ((lastRun.value as? String) ?? lastRun.label).contains("Last run") }
        wait(for: [expectation(for: ran, evaluatedWith: nil)], timeout: 10)

        element("menu-Alpha").click()
        app.menuItems["Show Activity"].click()

        let activity = app.windows["Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5), "Activity window did not open")
        XCTAssertTrue(activity.staticTexts["note1.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(activity.staticTexts["note2.txt"].exists)
        XCTAssertTrue(activity.staticTexts["Manual"].exists, "Trigger column should say Manual")
    }

    @MainActor
    func testToolbarOpensEmptyActivityLog() throws {
        element("showActivity").click()
        let activity = app.windows["Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue(activity.staticTexts["No Activity"].waitForExistence(timeout: 5))
    }
}

final class OnboardingUITests: XCTestCase {
    @MainActor
    func testStepsThroughAndSkips() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-onboarding"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Welcome to MFPete"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Onboarding did not open")
        XCTAssertTrue(window.staticTexts["Welcome to MFPete"].exists)

        window.buttons["Continue"].click()
        XCTAssertTrue(window.switches.firstMatch.waitForExistence(timeout: 5), "Launch at login toggle missing")
        window.buttons["Continue"].click()

        let skip = window.buttons["onboarding-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        let templates = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'onboarding-template-'"))
        XCTAssertEqual(templates.count, 3)
        skip.click()

        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: window)], timeout: 5)
    }
}
