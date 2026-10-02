import Foundation
import Testing
@testable import MFPeteCore

private func extensionIs(_ ext: String) -> ConditionGroup {
    ConditionGroup(items: [.condition(Condition(attribute: .extension, op: .isAnyOf, value: .text(ext)))])
}

struct RuleEngineTests {
    /// The phase's "done when": build a rule, point it at a temp folder,
    /// run it, and check files, log, and summary.
    @Test func runNowMovesRenamesAndTags() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/invoice.pdf")
        try h.sandbox.file("in/report.pdf")
        try h.sandbox.file("in/photo.jpg")
        try h.sandbox.folder("Documents")
        let rule = Rule(
            name: "File PDFs",
            isEnabled: false,
            scope: [h.sandbox.ref("in")],
            trigger: .daily(hour: 9, minute: 0),
            conditions: extensionIs("pdf"),
            actions: [
                .rename(pattern: "{name}-filed.{extension}", onConflict: .keepBoth),
                .addTags(["Filed"]),
                .move(to: h.sandbox.ref("Documents"), onConflict: .keepBoth),
            ]
        )
        await h.engine.setRules([rule])

        let result = await h.engine.runNow(ruleID: rule.id)
        guard case .completed(let summary) = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(h.sandbox.contents(of: "in") == ["photo.jpg"])
        #expect(h.sandbox.contents(of: "Documents") == ["invoice-filed.pdf", "report-filed.pdf"])
        #expect(h.sandbox.tags("Documents/invoice-filed.pdf") == ["Filed"])

        #expect(summary.trigger == .manual)
        #expect(summary.matched == 2)
        #expect(summary.actedOn == 2)
        #expect(summary.failed == 0)
        #expect(summary.dominantVerb == "moved to Documents")

        let log = try await h.log()
        #expect(log.count == 6)
        #expect(log.allSatisfy { $0.runTrigger == .manual && $0.result == .success && $0.ruleName == "File PDFs" })
        #expect(Set(log.map(\.action)) == ["Rename", "Add tags", "Move to Documents"])

