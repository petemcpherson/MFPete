import Foundation
import Testing
@testable import MFPeteCore

/// End-to-end tests with a real FSEvents stream and temp folders (spec §15).
/// Short settle delay and latency keep them quick.
@Suite(.serialized)
struct WatcherIntegrationTests {
    static let fast = TriggerCoordinator.Configuration(
        settleDelay: 0.3,
        streamLatency: 0.05,
        batchWindow: 0.05,
        runScheduleTimer: false
    )

    struct Setup {
        let h: EngineHarness
        let recorder: EventRecorder
        let state: InMemoryEngineState
        let coordinator: TriggerCoordinator

        init(
            rules: (Sandbox) throws -> [Rule],
            engine: RuleEngine.Configuration = RuleEngine.Configuration(),
            coordinator configuration: TriggerCoordinator.Configuration = WatcherIntegrationTests.fast,
            state: InMemoryEngineState = InMemoryEngineState()
        ) async throws {
            h = try EngineHarness(configuration: engine)
            recorder = EventRecorder(h.engine)
            self.state = state
            coordinator = TriggerCoordinator(engine: h.engine, state: state, configuration: configuration)
            await coordinator.setRules(try rules(h.sandbox))
            await coordinator.start()
        }
    }

    /// Writes a file somewhere unwatched, then moves it in, like a finished download.
    static func drop(_ name: String, into folder: String, _ sandbox: Sandbox, contents: String = "hello") throws {
        let staged = try sandbox.file("staging/\(name)", contents: contents)
        try FileManager.default.moveItem(at: staged, to: sandbox.root.appendingPathComponent("\(folder)/\(name)"))
    }

    @Test func addedFileRuns() async throws {
        let s = try await Setup { sandbox in
            try sandbox.folder("in")
            try sandbox.folder("out")
            return [Rule(scope: [sandbox.ref("in")], trigger: .fileAdded, actions: [.move(to: sandbox.ref("out"), onConflict: .keepBoth)])]
        }
        try s.h.sandbox.file("in/new.txt")
        #expect(await eventually { s.h.sandbox.contents(of: "out") == ["new.txt"] })
        #expect(await eventually { s.recorder.summaries.contains { $0.actedOn == 1 && $0.trigger == .fileEvent } })
        await s.coordinator.stop()
    }

    @Test func zipIsUnarchivedWithinThreeSeconds() async throws {
        let s = try await Setup(rules: { sandbox in
            try sandbox.folder("Downloads")
            return [Rule(scope: [sandbox.ref("Downloads")], trigger: .fileAdded,
                         conditions: ConditionGroup(items: [.condition(Condition(attribute: .extension, op: .isAnyOf, value: .text("zip")))]),
                         actions: [.unarchive(destination: nil, trashArchive: true)])]
        }, coordinator: TriggerCoordinator.Configuration(runScheduleTimer: false))
        let source = try s.h.sandbox.file("src/report.txt", contents: "quarterly")
        let zip = s.h.sandbox.root.appendingPathComponent("staging/report.zip")
        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        let dropped = Date()
        try FileManager.default.moveItem(at: zip, to: s.h.sandbox.root.appendingPathComponent("Downloads/report.zip"))
        #expect(await eventually(timeout: 6) { s.h.sandbox.contents(of: "Downloads") == ["report.txt"] })
        let elapsed = Date().timeIntervalSince(dropped)
        #expect(elapsed < 3.5, "Took \(elapsed) s")
        await s.coordinator.stop()
    }

    @Test func fileWrittenInChunksRunsOnceComplete() async throws {
        let s = try await Setup { sandbox in
            try sandbox.folder("in")
            try sandbox.folder("out")
            return [Rule(scope: [sandbox.ref("in")], trigger: .fileAdded, actions: [.move(to: sandbox.ref("out"), onConflict: .keepBoth)])]
        }
        let url = s.h.sandbox.root.appendingPathComponent("in/big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<6 {
            try handle.write(contentsOf: Data(repeating: 7, count: 10_000))
            try await Task.sleep(nanoseconds: 120_000_000)
            #expect(s.h.sandbox.contents(of: "out").isEmpty, "Moved before the file settled")
        }
        try handle.close()

        #expect(await eventually { s.h.sandbox.contents(of: "out") == ["big.bin"] })
        let size = try FileManager.default.attributesOfItem(atPath: s.h.sandbox.root.appendingPathComponent("out/big.bin").path)[.size] as? Int
        #expect(size == 60_000)
        #expect(try await s.h.log().count == 1)
        await s.coordinator.stop()
    }

