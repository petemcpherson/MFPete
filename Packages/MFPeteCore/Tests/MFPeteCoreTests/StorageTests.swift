import Foundation
import Testing
@testable import MFPeteCore

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MFPeteCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sampleRule(_ name: String, order: Int = 0) -> Rule {
    Rule(
        name: name,
        order: order,
        scope: [FolderRef(path: "/tmp/in")],
        actions: [.trash],
        createdAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }

struct RulesStoreTests {
    @Test func firstLaunchStartsEmptyWithNoIssue() throws {
        let directory = try makeTempDirectory().appendingPathComponent("MFPete")
        let result = RulesStore(directory: directory).load()
        #expect(result.rules.isEmpty)
        #expect(result.issue == nil)
    }

    @Test func saveCreatesFolderAndLoadsInOrder() throws {
        let directory = try makeTempDirectory().appendingPathComponent("MFPete")
        let store = RulesStore(directory: directory)
        try store.save([sampleRule("B", order: 1), sampleRule("A", order: 0)])

        let result = store.load()
        #expect(result.rules.map(\.name) == ["A", "B"])
        #expect(result.issue == nil)

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"version\" : 1"))
    }

    @Test func secondSaveWritesBackupOfPreviousFile() throws {
        let store = RulesStore(directory: try makeTempDirectory())
        try store.save([sampleRule("First")])
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))

        try store.save([sampleRule("Second")])
        let backup = try RulesFile.decode(try Data(contentsOf: store.backupURL))
        #expect(backup.rules.map(\.name) == ["First"])
        #expect(store.load().rules.map(\.name) == ["Second"])
    }

    @Test func corruptFileFallsBackToBackup() throws {
        let directory = try makeTempDirectory()
        let store = RulesStore(directory: directory, now: fixedNow)
        try store.save([sampleRule("Good")])
        try store.save([sampleRule("Newer")])
        try Data("{ not json".utf8).write(to: store.fileURL)

        let result = store.load()
        #expect(result.rules.map(\.name) == ["Good"])
        guard case .recoveredFromBackup(let corrupt?) = result.issue else {
            Issue.record("Expected recoveredFromBackup, got \(String(describing: result.issue))")
            return
        }
        #expect(corrupt.lastPathComponent.hasPrefix("rules.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        // Saving after recovery must not overwrite the good backup with the corrupt file.
        try store.save([sampleRule("Recovered")])
        let backup = try RulesFile.decode(try Data(contentsOf: store.backupURL))
        #expect(backup.rules.map(\.name) == ["Good"])
    }

    @Test func bothCorruptStartsEmptyAndKeepsCorruptFile() throws {
        let directory = try makeTempDirectory()
        let store = RulesStore(directory: directory, now: fixedNow)
        try Data("garbage".utf8).write(to: store.fileURL)
        try Data("also garbage".utf8).write(to: store.backupURL)

        let result = store.load()
        #expect(result.rules.isEmpty)
        guard case .startedEmpty(let corrupt?) = result.issue else {
            Issue.record("Expected startedEmpty, got \(String(describing: result.issue))")
            return
        }
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "garbage")
    }

    @Test func newerVersionIsNotLoaded() throws {
        let store = RulesStore(directory: try makeTempDirectory(), now: fixedNow)
        try Data(#"{"version": 99, "rules": []}"#.utf8).write(to: store.fileURL)
        let result = store.load()
        guard case .startedEmpty(let corrupt?) = result.issue else {
            Issue.record("Expected startedEmpty")
            return
        }
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test func reportsRulesDisabledForUnknownElements() throws {
        let store = RulesStore(directory: try makeTempDirectory())
        let json = """
        {"version": 1, "rules": [{
          "id": "44444444-4444-4444-4444-444444444444", "name": "Future",
          "trigger": {"type": "fileAdded"}, "actions": [{"type": "teleport"}],
          "createdAt": "2026-10-01T09:00:00Z"
        }]}
        """
        try Data(json.utf8).write(to: store.fileURL)
        let result = store.load()
        #expect(result.disabledUnknownRules == ["Future"])
        #expect(result.rules.first?.isEnabled == false)
    }
}

struct MigrationTests {
    @Test func currentVersionPassesThrough() throws {
        let data = Data(#"{"version": 1, "rules": []}"#.utf8)
        #expect(try RulesMigrator().migrate(data) == data)
    }

    @Test func missingVersionCountsAsOne() throws {
        let file = try RulesFile.decode(Data(#"{"rules": []}"#.utf8))
        #expect(file.rules.isEmpty)
    }

    @Test func runsStepsInOrder() throws {
        // Pretend v1 renamed "ruleList" (v0) to "rules", then v2 added nothing.
        let migrator = RulesMigrator(currentVersion: 2, steps: [
            0: { json in
                guard case .object(var fields) = json else { return json }
                fields["rules"] = fields.removeValue(forKey: "ruleList")
                return .object(fields)
            },
            1: { json in json },
        ])
        let data = Data(#"{"version": 0, "ruleList": []}"#.utf8)
        let migrated = try JSONDecoder().decode(JSONValue.self, from: try migrator.migrate(data))
        guard case .object(let fields) = migrated else {
            Issue.record("Expected object")
            return
        }
        #expect(fields["version"] == .number(2))
        #expect(fields["rules"] == .array([]))
        #expect(fields["ruleList"] == nil)
    }

    @Test func missingStepThrows() {
        let migrator = RulesMigrator(currentVersion: 3, steps: [:])
        #expect(throws: RulesMigrator.MigrationError.missingStep(from: 1)) {
            try migrator.migrate(Data(#"{"version": 1}"#.utf8))
        }
    }

    @Test func newerVersionThrows() {
        #expect(throws: RulesMigrator.MigrationError.unsupportedVersion(5)) {
            try RulesMigrator().migrate(Data(#"{"version": 5, "rules": []}"#.utf8))
        }
    }
}

struct DataStoreTests {
    @Test func processedRecordLifecycle() async throws {
        let store = ProcessedStore(modelContainer: try DataStore.makeInMemoryContainer())
        let ruleID = UUID()
        let modified = Date(timeIntervalSince1970: 1_000)

        #expect(try await !store.isProcessed(ruleID: ruleID, fileKey: "f1", modifiedAt: modified))

        try await store.markProcessed(ruleID: ruleID, fileKey: "f1", modifiedAt: modified)
        #expect(try await store.isProcessed(ruleID: ruleID, fileKey: "f1", modifiedAt: modified))
        // File changed after processing: eligible again.
        #expect(try await !store.isProcessed(ruleID: ruleID, fileKey: "f1", modifiedAt: modified.addingTimeInterval(1)))
        // Another rule has its own record.
        #expect(try await !store.isProcessed(ruleID: UUID(), fileKey: "f1", modifiedAt: modified))

        // Upsert, not duplicate.
        try await store.markProcessed(ruleID: ruleID, fileKey: "f1", modifiedAt: modified.addingTimeInterval(10))
        try await store.markProcessed(ruleID: ruleID, fileKey: "f2", modifiedAt: modified)
        #expect(try await store.fileKeys(ruleID: ruleID) == ["f1", "f2"])

        try await store.remove(ruleID: ruleID, fileKeys: ["f2"])
        #expect(try await store.fileKeys(ruleID: ruleID) == ["f1"])

        try await store.reset(ruleID: ruleID)
        #expect(try await store.fileKeys(ruleID: ruleID).isEmpty)
    }

    @Test func activityPruning() async throws {
        let store = ActivityStore(modelContainer: try DataStore.makeInMemoryContainer())
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ruleID = UUID()
        let day: TimeInterval = 24 * 60 * 60

        func record(_ age: TimeInterval) -> ActivityRecord {
            ActivityRecord(
                timestamp: now.addingTimeInterval(-age),
                ruleID: ruleID,
                ruleName: "Rule",
                action: "Move to Trash",
                sourcePath: "/tmp/\(age)",
                result: .success
            )
        }

        try await store.add([record(40 * day), record(31 * day), record(3 * day), record(2 * day), record(1 * day)])
        #expect(try await store.count() == 5)

        try await store.prune(policy: RetentionPolicy(maxAgeDays: 30, maxEntries: 2), now: now)
        let remaining = try await store.recent(limit: 10)
        #expect(remaining.map(\.sourcePath) == ["/tmp/\(1 * day)", "/tmp/\(2 * day)"])

        let forRule = try await store.recent(limit: 10, ruleID: UUID())
        #expect(forRule.isEmpty)

        try await store.deleteAll()
        #expect(try await store.count() == 0)
    }

    @Test func onDiskContainer() throws {
        let url = try makeTempDirectory().appendingPathComponent("sub/MFPete.store")
        _ = try DataStore.makeContainer(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
