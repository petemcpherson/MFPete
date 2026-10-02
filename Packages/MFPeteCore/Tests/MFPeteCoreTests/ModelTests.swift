import Foundation
import Testing
@testable import MFPeteCore

struct FolderRefTests {
    let home = "/Users/pete"

    @Test func abbreviatesHome() {
        #expect(FolderRef(path: "/Users/pete/Downloads").tildeAbbreviated(home: home) == "~/Downloads")
        #expect(FolderRef(path: "/Users/pete").tildeAbbreviated(home: home) == "~")
        #expect(FolderRef(path: "/Users/peter/Downloads").tildeAbbreviated(home: home) == "/Users/peter/Downloads")
        #expect(FolderRef(path: "/Volumes/Disk").tildeAbbreviated(home: home) == "/Volumes/Disk")
    }

    @Test func expandsTilde() {
        #expect(FolderRef(expanding: "~/Downloads", home: home).path == "/Users/pete/Downloads")
        #expect(FolderRef(expanding: "~", home: home).path == "/Users/pete")
        #expect(FolderRef(expanding: "/tmp/x", home: home).path == "/tmp/x")
        #expect(FolderRef(expanding: "~other/x", home: home).path == "~other/x")
    }

    @Test func ruleExportAbbreviatesAllFolders() {
        let rule = Rule(
            scope: [FolderRef(path: "/Users/pete/Downloads")],
            actions: [
                .move(to: FolderRef(path: "/Users/pete/Archive"), onConflict: .keepBoth),
                .unarchive(destination: FolderRef(path: "/Users/pete/Out"), trashArchive: true),
            ]
        )
        let exported = rule.tildeAbbreviated(home: home)
        #expect(exported.scope == [FolderRef(path: "~/Downloads")])
        #expect(exported.actions == [
            .move(to: FolderRef(path: "~/Archive"), onConflict: .keepBoth),
            .unarchive(destination: FolderRef(path: "~/Out"), trashArchive: true),
        ])
    }
}

struct RuleNamingTests {
    @Test func autoName() {
        let downloads = FolderRef(path: "/Users/pete/Downloads")
        #expect(Rule.autoName(scope: [downloads], actions: [.trash]) == "Downloads: Move to Trash")
        #expect(Rule.autoName(scope: [downloads], actions: [.move(to: FolderRef(path: "/x/Archive"), onConflict: .keepBoth)])
            == "Downloads: Move to Archive")
        #expect(Rule.autoName(scope: [downloads], actions: []) == "Downloads")
        #expect(Rule.autoName(scope: [], actions: [.trash]) == "Move to Trash")
        #expect(Rule.autoName(scope: [], actions: []) == "New Rule")
    }

    @Test func initUsesAutoNameWhenNil() {
        let rule = Rule(scope: [FolderRef(path: "/Users/pete/Desktop")], actions: [.revealInFinder])
        #expect(rule.name == "Desktop: Reveal in Finder")
    }
}

struct OperatorValidityTests {
    @Test func table() {
        #expect(Attribute.extension.allowedOperators == [.is, .isNot, .isAnyOf])
        #expect(Attribute.kind.allowedOperators == [.is, .isNot])
        #expect(Attribute.size.allowedOperators == [.greaterThan, .lessThan])
        #expect(Attribute.dateAdded.allowedOperators == [.inTheLast, .notInTheLast, .before, .after])
        #expect(Attribute.tags.allowedOperators == [.containsTag, .doesNotContainTag, .hasNoTags])
        #expect(Attribute.downloadedFrom.allowedOperators == [.contains, .doesNotContain, .is])
        #expect(Attribute.anyFile.allowedOperators == [.always])
        #expect(!Attribute.name.allows(.isAnyOf))
        #expect(Attribute.fullName.allows(.matchesPattern))
    }

    @Test func valueTypes() {
        #expect(Operator.is.valueType(for: .kind) == .kind)
        #expect(Operator.is.valueType(for: .name) == .text)
        #expect(Operator.inTheLast.valueType(for: .dateCreated) == .duration)
        #expect(Operator.after.valueType(for: .dateCreated) == .date)
        #expect(Operator.hasNoTags.valueType(for: .tags) == .none)
    }

    @Test func malformedConditions() {
        #expect(!Condition(attribute: .size, op: .is, value: .text("x")).isWellFormed)
        #expect(!Condition(attribute: .size, op: .greaterThan, value: .text("x")).isWellFormed)
        #expect(Condition(attribute: .size, op: .greaterThan, value: .size(5, .mb)).isWellFormed)
    }

    @Test func sizeUnitsAreDecimal() {
        #expect(SizeUnit.kb.bytes == 1_000)
        #expect(SizeUnit.gb.bytes == 1_000_000_000)
    }
}
