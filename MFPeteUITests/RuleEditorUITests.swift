import XCTest

/// Rule editor tests (plan Phase 5.8, spec §15). The fixture rules ("Alpha",
/// "Beta", "Gamma") watch a temporary Inbox with note1.txt and note2.txt.
final class RuleEditorUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func launch(empty: Bool = false) {
        app.launchArguments = ["--ui-testing"] + (empty ? ["--ui-testing-empty"] : [])
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Preview rows combine their texts into one accessibility element.
    private func previewRow(_ fileName: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", fileName)).firstMatch
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: timeout)
    }

    private func openEditor(for ruleName: String) {
        XCTAssertTrue(element("toggle-\(ruleName)").waitForExistence(timeout: 10), "Rules window did not open")
        app.staticTexts[ruleName].firstMatch.doubleClick()
        XCTAssertTrue(element("saveRule").waitForExistence(timeout: 5), "Editor did not open")
    }

    @MainActor
    func testCreateRuleFromTemplate() throws {
        launch(empty: true)
        let template = element("template-unzipDownloads")
        XCTAssertTrue(template.waitForExistence(timeout: 10), "Empty state did not show templates")
        template.click()

        let name = element("ruleName")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Unzip downloads")
        let summary = element("ruleSummary")
        XCTAssertTrue(summary.label.contains("zip") || (summary.value as? String ?? "").contains("zip"))

        element("saveRule").click()
        XCTAssertTrue(element("toggle-Unzip downloads").waitForExistence(timeout: 5), "Saved rule not in the list")
    }

    @MainActor
    func testEditAndSaveRule() throws {
        launch()
        openEditor(for: "Alpha")

        let name = element("ruleName")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Alpha Edited")
        element("saveRule").click()

        XCTAssertTrue(element("toggle-Alpha Edited").waitForExistence(timeout: 5), "Edited name not saved")
        XCTAssertFalse(element("saveRule").exists, "Editor did not close")
    }

    @MainActor
    func testPreviewShowsMatchingFiles() throws {
        launch()
        openEditor(for: "Alpha")

        let count = element("matchCount")
        XCTAssertTrue(count.waitForExistence(timeout: 10), "Live match count did not appear")
        waitUntil { (count.value as? String ?? count.label).contains("2 files") }

        element("editorPreview").click()
        XCTAssertTrue(previewRow("note1.txt").waitForExistence(timeout: 10), "Preview did not list note1.txt")
        XCTAssertTrue(previewRow("note2.txt").exists)
    }

    @MainActor
    func testInvalidRuleIsNotSaved() throws {
        launch()
        XCTAssertTrue(element("toggle-Alpha").waitForExistence(timeout: 10))
        element("addRule").buttons.firstMatch.click()
        XCTAssertTrue(element("saveRule").waitForExistence(timeout: 5))

        element("saveRule").click()
        XCTAssertTrue(element("editorIssues").waitForExistence(timeout: 5), "Validation problems not shown")
        XCTAssertTrue(element("saveRule").exists, "Editor closed with an invalid rule")
    }
}
