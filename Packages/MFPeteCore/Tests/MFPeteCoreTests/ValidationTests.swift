import Foundation
import Testing
@testable import MFPeteCore

struct RuleValidatorTests {
    private let validator = RuleValidator()
    private let downloads = FolderRef(path: "/Users/me/Downloads")
    private let archive = FolderRef(path: "/Users/me/Archive")

    private func rule(
        scope: [FolderRef]? = nil,
        trigger: Trigger = .fileAdded,
        conditions: [ConditionItem] = [.condition(Condition(attribute: .extension, op: .is, value: .text("zip")))],
        actions: [Action] = [.trash]
    ) -> Rule {
        Rule(
            name: "Test",
            scope: scope ?? [downloads],
            trigger: trigger,
            conditions: ConditionGroup(items: conditions),
            actions: actions
        )
    }

    private func codes(_ rule: Rule, _ severity: RuleIssue.Severity = .error) -> [RuleIssue.Code] {
        validator.validate(rule).filter { $0.severity == severity }.map(\.code)
    }

    @Test func validRuleHasNoIssues() {
        #expect(validator.validate(rule()).isEmpty)
        #expect(!validator.hasErrors(rule()))
    }

    // MARK: Scope

    @Test func needsAtLeastOneFolder() {
        #expect(codes(rule(scope: [])) == [.noFolders])
    }

    @Test func templateFolderLeftEmptyIsAnError() {
        #expect(codes(rule(scope: [FolderRef(path: "")])) == [.emptyFolder])
    }

    // MARK: Trigger

    @Test func intervalMinimumIsFiveMinutes() {
        #expect(codes(rule(trigger: .interval(minutes: 4))) == [.intervalTooShort])
        #expect(codes(rule(trigger: .interval(minutes: 5))).isEmpty)
    }

    @Test func weeklyNeedsADay() {
        #expect(codes(rule(trigger: .weekly(weekdays: [], hour: 9, minute: 0))) == [.noWeekdays])
        #expect(codes(rule(trigger: .weekly(weekdays: [2], hour: 9, minute: 0))).isEmpty)
    }

    @Test func dailyNeedsAValidTime() {
        #expect(codes(rule(trigger: .daily(hour: 24, minute: 0))) == [.invalidTime])
        #expect(codes(rule(trigger: .daily(hour: 9, minute: 0, days: 0))) == [.invalidDayCount])
        #expect(codes(rule(trigger: .daily(hour: 9, minute: 0, days: 3))).isEmpty)
    }

    // MARK: Conditions

    @Test func emptyTextValueIsMissing() {
        let empty = rule(conditions: [.condition(Condition(attribute: .name, op: .contains, value: .text("  ")))])
        #expect(codes(empty) == [.conditionValueMissing])
        let emptyList = rule(conditions: [.condition(Condition(attribute: .extension, op: .isAnyOf, value: .text(" , ")))])
        #expect(codes(emptyList) == [.conditionValueMissing])
    }

    @Test func emptyTagsAndZeroAmountsAreMissing() {
        let tags = rule(conditions: [.condition(Condition(attribute: .tags, op: .containsTag, value: .tags([])))])
        #expect(codes(tags) == [.conditionValueMissing])
        let size = rule(conditions: [.condition(Condition(attribute: .size, op: .greaterThan, value: .size(0, .mb)))])
        #expect(codes(size) == [.conditionValueMissing])
        let age = rule(trigger: .daily(hour: 9, minute: 0), conditions: [
            .condition(Condition(attribute: .dateAdded, op: .notInTheLast, value: .duration(0, .days))),
        ])
        #expect(codes(age) == [.conditionValueMissing])
    }

    @Test func valuelessOperatorsNeedNoValue() {
        let rule = rule(conditions: [
            .condition(Condition(attribute: .tags, op: .hasNoTags)),
            .condition(Condition(attribute: .anyFile, op: .always)),
        ])
        #expect(codes(rule).isEmpty)
    }

    @Test func malformedConditionIsInvalid() {
        let bad = rule(conditions: [.condition(Condition(attribute: .size, op: .contains, value: .text("x")))])
        #expect(codes(bad) == [.conditionInvalid])
    }

    @Test func nestedGroupConditionsAreChecked() {
        let nested = rule(conditions: [
            .group(ConditionGroup(match: .any, items: [
                .condition(Condition(attribute: .name, op: .is, value: .text(""))),
            ])),
        ])
        #expect(codes(nested) == [.conditionValueMissing])
    }

