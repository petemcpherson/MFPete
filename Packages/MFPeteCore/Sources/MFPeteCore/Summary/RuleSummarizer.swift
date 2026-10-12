import Foundation

/// Plain-language text for a rule (D11): the editor's live sentence and the
/// two-line dashboard summary.
///
/// "When a file is added to Downloads, if its extension is dmg or zip, then
/// move it to the Trash."
public struct RuleSummarizer: Sendable {
    public var locale: Locale
    public var calendar: Calendar

    public init(locale: Locale = .current, calendar: Calendar = .current) {
        self.locale = locale
        self.calendar = calendar
    }

    /// Two lines for a dashboard row.
    public struct ShortSummary: Hashable, Sendable {
        /// Trigger and conditions: "When a file is added to Downloads, if its extension is dmg".
        public var trigger: String
        /// Actions: "Move it to the Trash".
        public var actions: String
    }

    public func sentence(for rule: Rule) -> String {
        var parts = [triggerPhrase(rule)]
        if let conditions = conditionsPhrase(summaryConditions(rule)) {
            parts.append(localized("if \(conditions)"))
        }
        parts.append(localized("then \(actionsPhrase(rule.actions))"))
        return parts.joined(separator: ", ") + "."
    }

    public func shortSummary(for rule: Rule) -> ShortSummary {
        var first = triggerPhrase(rule)
        if let conditions = conditionsPhrase(summaryConditions(rule)) {
            first += ", " + localized("if \(conditions)")
        }
        return ShortSummary(trigger: first, actions: capitalizedFirst(actionsPhrase(rule.actions)))
    }

    // MARK: - Trigger

    func triggerPhrase(_ rule: Rule) -> String {
        let folders = foldersPhrase(rule.scope)
        let types = rule.conditions.itemTypes
        switch rule.trigger {
        case .fileAdded:
            switch types {
            case .files: return localized("When a file is added to \(folders)")
            case .folders: return localized("When a folder is added to \(folders)")
            case .filesAndFolders: return localized("When a file or folder is added to \(folders)")
            }
        case .fileModified:
            switch types {
            case .files: return localized("When a file is modified in \(folders)")
            case .folders: return localized("When a folder is modified in \(folders)")
            case .filesAndFolders: return localized("When a file or folder is modified in \(folders)")
            }
        case .fileRemoved:
            switch types {
            case .files: return localized("When a file is removed from \(folders)")
            case .folders: return localized("When a folder is removed from \(folders)")
            case .filesAndFolders: return localized("When a file or folder is removed from \(folders)")
            }
        case .interval(let minutes):
            let every = minutes % 60 == 0
                ? (minutes == 60 ? localized("Every hour") : localized("Every \(minutes / 60) hours"))
                : localized("Every \(minutes) minutes")
            return localized("\(every), \(itemsIn(folders, types))")
        case .daily(let hour, let minute, let days) where days > 1:
            return localized("Every \(days) days at \(time(hour, minute)), \(itemsIn(folders, types))")
        case .daily(let hour, let minute, _):
            return localized("Every day at \(time(hour, minute)), \(itemsIn(folders, types))")
        case .weekly(let weekdays, let hour, let minute):
            return localized("Every \(weekdaysPhrase(weekdays)) at \(time(hour, minute)), \(itemsIn(folders, types))")
        }
    }

    private func itemsIn(_ folders: String, _ types: ItemTypes) -> String {
        switch types {
        case .files: return localized("for files in \(folders)")
        case .folders: return localized("for folders in \(folders)")
        case .filesAndFolders: return localized("for files and folders in \(folders)")
        }
    }

    /// Top-level conditions minus "Kind is File/Folder" ones the trigger
    /// phrase already says ("for files in…").
    private func summaryConditions(_ rule: Rule) -> ConditionGroup {
        var group = rule.conditions
        guard group.match == .all || group.items.count == 1 else { return group }
        let types = group.itemTypes
        group.items.removeAll { item in
            guard case .condition(let condition) = item, condition.isItemTypeCondition else { return false }
            return (types == .files && condition.excludesFolders) || (types == .folders && condition.excludesFiles)
        }
        return group
    }

    private func foldersPhrase(_ scope: [FolderRef]) -> String {
        guard !scope.isEmpty else { return localized("a folder") }
        return join(scope.map(\.displayName), conjunction: localized("and"))
    }

