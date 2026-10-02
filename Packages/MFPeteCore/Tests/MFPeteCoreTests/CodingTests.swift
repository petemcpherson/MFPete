import Foundation
import Testing
@testable import MFPeteCore

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try RulesFile.makeEncoder().encode(value)
    return try RulesFile.makeDecoder().decode(T.self, from: data)
}

private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try RulesFile.makeEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

struct CodingTests {
    static let triggers: [Trigger] = [
        .fileAdded,
        .fileModified,
        .fileRemoved,
        .interval(minutes: 30),
        .daily(hour: 9, minute: 0),
        .weekly(weekdays: [2, 4, 6], hour: 18, minute: 15),
    ]

    static let actions: [Action] = [
        .move(to: FolderRef(path: "/tmp/a"), onConflict: .keepBoth),
        .copy(to: FolderRef(path: "/tmp/b"), onConflict: .replace),
        .rename(pattern: "{name} {today}", onConflict: .skip),
        .changeExtension("md"),
        .trash,
        .sortIntoSubfolder(base: FolderRef(path: "/tmp/sorted"), pattern: "{year}/{month}"),
        .addTags(["Red", "Work"]),
        .removeTags(["Old"]),
        .unarchive(destination: nil, trashArchive: true),
        .unarchive(destination: FolderRef(path: "/tmp/out"), trashArchive: false),
        .open(withApp: nil),
        .open(withApp: URL(fileURLWithPath: "/Applications/Preview.app")),
        .revealInFinder,
        .notify(message: "Moved {fullname}"),
    ]

    static let values: [ConditionValue] = [
        .none,
        .text("invoice"),
        .size(1.5, .gb),
        .duration(3, .weeks),
        .date(fixedDate),
        .kind(.diskImage),
        .tags(["Blue", "Green"]),
    ]

    @Test(arguments: triggers)
    func triggerRoundTrip(_ trigger: Trigger) throws {
        #expect(try roundTrip(trigger) == trigger)
    }

    @Test(arguments: actions)
    func actionRoundTrip(_ action: Action) throws {
        #expect(try roundTrip(action) == action)
    }

    @Test(arguments: values)
    func conditionValueRoundTrip(_ value: ConditionValue) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test func everyAttributeAndOperatorRoundTrips() throws {
        for attribute in Attribute.allCases {
            for op in attribute.allowedOperators {
                var value = ConditionValue.empty(op.valueType(for: attribute))
                if case .date = value {
                    // ISO 8601 coding drops fractional seconds.
                    value = .date(fixedDate)
                }
                let condition = Condition(attribute: attribute, op: op, value: value)
                let item = ConditionItem.condition(condition)
                #expect(try roundTrip(item) == item)
                #expect(condition.isWellFormed)
            }
        }
    }

    @Test func triggerUsesTypeDiscriminator() throws {
        let object = try json(Trigger.weekly(weekdays: [6, 2], hour: 18, minute: 0))
        #expect(object["type"] as? String == "weekly")
        #expect(object["weekdays"] as? [Int] == [2, 6])
    }

    @Test func actionUsesTypeDiscriminator() throws {
        let object = try json(Action.move(to: FolderRef(path: "/tmp/x"), onConflict: .keepBoth))
        #expect(object["type"] as? String == "move")
        #expect(object["destination"] as? String == "/tmp/x")
        #expect(object["onConflict"] as? String == "keepBoth")
    }

    @Test func fullRuleRoundTrip() throws {
        let rule = Rule(
            name: "Everything",
            isEnabled: true,
            order: 3,
            scope: [FolderRef(path: "/tmp/in"), FolderRef(path: "/tmp/in2")],
            trigger: .daily(hour: 7, minute: 45),
            conditions: ConditionGroup(match: .any, items: [
                .condition(Condition(attribute: .extension, op: .is, value: .text("pdf"))),
                .group(ConditionGroup(match: .all, items: [
                    .condition(Condition(attribute: .tags, op: .hasNoTags)),
                    .group(ConditionGroup(match: .any, items: [
                        .condition(Condition(attribute: .dateModified, op: .before, value: .date(fixedDate))),
                    ])),
                ])),
            ]),
            actions: CodingTests.actions,
            options: RuleOptions(includeSubfolders: true, includeHidden: true, stopOtherRules: true, notifyEachRun: true),
            notes: "Notes",
            createdAt: fixedDate,
            modifiedAt: fixedDate.addingTimeInterval(60)
        )
        #expect(try roundTrip(rule) == rule)
    }
}

