import Foundation
import MFPeteCore
import Testing
@testable import MFPete

@MainActor
struct RuleListQueryTests {
    private let downloads = FolderRef(path: "/Users/me/Downloads")
    private let desktop = FolderRef(path: "/Users/me/Desktop")

    private func rules() -> [Rule] {
        [
            Rule(name: "Clean Downloads", order: 0, scope: [downloads],
                 createdAt: Date(timeIntervalSince1970: 300)),
            Rule(name: "archive screenshots", isEnabled: false, order: 1, scope: [desktop],
                 trigger: .daily(hour: 9, minute: 0), createdAt: Date(timeIntervalSince1970: 100)),
            Rule(name: "Sort Desktop", order: 2, scope: [desktop, downloads],
                 trigger: .interval(minutes: 30), createdAt: Date(timeIntervalSince1970: 200)),
        ]
    }

    @Test func manualOrderAndNoFilterShowsAllAndAllowsReorder() {
        let query = RuleListQuery()
        #expect(query.apply(to: rules().reversed()).map(\.name)
            == ["Clean Downloads", "archive screenshots", "Sort Desktop"])
        #expect(query.allowsReorder)
    }

    @Test func searchMatchesRuleNameAndFolderNameCaseInsensitively() {
        var query = RuleListQuery(searchText: "clean")
        #expect(query.apply(to: rules()).map(\.name) == ["Clean Downloads"])

        query.searchText = "DESKTOP"
        #expect(query.apply(to: rules()).map(\.name) == ["archive screenshots", "Sort Desktop"])

        // Every word must match somewhere.
        query.searchText = "sort downloads"
        #expect(query.apply(to: rules()).map(\.name) == ["Sort Desktop"])
        #expect(!query.allowsReorder)
    }

    @Test func statusFilters() {
        let all = rules()
        let erroring = all[2].id
        var query = RuleListQuery(status: .enabled)
        #expect(query.apply(to: all).map(\.name) == ["Clean Downloads", "Sort Desktop"])

        query.status = .disabled
        #expect(query.apply(to: all).map(\.name) == ["archive screenshots"])

        query.status = .hasErrors
        #expect(query.apply(to: all) { $0 == erroring }.map(\.name) == ["Sort Desktop"])
    }

    @Test func triggerAndFolderFilters() {
        var query = RuleListQuery(trigger: .schedule)
        #expect(query.apply(to: rules()).map(\.name) == ["archive screenshots", "Sort Desktop"])

        query.trigger = .fileEvent
        #expect(query.apply(to: rules()).map(\.name) == ["Clean Downloads"])

        query = RuleListQuery(folder: downloads.path)
        #expect(query.apply(to: rules()).map(\.name) == ["Clean Downloads", "Sort Desktop"])

        query.clearFilters()
        #expect(!query.isFiltering)
    }

    @Test func sortByNameIgnoresCase() {
        let query = RuleListQuery(sort: .name)
        #expect(query.apply(to: rules()).map(\.name)
            == ["archive screenshots", "Clean Downloads", "Sort Desktop"])
        #expect(!query.allowsReorder)
    }

    @Test func sortByLastRunPutsNeverRunLast() {
        let all = rules()
        let stats: [Rule.ID: RuleStats] = [
            all[1].id: RuleStats(lastRun: Date(timeIntervalSince1970: 50)),
            all[2].id: RuleStats(lastRun: Date(timeIntervalSince1970: 90)),
        ]
        let query = RuleListQuery(sort: .lastRun)
        #expect(query.apply(to: all, stats: stats).map(\.name)
            == ["Sort Desktop", "archive screenshots", "Clean Downloads"])
    }

    @Test func sortByDateCreatedNewestFirst() {
        let query = RuleListQuery(sort: .dateCreated)
        #expect(query.apply(to: rules()).map(\.name)
            == ["Clean Downloads", "Sort Desktop", "archive screenshots"])
    }

    @Test func folderListIsUniqueAndSortedByName() {
        #expect(RuleListQuery.folders(in: rules()).map(\.displayName) == ["Desktop", "Downloads"])
    }
}

@MainActor
struct EngineControllerTests {
    @Test func runNowActsOnFilesAndUpdatesLastRun() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFPeteRunNow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))

        let state = try makeTestAppState()
        let rule = Rule(
            name: "Tag",
            isEnabled: false,
            scope: [FolderRef(path: folder.path)],
            actions: [.addTags(["Done"])]
        )
        state.add(rule)
        let controller = state.engineController
        #expect(controller.stats[rule.id]?.lastRun == nil)

        await controller.runNow(rule.id)

        #expect(!controller.isRunning(rule.id))
        #expect(controller.stats[rule.id]?.lastRun != nil)
        #expect(controller.stats[rule.id]?.fileCount == 1)
        #expect(controller.recentActivity.first?.ruleID == rule.id)
        let tags = try folder.appendingPathComponent("a.txt").resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Done"])
    }

    @Test func pauseIsPersistedAndOffersScanOnResume() throws {
        let suite = "MFPeteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let container = try DataStore.makeInMemoryContainer()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFPeteTests-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(rulesStore: RulesStore(directory: directory), modelContainer: container, defaults: defaults)
        state.add(Rule(name: "Added", scope: [FolderRef(path: "/tmp")], actions: [.trash]))

        state.engineController.setPaused(true)
        #expect(defaults.bool(forKey: SettingsKey.isPaused))
        #expect(!state.engineController.offerScanAfterResume)

        let relaunched = EngineController(modelContainer: container, defaults: defaults)
        #expect(relaunched.isPaused)

        state.engineController.setPaused(false)
        #expect(state.engineController.offerScanAfterResume)
    }
}
