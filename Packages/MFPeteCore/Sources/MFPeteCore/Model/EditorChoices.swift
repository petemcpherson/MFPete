import Foundation

// Choices and labels for the rule editor's popup menus (spec §8.3). They live
// here, next to the model, so the editor and the validator agree on them.

/// The trigger popup. Picking a type builds a trigger with default values.
public enum TriggerType: String, Hashable, Sendable, CaseIterable, Identifiable {
    case fileAdded
    case interval
    case daily
    case weekly
    case fileModified
    case fileRemoved

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fileAdded: return localized("A file is added")
        case .interval: return localized("Every few minutes or hours")
        case .daily: return localized("Every day or every few days")
        case .weekly: return localized("Every week")
        case .fileModified: return localized("A file is modified")
        case .fileRemoved: return localized("A file is removed")
        }
    }

    /// A trigger of this type. Keeps the time of day when switching between
    /// daily and weekly.
    public func makeTrigger(from current: Trigger) -> Trigger {
        var time = (hour: 9, minute: 0)
        switch current {
        case .daily(let hour, let minute, _), .weekly(_, let hour, let minute):
            time = (hour, minute)
        default:
            break
        }
        switch self {
        case .fileAdded: return .fileAdded
        case .fileModified: return .fileModified
        case .fileRemoved: return .fileRemoved
        case .interval:
            if case .interval = current { return current }
            return .interval(minutes: 60)
        case .daily:
            if case .daily = current { return current }
            return .daily(hour: time.hour, minute: time.minute)
        case .weekly:
            if case .weekly = current { return current }
            // Monday (Calendar numbering: 1 = Sunday).
            return .weekly(weekdays: [2], hour: time.hour, minute: time.minute)
        }
    }
}

extension Trigger {
    public var type: TriggerType {
        switch self {
        case .fileAdded: return .fileAdded
        case .fileModified: return .fileModified
        case .fileRemoved: return .fileRemoved
        case .interval: return .interval
        case .daily: return .daily
        case .weekly: return .weekly
        }
    }
}

/// The action popup.
public enum ActionType: String, Hashable, Sendable, CaseIterable, Identifiable {
    case move
    case copy
    case rename
    case changeExtension
    case trash
    case sortIntoSubfolder
    case addTags
    case removeTags
    case unarchive
    case open
    case revealInFinder
    case notify
    case emptyTrash

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .move: return localized("Move to folder")
        case .copy: return localized("Copy to folder")
        case .rename: return localized("Rename")
        case .changeExtension: return localized("Change extension")
        case .trash: return localized("Move to Trash")
        case .sortIntoSubfolder: return localized("Sort into subfolder")
        case .addTags: return localized("Add tags")
        case .removeTags: return localized("Remove tags")
        case .unarchive: return localized("Unarchive")
        case .open: return localized("Open")
        case .revealInFinder: return localized("Reveal in Finder")
        case .notify: return localized("Show notification")
        case .emptyTrash: return localized("Empty Trash")
        }
    }

    /// Actions allowed on "File removed" rules: the file is gone, so only a
    /// notification makes sense (spec §3.1).
    public var worksWithoutFile: Bool {
        self == .notify
    }

    /// A new action of this type with default parameters. Folder parameters
    /// start empty, so validation asks the user to pick one.
    public func makeAction() -> Action {
        switch self {
        case .move: return .move(to: FolderRef(path: ""), onConflict: .keepBoth)
        case .copy: return .copy(to: FolderRef(path: ""), onConflict: .keepBoth)
        case .rename: return .rename(pattern: "{name}.{extension}", onConflict: .keepBoth)
        case .changeExtension: return .changeExtension("")
        case .trash: return .trash
        case .sortIntoSubfolder: return .sortIntoSubfolder(base: FolderRef(path: ""), pattern: "{extension}")
        case .addTags: return .addTags([])
        case .removeTags: return .removeTags([])
        case .unarchive: return .unarchive(destination: nil, trashArchive: false)
        case .open: return .open(withApp: nil)
        case .revealInFinder: return .revealInFinder
        case .notify: return .notify(message: "{fullname}")
        case .emptyTrash: return .emptyTrash
        }
    }
}

