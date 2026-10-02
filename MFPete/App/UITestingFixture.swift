import Foundation
import MFPeteCore
import SwiftData

/// Isolated state for UI tests, chosen with the `--ui-testing` launch
/// argument: rules, data store, and settings live in a fresh temporary
/// folder, so tests never touch the user's real rules. Adding
/// `--ui-testing-empty` starts with no rules (the empty dashboard).
/// Templates expand `~` to the temporary folder, which has an empty
/// `Downloads` folder, so tests never touch the user's real folders.
enum UITestingFixture {
    static let launchArgument = "--ui-testing"
    static let emptyArgument = "--ui-testing-empty"
    /// Shows the first-launch window instead of the Rules window.
    static let onboardingArgument = "--ui-testing-onboarding"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeAppState() -> AppState {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MFPeteUITests-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("Downloads", isDirectory: true), withIntermediateDirectories: true)
        for name in ["note1.txt", "note2.txt"] {
            try? Data("MFPete".utf8).write(to: inbox.appendingPathComponent(name))
        }

        let folder = FolderRef(path: inbox.path)
        let tag = Action.addTags(["MFPete UI Test"])
        let startsEmpty = ProcessInfo.processInfo.arguments.contains(emptyArgument)
        let rules = startsEmpty ? [] : [
            Rule(
                name: "Alpha",
                order: 0,
                scope: [folder],
                conditions: ConditionGroup(items: [
                    .condition(Condition(attribute: .extension, op: .is, value: .text("txt"))),
                ]),
                actions: [tag]
            ),
            Rule(name: "Beta", isEnabled: false, order: 1, scope: [folder], trigger: .daily(hour: 9, minute: 0), actions: [tag]),
            Rule(
                name: "Gamma",
                order: 2,
                scope: [folder],
                conditions: ConditionGroup(items: [
                    .condition(Condition(attribute: .extension, op: .is, value: .text("md"))),
                ]),
                actions: [tag]
            ),
        ]
        let store = RulesStore(directory: root.appendingPathComponent("Support", isDirectory: true))
        try? store.save(rules)

        let suite = "com.mftpete.MFPete.uitests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let container = try? DataStore.makeInMemoryContainer()
        let state = AppState(rulesStore: store, modelContainer: container, defaults: defaults)
        state.templateHome = root.path
        if !ProcessInfo.processInfo.arguments.contains(onboardingArgument) {
            state.openWindow(WindowID.rules)
        }
        return state
    }
}
