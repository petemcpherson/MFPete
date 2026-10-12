import Foundation
import Testing
@testable import MFPeteCore

/// Stands in for Finder: counts calls and returns a fixed item count or error.
private actor FakeFinder {
    private(set) var calls = 0
    private let result: Result<Int, Error>

    init(_ result: Result<Int, Error>) {
        self.result = result
    }

    func empty() throws -> Int {
        calls += 1
        return try result.get()
    }
}

private struct FinderError: LocalizedError {
    var errorDescription: String? { "Finder said no" }
}

private func engine(_ finder: FakeFinder) throws -> (EngineHarness, RuleEngine) {
    let h = try EngineHarness()
    var environment = h.environment
    environment.emptyTrash = { try await finder.empty() }
    return (h, RuleEngine(activityStore: h.activity, processedStore: h.processed, environment: environment))
}

private let emptyTrashRule = RuleTemplate.emptyTrashWeekly.makeRule(home: "/Users/me")

struct EmptyTrashEngineTests {
    @Test func runEmptiesOnceAndLogsOneEntry() async throws {
        let finder = FakeFinder(.success(12))
        let (h, engine) = try engine(finder)
        await engine.setRules([emptyTrashRule])

        guard case .completed(let summary) = await engine.runNow(ruleID: emptyTrashRule.id) else {
            Issue.record("Expected completed")
            return
        }
        #expect(await finder.calls == 1)
        #expect(summary.actedOn == 12)
        #expect(summary.dominantVerb == "deleted from Trash")
        #expect(RunNotificationText(summary: summary).body == "12 files deleted from Trash")

        let log = try await h.log()
        #expect(log.count == 1)
        #expect(log.first?.action == "Empty Trash")
        #expect(log.first?.result == .success)
        #expect(log.first?.message == "Deleted 12 items")
    }

    @Test func alreadyEmptyTrashIsLoggedAsSkipped() async throws {
        let finder = FakeFinder(.success(0))
        let (h, engine) = try engine(finder)
        await engine.setRules([emptyTrashRule])

        let summary = await engine.scanAndRun(emptyTrashRule, reason: .scheduled)
        #expect(summary.matched == 0)
        #expect(!summary.hasErrors)
        let log = try await h.log()
        #expect(log.map(\.result) == [.skipped])
        #expect(log.first?.message == "The Trash was already empty")
    }

    @Test func finderErrorMarksTheRule() async throws {
        let finder = FakeFinder(.failure(FinderError()))
        let (h, engine) = try engine(finder)
        await engine.setRules([emptyTrashRule])

        let summary = await engine.scanAndRun(emptyTrashRule, reason: .scheduled)
        #expect(summary.ruleErrors == ["Finder said no"])
        #expect(RunNotificationText(summary: summary).body == "Finder said no")
        #expect(await engine.status(of: emptyTrashRule.id) == .error("Finder said no"))
        #expect(try await h.log().map(\.result) == [.failed])
    }

    @Test func pausedOrDisabledScheduledRunsDoNothing() async throws {
        let finder = FakeFinder(.success(3))
        let (_, engine) = try engine(finder)
        var disabled = emptyTrashRule
        disabled.isEnabled = false
        await engine.setRules([disabled])

        _ = await engine.scanAndRun(disabled, reason: .scheduled)
        await engine.setPaused(true)
        _ = await engine.scanAndRun(emptyTrashRule, reason: .scheduled)
        #expect(await finder.calls == 0)
    }

    @Test func fileEventRunsSkipEmptyTrashRules() async throws {
        let finder = FakeFinder(.success(3))
        let (h, engine) = try engine(finder)
        let file = try h.sandbox.file("in/a.txt")
        var rule = emptyTrashRule
        rule.trigger = .fileAdded
        rule.scope = [h.sandbox.ref("in")]

        let summaries = await engine.run(rules: [rule], candidates: [file], reason: .fileEvent)
        #expect(summaries.isEmpty)
        #expect(await finder.calls == 0)
    }

    @Test func defaultEnvironmentFailsClearly() async throws {
        let h = try EngineHarness()
        await h.engine.setRules([emptyTrashRule])
        let summary = await h.engine.scanAndRun(emptyTrashRule, reason: .manual)
        #expect(summary.ruleErrors == ["Empty Trash is not available"])
    }
}

struct EmptyTrashRuleTests {
    private let validator = RuleValidator()

    @Test func templateNeedsNoFoldersOrConditions() {
        #expect(emptyTrashRule.scope.isEmpty)
        #expect(emptyTrashRule.emptiesTrash)
        #expect(!validator.hasErrors(emptyTrashRule))
    }

    @Test func warnsThatDeletionIsPermanent() {
        let warnings = validator.validate(emptyTrashRule).filter { $0.severity == .warning }
        #expect(warnings.map(\.code) == [.destructiveWithoutConditions])
        #expect(warnings.first?.message == "This rule permanently deletes everything in the Trash.")
    }

    @Test func needsAScheduleTrigger() {
        var rule = emptyTrashRule
        rule.trigger = .fileAdded
        #expect(validator.validate(rule).filter { $0.severity == .error }.map(\.code) == [.emptyTrashNeedsSchedule])
    }

    @Test func mustBeTheOnlyAction() {
        var rule = emptyTrashRule
        rule.actions.append(.notify(message: "Done"))
        #expect(validator.validate(rule).filter { $0.severity == .error }.map(\.code) == [.emptyTrashWithOtherActions])
    }

    @Test func sentenceHasNoFolders() {
        let summarizer = RuleSummarizer(locale: Locale(identifier: "en_US"), calendar: utcCalendar)
        let sentence = summarizer.sentence(for: emptyTrashRule)
        #expect(sentence.hasPrefix("Every Mon at "))
        #expect(sentence.hasSuffix(", then empty the Trash."))
        #expect(!sentence.contains("folder"))
    }

    @Test func codingRoundTrip() throws {
        let data = try JSONEncoder().encode(emptyTrashRule)
        #expect(String(decoding: data, as: UTF8.self).contains(#"{"type":"emptyTrash"}"#))
        #expect(try JSONDecoder().decode(Rule.self, from: data) == emptyTrashRule)
    }
}