extension Action {
    /// Nil for unknown actions from a newer app version.
    public var type: ActionType? {
        switch self {
        case .move: return .move
        case .copy: return .copy
        case .rename: return .rename
        case .changeExtension: return .changeExtension
        case .trash: return .trash
        case .sortIntoSubfolder: return .sortIntoSubfolder
        case .addTags: return .addTags
        case .removeTags: return .removeTags
        case .unarchive: return .unarchive
        case .open: return .open
        case .revealInFinder: return .revealInFinder
        case .notify: return .notify
        case .emptyTrash: return .emptyTrash
        case .unknown: return nil
        }
    }
}

extension ConflictPolicy {
    public var displayName: String {
        switch self {
        case .keepBoth: return localized("Keep both")
        case .replace: return localized("Replace (old one to Trash)")
        case .skip: return localized("Skip")
        }
    }
}

extension Attribute {
    public var displayName: String {
        switch self {
        case .name: return localized("Name (no extension)")
        case .fullName: return localized("Name with extension")
        case .extension: return localized("Extension")
        case .kind: return localized("Kind")
        case .size: return localized("Size")
        case .dateAdded: return localized("Date added")
        case .dateCreated: return localized("Date created")
        case .dateModified: return localized("Date modified")
        case .tags: return localized("Tags")
        case .downloadedFrom: return localized("Downloaded from")
        case .anyFile: return localized("Any file")
        }
    }

    /// A new condition on this attribute with its default operator.
    public func makeCondition() -> Condition {
        let op = allowedOperators[0]
        return Condition(attribute: self, op: op, value: .empty(op.valueType(for: self)))
    }
}

extension Operator {
    public var displayName: String {
        switch self {
        case .is: return localized("is")
        case .isNot: return localized("is not")
        case .contains: return localized("contains")
        case .doesNotContain: return localized("does not contain")
        case .startsWith: return localized("starts with")
        case .endsWith: return localized("ends with")
        case .matchesPattern: return localized("matches pattern")
        case .isAnyOf: return localized("is any of")
        case .greaterThan: return localized("is greater than")
        case .lessThan: return localized("is less than")
        case .inTheLast: return localized("is in the last")
        case .notInTheLast: return localized("is not in the last")
        case .before: return localized("is before")
        case .after: return localized("is after")
        case .containsTag: return localized("contains tag")
        case .doesNotContainTag: return localized("does not contain tag")
        case .hasNoTags: return localized("has no tags")
        case .always: return localized("matches")
        }
    }
}

extension Condition {
    /// The same condition on another attribute. Keeps the operator and value
    /// when they still fit, otherwise uses the attribute's defaults.
    public func changingAttribute(to attribute: Attribute) -> Condition {
        guard attribute.allows(op) else { return attribute.makeCondition() }
        var copy = self
        copy.attribute = attribute
        if !attribute.supportsMatchCase { copy.caseSensitive = false }
        let type = op.valueType(for: attribute)
        if value.valueType != type { copy.value = .empty(type) }
        return copy
    }

    /// The same condition with another operator. Keeps the value when its
    /// type still fits.
    public func changingOperator(to op: Operator) -> Condition {
        var copy = self
        copy.op = op
        let type = op.valueType(for: attribute)
        if value.valueType != type { copy.value = .empty(type) }
        return copy
    }

    /// Age conditions ("is not in the last 3 days") only make sense on
    /// schedules (spec §4.2).
    public var isAgeCondition: Bool {
        attribute.isDate && (op == .inTheLast || op == .notInTheLast)
    }
}

extension ConditionGroup {
    /// Every condition at any depth.
    public var allConditions: [Condition] {
        items.flatMap { item -> [Condition] in
            switch item {
            case .condition(let condition): return [condition]
            case .group(let group): return group.allConditions
            case .unknown: return []
            }
        }
    }
}

extension SizeUnit {
    public var displayName: String {
        switch self {
        case .kb: return localized("KB")
        case .mb: return localized("MB")
        case .gb: return localized("GB")
        }
    }
}

extension DurationUnit {
    public var displayName: String {
        switch self {
        case .minutes: return localized("minutes")
        case .hours: return localized("hours")
        case .days: return localized("days")
        case .weeks: return localized("weeks")
        case .months: return localized("months")
        }
    }
}

/// Splits a comma list ("work, urgent") into trimmed, non-empty items.
public func splitCommaList(_ text: String) -> [String] {
    text.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