    @Test func unknownConditionIsAnError() {
        let unknown = rule(conditions: [.unknown(.object(["type": .string("future")]))])
        #expect(codes(unknown) == [.unknownCondition])
    }

    // MARK: Actions

    @Test func needsAtLeastOneAction() {
        #expect(codes(rule(actions: [])) == [.noActions])
    }

    @Test func requiredActionParameters() {
        let empty = FolderRef(path: "")
        let cases: [Action] = [
            .move(to: empty, onConflict: .keepBoth),
            .copy(to: empty, onConflict: .keepBoth),
            .rename(pattern: " ", onConflict: .keepBoth),
            .changeExtension("."),
            .addTags([]),
            .removeTags([]),
            .notify(message: ""),
            .unarchive(destination: empty, trashArchive: false),
        ]
        for action in cases {
            let issues = validator.validate(rule(actions: [action]))
            #expect(issues.map(\.code) == [.actionParameterMissing], "\(action)")
            #expect(issues.first?.actionIndex == 0)
        }
        let sort = rule(actions: [.sortIntoSubfolder(base: empty, pattern: "/")])
        #expect(codes(sort) == [.actionParameterMissing, .actionParameterMissing])
    }

    @Test func actionsWithoutParametersAreValid() {
        let actions: [Action] = [.open(withApp: nil), .revealInFinder, .unarchive(destination: nil, trashArchive: true)]
        #expect(codes(rule(actions: actions)).isEmpty)
    }

    @Test func templateDefaultsFailUntilFilledIn() {
        for type in ActionType.allCases {
            let action = type.makeAction()
            #expect(action.type == type)
        }
        #expect(codes(rule(actions: [ActionType.move.makeAction()])) == [.actionParameterMissing])
        #expect(codes(rule(actions: [ActionType.rename.makeAction()])).isEmpty)
    }

    @Test func fileRemovedAllowsOnlyNotifications() {
        let removed = rule(trigger: .fileRemoved, actions: [.trash, .notify(message: "Gone: {fullname}")])
        let issues = validator.validate(removed).filter { $0.severity == .error }
        #expect(issues.map(\.code) == [.actionNeedsFile])
        #expect(issues.first?.actionIndex == 0)
    }

    @Test func unknownActionIsAnError() {
        let unknown = rule(actions: [.unknown(.object(["type": .string("future")]))])
        #expect(codes(unknown) == [.unknownAction])
    }

    @Test func moveIntoSourceFolderIsAnError() {
        let move = rule(actions: [.move(to: FolderRef(path: "/Users/me/Downloads/"), onConflict: .keepBoth)])
        #expect(codes(move) == [.moveToSourceFolder])
    }

    @Test func moveIntoSourceFolderAfterRenameIsAWarning() {
        let renameFirst = rule(actions: [
            .rename(pattern: "{date-added} {name}.{extension}", onConflict: .keepBoth),
            .move(to: downloads, onConflict: .keepBoth),
        ])
        #expect(codes(renameFirst).isEmpty)
        #expect(codes(renameFirst, .warning) == [.moveToSourceFolder])

        let moveElsewhere = rule(actions: [.move(to: archive, onConflict: .keepBoth)])
        #expect(validator.validate(moveElsewhere).isEmpty)
    }

    @Test func unknownTokensAreFlagged() {
        let rename = rule(actions: [.rename(pattern: "{name}-{nope}.{extension}", onConflict: .keepBoth)])
        let issues = validator.validate(rename)
        #expect(issues.map(\.code) == [.unknownToken])
        #expect(issues.first?.severity == .warning)
        #expect(issues.first?.message.contains("{nope}") == true)
        let sort = rule(actions: [.sortIntoSubfolder(base: archive, pattern: "{year}/{bogus}")])
        #expect(codes(sort, .warning) == [.unknownToken])
    }

    // MARK: Destructive warning and hints

    @Test func trashWithoutConditionsWarns() {
        let trashAll = rule(conditions: [], actions: [.trash])
        #expect(codes(trashAll, .warning) == [.destructiveWithoutConditions])
        #expect(validator.destructiveWarning(for: trashAll) == "This rule will trash every file added to Downloads.")

        let scheduled = rule(trigger: .daily(hour: 9, minute: 0), conditions: [], actions: [.trash])
        #expect(validator.destructiveWarning(for: scheduled) == "This rule will trash every file in Downloads.")
    }

