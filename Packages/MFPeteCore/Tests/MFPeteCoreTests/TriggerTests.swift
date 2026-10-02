import CoreServices
import Foundation
import Testing
@testable import MFPeteCore

private func extensionIs(_ ext: String) -> ConditionGroup {
    ConditionGroup(items: [.condition(Condition(attribute: .extension, op: .isAnyOf, value: .text(ext)))])
}

private func flags(_ values: Int...) -> FSEventStreamEventFlags {
    values.reduce(0) { $0 | FSEventStreamEventFlags($1) }
}

/// Time formats use a narrow no-break space before AM/PM.
private func plainSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
}

private func manualOnly() -> TriggerCoordinator.Configuration {
    TriggerCoordinator.Configuration(watchFiles: false, runScheduleTimer: false)
}

struct FileEventMappingTests {
    @Test func renameHalvesAndBasicKinds() {
        let renamed = flags(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsFile)
        #expect(FileEvent.kind(flags: renamed, exists: true) == .added)
        #expect(FileEvent.kind(flags: renamed, exists: false) == .removed)
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemCreated), exists: true) == .added)
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemRemoved), exists: false) == .removed)
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemModified), exists: true) == .modified)
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemXattrMod), exists: true) == .modified)
        // Created then deleted within the latency: gone, nothing to remove.
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemCreated), exists: false) == nil)
        // Sticky "created" on a write to an older file: modified. Not for renames.
        let createdAndWritten = flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemModified)
        #expect(FileEvent.kind(flags: createdAndWritten, exists: true, createdLongAgo: false) == .added)
        #expect(FileEvent.kind(flags: createdAndWritten, exists: true, createdLongAgo: true) == .modified)
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemModified), exists: true, createdLongAgo: true) == .added)
        // Deleted and created again: exists, so added.
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemCreated), exists: true) == .added)
        #expect(FileEvent.kind(flags: flags(kFSEventStreamEventFlagRootChanged), exists: true) == nil)
    }

    @Test func batchFlagsRequestRescans() {
        var replaying = true
        let batch = FSEventsWatcher.makeBatch(
            paths: ["/a/new.txt", "/a", "/b", "/", "/a/gone.txt"],
            flags: [
                flags(kFSEventStreamEventFlagItemCreated),
                flags(kFSEventStreamEventFlagMustScanSubDirs),
                flags(kFSEventStreamEventFlagKernelDropped),
                flags(kFSEventStreamEventFlagHistoryDone),
                flags(kFSEventStreamEventFlagItemRenamed),
            ],
            ids: [10, 11, 12, 0, 13],
            replaying: &replaying,
            inspect: { ($0 == "/a/new.txt", 100) }
        )
        #expect(batch.events == [
            FileEvent(url: URL(fileURLWithPath: "/a/new.txt"), kind: .added),
            FileEvent(url: URL(fileURLWithPath: "/a/gone.txt"), kind: .removed),
        ])
        #expect(batch.rescanFolders.map(\.path) == ["/a", "/b"])
        #expect(batch.historyDone)
        #expect(!replaying)
        #expect(!batch.rescanAll)
        #expect(batch.lastEventID == 13)

        let wrapped = FSEventsWatcher.makeBatch(
            paths: ["/"], flags: [flags(kFSEventStreamEventFlagEventIdsWrapped)], ids: [1],
            replaying: &replaying, inspect: { _ in (true, nil) }
        )
        #expect(wrapped.rescanAll)
    }

    @Test func replayedCreationsStayAdded() {
        let createdAndWritten = flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemModified)
        var replaying = true
        let batch = FSEventsWatcher.makeBatch(
            paths: ["/a/old.txt", "/", "/a/old.txt"],
            flags: [createdAndWritten, flags(kFSEventStreamEventFlagHistoryDone), createdAndWritten],
            ids: [1, 0, 2],
            replaying: &replaying,
            inspect: { _ in (true, 3600) }
        )
        #expect(batch.events.map(\.kind) == [.added, .modified])
    }
}