    @Test func modifiedFileRunsButEngineEditsDoNot() async throws {
        let s = try await Setup { sandbox in
            try sandbox.file("in/notes.txt", contents: "v1")
            return [Rule(scope: [sandbox.ref("in")], trigger: .fileModified, actions: [.addTags(["Changed"])])]
        }
        let url = s.h.sandbox.root.appendingPathComponent("in/notes.txt")
        // A write right after creation still looks like part of creating
        // the file. Edit it once it is a little older.
        try await Task.sleep(nanoseconds: UInt64((FileEvent.stickyCreatedWindow + 0.3) * 1_000_000_000))
        try Data("v2".utf8).write(to: url)
        #expect(await eventually { s.h.sandbox.tags("in/notes.txt") == ["Changed"] })
        // Tagging changed the file's metadata. That must not fire the rule again.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(try await s.h.log().count == 1)
        await s.coordinator.stop()
    }

    @Test func removedFileNotifies() async throws {
        let s = try await Setup { sandbox in
            try sandbox.file("in/old.pdf")
            return [Rule(name: "Watch deletes", scope: [sandbox.ref("in")], trigger: .fileRemoved,
                         actions: [.notify(message: "{fullname} removed")])]
        }
        try FileManager.default.removeItem(at: s.h.sandbox.root.appendingPathComponent("in/old.pdf"))
        #expect(await eventually { s.h.notifier.posted.map(\.body) == ["old.pdf removed"] })
        await s.coordinator.stop()
    }

    @Test func chainingAcrossTwoRules() async throws {
        let s = try await Setup { sandbox in
            try sandbox.folder("Downloads")
            try sandbox.folder("Images")
            return [
                Rule(name: "File images", order: 0, scope: [sandbox.ref("Downloads")], trigger: .fileAdded,
                     actions: [.move(to: sandbox.ref("Images"), onConflict: .keepBoth)]),
                Rule(name: "Tag images", order: 1, scope: [sandbox.ref("Images")], trigger: .fileAdded,
                     actions: [.addTags(["Inbox"])]),
            ]
        }
        try Self.drop("photo.jpg", into: "Downloads", s.h.sandbox)
        #expect(await eventually { s.h.sandbox.tags("Images/photo.jpg") == ["Inbox"] })
        #expect(s.h.sandbox.contents(of: "Downloads").isEmpty)
        await s.coordinator.stop()
    }

    @Test func loopGuardStopsCopyPingPong() async throws {
        let s = try await Setup { sandbox in
            try sandbox.folder("A")
            try sandbox.folder("B")
            return [
                Rule(name: "A to B", order: 0, scope: [sandbox.ref("A")], trigger: .fileAdded,
                     actions: [.copy(to: sandbox.ref("B"), onConflict: .keepBoth)]),
                Rule(name: "B to A", order: 1, scope: [sandbox.ref("B")], trigger: .fileAdded,
                     actions: [.copy(to: sandbox.ref("A"), onConflict: .keepBoth)]),
            ]
        }
        try Self.drop("x.txt", into: "A", s.h.sandbox)
        #expect(await eventually(timeout: 15) { !s.recorder.loops.isEmpty })
        let alert = try #require(s.recorder.loops.first)
        #expect(Set(alert.ruleNames) == ["A to B", "B to A"])
        #expect(alert.message.hasPrefix("Possible rule loop between"))

        // The chain stays stopped.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let total = s.h.sandbox.contents(of: "A").count + s.h.sandbox.contents(of: "B").count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(s.h.sandbox.contents(of: "A").count + s.h.sandbox.contents(of: "B").count == total)
        #expect(total <= 13)
        #expect(try await s.h.log().contains { $0.action == "Loop guard" && $0.result == .failed })
        await s.coordinator.stop()
    }