    @Test func replacePolicyWithoutConditionsWarns() {
        let replace = rule(conditions: [], actions: [.move(to: archive, onConflict: .replace)])
        #expect(codes(replace, .warning) == [.destructiveWithoutConditions])
        let keepBoth = rule(conditions: [], actions: [.move(to: archive, onConflict: .keepBoth)])
        #expect(validator.destructiveWarning(for: keepBoth) == nil)
    }

    @Test func conditionsSilenceDestructiveWarning() {
        #expect(validator.destructiveWarning(for: rule()) == nil)
    }

    @Test func hints() {
        #expect(RuleValidator.matchesEverything(rule(conditions: [])))
        #expect(!RuleValidator.matchesEverything(rule()))

        let age = [ConditionItem.condition(Condition(attribute: .dateAdded, op: .notInTheLast, value: .duration(3, .days)))]
        #expect(RuleValidator.showsAgeHint(rule(trigger: .fileAdded, conditions: age)))
        #expect(!RuleValidator.showsAgeHint(rule(trigger: .daily(hour: 9, minute: 0), conditions: age)))
        #expect(!RuleValidator.showsAgeHint(rule(trigger: .fileAdded)))
    }

    @Test func everyTemplateValidatesOnceFoldersAreSet() {
        for template in RuleTemplate.all {
            var rule = template.makeRule(home: "/Users/me")
            rule.scope = rule.scope.isEmpty ? [downloads] : rule.scope
            rule.actions = rule.actions.map { action in
                action.mappingFolders { $0.path.isEmpty ? archive : $0 }
            }
            #expect(!validator.hasErrors(rule), "\(template.id): \(validator.validate(rule))")
        }
    }

    @Test func templatesWithoutFoldersAskForThem() {
        #expect(validator.hasErrors(RuleTemplate.sortByType.makeRule(home: "/Users/me")))
        #expect(validator.hasErrors(RuleTemplate.textToMarkdown.makeRule(home: "/Users/me")))
    }
}

struct EditorChoicesTests {
    @Test func triggerTypeRoundTrip() {
        for type in TriggerType.allCases {
            #expect(type.makeTrigger(from: .fileAdded).type == type)
        }
    }

    @Test func switchingScheduleKeepsTimeOfDay() {
        let weekly = TriggerType.weekly.makeTrigger(from: .daily(hour: 18, minute: 30))
        #expect(weekly == .weekly(weekdays: [2], hour: 18, minute: 30))
        let daily = TriggerType.daily.makeTrigger(from: .weekly(weekdays: [1, 7], hour: 7, minute: 15))
        #expect(daily == .daily(hour: 7, minute: 15))
        #expect(TriggerType.daily.makeTrigger(from: .daily(hour: 7, minute: 15, days: 3)) == .daily(hour: 7, minute: 15, days: 3))
        #expect(TriggerType.interval.makeTrigger(from: .interval(minutes: 15)) == .interval(minutes: 15))
    }

    @Test func everyAttributeDefaultIsWellFormed() {
        for attribute in Attribute.allCases {
            #expect(attribute.makeCondition().isWellFormed, "\(attribute)")
        }
    }

    @Test func changingAttributeKeepsMatchCaseOnlyForTextAttributes() {
        let name = Condition(attribute: .name, op: .is, value: .text("pdf"), caseSensitive: true)
        #expect(name.changingAttribute(to: .fullName).caseSensitive)
        #expect(!name.changingAttribute(to: .extension).caseSensitive)
    }

    @Test func changingAttributeKeepsFittingOperatorAndValue() {
        let name = Condition(attribute: .name, op: .contains, value: .text("invoice"))
        let fullName = name.changingAttribute(to: .fullName)
        #expect(fullName == Condition(attribute: .fullName, op: .contains, value: .text("invoice")))

        let kind = name.changingAttribute(to: .kind)
        #expect(kind.op == .is)
        #expect(kind.value.valueType == .kind)
        #expect(kind.isWellFormed)

        // "is" on Extension keeps text; switching to Kind needs a kind value.
        let ext = Condition(attribute: .extension, op: .is, value: .text("zip"))
        #expect(ext.changingAttribute(to: .kind).value == .kind(.document))
    }

    @Test func changingOperatorResetsValueOnlyWhenTypeChanges() {
        let date = Condition(attribute: .dateAdded, op: .inTheLast, value: .duration(3, .days))
        #expect(date.changingOperator(to: .notInTheLast).value == .duration(3, .days))
        #expect(date.changingOperator(to: .before).value.valueType == .date)
        #expect(date.changingOperator(to: .before).isWellFormed)
    }