struct LoopGuardTests {
    @Test func tripsOnceOverLimitThenBlocks() {
        var guardrail = LoopGuard(limit: 10, window: 60)
        let a = UUID(), b = UUID()
        for index in 0..<5 {
            let now = testNow.addingTimeInterval(TimeInterval(index))
            #expect(guardrail.record("chain", ruleIDs: [a, b], now: now) == nil)
        }
        #expect(guardrail.record("chain", ruleIDs: [a], now: testNow.addingTimeInterval(6)) == [a, b])
        #expect(guardrail.isBlocked("chain", now: testNow.addingTimeInterval(7)))
        // Reported once, not on every further run.
        #expect(guardrail.record("chain", ruleIDs: [a], now: testNow.addingTimeInterval(8)) == nil)
        #expect(!guardrail.isBlocked("chain", now: testNow.addingTimeInterval(70)))
        #expect(!guardrail.isBlocked("other", now: testNow))
    }

    @Test func oldRunsFallOutOfWindow() {
        var guardrail = LoopGuard(limit: 3, window: 60)
        let a = UUID()
        for index in 0..<3 {
            #expect(guardrail.record("chain", ruleIDs: [a], now: testNow.addingTimeInterval(TimeInterval(index * 40))) == nil)
        }
        // Only two of the earlier runs are within 60 s of this one.
        #expect(guardrail.record("chain", ruleIDs: [a], now: testNow.addingTimeInterval(100)) == nil)
    }

    @Test func copiesInheritTheirSourceChain() {
        var guardrail = LoopGuard()
        let copy = URL(fileURLWithPath: "/tmp/out/copy.txt")
        #expect(guardrail.chainKey(for: copy, fileKey: "copy-key", now: testNow) == "copy-key")
        guardrail.noteProduced(copy, chain: "source-key", now: testNow)
        #expect(guardrail.chainKey(for: copy, fileKey: "copy-key", now: testNow) == "source-key")
        #expect(guardrail.chainKey(for: copy, fileKey: "copy-key", now: testNow.addingTimeInterval(120)) == "copy-key")
    }

    @Test func messages() {
        #expect(LoopAlert.message(for: ["Rule A", "Rule B"]) == "Possible rule loop between Rule A and Rule B")
        #expect(LoopAlert.message(for: ["Rule A"]) == "Possible rule loop in Rule A")
    }
}