        let stats = try await h.activity.stats(ruleID: rule.id)
        #expect(stats.fileCount == 2)
        #expect(stats.lastRun != nil)
        #expect(stats.lastError == nil)
        #expect(await h.engine.isRunning(rule.id) == false)
    }

    @Test func oncePerFileUntilModified() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt", modified: Date(timeIntervalSince1970: 1_700_000_000))
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.addTags(["Seen"])])
        await h.engine.setRules([rule])

        guard case .completed(let first) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(first.actedOn == 1)

        guard case .completed(let second) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(second.actedOn == 0)
        #expect(second.skippedProcessed == 1)
        let noMatch = try await h.log().first
        #expect(noMatch?.message == "No new matching files (1 already processed)")

        // Changing the file makes it eligible again.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        guard case .completed(let third) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(third.actedOn == 1)

        // Run Again on All Files.
        try await h.processed.reset(ruleID: rule.id)
        guard case .completed(let fourth) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(fourth.actedOn == 1)
    }

    @Test func runNowWorksWhenDisabledAndPaused() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        let rule = Rule(isEnabled: false, scope: [h.sandbox.ref("in")], actions: [.trash])
        await h.engine.setRules([rule])
        await h.engine.setPaused(true)

        // Automatic runs do nothing while paused or disabled.
        let automatic = await h.engine.scanAndRun(rule, reason: .scheduled)
        #expect(automatic.matched == 0)
        let event = await h.engine.run(rules: [rule], candidates: [h.sandbox.root.appendingPathComponent("in/a.txt")], reason: .fileEvent)
        #expect(event.isEmpty)
        #expect(h.sandbox.exists("in/a.txt"))

        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(summary.actedOn == 1)
        #expect(summary.dominantVerb == "moved to Trash")
        #expect(!h.sandbox.exists("in/a.txt"))
    }

    @Test func runNowRejections() async throws {
        let h = try EngineHarness()
        let removed = Rule(scope: [h.sandbox.ref("in")], trigger: .fileRemoved, actions: [.notify(message: "gone")])
        var unknown = Rule(scope: [h.sandbox.ref("in")], actions: [.unknown(.object(["type": .string("future")]))])
        unknown.isEnabled = false
        await h.engine.setRules([removed, unknown])

        #expect(await h.engine.runNow(ruleID: removed.id) == .notAvailableForFileRemoved)
        #expect(await h.engine.runNow(ruleID: unknown.id) == .unsupportedElements)
        #expect(await h.engine.runNow(ruleID: UUID()) == .ruleNotFound)
    }

    @Test func runNowWhileRunningReturnsAlreadyRunning() async throws {
        let h = try EngineHarness()
        for index in 0..<40 { try h.sandbox.file("in/f\(index).txt") }
        let slow = SlowWorkspace()
        let engine = RuleEngine(
            activityStore: h.activity,
            processedStore: h.processed,
            environment: ActionEnvironment(workspace: slow, trash: { _ in nil })
        )
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.revealInFinder])
        await engine.setRules([rule])

        async let first = engine.runNow(ruleID: rule.id)
        await slow.waitUntilStarted()
        let second = await engine.runNow(ruleID: rule.id)
        #expect(second == .alreadyRunning)
        #expect(await engine.isRunning(rule.id))
        guard case .completed(let summary) = await first else { Issue.record(); return }
        #expect(summary.actedOn == 40)
    }

    @Test func noMatchingFilesEntry() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        let rule = Rule(name: "PDFs", scope: [h.sandbox.ref("in")], conditions: extensionIs("pdf"), actions: [.trash])
        await h.engine.setRules([rule])

        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(summary.hadNoMatches)
        let log = try await h.log()
        #expect(log.count == 1)
        #expect(log[0].message == "No matching files")
        #expect(log[0].runTrigger == .manual)
        #expect(log[0].result == .skipped)

        // Automatic runs with no matches write nothing.
        _ = await h.engine.scanAndRun(rule, reason: .scheduled)
        #expect(try await h.log().count == 1)
    }

    @Test func failedActionStopsChainAndIsLogged() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        let rule = Rule(
            scope: [h.sandbox.ref("in")],
            actions: [.move(to: h.sandbox.ref("missing"), onConflict: .keepBoth), .addTags(["Never"])]
        )
        await h.engine.setRules([rule])

        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(summary.failed == 1)
        #expect(summary.hasErrors)
        #expect(h.sandbox.tags("in/a.txt").isEmpty)
        let log = try await h.log()
        #expect(log.count == 1)
        #expect(log[0].result == .failed)
        guard case .error = await h.engine.status(of: rule.id) else { Issue.record("Expected error status"); return }

        // Failed files are not marked processed, so they retry after a fix.
        try h.sandbox.folder("missing")
        guard case .completed(let retry) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(retry.actedOn == 1)
        #expect(await h.engine.status(of: rule.id) == .ok)
        #expect(h.sandbox.tags("missing/a.txt") == ["Never"])
    }

    @Test func missingScopeFolderMarksRule() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        let rule = Rule(scope: [h.sandbox.ref("in"), h.sandbox.ref("gone")], actions: [.addTags(["X"])])
        await h.engine.setRules([rule])

        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(summary.actedOn == 1)
        #expect(summary.ruleErrors.count == 1)
        #expect(summary.ruleErrors[0].hasPrefix("Folder missing"))
        guard case .folderMissing = await h.engine.status(of: rule.id) else { Issue.record("Expected folder missing"); return }

        // The rule-level entry is written once, not on every run.
        _ = await h.engine.runNow(ruleID: rule.id)
        let errors = try await h.log().filter { $0.action == "Check folders" }
        #expect(errors.count == 1)

        try h.sandbox.folder("gone")
        _ = await h.engine.runNow(ruleID: rule.id)
        #expect(await h.engine.status(of: rule.id) == .ok)
    }

    @Test func subfoldersHiddenAndPackages() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/top.txt")
        try h.sandbox.file("in/.secret.txt")
        try h.sandbox.file("in/.DS_Store")
        try h.sandbox.file("in/movie.crdownload")
        try h.sandbox.file("in/nested/deep.txt")
        try h.sandbox.file("in/Tool.app/Contents/Info.txt")
        let txt = extensionIs("txt")

        let shallow = Rule(scope: [h.sandbox.ref("in")], conditions: txt, actions: [.addTags(["A"])])
        await h.engine.setRules([shallow])
        guard case .completed(let a) = await h.engine.runNow(ruleID: shallow.id) else { Issue.record(); return }
        #expect(a.actedOn == 1)

        let deep = Rule(
            scope: [h.sandbox.ref("in")], conditions: txt, actions: [.addTags(["B"])],
            options: RuleOptions(includeSubfolders: true, includeHidden: true)
        )
        await h.engine.setRules([deep])
        guard case .completed(let b) = await h.engine.runNow(ruleID: deep.id) else { Issue.record(); return }
        // top, .secret, nested/deep. Not inside the package; never .DS_Store.
        #expect(b.actedOn == 3)
        #expect(h.sandbox.tags("in/Tool.app/Contents/Info.txt").isEmpty)
    }

    @Test func rulesRunInOrderAndMovedFilesSkipLaterRules() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        try h.sandbox.folder("out")
        let tag = Rule(name: "Tag", order: 0, scope: [h.sandbox.ref("in")], actions: [.addTags(["First"])])
        let rename = Rule(name: "Rename", order: 1, scope: [h.sandbox.ref("in")], actions: [.rename(pattern: "b.txt", onConflict: .keepBoth)])
        let move = Rule(name: "Move", order: 2, scope: [h.sandbox.ref("in")], actions: [.move(to: h.sandbox.ref("out"), onConflict: .keepBoth)])
        let late = Rule(name: "Late", order: 3, scope: [h.sandbox.ref("in")], actions: [.addTags(["Late"])])

        // Passed out of order; the engine sorts by `order`.
        let summaries = await h.engine.run(rules: [late, move, rename, tag], candidates: [file], reason: .fileEvent)
        #expect(summaries.map(\.ruleName) == ["Tag", "Rename", "Move", "Late"])
        #expect(summaries.map(\.actedOn) == [1, 1, 1, 0])
        #expect(h.sandbox.contents(of: "out") == ["b.txt"])
        #expect(h.sandbox.tags("out/b.txt") == ["First"])
        #expect(try await h.log().allSatisfy { $0.runTrigger == .fileEvent })
    }

    @Test func stopProcessingOtherRules() async throws {
        let h = try EngineHarness()
        let pdf = try h.sandbox.file("in/a.pdf")
        let txt = try h.sandbox.file("in/a.txt")
        let first = Rule(
            name: "PDF only", order: 0, scope: [h.sandbox.ref("in")], conditions: extensionIs("pdf"),
            actions: [.addTags(["PDF"])], options: RuleOptions(stopOtherRules: true)
        )
        let second = Rule(name: "All", order: 1, scope: [h.sandbox.ref("in")], actions: [.addTags(["All"])])

        let summaries = await h.engine.run(rules: [first, second], candidates: [pdf, txt], reason: .fileEvent)
        #expect(summaries.map(\.actedOn) == [1, 1])
        #expect(h.sandbox.tags("in/a.pdf") == ["PDF"])
        #expect(h.sandbox.tags("in/a.txt") == ["All"])
    }

    @Test func automaticRunsSkipDisabledRulesAndOutOfScopeFiles() async throws {
        let h = try EngineHarness()
        let inside = try h.sandbox.file("in/a.txt")
        let outside = try h.sandbox.file("elsewhere/b.txt")
        let enabled = Rule(order: 0, scope: [h.sandbox.ref("in")], actions: [.addTags(["On"])])
        let disabled = Rule(isEnabled: false, order: 1, scope: [h.sandbox.ref("in")], actions: [.addTags(["Off"])])

        let summaries = await h.engine.run(rules: [enabled, disabled], candidates: [inside, outside], reason: .fileEvent)
        #expect(summaries.count == 1)
        #expect(summaries[0].matched == 1)
        #expect(h.sandbox.tags("in/a.txt") == ["On"])
        #expect(h.sandbox.tags("elsewhere/b.txt").isEmpty)
    }

    @Test func selfChangesAreTrackedForProducingRule() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        try h.sandbox.folder("out")
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.move(to: h.sandbox.ref("out"), onConflict: .keepBoth)])
        await h.engine.setRules([rule])
        _ = await h.engine.runNow(ruleID: rule.id)

        let moved = h.sandbox.root.appendingPathComponent("out/a.txt")
        #expect(await h.engine.selfChangeProducer(of: moved) == rule.id)
        #expect(await h.engine.selfChangeProducer(of: h.sandbox.root.appendingPathComponent("out/other.txt")) == nil)
    }

    @Test func selfChangeTrackerExpires() {
        var tracker = SelfChangeTracker(ttl: 5)
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let id = UUID()
        tracker.record(url, ruleID: id, now: testNow)
        #expect(tracker.producer(of: url, now: testNow.addingTimeInterval(4)) == id)
        #expect(tracker.producer(of: url, now: testNow.addingTimeInterval(6)) == nil)
        #expect(tracker.count == 0)
    }

    @Test func processedRecordsForGoneFilesArePruned() async throws {
        let h = try EngineHarness()
        let a = try h.sandbox.file("in/a.txt")
        try h.sandbox.file("in/b.txt")
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.addTags(["X"])])
        await h.engine.setRules([rule])
        _ = await h.engine.runNow(ruleID: rule.id)
        #expect(try await h.processed.fileKeys(ruleID: rule.id).count == 2)

        try FileManager.default.removeItem(at: a)
        _ = await h.engine.runNow(ruleID: rule.id)
        #expect(try await h.processed.fileKeys(ruleID: rule.id).count == 1)
    }

    @Test func manyFilesInParallel() async throws {
        let h = try EngineHarness()
        for index in 0..<30 { try h.sandbox.file("in/f\(index).log") }
        try h.sandbox.folder("out")
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.sortIntoSubfolder(base: h.sandbox.ref("out"), pattern: "{extension}")])
        await h.engine.setRules([rule])
        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(summary.actedOn == 30)
        #expect(h.sandbox.contents(of: "out/log").count == 30)
    }

    @Test func dominantVerb() {
        #expect(RuleEngine.dominantVerb([]) == nil)
        #expect(RuleEngine.dominantVerb(["moved to Trash", "moved to Trash"]) == "moved to Trash")
        #expect(RuleEngine.dominantVerb(["moved to Trash", "renamed"]) == "processed")
    }
}