struct FixtureTests {
    func loadFixture() throws -> RulesFile {
        let url = try #require(Bundle.module.url(forResource: "rules-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try RulesFile.decode(try Data(contentsOf: url))
    }

    @Test func decodesFixture() throws {
        let file = try loadFixture()
        #expect(file.version == 1)
        #expect(file.rules.count == 2)

        let clean = file.rules[0]
        #expect(clean.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(clean.name == "Clean Downloads")
        #expect(clean.isEnabled)
        #expect(clean.scope == [FolderRef(path: FolderRef.homePath + "/Downloads")])
        #expect(clean.trigger == .fileAdded)
        #expect(clean.conditions == ConditionGroup(match: .all, items: [
            .condition(Condition(attribute: .extension, op: .isAnyOf, value: .text("dmg, zip"))),
            .group(ConditionGroup(match: .any, items: [
                .condition(Condition(attribute: .size, op: .greaterThan, value: .size(100, .mb))),
                .condition(Condition(attribute: .kind, op: .is, value: .kind(.diskImage))),
            ])),
        ]))
        #expect(clean.actions == [.trash])
        #expect(clean.options.stopOtherRules)
        #expect(clean.notes == "Keeps Downloads tidy.")
        #expect(clean.createdAt == ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z"))

        let screenshots = file.rules[1]
        #expect(!screenshots.isEnabled)
        #expect(screenshots.trigger == .weekly(weekdays: [2, 4, 6], hour: 18, minute: 30))
        #expect(screenshots.actions == [
            .sortIntoSubfolder(base: FolderRef(path: "/Users/Shared/Screenshots/Archive"), pattern: "{year}/{month}"),
            .addTags(["Archived"]),
            .move(to: FolderRef(path: "/Users/Shared/Old"), onConflict: .keepBoth),
        ])
        #expect(screenshots.options.includeSubfolders)
        #expect(screenshots.options.notifyEachRun)
    }

    @Test func fixtureReencodesToSameModel() throws {
        let file = try loadFixture()
        let reencoded = try RulesFile.decode(try file.encoded())
        #expect(reencoded == file)
    }
}

struct UnknownElementTests {
    let ruleJSON = """
    {
      "version": 1,
      "rules": [{
        "id": "33333333-3333-3333-3333-333333333333",
        "name": "From the future",
        "isEnabled": true,
        "order": 0,
        "scope": ["/tmp"],
        "trigger": {"type": "fileAdded"},
        "conditions": {"match": "all", "items": [
          {"type": "condition", "attribute": "imageWidth", "operator": "greaterThan",
           "value": {"type": "number", "amount": 800}}
        ]},
        "actions": [
          {"type": "trash"},
          {"type": "runShortcut", "shortcut": "Resize"}
        ],
        "createdAt": "2026-10-01T09:00:00Z"
      }]
    }
    """

    @Test func unknownActionAndAttributeLoadAsPlaceholdersAndDisableRule() throws {
        let file = try RulesFile.decode(Data(ruleJSON.utf8))
        let rule = try #require(file.rules.first)

        #expect(rule.actions.first == .trash)
        guard case .unknown(let raw) = rule.actions[1] else {
            Issue.record("Expected unknown action")
            return
        }
        #expect(raw.typeName == "runShortcut")

        guard case .unknown = rule.conditions.items.first else {
            Issue.record("Expected unknown condition")
            return
        }
        #expect(rule.containsUnknownElements)
        #expect(!rule.isEnabled)
    }

    @Test func unknownElementsSurviveReencoding() throws {
        let rule = try #require(try RulesFile.decode(Data(ruleJSON.utf8)).rules.first)
        let data = try RulesFile(rules: [rule]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("runShortcut"))
        #expect(text.contains("imageWidth"))

        let again = try #require(try RulesFile.decode(data).rules.first)
        #expect(again == rule)
    }

    @Test func unknownTriggerFailsDecoding() {
        let json = ruleJSON.replacingOccurrences(of: "\"fileAdded\"", with: "\"onBluetooth\"")
        #expect(throws: (any Error).self) { try RulesFile.decode(Data(json.utf8)) }
    }
}