struct EngineSafetyTests {
    @Test func manualRunOverThresholdNeedsApproval() async throws {
        let h = try EngineHarness(configuration: RuleEngine.Configuration(bulkThreshold: 3))
        for index in 0..<5 { try h.sandbox.file("in/\(index).txt") }
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.addTags(["Bulk"])])
        await h.engine.setRules([rule])

        guard case .needsApproval(let request) = await h.engine.runNow(ruleID: rule.id) else {
            Issue.record("Expected approval request"); return
        }
        #expect(request.fileCount == 5)
        #expect(request.trigger == .manual)
        #expect(h.sandbox.tags("in/0.txt").isEmpty)
        #expect(try await h.log().isEmpty)

        let summary = await h.engine.resolveBulkApproval(request.id, approve: true)
        #expect(summary?.actedOn == 5)
        #expect(h.sandbox.tags("in/4.txt") == ["Bulk"])
        // A request is answered once.
        #expect(await h.engine.resolveBulkApproval(request.id, approve: true) == nil)
    }

    @Test func cancelledBulkRunDoesNothing() async throws {
        let h = try EngineHarness(configuration: RuleEngine.Configuration(bulkThreshold: 2))
        for index in 0..<3 { try h.sandbox.file("in/\(index).txt") }
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.trash])
        await h.engine.setRules([rule])
        guard case .needsApproval(let request) = await h.engine.runNow(ruleID: rule.id) else {
            Issue.record("Expected approval request"); return
        }
        #expect(await h.engine.resolveBulkApproval(request.id, approve: false) == nil)
        #expect(h.sandbox.contents(of: "in").count == 3)
        #expect(await h.engine.pendingBulkRequests.isEmpty)
    }

    @Test func processedFilesDoNotCountTowardBulk() async throws {
        let h = try EngineHarness(configuration: RuleEngine.Configuration(bulkThreshold: 3))
        for index in 0..<5 { try h.sandbox.file("in/\(index).txt") }
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.addTags(["Seen"])])
        await h.engine.setRules([rule])
        await h.engine.markExistingProcessed(for: rule)
        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else {
            Issue.record("Expected completed"); return
        }
        #expect(summary.skippedProcessed == 5)
    }

    @Test func fileEventBulkIsHeldAndEmitted() async throws {
        let h = try EngineHarness(configuration: RuleEngine.Configuration(bulkThreshold: 3))
        let recorder = EventRecorder(h.engine)
        let urls = try (0..<5).map { try h.sandbox.file("in/\($0).txt") }
        let rule = Rule(scope: [h.sandbox.ref("in")], trigger: .fileAdded, actions: [.addTags(["Bulk"])])
        await h.engine.setRules([rule])

        let summaries = await h.engine.handleFileEvents(added: urls, modified: [])
        #expect(summaries.first?.pendingApproval?.fileCount == 5)
        #expect(h.sandbox.tags("in/0.txt").isEmpty)
        #expect(await eventually { recorder.bulkRequests.count == 1 })

        let request = recorder.bulkRequests[0]
        #expect(request.trigger == .fileEvent)
        let summary = await h.engine.resolveBulkApproval(request.id, approve: true)
        #expect(summary?.actedOn == 5)
    }

    @Test func ruleSkipsItsOwnOutputButOthersSeeIt() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        let first = Rule(name: "First", order: 0, scope: [h.sandbox.ref("in")], trigger: .fileAdded, actions: [.addTags(["One"])])
        await h.engine.setRules([first])
        _ = await h.engine.handleFileEvents(added: [file], modified: [])
        #expect(await h.engine.selfChangeProducer(of: file) == first.id)

        // Same file arrives again as an event: the producing rule ignores it.
        try await h.processed.reset(ruleID: first.id)
        let again = await h.engine.handleFileEvents(added: [file], modified: [])
        #expect(again.first?.matched == 0)

        let second = Rule(name: "Second", order: 1, scope: [h.sandbox.ref("in")], trigger: .fileAdded, actions: [.addTags(["Two"])])
        await h.engine.setRules([first, second])
        let both = await h.engine.handleFileEvents(added: [file], modified: [])
        #expect(both.map(\.actedOn) == [0, 1])
        #expect(Set(h.sandbox.tags("in/a.txt")) == ["One", "Two"])
    }

    @Test func modifiedIgnoresEngineChanges() async throws {
        let h = try EngineHarness()
        let file = try h.sandbox.file("in/a.txt")
        let tagger = Rule(name: "Tagger", order: 0, scope: [h.sandbox.ref("in")], trigger: .fileAdded, actions: [.addTags(["T"])])
        let watcher = Rule(name: "Watcher", order: 1, scope: [h.sandbox.ref("in")], trigger: .fileModified, actions: [.addTags(["Changed"])])
        await h.engine.setRules([tagger, watcher])

        _ = await h.engine.handleFileEvents(added: [file], modified: [])
        // The engine just tagged it: not a user modification.
        let ignored = await h.engine.handleFileEvents(added: [], modified: [file])
        #expect(ignored.isEmpty)

        let other = try h.sandbox.file("in/b.txt")
        let external = await h.engine.handleFileEvents(added: [], modified: [other])
        #expect(external.first?.actedOn == 1)
        #expect(h.sandbox.tags("in/b.txt") == ["Changed"])
    }

    @Test func removedRulesNotifyOnlyByName() async throws {
        let h = try EngineHarness()
        try h.sandbox.folder("in")
        try h.sandbox.folder("out")
        let rule = Rule(
            name: "Gone",
            scope: [h.sandbox.ref("in")],
            trigger: .fileRemoved,
            conditions: extensionIs("pdf"),
            actions: [.notify(message: "{fullname} was removed"), .move(to: h.sandbox.ref("out"), onConflict: .keepBoth)]
        )
        await h.engine.setRules([rule])
        let gone = h.sandbox.root.appendingPathComponent("in/report.pdf")
        let other = h.sandbox.root.appendingPathComponent("in/photo.jpg")
        let summaries = await h.engine.handleRemoved([gone, other])

        #expect(summaries.first?.matched == 1)
        #expect(summaries.first?.actedOn == 1)
        #expect(h.notifier.posted.map(\.body) == ["report.pdf was removed"])
        let log = try await h.log()
        #expect(log.count == 2)
        #expect(log.contains { $0.result == .skipped && $0.message == "Not available for removed files" })
        // Run Now is not available for these rules.
        #expect(await h.engine.runNow(ruleID: rule.id) == .notAvailableForFileRemoved)
    }

    @Test func unmountedVolumeIsQuiet() async throws {
        let h = try EngineHarness()
        let folder = FolderRef(path: "/Volumes/MFPeteNoSuchVolume-\(UUID().uuidString)/Inbox")
        #expect(FolderHealth.check(folder) == .unavailable)
        #expect(FolderHealth.volumeRoot(of: "/Volumes/Backup/a/b") == "/Volumes/Backup")
        #expect(FolderHealth.volumeRoot(of: "/Users/me") == nil)

        let rule = Rule(scope: [folder], trigger: .daily(hour: 9, minute: 0), actions: [.trash])
        await h.engine.setRules([rule])
        let summary = await h.engine.scanAndRun(rule, reason: .scheduled)
        #expect(summary.ruleErrors.isEmpty)
        #expect(try await h.log().isEmpty)
        let status = await h.engine.status(of: rule.id)
        #expect(status == .folderUnavailable(folder.tildeAbbreviated()))
        #expect(!status.isError)

        await h.engine.setVolume((folder.path as NSString).deletingLastPathComponent, mounted: true)
        #expect(await h.engine.status(of: rule.id) == .ok)
    }

    @Test func runAgainOnAllFiles() async throws {
        let h = try EngineHarness()
        try h.sandbox.file("in/a.txt")
        let rule = Rule(scope: [h.sandbox.ref("in")], actions: [.addTags(["Seen"])])
        await h.engine.setRules([rule])
        _ = await h.engine.runNow(ruleID: rule.id)
        guard case .completed(let skipped) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(skipped.skippedProcessed == 1)

        await h.engine.resetProcessed(ruleID: rule.id)
        guard case .completed(let again) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(again.actedOn == 1)
    }
}

