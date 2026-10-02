import Foundation
import Testing
@testable import MFPeteCore

/// Spec §5.8: a full scan of a 5,000-item folder finishes in under 2 seconds.
struct PerformanceTests {
    private static let fileCount = 5_000

    private func makeFolder(_ h: EngineHarness) throws {
        let folder = try h.sandbox.folder("in")
        for index in 0..<Self.fileCount {
            let ext = ["txt", "pdf", "jpg", "png", "zip"][index % 5]
            try Data().write(to: folder.appendingPathComponent("file-\(index).\(ext)"))
        }
    }

    private func rule(_ h: EngineHarness) -> Rule {
        Rule(
            name: "Find disk images",
            isEnabled: false,
            scope: [h.sandbox.ref("in")],
            trigger: .daily(hour: 9, minute: 0),
            conditions: ConditionGroup(match: .any, items: [
                .condition(Condition(attribute: .extension, op: .is, value: .text("dmg"))),
                .condition(Condition(attribute: .name, op: .contains, value: .text("installer"))),
            ]),
            actions: [.trash]
        )
    }

    @Test func fullScanOfFiveThousandFilesIsFast() async throws {
        let h = try EngineHarness()
        try makeFolder(h)
        let rule = rule(h)
        await h.engine.setRules([rule])

        let clock = ContinuousClock()
        var summary: RunSummary?
        let elapsed = await clock.measure {
            summary = await h.engine.scanAndRun(rule, reason: .manual)
        }

        #expect(summary?.matched == 0)
        #expect(elapsed < .seconds(2), "Scan took \(elapsed)")
    }

    @Test func previewOfFiveThousandFilesIsFast() async throws {
        let h = try EngineHarness()
        try makeFolder(h)
        let rule = rule(h)

        let clock = ContinuousClock()
        var results: [PlannedFileResult] = []
        let elapsed = await clock.measure {
            results = await h.engine.plan(rule: rule)
        }

        #expect(results.isEmpty)
        #expect(elapsed < .seconds(2), "Preview took \(elapsed)")
    }
}
