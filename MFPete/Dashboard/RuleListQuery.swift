import Foundation
import MFPeteCore

/// Search, filter, and sort for the dashboard (spec §8.2). Pure value logic,
/// unit tested without UI.
struct RuleListQuery: Equatable {
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, enabled, disabled, hasErrors
        var id: Self { self }

        var title: String {
            switch self {
            case .all: return String(localized: "All Rules")
            case .enabled: return String(localized: "Enabled")
            case .disabled: return String(localized: "Disabled")
            case .hasErrors: return String(localized: "Has Errors")
            }
        }
    }

    enum TriggerFilter: String, CaseIterable, Identifiable {
        case all, fileEvent, schedule
        var id: Self { self }

        var title: String {
            switch self {
            case .all: return String(localized: "Any Trigger")
            case .fileEvent: return String(localized: "File Event")
            case .schedule: return String(localized: "Schedule")
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        /// Drag order, which is also run order (D5).
        case manual, name, lastRun, dateCreated
        var id: Self { self }

        var title: String {
            switch self {
            case .manual: return String(localized: "Manual")
            case .name: return String(localized: "Name")
            case .lastRun: return String(localized: "Last Run")
            case .dateCreated: return String(localized: "Date Created")
            }
        }
    }

    var searchText = ""
    var status: StatusFilter = .all
    var trigger: TriggerFilter = .all
    /// Path of a scope folder, or nil for all folders.
    var folder: String?
    var sort: Sort = .manual

    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || status != .all || trigger != .all || folder != nil
    }

    /// Drag reorder only makes sense on the full list in manual order.
    var allowsReorder: Bool {
        sort == .manual && !isFiltering
    }

    mutating func clearFilters() {
        searchText = ""
        status = .all
        trigger = .all
        folder = nil
    }

    /// The rules to show, filtered and sorted. `hasError` reports a rule's
    /// error badge; `stats` gives last run times.
    func apply(
        to rules: [Rule],
        stats: [Rule.ID: RuleStats] = [:],
        hasError: (Rule.ID) -> Bool = { _ in false }
    ) -> [Rule] {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let filtered = rules.filter { rule in
            matchesSearch(rule, terms: terms)
                && matchesStatus(rule, hasError: hasError)
                && matchesTrigger(rule)
                && (folder.map { path in rule.scope.contains { $0.path == path } } ?? true)
        }
        return sorted(filtered, stats: stats)
    }

    /// Every scope folder used by the rules, for the Folder filter. Sorted by name.
    static func folders(in rules: [Rule]) -> [FolderRef] {
        var seen: Set<String> = []
        var folders: [FolderRef] = []
        for folder in rules.flatMap(\.scope) where !folder.path.isEmpty && seen.insert(folder.path).inserted {
            folders.append(folder)
        }
        return folders.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Filters

    /// Every search word must appear in the rule name or a scope folder name.
    private func matchesSearch(_ rule: Rule, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = ([rule.name] + rule.scope.map(\.displayName)).joined(separator: " ")
        return terms.allSatisfy { haystack.localizedStandardContains($0) }
    }

    private func matchesStatus(_ rule: Rule, hasError: (Rule.ID) -> Bool) -> Bool {
        switch status {
        case .all: return true
        case .enabled: return rule.isEnabled
        case .disabled: return !rule.isEnabled
        case .hasErrors: return hasError(rule.id)
        }
    }

    private func matchesTrigger(_ rule: Rule) -> Bool {
        switch trigger {
        case .all: return true
        case .fileEvent: return rule.trigger.isFileEvent
        case .schedule: return rule.trigger.isSchedule
        }
    }

    // MARK: - Sorting

    private func sorted(_ rules: [Rule], stats: [Rule.ID: RuleStats]) -> [Rule] {
        switch sort {
        case .manual:
            return rules.sorted { $0.order < $1.order }
        case .name:
            return rules.sorted { lhs, rhs in
                let result = lhs.name.localizedStandardCompare(rhs.name)
                return result == .orderedSame ? lhs.order < rhs.order : result == .orderedAscending
            }
        case .lastRun:
            // Most recent first; rules that never ran go last, in manual order.
            return rules.sorted { lhs, rhs in
                switch (stats[lhs.id]?.lastRun, stats[rhs.id]?.lastRun) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.order < rhs.order
                }
            }
        case .dateCreated:
            // Newest first.
            return rules.sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.order < rhs.order : lhs.createdAt > rhs.createdAt
            }
        }
    }
}
