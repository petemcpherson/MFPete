import Foundation

/// Which items a rule's conditions can match. Scope folders list files and
/// folders alike; only conditions tell them apart.
public enum ItemTypes: Hashable, Sendable {
    case files
    case folders
    case filesAndFolders
}

extension FileKind {
    /// True if an item classified as `actual` counts as this kind. `.file`
    /// covers every kind except `.folder`.
    public func includes(_ actual: FileKind) -> Bool {
        self == .file ? actual != .folder : self == actual
    }
}

extension Condition {
    /// "Kind is File": the condition that keeps folders out of a rule.
    public static let filesOnly = Condition(attribute: .kind, op: .is, value: .kind(.file))

    /// True if no folder can satisfy this condition. Folders have no size,
    /// and in practice no extension.
    var excludesFolders: Bool {
        switch (attribute, op, value) {
        case (.kind, .is, .kind(let kind)): return kind != .folder
        case (.kind, .isNot, .kind(let kind)): return kind == .folder
        case (.size, _, _): return true
        case (.extension, .is, .text(let text)): return !ConditionEvaluator.normalizeExtension(text).isEmpty
        case (.extension, .isAnyOf, .text(let text)): return !ConditionEvaluator.extensionList(text).isEmpty
        default: return false
        }
    }

    /// True if no file can satisfy this condition.
    var excludesFiles: Bool {
        switch (attribute, op, value) {
        case (.kind, .is, .kind(.folder)), (.kind, .isNot, .kind(.file)): return true
        default: return false
        }
    }

    /// Kind is (not) File or Folder: a condition that only picks the item type.
    var isItemTypeCondition: Bool {
        guard attribute == .kind, case .kind(let kind) = value else { return false }
        return kind == .file || kind == .folder
    }
}

extension ConditionGroup {
    public var itemTypes: ItemTypes {
        switch (excludes(where: \.excludesFolders), excludes(where: \.excludesFiles)) {
        case (false, true): return .folders
        case (true, _): return .files
        case (false, false): return .filesAndFolders
        }
    }

    /// True if every item this group can match fails `test`'s item type.
    /// An All group needs one excluding member; an Any group needs all.
    private func excludes(where test: (Condition) -> Bool) -> Bool {
        let results = items.map { item -> Bool in
            switch item {
            case .condition(let condition): return test(condition)
            case .group(let group): return group.excludes(where: test)
            case .unknown: return false
            }
        }
        guard !results.isEmpty else { return false }
        return match == .all ? results.contains(true) : results.allSatisfy { $0 }
    }
}

extension Action {
    /// Moves, renames, or deletes the item: worth a warning when folders match.
    var changesItem: Bool {
        switch self {
        case .move, .copy, .rename, .changeExtension, .trash, .sortIntoSubfolder: return true
        default: return false
        }
    }
}

extension Rule {
    /// Starting point for "New Rule": files only, so folders are opt-in.
    public static func newBlank() -> Rule {
        Rule(conditions: ConditionGroup(items: [.condition(.filesOnly)]))
    }

    /// The rule with "Kind is File" added so it skips folders. Nil when that
    /// would nest groups deeper than the editor allows (D12).
    public func restrictedToFiles() -> Rule? {
        var copy = self
        if conditions.match == .all || conditions.items.count <= 1 {
            copy.conditions.match = .all
            copy.conditions.items.insert(.condition(.filesOnly), at: 0)
        } else {
            let hasGroups = conditions.items.contains { if case .group = $0 { return true }; return false }
            guard !hasGroups else { return nil }
            copy.conditions = ConditionGroup(match: .all, items: [.condition(.filesOnly), .group(conditions)])
        }
        return copy
    }
}
