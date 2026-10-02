import Foundation
import MFPeteCore
import Testing
@testable import MFPete

/// Records posted notifications instead of showing them.
final class RecordingPoster: NotificationPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(title: String, body: String, ruleID: UUID?)] = []

    var posts: [(title: String, body: String, ruleID: UUID?)] {
        lock.withLock { _posts }
    }

    func post(title: String, body: String, ruleID: UUID?) {
        lock.withLock { _posts.append((title, body, ruleID)) }
    }
}

@MainActor
struct SummaryNotifierTests {
    private func summary(_ trigger: RunTrigger, rule: UUID, actedOn: Int, failed: Int = 0) -> RunSummary {
        var summary = RunSummary(ruleID: rule, ruleName: "Clean Downloads", trigger: trigger, startedAt: Date())
        summary.actedOn = actedOn
        summary.matched = actedOn + failed
        summary.failed = failed
        summary.dominantVerb = "moved to Trash"
        return summary
    }

    @Test func manualRunsPostRightAwayAndFileEventsMerge() async throws {
        let poster = RecordingPoster()
        let notifier = SummaryNotifier(poster: poster, window: 0.2)
        let rule = UUID()

        notifier.runFinished(summary(.manual, rule: rule, actedOn: 1), level: .errorsOnly, notifyEachRun: false)
        #expect(poster.posts.map(\.body) == ["1 file moved to Trash"])
        #expect(poster.posts.first?.ruleID == rule)

        for _ in 0..<3 {
            notifier.runFinished(summary(.fileEvent, rule: rule, actedOn: 2), level: .everyRun, notifyEachRun: false)
        }
        #expect(poster.posts.count == 1)
        try await Task.sleep(for: .seconds(0.5))
        #expect(poster.posts.map(\.body) == ["1 file moved to Trash", "6 files moved to Trash"])
    }

    @Test func levelIsRespected() {
        let poster = RecordingPoster()
        let notifier = SummaryNotifier(poster: poster, window: 0)
        let rule = UUID()
        notifier.runFinished(summary(.manual, rule: rule, actedOn: 1), level: .off, notifyEachRun: true)
        notifier.runFinished(summary(.scheduled, rule: rule, actedOn: 1), level: .errorsOnly, notifyEachRun: false)
        #expect(poster.posts.isEmpty)
        notifier.runFinished(summary(.scheduled, rule: rule, actedOn: 1, failed: 1), level: .errorsOnly, notifyEachRun: false)
        #expect(poster.posts.map(\.body) == ["1 file processed, 1 failed"])

        let alert = LoopAlert(ruleIDs: [rule], ruleNames: ["A", "B"], filePath: "/tmp/x")
        notifier.loopDetected(alert, level: .off)
        #expect(poster.posts.count == 1)
        notifier.loopDetected(alert, level: .errorsOnly)
        #expect(poster.posts.last?.body == "Possible rule loop between A and B")
    }
}

@MainActor
struct SettingsStateTests {
    @Test func engineSettingsClampAndPersist() throws {
        let suite = "MFPeteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = AppState(
            rulesStore: RulesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)),
            modelContainer: try DataStore.makeInMemoryContainer(),
            defaults: defaults
        )
        let controller = state.engineController
        #expect(controller.notificationLevel == .errorsOnly)
        #expect(controller.settleDelay == 2)
        #expect(controller.bulkThreshold == 50)

        controller.setSettleDelay(99)
        controller.setBulkThreshold(1)
        controller.setNotificationLevel(.everyRun)
        #expect(controller.settleDelay == 30)
        #expect(controller.bulkThreshold == 5)
        #expect(defaults.double(forKey: SettingsKey.settleDelay) == 30)
        #expect(defaults.integer(forKey: SettingsKey.bulkThreshold) == 5)
        #expect(defaults.string(forKey: SettingsKey.notificationLevel) == "everyRun")

        state.completeOnboarding()
        #expect(defaults.bool(forKey: SettingsKey.hasCompletedOnboarding))
    }

    @Test func importedRulesAppendAtEndDisabled() throws {
        let state = try makeTestAppState()
        state.add(Rule(name: "Existing", scope: [FolderRef(path: "/tmp")], actions: [.trash]))
        let data = try RulesFile(rules: [
            Rule(name: "Imported", order: 7, scope: [FolderRef(path: "/tmp")], actions: [.trash]),
        ]).encoded()
        let result = try RuleImporter().importRules(from: data, startOrder: state.rules.count)
        state.append(result.rules)
        #expect(state.rules.map(\.name) == ["Existing", "Imported"])
        #expect(state.rules.map(\.order) == [0, 1])
        #expect(state.rules[1].isEnabled == false)
    }

    @Test func showActivityRecordsRequest() throws {
        let state = try makeTestAppState()
        let id = UUID()
        state.showActivity(ruleID: id)
        #expect(state.activityRequest?.ruleID == id)
        let first = state.activityRequest
        state.showActivity(ruleID: id)
        #expect(state.activityRequest != first)
    }

    @Test func refreshFlagsMissingFolderOnDisabledRule() async throws {
        let state = try makeTestAppState()
        let missing = "/tmp/MFPete-missing-\(UUID().uuidString)"
        state.add(Rule(name: "Imported", isEnabled: false, scope: [FolderRef(path: missing)], actions: [.trash]))
        await state.engineController.settle()
        await state.engineController.refresh()
        let id = state.rules[0].id
        #expect(state.engineController.status(of: id) == .folderMissing(missing))
        #expect(state.engineController.folderUsages.map(\.health) == [.missing])
    }
}
