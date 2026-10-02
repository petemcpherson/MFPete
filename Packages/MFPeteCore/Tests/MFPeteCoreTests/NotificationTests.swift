import Foundation
import Testing
@testable import MFPeteCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let ruleA = UUID()
private let ruleB = UUID()

private func summary(
    _ trigger: RunTrigger,
    rule: UUID = ruleA,
    actedOn: Int = 0,
    failed: Int = 0,
    ruleErrors: [String] = [],
    skippedProcessed: Int = 0,
    verb: String? = nil,
    at date: Date = start
) -> RunSummary {
    var summary = RunSummary(ruleID: rule, ruleName: "Clean Downloads", trigger: trigger, startedAt: date)
    summary.actedOn = actedOn
    summary.failed = failed
    summary.matched = actedOn + failed + skippedProcessed
    summary.ruleErrors = ruleErrors
    summary.skippedProcessed = skippedProcessed
    summary.dominantVerb = verb
    return summary
}

struct NotificationPolicyTests {
    private func notify(_ level: NotificationLevel, eachRun: Bool = false, _ summary: RunSummary) -> Bool {
        NotificationPolicy.shouldNotify(level: level, notifyEachRun: eachRun, summary: summary)
    }

    @Test func offNeverNotifies() {
        #expect(!notify(.off, summary(.fileEvent, actedOn: 3)))
        #expect(!notify(.off, eachRun: true, summary(.scheduled, actedOn: 3)))
        #expect(!notify(.off, summary(.manual)))
        #expect(!notify(.off, summary(.fileEvent, failed: 1)))
        #expect(!NotificationPolicy.shouldNotifyLoop(level: .off))
    }

    @Test func errorsOnlyRow() {
        // Automatic runs: only with "Notify on each run".
        #expect(!notify(.errorsOnly, summary(.fileEvent, actedOn: 3)))
        #expect(!notify(.errorsOnly, summary(.scheduled, actedOn: 3)))
        #expect(notify(.errorsOnly, eachRun: true, summary(.fileEvent, actedOn: 3)))
        #expect(notify(.errorsOnly, eachRun: true, summary(.scheduledLate, actedOn: 1)))
        // Manual runs always, even with no matches.
        #expect(notify(.errorsOnly, summary(.manual)))
        #expect(notify(.errorsOnly, summary(.applyExisting, actedOn: 2)))
        // Errors always.
        #expect(notify(.errorsOnly, summary(.fileEvent, failed: 1)))
        #expect(notify(.errorsOnly, summary(.scheduled, ruleErrors: ["Folder missing: ~/X"])))
        #expect(NotificationPolicy.shouldNotifyLoop(level: .errorsOnly))
    }

    @Test func everyRunRow() {
        #expect(notify(.everyRun, summary(.fileEvent, actedOn: 1)))
        #expect(notify(.everyRun, summary(.scheduled, actedOn: 4)))
        #expect(notify(.everyRun, summary(.manual)))
        #expect(notify(.everyRun, summary(.scheduled, failed: 2)))
        #expect(NotificationPolicy.shouldNotifyLoop(level: .everyRun))
    }

    @Test func automaticRunsWithNoFilesActedOnNeverNotify() {
        for level in NotificationLevel.allCases {
            #expect(!notify(level, eachRun: true, summary(.fileEvent)))
            #expect(!notify(level, eachRun: true, summary(.scheduled, skippedProcessed: 5)))
        }
    }

    @Test func runsWaitingForBulkApprovalDoNotNotify() {
        var held = summary(.manual, failed: 1)
        held.pendingApproval = BulkApprovalRequest(ruleID: ruleA, ruleName: "X", fileCount: 60, trigger: .manual)
        #expect(!notify(.everyRun, held))
    }
}

struct RunNotificationTextTests {
    @Test func successUsesDominantVerb() {
        let text = RunNotificationText(summary: summary(.fileEvent, actedOn: 3, verb: "moved to Trash"))
        #expect(text.title == "Clean Downloads")
        #expect(text.body == "3 files moved to Trash")
        #expect(RunNotificationText(summary: summary(.manual, actedOn: 1, verb: "tagged")).body == "1 file tagged")
        #expect(RunNotificationText(summary: summary(.manual, actedOn: 2)).body == "2 files processed")
    }