    private func time(_ hour: Int, _ minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func weekdaysPhrase(_ weekdays: Set<Int>) -> String {
        var localeCalendar = calendar
        localeCalendar.locale = locale
        let symbols = localeCalendar.shortWeekdaySymbols
        // Order from the locale's first weekday (Monday in most of Europe).
        let ordered = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let names = ordered.filter(weekdays.contains).map { symbols[$0 - 1] }
        if names.count == 7 { return localized("day") }
        return join(names, conjunction: localized("and"))
    }

    // MARK: - Conditions

    /// Nil when the group is empty (the rule matches every file).
    func conditionsPhrase(_ group: ConditionGroup) -> String? {
        let phrases = group.items.map(itemPhrase)
        guard !phrases.isEmpty else { return nil }
        let conjunction = group.match == .all ? localized("and") : localized("or")
        return phrases.joined(separator: " \(conjunction) ")
    }

    private func itemPhrase(_ item: ConditionItem) -> String {
        switch item {
        case .condition(let condition):
            return conditionPhrase(condition)
        case .group(let group):
            guard let phrase = conditionsPhrase(group) else { return localized("it is any file") }
            return group.items.count > 1 ? "(\(phrase))" : phrase
        case .unknown:
            return localized("an unsupported condition")
        }
    }

    func conditionPhrase(_ condition: Condition) -> String {
        let phrase = basePhrase(condition)
        guard condition.caseSensitive, condition.attribute.supportsMatchCase else { return phrase }
        return localized("\(phrase) (match case)")
    }

    private func basePhrase(_ condition: Condition) -> String {
        let value = valuePhrase(condition)
        switch condition.attribute {
        case .name: return localized("its name without extension \(textOperator(condition.op)) \(value)")
        case .fullName: return localized("its name with extension \(textOperator(condition.op)) \(value)")
        case .extension:
            switch condition.op {
            case .isNot: return localized("its extension is not \(value)")
            default: return localized("its extension is \(value)")
            }
        case .kind:
            return condition.op == .isNot
                ? localized("its kind is not \(value)")
                : localized("its kind is \(value)")
        case .size:
            return condition.op == .lessThan
                ? localized("its size is less than \(value)")
                : localized("its size is greater than \(value)")
        case .dateAdded: return localized("its date added \(dateOperator(condition.op, value))")
        case .dateCreated: return localized("its date created \(dateOperator(condition.op, value))")
        case .dateModified: return localized("its date modified \(dateOperator(condition.op, value))")
        case .tags:
            switch condition.op {
            case .hasNoTags: return localized("it has no tags")
            case .doesNotContainTag: return localized("its tags do not include \(value)")
            default: return localized("its tags include \(value)")
            }
        case .downloadedFrom:
            return localized("its download source \(textOperator(condition.op)) \(value)")
        case .anyFile:
            return localized("it is any file")
        }
    }

    private func textOperator(_ op: Operator) -> String {
        switch op {
        case .is: return localized("is")
        case .isNot: return localized("is not")
        case .contains: return localized("contains")
        case .doesNotContain: return localized("does not contain")
        case .startsWith: return localized("starts with")
        case .endsWith: return localized("ends with")
        case .matchesPattern: return localized("matches")
        default: return op.rawValue
        }
    }

    private func dateOperator(_ op: Operator, _ value: String) -> String {
        switch op {
        case .inTheLast: return localized("is in the last \(value)")
        case .notInTheLast: return localized("is not in the last \(value)")
        case .before: return localized("is before \(value)")
        case .after: return localized("is after \(value)")
        default: return value
        }
    }

    private func valuePhrase(_ condition: Condition) -> String {
        switch condition.value {
        case .none:
            return ""
        case .text(let text):
            if condition.attribute == .extension {
                let list = condition.op == .isAnyOf
                    ? ConditionEvaluator.extensionList(text)
                    : [ConditionEvaluator.normalizeExtension(text)]
                return join(list, conjunction: localized("or"))
            }
            return "“\(text)”"
        case .size(let amount, let unit):
            let number = amount.rounded() == amount ? String(Int(amount)) : String(amount)
            return "\(number) \(unit.rawValue.uppercased())"
        case .duration(let amount, let unit):
            return durationPhrase(amount, unit)
        case .date(let date):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        case .kind(let kind):
            return kind.displayName
        case .tags(let tags):
            return join(tags, conjunction: localized("or"))
        }
    }

    private func durationPhrase(_ amount: Int, _ unit: DurationUnit) -> String {
        switch unit {
        case .minutes: return amount == 1 ? localized("minute") : localized("\(amount) minutes")
        case .hours: return amount == 1 ? localized("hour") : localized("\(amount) hours")
        case .days: return amount == 1 ? localized("day") : localized("\(amount) days")
        case .weeks: return amount == 1 ? localized("week") : localized("\(amount) weeks")
        case .months: return amount == 1 ? localized("month") : localized("\(amount) months")
        }
    }

    // MARK: - Actions

    func actionsPhrase(_ actions: [Action]) -> String {
        guard !actions.isEmpty else { return localized("do nothing") }
        return join(actions.map(actionPhrase), conjunction: localized("and"))
    }

    func actionPhrase(_ action: Action) -> String {
        switch action {
        case .move(let folder, _): return localized("move it to \(folder.displayName)")
        case .copy(let folder, _): return localized("copy it to \(folder.displayName)")
        case .rename(let pattern, _): return localized("rename it to “\(pattern)”")
        case .changeExtension(let ext):
            return localized("change its extension to \(ConditionEvaluator.normalizeExtension(ext))")
        case .trash: return localized("move it to the Trash")
        case .sortIntoSubfolder(let base, let pattern):
            return localized("sort it into \(base.displayName)/\(pattern)")
        case .addTags(let tags): return localized("tag it \(join(tags, conjunction: localized("and")))")
        case .removeTags(let tags): return localized("remove tags \(join(tags, conjunction: localized("and")))")
        case .unarchive(let destination, let trashArchive):
            let base = destination.map { localized("unarchive it into \($0.displayName)") } ?? localized("unarchive it")
            return trashArchive ? localized("\(base) and move the archive to the Trash") : base
        case .open(let app):
            guard let app else { return localized("open it") }
            return localized("open it with \(app.deletingPathExtension().lastPathComponent)")
        case .revealInFinder: return localized("reveal it in Finder")
        case .notify: return localized("show a notification")
        case .unknown: return localized("run an unsupported action")
        }
    }

    // MARK: - Helpers

    /// "a", "a and b", "a, b, and c".
    private func join(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items[items.count - 1]
        }
    }

    private func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
