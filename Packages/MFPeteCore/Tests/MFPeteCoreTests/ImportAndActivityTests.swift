import Foundation
import Testing
@testable import MFPeteCore

struct RuleImporterTests {
    private func exported(_ rules: [Rule], version: Int = RulesFile.currentVersion) throws -> Data {
        try RulesFile(version: version, rules: rules.map { $0.tildeAbbreviated() }).encoded()
    }

    @Test func importsDisabledWithNewIDsAtEnd() throws {
        let home = FolderRef.homePath
        let first = Rule(name: "One", order: 0, scope: [FolderRef(path: home + "/Downloads")], actions: [.trash])
        let second = Rule(name: "Two", order: 1, scope: [FolderRef(path: "/tmp")], actions: [.addTags(["x"])])
        let data = try exported([second, first])

        let result = try RuleImporter().importRules(from: data, startOrder: 4)
        #expect(result.rules.map(\.name) == ["One", "Two"])
        #expect(result.rules.map(\.order) == [4, 5])
        #expect(result.rules.allSatisfy { !$0.isEnabled })
        #expect(!result.rules.contains { $0.id == first.id || $0.id == second.id })
        #expect(result.rules[0].scope == [FolderRef(path: home + "/Downloads")])
        #expect(result.unknownRuleNames.isEmpty)
    }

    @Test func unknownActionsAreReported() throws {
        let json = """
        {"version":1,"rules":[{"id":"\(UUID().uuidString)","name":"Future","trigger":{"type":"fileAdded"},
        "createdAt":"2026-10-01T00:00:00Z","actions":[{"type":"teleport"}]}]}
        """
        let result = try RuleImporter().importRules(from: Data(json.utf8), startOrder: 0)
        #expect(result.unknownRuleNames == ["Future"])
        #expect(result.rules.first?.isEnabled == false)
    }

    @Test func rejectsBadFiles() throws {
        #expect(throws: RuleImporter.ImportError.unreadable) {
            try RuleImporter().importRules(from: Data("nope".utf8), startOrder: 0)
        }
        #expect(throws: RuleImporter.ImportError.noRules) {
            try RuleImporter().importRules(from: try exported([]), startOrder: 0)
        }
        #expect(throws: RuleImporter.ImportError.newerVersion(99)) {
            try RuleImporter().importRules(from: Data(#"{"version":99,"rules":[]}"#.utf8), startOrder: 0)
        }
    }

    @Test func migratesOlderVersions() throws {
        let migrator = RulesMigrator(currentVersion: 2, steps: [1: { $0 }])
        let data = try exported([Rule(name: "Old", scope: [], actions: [.trash])], version: 1)
        let result = try RuleImporter(migrator: migrator).importRules(from: data, startOrder: 0)
        #expect(result.rules.map(\.name) == ["Old"])
    }
}

struct FolderStatusCheckerTests {
    @Test func groupsRulesByFolderAndReportsStatus() {
        let good = FolderRef(path: "/a")
        let missing = FolderRef(path: "/b")
        let one = Rule(name: "One", scope: [good, missing], actions: [.trash])
        let two = Rule(name: "Two", scope: [good], actions: [.trash])
        let usages = FolderStatusChecker.usages(for: [one, two]) { $0 == missing ? .missing : .ok }

        #expect(usages.map(\.folder) == [good, missing])
        #expect(usages[0].ruleNames == ["One", "Two"])
        #expect(usages[1].health == .missing)

        let statuses = FolderStatusChecker.ruleStatuses(from: usages, rules: [one, two])
        #expect(statuses[one.id] == .folderMissing("/b"))
        #expect(statuses[two.id] == nil)
    }

    @Test func realCheckFindsMissingFolder() {
        let path = "/tmp/MFPete-missing-\(UUID().uuidString)"
        let usages = FolderStatusChecker.usages(for: [Rule(name: "X", scope: [FolderRef(path: path)], actions: [.trash])])
        #expect(usages.first?.health == .missing)
    }
}

struct ActivityEntriesTests {
    @Test func filtersByRuleAndErrors() async throws {
        let store = ActivityStore(modelContainer: try DataStore.makeInMemoryContainer())
        let ruleA = UUID()
        let ruleB = UUID()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.add([
            ActivityRecord(timestamp: base, ruleID: ruleA, ruleName: "A", action: "Move", sourcePath: "/1", result: .success),
            ActivityRecord(timestamp: base.addingTimeInterval(1), ruleID: ruleA, ruleName: "A", action: "Move", sourcePath: "/2", result: .failed),
            ActivityRecord(timestamp: base.addingTimeInterval(2), ruleID: ruleB, ruleName: "B", action: "Tag", sourcePath: "/3", result: .skipped),
            ActivityRecord(timestamp: base.addingTimeInterval(3), ruleID: ruleB, ruleName: "B", action: "Tag", sourcePath: "/4", result: .failed),
        ])

        #expect(try await store.entries().map(\.sourcePath) == ["/4", "/3", "/2", "/1"])
        #expect(try await store.entries(ruleID: ruleA).map(\.sourcePath) == ["/2", "/1"])
        #expect(try await store.entries(errorsOnly: true).map(\.sourcePath) == ["/4", "/2"])
        #expect(try await store.entries(ruleID: ruleB, errorsOnly: true).map(\.sourcePath) == ["/4"])
        #expect(try await store.entries(limit: 2).count == 2)
    }
}