struct CoordinatorTests {
    @Test func applyToExistingDefaultsToOnlyNewFiles() async throws {
        let h = try EngineHarness()
        let recorder = EventRecorder(h.engine)
        let coordinator = TriggerCoordinator(engine: h.engine, state: InMemoryEngineState(), configuration: manualOnly())
        let a = try h.sandbox.file("in/a.pdf")
        try h.sandbox.file("in/b.pdf")
        try h.sandbox.file("in/c.jpg")
        var rule = Rule(name: "PDFs", isEnabled: false, scope: [h.sandbox.ref("in")], trigger: .fileAdded,
                        conditions: extensionIs("pdf"), actions: [.addTags(["PDF"])])
        await coordinator.setRules([rule])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.applyRequests.isEmpty)

        rule.isEnabled = true
        await coordinator.setRules([rule])
        #expect(await eventually { recorder.applyRequests.count == 1 })
        #expect(recorder.applyRequests[0].fileCount == 2)
        #expect(recorder.applyRequests[0].folderNames == ["in"])

        // Before any answer, existing files are already left alone.
        let event = await h.engine.handleFileEvents(added: [a], modified: [])
        #expect(event.first?.skippedProcessed == 1)
        #expect(h.sandbox.tags("in/a.pdf").isEmpty)