struct DryRunTests {
    @Test func planPredictsDestinationsWithoutChanges() async throws {
        let h = try EngineHarness(now: testNow)
        try h.sandbox.file("in/invoice.pdf")
        try h.sandbox.file("in/notes.txt")
        try h.sandbox.file("in/x.zip")
        try h.sandbox.file("Documents/pdf/invoice.pdf")
        let rule = Rule(
            scope: [h.sandbox.ref("in")],
            conditions: extensionIs("pdf, txt"),
            actions: [
                .sortIntoSubfolder(base: h.sandbox.ref("Documents"), pattern: "{extension}"),
                .addTags(["Sorted"]),
            ]
        )
        let plan = await h.engine.plan(rule: rule)

        #expect(plan.map(\.file.lastPathComponent) == ["invoice.pdf", "notes.txt"])
        #expect(plan[0].steps.first?.destination?.path.hasSuffix("Documents/pdf/invoice 2.pdf") == true)
        #expect(plan[1].steps.first?.destination?.path.hasSuffix("Documents/txt/notes.txt") == true)
        #expect(plan.allSatisfy { $0.steps.count == 2 && $0.steps.allSatisfy { $0.outcome == .willSucceed } })
        // Nothing changed on disk.
        #expect(h.sandbox.contents(of: "in") == ["invoice.pdf", "notes.txt", "x.zip"])
        #expect(!h.sandbox.exists("Documents/txt"))
    }

