import Foundation

/// Tests a file snapshot against a rule's conditions (spec §4).
///
/// Semantics worth knowing:
/// - An empty group matches every file. `.all` = AND, `.any` = OR. Groups nest
///   to any depth.
/// - Text comparisons ignore case unless the condition sets `caseSensitive`.
/// - Size units are decimal (1 KB = 1000 bytes) to match Finder. Folders and
///   packages have no size in v1, so size conditions never match them.
/// - "Before date" means earlier than the start of that calendar day. "After
///   date" means on or after the start of the next day.
/// - Tags: "contains tag" matches if the file has any of the listed tags;
///   "does not contain tag" matches if it has none of them.
/// - A missing attribute (no date added, unknown condition) never matches.
public struct ConditionEvaluator: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func matches(_ group: ConditionGroup, snapshot: FileSnapshot, now: Date) -> Bool {
        guard !group.items.isEmpty else { return true }
        let test = { (item: ConditionItem) -> Bool in
            switch item {
            case .condition(let condition): return matches(condition, snapshot: snapshot, now: now)
            case .group(let nested): return matches(nested, snapshot: snapshot, now: now)
            case .unknown: return false
            }
        }
        switch group.match {
        case .all: return group.items.allSatisfy(test)
        case .any: return group.items.contains(where: test)
        }
    }

    public func matches(_ condition: Condition, snapshot: FileSnapshot, now: Date) -> Bool {
        guard condition.isWellFormed else { return false }
        let options: String.CompareOptions = condition.caseSensitive ? [] : [.caseInsensitive]

        switch (condition.attribute, condition.value) {
        case (.name, .text(let text)):
            return compareText(snapshot.name, condition.op, text, options)
        case (.fullName, .text(let text)):
            return compareText(snapshot.fullName, condition.op, text, options)
        case (.extension, .text(let text)):
            return compareExtension(snapshot.fileExtension, condition.op, text)
        case (.kind, .kind(let kind)):
            return condition.op == .is ? kind.includes(snapshot.kind) : !kind.includes(snapshot.kind)
        case (.size, .size(let amount, let unit)):
            guard let size = snapshot.fileSize else { return false }
            let limit = amount * unit.bytes
            return condition.op == .greaterThan ? Double(size) > limit : Double(size) < limit
        case (.dateAdded, _), (.dateCreated, _), (.dateModified, _):
            return compareDate(date(of: condition.attribute, in: snapshot), condition.op, condition.value, now: now)
        case (.tags, _):
            return compareTags(snapshot.tags, condition.op, condition.value)
        case (.downloadedFrom, .text(let text)):
            return compareSources(snapshot.downloadedFrom, condition.op, text, options)
        case (.anyFile, _):
            return true
        default:
            return false
        }
    }

    // MARK: - Text

    private func compareText(_ subject: String, _ op: Operator, _ value: String, _ options: String.CompareOptions) -> Bool {
        switch op {
        case .is: return subject.compare(value, options: options) == .orderedSame
        case .isNot: return subject.compare(value, options: options) != .orderedSame
        case .contains: return !value.isEmpty && subject.range(of: value, options: options) != nil
        case .doesNotContain: return value.isEmpty || subject.range(of: value, options: options) == nil
        case .startsWith: return subject.range(of: value, options: options.union(.anchored)) != nil
        case .endsWith: return subject.range(of: value, options: options.union([.anchored, .backwards])) != nil
        case .matchesPattern:
            return WildcardPattern.matches(subject, pattern: value, caseSensitive: !options.contains(.caseInsensitive))
        default: return false
        }
    }

    // MARK: - Extension

    /// Normalizes a user-entered extension: trimmed, leading dot removed, lowercased.
    static func normalizeExtension(_ text: String) -> String {
        var ext = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while ext.hasPrefix(".") { ext.removeFirst() }
        return ext.lowercased()
    }

    /// Splits "dmg, .zip ,PKG" into ["dmg", "zip", "pkg"].
    static func extensionList(_ text: String) -> [String] {
        text.split(separator: ",").map { normalizeExtension(String($0)) }.filter { !$0.isEmpty }
    }

    private func compareExtension(_ subject: String, _ op: Operator, _ value: String) -> Bool {
        let ext = subject.lowercased()
        switch op {
        case .is: return ext == ConditionEvaluator.normalizeExtension(value)
        case .isNot: return ext != ConditionEvaluator.normalizeExtension(value)
        case .isAnyOf: return ConditionEvaluator.extensionList(value).contains(ext)
        default: return false
        }
    }

    // MARK: - Dates

    private func date(of attribute: Attribute, in snapshot: FileSnapshot) -> Date? {
        switch attribute {
        case .dateAdded: return snapshot.dateAdded
        case .dateCreated: return snapshot.dateCreated
        case .dateModified: return snapshot.dateModified
        default: return nil
        }
    }

    /// Start of the "in the last N units" window ending at `now`.
    func windowStart(_ amount: Int, _ unit: DurationUnit, now: Date) -> Date? {
        let component: Calendar.Component
        var value = amount
        switch unit {
        case .minutes: component = .minute
        case .hours: component = .hour
        case .days: component = .day
        case .weeks: component = .day; value = amount * 7
        case .months: component = .month
        }
        return calendar.date(byAdding: component, value: -value, to: now)
    }

    private func compareDate(_ date: Date?, _ op: Operator, _ value: ConditionValue, now: Date) -> Bool {
        guard let date else { return false }
        switch (op, value) {
        case (.inTheLast, .duration(let amount, let unit)):
            guard let start = windowStart(amount, unit, now: now) else { return false }
            return date >= start
        case (.notInTheLast, .duration(let amount, let unit)):
            guard let start = windowStart(amount, unit, now: now) else { return false }
            return date < start
        case (.before, .date(let day)):
            return date < calendar.startOfDay(for: day)
        case (.after, .date(let day)):
            guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return false }
            return date >= next
        default:
            return false
        }
    }

    // MARK: - Tags and sources

    private func compareTags(_ tags: [String], _ op: Operator, _ value: ConditionValue) -> Bool {
        let fileTags = Set(tags.map { $0.lowercased() })
        switch (op, value) {
        case (.hasNoTags, _):
            return fileTags.isEmpty
        case (.containsTag, .tags(let wanted)):
            return wanted.contains { fileTags.contains($0.lowercased()) }
        case (.doesNotContainTag, .tags(let unwanted)):
            return !unwanted.contains { fileTags.contains($0.lowercased()) }
        default:
            return false
        }
    }

    private func compareSources(_ sources: [String], _ op: Operator, _ value: String, _ options: String.CompareOptions) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces)
        switch op {
        case .contains:
            return !value.isEmpty && sources.contains { $0.range(of: value, options: options) != nil }
        case .doesNotContain:
            return value.isEmpty || !sources.contains { $0.range(of: value, options: options) != nil }
        case .is:
            return sources.contains { $0.compare(value, options: options) == .orderedSame }
        default:
            return false
        }
    }
}

/// Whole-string wildcard matching: `*` matches any run of characters
/// (including none), `?` matches exactly one character. No other special
/// characters, so names with `[` or `\` match literally.
public enum WildcardPattern {
    public static func matches(_ text: String, pattern: String, caseSensitive: Bool = false) -> Bool {
        let text = Array(caseSensitive ? text : text.lowercased())
        let pattern = Array(caseSensitive ? pattern : pattern.lowercased())
        var t = 0, p = 0
        var starP = -1, starT = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                t += 1; p += 1
            } else if p < pattern.count, pattern[p] == "*" {
                starP = p; starT = t; p += 1
            } else if starP >= 0 {
                // Backtrack: let the last `*` absorb one more character.
                p = starP + 1; starT += 1; t = starT
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
