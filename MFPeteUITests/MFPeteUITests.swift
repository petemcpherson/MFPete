//
//  MFPeteUITests.swift
//  MFPeteUITests
//
//  Created by Pete McPherson on 10/1/26.
//

import XCTest

/// Dashboard tests (plan Phase 4.4). The `--ui-testing` launch argument gives
/// the app isolated rules ("Alpha", "Beta" disabled, "Gamma") on a temporary
/// folder and opens the Rules window.
final class MFPeteUITests: XCTestCase {
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

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int ?? Int(toggle.value as? String ?? "") ?? 0) == 1
    }

    @MainActor
    func testToggleRule() throws {
        let toggle = element("toggle-Beta")
        XCTAssertFalse(isOn(toggle))
        toggle.click()
        let enabled = NSPredicate { _, _ in self.isOn(toggle) }
        wait(for: [expectation(for: enabled, evaluatedWith: nil)], timeout: 5)
    }

    @MainActor
    func testRunNowUpdatesLastRun() throws {
        let lastRun = element("lastRun-Alpha")
        XCTAssertTrue(lastRun.waitForExistence(timeout: 5))
        element("run-Alpha").click()
        let ran = NSPredicate { _, _ in
            let text = (lastRun.value as? String) ?? lastRun.label
            return text.contains("Last run")
        }
        wait(for: [expectation(for: ran, evaluatedWith: nil)], timeout: 10)
    }

    @MainActor
    func testDeleteAsksForConfirmation() throws {
        element("menu-Gamma").click()
        app.menuItems["Delete…"].click()

        let confirm = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(element("toggle-Gamma").exists, "Rule deleted before confirming")
        confirm.click()

        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: element("toggle-Gamma"))], timeout: 5)
        XCTAssertTrue(element("toggle-Alpha").exists)
    }

    @MainActor
    func testDragReordersRules() throws {
        let alpha = app.staticTexts["Alpha"].firstMatch
        let gamma = app.staticTexts["Gamma"].firstMatch
        XCTAssertLessThan(alpha.frame.minY, gamma.frame.minY)

        gamma.press(forDuration: 0.6, thenDragTo: alpha)

        let reordered = NSPredicate { _, _ in gamma.frame.minY < alpha.frame.minY }
        wait(for: [expectation(for: reordered, evaluatedWith: nil)], timeout: 5)
    }
}
