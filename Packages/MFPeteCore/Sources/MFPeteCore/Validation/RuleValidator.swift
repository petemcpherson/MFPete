import Foundation

/// A problem the editor shows before saving (spec §8.3). Errors block Save;
/// warnings do not.
public struct RuleIssue: Hashable, Sendable {
    public enum Severity: Hashable, Sendable {
        case error
        case warning
    }

    public enum Code: Hashable, Sendable {
        case noFolders
        case emptyFolder
        case intervalTooShort
        case noWeekdays
        case invalidTime
        case invalidDayCount
        case conditionValueMissing
        case conditionInvalid
        case unknownCondition
        case noActions
        case actionParameterMissing
        case unknownAction
        /// Only "Show notification" works on "File removed" rules (spec §3.1).
        case actionNeedsFile
        /// Move to a scope folder: an error, or a warning after a rename.
        case moveToSourceFolder
        /// A `{token}` this version does not know. It renders literally.
        case unknownToken
        /// Trash or Replace with no conditions: every file is affected.
        /// Also Empty Trash, which deletes everything in the Trash.
        case destructiveWithoutConditions
        /// Empty Trash needs a schedule trigger.
        case emptyTrashNeedsSchedule
        /// Empty Trash must be the rule's only action.
        case emptyTrashWithOtherActions
    }

    public var severity: Severity
    public var code: Code
    public var message: String
    /// The action the issue is about, if any.
    public var actionIndex: Int?

    public init(_ severity: Severity, _ code: Code, _ message: String, actionIndex: Int? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.actionIndex = actionIndex
    }
}

/// Checks a rule before it is saved (spec §8.3).
public struct RuleValidator: Sendable {
    public init() {}