        let summary = await coordinator.resolveApplyExisting(ruleID: rule.id, apply: true)
        #expect(summary?.actedOn == 2)
        #expect(summary?.trigger == .applyExisting)
        #expect(h.sandbox.tags("in/b.pdf") == ["PDF"])
        #expect(h.sandbox.tags("in/c.jpg").isEmpty)
    }

    @Test func onlyNewFilesKeepsExistingUntouched() async throws {
        let h = try EngineHarness()
        let recorder = EventRecorder(h.engine)
        let coordinator = TriggerCoordinator(engine: h.engine, state: InMemoryEngineState(), configuration: manualOnly())
        let existing = try h.sandbox.file("in/a.txt")
        await coordinator.setRules([])
        let rule = Rule(scope: [h.sandbox.ref("in")], trigger: .fileAdded, actions: [.addTags(["New"])])
        await coordinator.setRules([rule])
        #expect(await eventually { recorder.applyRequests.count == 1 })
        #expect(await coordinator.resolveApplyExisting(ruleID: rule.id, apply: false) == nil)

        _ = await h.engine.handleFileEvents(added: [existing], modified: [])
        #expect(h.sandbox.tags("in/a.txt").isEmpty)
        let fresh = try h.sandbox.file("in/b.txt")
        _ = await h.engine.handleFileEvents(added: [fresh], modified: [])
        #expect(h.sandbox.tags("in/b.txt") == ["New"])
    }

    @Test func missedScheduleRunsOnceLate() async throws {
        let clock = TestClock(testNow)
        let h = try EngineHarness(clock: clock)
        let recorder = EventRecorder(h.engine)
        let state = InMemoryEngineState()
        let coordinator = TriggerCoordinator(engine: h.engine, state: state, configuration: manualOnly())
        try h.sandbox.file("in/a.txt")
        let rule = Rule(name: "Morning", scope: [h.sandbox.ref("in")], trigger: .daily(hour: 9, minute: 0), actions: [.addTags(["Daily"])])
        // Last ran two days ago at 9:00; the Mac slept through two 9:00s.
        state.setLastScheduledRun(testNow.addingTimeInterval(-2 * 86_400 - 3 * 3600), ruleID: rule.id)
        await coordinator.setRules([rule])

        await coordinator.start()
        #expect(h.sandbox.tags("in/a.txt") == ["Daily"])
        let log = try await h.log()
        #expect(log.count == 1)
        #expect(log[0].runTrigger == .scheduledLate)
        #expect(plainSpaces(log[0].detail) == "Ran late (missed 9:00 AM)")
        #expect(state.lastScheduledRun(ruleID: rule.id) == testNow)
        #expect(await eventually { recorder.summaries.first?.note.map(plainSpaces) == "Ran late (missed 9:00 AM)" })

        // No backlog: checking again does nothing.
        try h.sandbox.file("in/b.txt")
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/b.txt").isEmpty)

        // Next morning on time: a normal scheduled run.
        clock.set(testNow.addingTimeInterval(21 * 3600 + 10))
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/b.txt") == ["Daily"])
        #expect(try await h.log().first?.runTrigger == .scheduled)
        await coordinator.stop()
    }

    @Test func newScheduleRuleStartsItsClockNow() async throws {
        let clock = TestClock(testNow)
        let h = try EngineHarness(clock: clock)
        let state = InMemoryEngineState()
        let coordinator = TriggerCoordinator(engine: h.engine, state: state, configuration: manualOnly())
        try h.sandbox.file("in/a.txt")
        let rule = Rule(scope: [h.sandbox.ref("in")], trigger: .interval(minutes: 30), actions: [.addTags(["Tick"])])
        await coordinator.setRules([rule])
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/a.txt").isEmpty)
        #expect(state.lastScheduledRun(ruleID: rule.id) == testNow)
        #expect(await coordinator.nextScheduledFireDate() == testNow.addingTimeInterval(30 * 60))

        clock.advance(30 * 60 + 5)
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/a.txt") == ["Tick"])
        #expect(try await h.log().first?.runTrigger == .scheduled)
    }

    @Test func manualRunLeavesScheduleAlone() async throws {
        let clock = TestClock(testNow)
        let h = try EngineHarness(clock: clock)
        let state = InMemoryEngineState()
        let coordinator = TriggerCoordinator(engine: h.engine, state: state, configuration: manualOnly())
        try h.sandbox.file("in/a.txt")
        let rule = Rule(scope: [h.sandbox.ref("in")], trigger: .daily(hour: 9, minute: 0), actions: [.addTags(["Now"])])
        let lastRun = testNow.addingTimeInterval(-3 * 3600)
        state.setLastScheduledRun(lastRun, ruleID: rule.id)
        await coordinator.setRules([rule])

        guard case .completed(let summary) = await h.engine.runNow(ruleID: rule.id) else { Issue.record(); return }
        #expect(summary.actedOn == 1)
        #expect(state.lastScheduledRun(ruleID: rule.id) == lastRun)
        #expect(await coordinator.nextScheduledFireDate(ruleID: rule.id) == testNow.addingTimeInterval(21 * 3600))
    }

    @Test func pausedScheduleSkipsWithoutCatchUp() async throws {
        let clock = TestClock(testNow)
        let h = try EngineHarness(clock: clock)
        let state = InMemoryEngineState()
        let coordinator = TriggerCoordinator(engine: h.engine, state: state, configuration: manualOnly())
        try h.sandbox.file("in/a.txt")
        let rule = Rule(scope: [h.sandbox.ref("in")], trigger: .interval(minutes: 10), actions: [.addTags(["X"])])
        state.setLastScheduledRun(testNow.addingTimeInterval(-11 * 60), ruleID: rule.id)
        await coordinator.setRules([rule])
        await coordinator.setPaused(true)
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/a.txt").isEmpty)

        await coordinator.setPaused(false)
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/a.txt").isEmpty)
    }

    @Test func reEnabledScheduleDoesNotCatchUp() async throws {
        let clock = TestClock(testNow)
        let h = try EngineHarness(clock: clock)
        let state = InMemoryEngineState()
        let coordinator = TriggerCoordinator(engine: h.engine, state: state, configuration: manualOnly())
        try h.sandbox.file("in/a.txt")
        var rule = Rule(isEnabled: false, scope: [h.sandbox.ref("in")], trigger: .daily(hour: 9, minute: 0), actions: [.addTags(["X"])])
        state.setLastScheduledRun(testNow.addingTimeInterval(-7 * 86_400), ruleID: rule.id)
        await coordinator.setRules([rule])
        rule.isEnabled = true
        await coordinator.setRules([rule])
        await coordinator.checkSchedules()
        #expect(h.sandbox.tags("in/a.txt").isEmpty)
    }

    @Test func userDefaultsStateRoundTrip() throws {
        let suite = "MFPeteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = UserDefaultsEngineState(defaults: defaults)
        #expect(state.lastEventID() == nil)
        state.setLastEventID(UInt64.max - 1)
        #expect(state.lastEventID() == UInt64.max - 1)

        let keep = UUID(), drop = UUID()
        state.setLastScheduledRun(testNow, ruleID: keep)
        state.setLastScheduledRun(testNow, ruleID: drop)
        state.keepScheduledRuns(for: [keep])
        #expect(state.lastScheduledRun(ruleID: keep) == testNow)
        #expect(state.lastScheduledRun(ruleID: drop) == nil)
    }
}