    @Test func planUsesVirtualNamesAcrossFiles() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        try h.sandbox.file("in/b.txt")
        try h.sandbox.folder("out")
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [
            .rename(pattern: "same.txt", onConflict: .keepBoth),
            .move(to: h.sandbox.ref("out"), onConflict: .keepBoth),
        ])
        let plan = await h.engine.plan(rule: rule)
        let finals = plan.compactMap { $0.steps.last?.destination?.lastPathComponent }
        #expect(finals == ["same.txt", "same 2.txt"])
    }

    @Test func planReportsFailuresSkipsAndProcessed() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        try h.sandbox.file("out/a.txt")
        let skip = Rule(scope: [h.sandbox.ref("in")], actions: [.move(to: h.sandbox.ref("out"), onConflict: .skip), .trash])
        let skipPlan = await h.engine.plan(rule: skip)
        #expect(skipPlan[0].steps.count == 1)
        #expect(skipPlan[0].steps[0].outcome == .willSkip("Skipped: name exists"))

        let missing = Rule(scope: [h.sandbox.ref("in")], actions: [.copy(to: h.sandbox.ref("none"), onConflict: .keepBoth)])
        guard case .willFail = await h.engine.plan(rule: missing)[0].steps[0].outcome else { Issue.record(); return }

        let tag = Rule(scope: [h.sandbox.ref("in")], actions: [.addTags(["T"])])
        await h.engine.setRules([tag])
        _ = await h.engine.runNow(ruleID: tag.id)
        let processed = await h.engine.plan(rule: tag)
        #expect(processed[0].alreadyProcessed)
        #expect(processed[0].steps.isEmpty)
    }
}

/// Holds the first reveal until a second Run Now has been tried.
final class SlowWorkspace: WorkspaceService, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func open(_ url: URL, withApplicationAt app: URL?) async throws {}

    func revealInFinder(_ url: URL) async {
        lock.lock(); started = true; lock.unlock()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func waitUntilStarted() async {
        while true {
            lock.lock(); let done = started; lock.unlock()
            if done { return }
            await Task.yield()
        }
    }
}