    @Test func bulkGuardHoldsLargeDrop() async throws {
        let s = try await Setup(rules: { sandbox in
            try sandbox.folder("in")
            return [Rule(scope: [sandbox.ref("in")], trigger: .fileAdded, actions: [.addTags(["Bulk"])])]
        }, engine: RuleEngine.Configuration(bulkThreshold: 3))
        for index in 0..<6 {
            try s.h.sandbox.file("staging/\(index).txt")
        }
        for index in 0..<6 {
            try FileManager.default.moveItem(
                at: s.h.sandbox.root.appendingPathComponent("staging/\(index).txt"),
                to: s.h.sandbox.root.appendingPathComponent("in/\(index).txt")
            )
        }
        #expect(await eventually { s.recorder.bulkRequests.contains { $0.fileCount == 6 } })
        #expect((0..<6).allSatisfy { s.h.sandbox.tags("in/\($0).txt").isEmpty })

        let request = try #require(s.recorder.bulkRequests.first { $0.fileCount == 6 })
        let summary = await s.h.engine.resolveBulkApproval(request.id, approve: true)
        #expect(summary?.actedOn == 6)
        await s.coordinator.stop()
    }

    @Test func pauseDiscardsEvents() async throws {
        let s = try await Setup { sandbox in
            try sandbox.folder("in")
            try sandbox.folder("out")
            return [Rule(scope: [sandbox.ref("in")], trigger: .fileAdded, actions: [.move(to: sandbox.ref("out"), onConflict: .keepBoth)])]
        }
        await s.coordinator.setPaused(true)
        try Self.drop("a.txt", into: "in", s.h.sandbox)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(s.h.sandbox.contents(of: "in") == ["a.txt"])

        await s.coordinator.setPaused(false)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(s.h.sandbox.contents(of: "in") == ["a.txt"], "Events from the pause must not replay")

        // "Scan now" after resuming picks it up.
        await s.coordinator.scanFileEventRules()
        #expect(s.h.sandbox.contents(of: "out") == ["a.txt"])
        await s.coordinator.stop()
    }

    @Test func eventIDReplayCatchesUpAfterRestart() async throws {
        let state = InMemoryEngineState()
        let h = try EngineHarness()
        try h.sandbox.folder("in")
        try h.sandbox.folder("out")
        let rule = Rule(scope: [h.sandbox.ref("in")], trigger: .fileAdded, actions: [.move(to: h.sandbox.ref("out"), onConflict: .keepBoth)])

        let first = TriggerCoordinator(engine: h.engine, state: state, configuration: Self.fast)
        await first.setRules([rule])
        await first.start()
        // Something must happen so there is an event ID to store.
        try h.sandbox.file("in/before.txt")
        #expect(await eventually { h.sandbox.contents(of: "out") == ["before.txt"] })
        await first.stop()
        let stored = try #require(state.lastEventID())

        // While "closed": a file arrives.
        try Self.drop("while-closed.txt", into: "in", h.sandbox)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(h.sandbox.contents(of: "in") == ["while-closed.txt"])

        let second = TriggerCoordinator(engine: h.engine, state: state, configuration: Self.fast)
        await second.setRules([rule])
        await second.start()
        #expect(await eventually { h.sandbox.contents(of: "out") == ["before.txt", "while-closed.txt"] })
        await second.stop()
        #expect(try #require(state.lastEventID()) > stored)
    }

    @Test func ruleChangesRebuildTheStream() async throws {
        let s = try await Setup { sandbox in
            try sandbox.folder("one")
            try sandbox.folder("two")
            return [Rule(scope: [sandbox.ref("one")], trigger: .fileAdded, actions: [.addTags(["Seen"])])]
        }
        var rule = try #require(await s.h.engine.rules.first)
        rule.scope = [s.h.sandbox.ref("two")]
        await s.coordinator.setRules([rule])
        try Self.drop("b.txt", into: "two", s.h.sandbox)
        #expect(await eventually { s.h.sandbox.tags("two/b.txt") == ["Seen"] })
        await s.coordinator.stop()
    }
}