    @Test func splitsCommaLists() {
        #expect(splitCommaList(" dmg, zip ,,pkg ") == ["dmg", "zip", "pkg"])
        #expect(splitCommaList("").isEmpty)
    }
}

struct ProtectedLocationTests {
    @Test func homeFoldersAreProtected() {
        let home = "/Users/me"
        #expect(ProtectedLocation.of(FolderRef(path: "/Users/me/Downloads"), home: home) == .downloads)
        #expect(ProtectedLocation.of(FolderRef(path: "/Users/me/Desktop/Inbox"), home: home) == .desktop)
        #expect(ProtectedLocation.of(FolderRef(path: "/Users/me/Documents"), home: home) == .documents)
        #expect(ProtectedLocation.of(FolderRef(path: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"), home: home) == .iCloudDrive)
    }

    @Test func otherFoldersAreNotProtected() {
        let home = "/Users/me"
        #expect(ProtectedLocation.of(FolderRef(path: "/Users/me/Screenshots"), home: home) == nil)
        #expect(ProtectedLocation.of(FolderRef(path: "/Users/me/DownloadsOld"), home: home) == nil)
        #expect(ProtectedLocation.of(FolderRef(path: "/tmp"), home: home) == nil)
    }
}

struct ItemTypesTests {
    private func makeGroup(_ conditions: [Condition], match: Match = .all) -> ConditionGroup {
        ConditionGroup(match: match, items: conditions.map { .condition($0) })
    }

    @Test func conditionsDecideItemTypes() {
        let name = Condition(attribute: .name, op: .contains, value: .text("a"))
        let folder = Condition(attribute: .kind, op: .is, value: .kind(.folder))
        let pdf = Condition(attribute: .extension, op: .is, value: .text("pdf"))
        let size = Condition(attribute: .size, op: .greaterThan, value: .size(1, .mb))
        #expect(makeGroup([]).itemTypes == .filesAndFolders)
        #expect(makeGroup([name]).itemTypes == .filesAndFolders)
        #expect(makeGroup([.filesOnly, name]).itemTypes == .files)
        #expect(makeGroup([folder]).itemTypes == .folders)
        #expect(makeGroup([pdf]).itemTypes == .files)
        #expect(makeGroup([size]).itemTypes == .files)
        #expect(makeGroup([pdf, name], match: .any).itemTypes == .filesAndFolders)
        #expect(makeGroup([pdf, size], match: .any).itemTypes == .files)
        let nested = ConditionGroup(items: [.condition(name), .group(makeGroup([pdf, size], match: .any))])
        #expect(nested.itemTypes == .files)
    }

    @Test func fileKindMatchesEverythingButFolders() {
        #expect(FileKind.file.includes(.image))
        #expect(FileKind.file.includes(.other))
        #expect(!FileKind.file.includes(.folder))
        #expect(FileKind.image.includes(.image))
        #expect(!FileKind.image.includes(.pdf))
    }

    @Test func folderHintOnlyForChangingActions() {
        var rule = Rule(scope: [FolderRef(path: "/tmp")], actions: [.trash])
        #expect(RuleValidator.showsFolderHint(rule))
        rule.actions = [.notify(message: "")]
        #expect(!RuleValidator.showsFolderHint(rule))
        rule.actions = [.trash]
        rule.conditions = ConditionGroup(items: [.condition(.filesOnly)])
        #expect(!RuleValidator.showsFolderHint(rule))
    }

    @Test func restrictingToFiles() {
        let name = Condition(attribute: .name, op: .contains, value: .text("a"))
        let tag = Condition(attribute: .tags, op: .hasNoTags)
        var rule = Rule(conditions: ConditionGroup(items: [.condition(name)]))
        #expect(rule.restrictedToFiles()?.conditions == ConditionGroup(items: [.condition(.filesOnly), .condition(name)]))

        rule.conditions = ConditionGroup(match: .any, items: [.condition(name), .condition(tag)])
        let wrapped = rule.restrictedToFiles()?.conditions
        #expect(wrapped == ConditionGroup(items: [.condition(.filesOnly), .group(rule.conditions)]))
        #expect(wrapped?.itemTypes == .files)

        rule.conditions.items.append(.group(ConditionGroup(items: [.condition(tag)])))
        #expect(rule.restrictedToFiles() == nil)
    }

    @Test func newBlankRuleSkipsFolders() {
        #expect(Rule.newBlank().conditions.itemTypes == .files)
    }
}