    @Test func failuresAndErrors() {
        #expect(RunNotificationText(summary: summary(.fileEvent, actedOn: 5, failed: 1)).body == "5 files processed, 1 failed")
        #expect(RunNotificationText(summary: summary(.fileEvent, failed: 2)).body == "2 files failed")
        #expect(RunNotificationText(summary: summary(.scheduled, ruleErrors: ["Folder missing: ~/X"])).body == "Folder missing: ~/X")
        #expect(RunNotificationText(summary: summary(.scheduled, ruleErrors: ["A", "B", "C"])).body == "A (and 2 more)")
    }

    @Test func noMatches() {
        #expect(RunNotificationText(summary: summary(.manual)).body == "No matching files")
        #expect(RunNotificationText(summary: summary(.manual, skippedProcessed: 3)).body == "No new matching files")
    }

    @Test func loopAlert() {
        let alert = LoopAlert(ruleIDs: [ruleA, ruleB], ruleNames: ["A", "B"], filePath: "/tmp/x")
        let text = RunNotificationText(loop: alert)
        #expect(text.body == "Possible rule loop between A and B")
    }
}

struct NotificationCoalescerTests {
    @Test func fileEventsWithinWindowMerge() {
        var coalescer = NotificationCoalescer(window: 5)
        #expect(coalescer.add(summary(.fileEvent, actedOn: 1, verb: "moved to Trash"), now: start) == nil)
        #expect(coalescer.add(summary(.fileEvent, actedOn: 2, verb: "moved to Trash"), now: start.addingTimeInterval(2)) == nil)
        #expect(coalescer.add(summary(.fileEvent, failed: 1), now: start.addingTimeInterval(4.9)) == nil)
        #expect(coalescer.nextDeadline == start.addingTimeInterval(5))

        #expect(coalescer.due(at: start.addingTimeInterval(4.99)).isEmpty)
        let due = coalescer.due(at: start.addingTimeInterval(5))
        #expect(due.count == 1)
        #expect(due.first?.actedOn == 3)
        #expect(due.first?.failed == 1)
        #expect(due.first?.dominantVerb == "moved to Trash")
        #expect(coalescer.isEmpty)
    }

    @Test func runAfterWindowStartsNewSummary() {
        var coalescer = NotificationCoalescer(window: 5)
        _ = coalescer.add(summary(.fileEvent, actedOn: 1), now: start)
        #expect(coalescer.due(at: start.addingTimeInterval(5)).count == 1)
        _ = coalescer.add(summary(.fileEvent, actedOn: 1), now: start.addingTimeInterval(6))
        #expect(coalescer.nextDeadline == start.addingTimeInterval(11))
    }

    @Test func rulesAreKeptApart() {
        var coalescer = NotificationCoalescer(window: 5)
        _ = coalescer.add(summary(.fileEvent, rule: ruleA, actedOn: 1), now: start)
        _ = coalescer.add(summary(.fileEvent, rule: ruleB, actedOn: 4), now: start.addingTimeInterval(1))
        #expect(coalescer.due(at: start.addingTimeInterval(5)).map(\.actedOn) == [1])
        #expect(coalescer.due(at: start.addingTimeInterval(6)).map(\.actedOn) == [4])
    }

    @Test func otherTriggersPassThrough() {
        var coalescer = NotificationCoalescer(window: 5)
        for trigger in [RunTrigger.manual, .scheduled, .scheduledLate, .applyExisting] {
            #expect(coalescer.add(summary(trigger, actedOn: 1), now: start)?.trigger == trigger)
        }
        #expect(coalescer.isEmpty)
    }

    @Test func mixedVerbsFallBackToProcessed() {
        let merged = summary(.fileEvent, actedOn: 1, verb: "tagged")
            .merged(with: summary(.fileEvent, actedOn: 1, verb: "moved to Trash"))
        #expect(merged.dominantVerb == "processed")
        #expect(RunNotificationText(summary: merged).body == "2 files processed")
    }
}
