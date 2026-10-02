import Foundation
import Testing
@testable import MFPeteCore

private let summarizer = RuleSummarizer(locale: Locale(identifier: "en_US"), calendar: utcCalendar)
private let downloads = FolderRef(path: "/Users/me/Downloads")

private func condition(_ attribute: Attribute, _ op: Operator, _ value: ConditionValue = .none) -> ConditionItem {
    .condition(Condition(attribute: attribute, op: op, value: value))
}

struct RuleSummarizerTests {
    @Test func specExample() {
        let rule = Rule(
            scope: [downloads],
            conditions: ConditionGroup(items: [condition(.extension, .isAnyOf, .text("dmg, zip"))]),
            actions: [.trash]
        )
        #expect(summarizer.sentence(for: rule)
            == "When a file is added to Downloads, if its extension is dmg or zip, then move it to the Trash.")
    }

    /// Snapshot for each starter template (spec §8.6).
    @Test func templateSentences() {
        let screenshots = FolderRef(path: "/Users/me/Screenshots")
        let desktop = FolderRef(path: "/Users/me/Desktop")
        let inbox = FolderRef(path: "/Users/me/Desktop Inbox")
        let vault = FolderRef(path: "/Users/me/Vault")
        let documents = FolderRef(path: "/Users/me/Documents")

        let templates: [(Rule, String)] = [
            (Rule(
                scope: [downloads],
                trigger: .daily(hour: 9, minute: 0),
                conditions: ConditionGroup(items: [
                    .group(ConditionGroup(match: .any, items: [
                        condition(.kind, .is, .kind(.diskImage)),
                        condition(.kind, .is, .kind(.archive)),
                    ])),
                    condition(.dateAdded, .notInTheLast, .duration(7, .days)),
                ]),
                actions: [.trash]
            ), "Every day at 9:00\u{202F}AM, for files in Downloads, if (its kind is Disk Image or its kind is Archive) and its date added is not in the last 7 days, then move it to the Trash."),
            (Rule(
                scope: [downloads],
                conditions: ConditionGroup(items: [condition(.extension, .is, .text("zip"))]),
                actions: [.unarchive(destination: nil, trashArchive: true)]
            ), "When a file is added to Downloads, if its extension is zip, then unarchive it and move the archive to the Trash."),
            (Rule(
                scope: [screenshots],
                trigger: .daily(hour: 18, minute: 30),
                conditions: ConditionGroup(items: [
                    condition(.name, .startsWith, .text("Screenshot")),
                    condition(.dateAdded, .notInTheLast, .duration(3, .days)),
                ]),
                actions: [.move(to: FolderRef(path: "/Users/me/Screenshots/Archive"), onConflict: .keepBoth)]
            ), "Every day at 6:30\u{202F}PM, for files in Screenshots, if its name starts with “Screenshot” and its date added is not in the last 3 days, then move it to Archive."),
            (Rule(
                scope: [desktop],
                conditions: ConditionGroup(items: [condition(.kind, .isNot, .kind(.alias))]),
                actions: [.move(to: inbox, onConflict: .keepBoth)]
            ), "When a file is added to Desktop, if its kind is not Alias, then move it to Desktop Inbox."),
            (Rule(
                scope: [documents],
                actions: [.sortIntoSubfolder(base: documents, pattern: "{extension}")]
            ), "When a file is added to Documents, then sort it into Documents/{extension}."),
            (Rule(
                scope: [downloads],
                conditions: ConditionGroup(items: [condition(.extension, .is, .text("txt"))]),
                actions: [.changeExtension("md"), .move(to: vault, onConflict: .keepBoth)]
            ), "When a file is added to Downloads, if its extension is txt, then change its extension to md and move it to Vault."),
        ]
        for (rule, expected) in templates {
            #expect(summarizer.sentence(for: rule) == expected)
        }
    }

    @Test func triggers() {
        let base = Rule(scope: [downloads, FolderRef(path: "/Users/me/Desktop")], actions: [.revealInFinder])
        func phrase(_ trigger: Trigger) -> String {
            var rule = base
            rule.trigger = trigger
            return summarizer.triggerPhrase(rule)
        }
        #expect(phrase(.fileModified) == "When a file is modified in Downloads and Desktop")
        #expect(phrase(.fileRemoved) == "When a file is removed from Downloads and Desktop")
        #expect(phrase(.interval(minutes: 30)) == "Every 30 minutes, for files in Downloads and Desktop")
        #expect(phrase(.interval(minutes: 60)) == "Every hour, for files in Downloads and Desktop")
        #expect(phrase(.interval(minutes: 120)) == "Every 2 hours, for files in Downloads and Desktop")
        #expect(phrase(.weekly(weekdays: [2, 4, 6], hour: 18, minute: 0))
            == "Every Mon, Wed, and Fri at 6:00\u{202F}PM, for files in Downloads and Desktop")
        #expect(phrase(.weekly(weekdays: Set(1...7), hour: 8, minute: 5))
            == "Every day at 8:05\u{202F}AM, for files in Downloads and Desktop")
        var empty = base
        empty.scope = []
        #expect(summarizer.triggerPhrase(empty) == "When a file is added to a folder")
    }

    @Test func conditionPhrases() {
        func phrase(_ item: ConditionItem) -> String? {
            summarizer.conditionsPhrase(ConditionGroup(items: [item]))
        }
        #expect(phrase(condition(.fullName, .matchesPattern, .text("IMG_*"))) == "its full name matches “IMG_*”")
        #expect(phrase(condition(.size, .greaterThan, .size(1.5, .gb))) == "its size is greater than 1.5 GB")
        #expect(phrase(condition(.size, .lessThan, .size(10, .kb))) == "its size is less than 10 KB")
        #expect(phrase(condition(.dateModified, .inTheLast, .duration(1, .hours))) == "its date modified is in the last hour")
        let date = utcCalendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        #expect(phrase(condition(.dateCreated, .before, .date(date))) == "its date created is before Jan 15, 2026")
        #expect(phrase(condition(.tags, .containsTag, .tags(["Red", "Blue"]))) == "its tags include Red or Blue")
        #expect(phrase(condition(.tags, .hasNoTags)) == "it has no tags")
        #expect(phrase(condition(.downloadedFrom, .contains, .text("github.com"))) == "its download source contains “github.com”")
        #expect(phrase(condition(.anyFile, .always)) == "it is any file")
        #expect(summarizer.conditionsPhrase(ConditionGroup()) == nil)

        let any = ConditionGroup(match: .any, items: [
            condition(.extension, .is, .text("png")),
            condition(.extension, .is, .text("jpg")),
        ])
        #expect(summarizer.conditionsPhrase(any) == "its extension is png or its extension is jpg")
    }

    @Test func actionPhrases() {
        let folder = FolderRef(path: "/Users/me/Backup")
        #expect(summarizer.actionPhrase(.copy(to: folder, onConflict: .keepBoth)) == "copy it to Backup")
        #expect(summarizer.actionPhrase(.rename(pattern: "{name}-{today}.{extension}", onConflict: .keepBoth))
            == "rename it to “{name}-{today}.{extension}”")
        #expect(summarizer.actionPhrase(.addTags(["Red", "Work"])) == "tag it Red and Work")
        #expect(summarizer.actionPhrase(.removeTags(["Red"])) == "remove tags Red")
        #expect(summarizer.actionPhrase(.unarchive(destination: folder, trashArchive: false)) == "unarchive it into Backup")
        #expect(summarizer.actionPhrase(.open(withApp: nil)) == "open it")
        #expect(summarizer.actionPhrase(.open(withApp: URL(fileURLWithPath: "/Applications/Preview.app"))) == "open it with Preview")
        #expect(summarizer.actionPhrase(.notify(message: "x")) == "show a notification")
        #expect(summarizer.actionsPhrase([.addTags(["A"]), .revealInFinder, .trash])
            == "tag it A, reveal it in Finder, and move it to the Trash")
        #expect(summarizer.actionsPhrase([]) == "do nothing")
    }

    @Test func shortSummary() {
        let rule = Rule(
            scope: [downloads],
            conditions: ConditionGroup(items: [condition(.extension, .is, .text("dmg"))]),
            actions: [.trash]
        )
        let short = summarizer.shortSummary(for: rule)
        #expect(short.trigger == "When a file is added to Downloads, if its extension is dmg")
        #expect(short.actions == "Move it to the Trash")
    }
}