    public func validate(_ rule: Rule) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        if rule.emptiesTrash {
            // No folders or conditions: the rule acts on the whole Trash.
            issues += emptyTrashIssues(rule)
        } else {
            issues += scopeIssues(rule)
            issues += conditionIssues(rule.conditions)
        }
        issues += triggerIssues(rule.trigger)
        issues += actionIssues(rule)
        if let warning = destructiveWarning(for: rule) {
            issues.append(RuleIssue(.warning, .destructiveWithoutConditions, warning))
        }
        return issues
    }

    public func hasErrors(_ rule: Rule) -> Bool {
        validate(rule).contains { $0.severity == .error }
    }

    /// "This rule will trash every file added to Downloads." Shown when the
    /// actions include Move to Trash or a Replace policy and there are no
    /// conditions.
    public func destructiveWarning(for rule: Rule) -> String? {
        if rule.emptiesTrash {
            return localized("This rule permanently deletes everything in the Trash.")
        }
        guard rule.conditions.items.isEmpty else { return nil }
        let folders = RuleValidator.folderList(rule.scope)
        let trashes = rule.actions.contains { $0 == .trash }
        let replaces = rule.actions.contains { action in
            switch action {
            case .move(_, .replace), .copy(_, .replace), .rename(_, .replace): return true
            default: return false
            }
        }
        if trashes {
            return rule.trigger.isFileEvent
                ? localized("This rule will trash every file added to \(folders).")
                : localized("This rule will trash every file in \(folders).")
        }
        if replaces {
            return localized("This rule acts on every file in \(folders) and can replace existing files.")
        }
        return nil
    }

    /// The editor shows "Matches all files in this folder" for empty conditions.
    public static func matchesEverything(_ rule: Rule) -> Bool {
        rule.conditions.items.isEmpty
    }

    /// The rule can match folders and an action would move, rename, or
    /// delete them. Users rarely mean that.
    public static func showsFolderHint(_ rule: Rule) -> Bool {
        rule.conditions.itemTypes == .filesAndFolders && rule.actions.contains(where: \.changesItem)
    }

    /// Age conditions on a file-event rule rarely do what the user wants
    /// (spec §4.2 notes).
    public static func showsAgeHint(_ rule: Rule) -> Bool {
        rule.trigger.isFileEvent && rule.conditions.allConditions.contains(where: \.isAgeCondition)
    }

    // MARK: - Parts

    private func scopeIssues(_ rule: Rule) -> [RuleIssue] {
        if rule.scope.isEmpty {
            return [RuleIssue(.error, .noFolders, localized("Add at least one folder to watch."))]
        }
        if rule.scope.contains(where: { $0.path.isEmpty }) {
            return [RuleIssue(.error, .emptyFolder, localized("Choose a folder for every folder entry."))]
        }
        return []
    }

    private func emptyTrashIssues(_ rule: Rule) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        if !rule.trigger.isSchedule {
            issues.append(RuleIssue(.error, .emptyTrashNeedsSchedule, localized("“Empty Trash” runs on a schedule. Choose how often to run it.")))
        }
        if rule.actions.count > 1 {
            issues.append(RuleIssue(.error, .emptyTrashWithOtherActions, localized("“Empty Trash” cannot be combined with other actions.")))
        }
        return issues
    }

    private func triggerIssues(_ trigger: Trigger) -> [RuleIssue] {
        switch trigger {
        case .interval(let minutes) where minutes < Trigger.minimumIntervalMinutes:
            return [RuleIssue(.error, .intervalTooShort, localized("Run at most every \(Trigger.minimumIntervalMinutes) minutes."))]
        case .weekly(let weekdays, let hour, let minute):
            var issues: [RuleIssue] = []
            if weekdays.isEmpty {
                issues.append(RuleIssue(.error, .noWeekdays, localized("Pick at least one day of the week.")))
            }
            if !Self.isValidTime(hour, minute) {
                issues.append(RuleIssue(.error, .invalidTime, localized("Pick a valid time of day.")))
            }
            return issues
        case .daily(let hour, let minute, let days):
            var issues: [RuleIssue] = []
            if days < 1 {
                issues.append(RuleIssue(.error, .invalidDayCount, localized("Run at least every 1 day.")))
            }
            if !Self.isValidTime(hour, minute) {
                issues.append(RuleIssue(.error, .invalidTime, localized("Pick a valid time of day.")))
            }
            return issues
        default:
            return []
        }
    }

    private static func isValidTime(_ hour: Int, _ minute: Int) -> Bool {
        (0..<24).contains(hour) && (0..<60).contains(minute)
    }

    private func conditionIssues(_ group: ConditionGroup) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        for item in group.items {
            switch item {
            case .condition(let condition):
                if let issue = conditionIssue(condition) { issues.append(issue) }
            case .group(let nested):
                issues += conditionIssues(nested)
            case .unknown:
                issues.append(RuleIssue(.error, .unknownCondition, localized("Remove the condition this version of MFPete does not support.")))
            }
        }
        return issues
    }

    private func conditionIssue(_ condition: Condition) -> RuleIssue? {
        guard condition.isWellFormed else {
            return RuleIssue(.error, .conditionInvalid, localized("A “\(condition.attribute.displayName)” condition has an invalid operator or value."))
        }
        let missing = RuleIssue(.error, .conditionValueMissing, localized("Enter a value for the “\(condition.attribute.displayName)” condition."))
        switch condition.value {
        case .text(let text):
            let empty = condition.op == .isAnyOf ? splitCommaList(text).isEmpty : text.trimmingCharacters(in: .whitespaces).isEmpty
            return empty ? missing : nil
        case .tags(let tags):
            return tags.isEmpty ? missing : nil
        case .size(let amount, _):
            return amount > 0 ? nil : missing
        case .duration(let amount, _):
            return amount > 0 ? nil : missing
        case .none, .date, .kind:
            return nil
        }
    }

    private func actionIssues(_ rule: Rule) -> [RuleIssue] {
        guard !rule.actions.isEmpty else {
            return [RuleIssue(.error, .noActions, localized("Add at least one action."))]
        }
        var issues: [RuleIssue] = []
        var renamed = false
        let scopePaths = Set(rule.scope.map { Self.normalized($0.path) })

        for (index, action) in rule.actions.enumerated() {
            let name = action.type?.displayName ?? action.displayName
            func error(_ code: RuleIssue.Code, _ message: String) {
                issues.append(RuleIssue(.error, code, message, actionIndex: index))
            }
            func missing(_ message: String) {
                error(.actionParameterMissing, message)
            }

            guard let type = action.type else {
                error(.unknownAction, localized("Remove the action this version of MFPete does not support."))
                continue
            }
            if rule.trigger == .fileRemoved, !type.worksWithoutFile, !rule.emptiesTrash {
                error(.actionNeedsFile, localized("“\(name)” cannot run when a file is removed. Use Show notification."))
            }

            switch action {
            case .move(let folder, _):
                if folder.path.isEmpty {
                    missing(localized("Choose a destination folder for “\(name)”."))
                } else if scopePaths.contains(Self.normalized(folder.path)) {
                    if renamed {
                        issues.append(RuleIssue(.warning, .moveToSourceFolder, localized("The file is moved into the folder it is already in."), actionIndex: index))
                    } else {
                        error(.moveToSourceFolder, localized("Move destination is the folder being watched. Choose another folder."))
                    }
                }
            case .copy(let folder, _):
                if folder.path.isEmpty { missing(localized("Choose a destination folder for “\(name)”.")) }
            case .rename(let pattern, _):
                renamed = true
                if pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                    missing(localized("Enter a name pattern for “\(name)”."))
                }
                issues += tokenIssues(pattern, index: index)
            case .changeExtension(let ext):
                renamed = true
                if ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty {
                    missing(localized("Enter the new extension."))
                }
            case .sortIntoSubfolder(let base, let pattern):
                if base.path.isEmpty { missing(localized("Choose a base folder for “\(name)”.")) }
                if pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty {
                    missing(localized("Enter a subfolder pattern for “\(name)”."))
                }
                issues += tokenIssues(pattern, index: index)
            case .addTags(let tags), .removeTags(let tags):
                if tags.isEmpty { missing(localized("Enter at least one tag for “\(name)”.")) }
            case .notify(let message):
                if message.trimmingCharacters(in: .whitespaces).isEmpty {
                    missing(localized("Enter a notification message."))
                }
                issues += tokenIssues(message, index: index)
            case .unarchive(let destination, _):
                if destination?.path.isEmpty == true { missing(localized("Choose a folder to unarchive into.")) }
            case .trash, .open, .revealInFinder, .emptyTrash, .unknown:
                break
            }
        }
        return issues
    }

    private func tokenIssues(_ pattern: String, index: Int) -> [RuleIssue] {
        PatternRenderer.unknownTokens(in: pattern).map { token in
            RuleIssue(.warning, .unknownToken, localized("Unknown token {\(token)} will appear as typed."), actionIndex: index)
        }
    }

    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func folderList(_ scope: [FolderRef]) -> String {
        let names = scope.map(\.displayName).filter { !$0.isEmpty }
        if names.isEmpty { return localized("this folder") }
        return ListFormatter.localizedString(byJoining: names)
    }
}
