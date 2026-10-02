//
//  MFPeteTests.swift
//  MFPeteTests
//
//  Created by Pete McPherson on 10/1/26.
//

import Foundation
import MFPeteCore
import SwiftData
import Testing
@testable import MFPete

/// Rules store, in-memory data, and settings isolated from the real app.
@MainActor
func makeTestAppState(store: RulesStore? = nil) throws -> AppState {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MFPeteTests-\(UUID().uuidString)", isDirectory: true)
    let suite = "MFPeteTests-\(UUID().uuidString)"
    return AppState(
        rulesStore: store ?? RulesStore(directory: directory),
        modelContainer: try DataStore.makeInMemoryContainer(),
        defaults: UserDefaults(suiteName: suite) ?? .standard
    )
}

@MainActor
struct AppStateTests {
    private func makeStore() throws -> RulesStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFPeteTests-\(UUID().uuidString)", isDirectory: true)
        return RulesStore(directory: directory)
    }

    @Test func rulesPersistAcrossRelaunch() throws {
        let store = try makeStore()
        let state = try makeTestAppState(store: store)
        #expect(state.rules.isEmpty)

        state.add(Rule(name: "A", scope: [FolderRef(path: "/tmp/a")], actions: [.trash]))
        state.add(Rule(name: "B", isEnabled: false))
        state.add(Rule(name: "C"))
        #expect(state.activeRuleCount == 2)

        state.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        state.setEnabled(true, for: state.rules[2].id)
        state.delete([state.rules[1].id])

        let relaunched = try makeTestAppState(store: store)
        #expect(relaunched.rules.map(\.name) == ["C", "B"])
        #expect(relaunched.rules.map(\.order) == [0, 1])
        #expect(relaunched.activeRuleCount == 2)
        #expect(relaunched.loadIssue == nil)
    }

    @Test func updateReplacesRuleAndBumpsModifiedDate() throws {
        let store = try makeStore()
        let state = try makeTestAppState(store: store)
        let original = Rule(name: "Old", createdAt: Date(timeIntervalSince1970: 0))
        state.add(original)

        var edited = original
        edited.name = "New"
        state.update(edited)

        let relaunched = try makeTestAppState(store: store)
        #expect(relaunched.rules.first?.name == "New")
        #expect(relaunched.rules.first.map { $0.modifiedAt > original.modifiedAt } == true)
    }

    @Test func duplicateInsertsDisabledCopyBelowOriginal() throws {
        let state = try makeTestAppState()
        state.add(Rule(name: "A", scope: [FolderRef(path: "/tmp/a")], actions: [.trash]))
        state.add(Rule(name: "B"))

        let copy = try #require(state.duplicate(state.rules[0].id))
        #expect(state.rules.map(\.name) == ["A", "A copy", "B"])
        #expect(state.rules.map(\.order) == [0, 1, 2])
        #expect(copy.id != state.rules[0].id)
        #expect(!copy.isEnabled)
        #expect(copy.actions == [.trash])
    }
}
