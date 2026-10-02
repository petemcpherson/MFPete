import Foundation

/// Settings › General › Notifications (spec §8.8).
public enum NotificationLevel: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case off
    case errorsOnly
    case everyRun

    public static let `default` = NotificationLevel.errorsOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return localized("Off")
        case .errorsOnly: return localized("Errors only")
        case .everyRun: return localized("Every run")
        }
    }
}

/// Decides when a run summary becomes a notification (spec §8.8 table).
/// The "Show notification" action does not go through here: it always fires.
public enum NotificationPolicy {
    /// - Parameters:
    ///   - notifyEachRun: the rule's "Notify on each run" option. It turns
    ///     summaries on under "Errors only".
    public static func shouldNotify(level: NotificationLevel, notifyEachRun: Bool, summary: RunSummary) -> Bool {
        guard summary.pendingApproval == nil else { return false }
        switch level {
        case .off:
            return false
        case .errorsOnly, .everyRun:
            if summary.hasErrors { return true }
            if summary.trigger.isUserStarted { return true }
            // Automatic runs that act on no files never notify.
            guard summary.actedOn > 0 else { return false }
            return level == .everyRun || notifyEachRun
        }
    }

    /// Loop guard alerts are errors: they post unless notifications are off.
    public static func shouldNotifyLoop(level: NotificationLevel) -> Bool {
        level != .off
    }
}

extension RunTrigger {
    /// Runs the user asked for: Run Now and "Apply" to existing files.
    public var isUserStarted: Bool {
        switch self {
        case .manual, .applyExisting: return true
        case .fileEvent, .scheduled, .scheduledLate: return false
        }
    }
}

/// Title and body of a summary notification, one per run, never one per
/// file: "Clean Downloads" / "3 files moved to Trash".
public struct RunNotificationText: Hashable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public init(summary: RunSummary) {
        title = summary.ruleName
        body = RunNotificationText.body(for: summary)
    }

    public init(loop alert: LoopAlert) {
        title = localized("Rule loop stopped")
        body = alert.message
    }

    static func body(for summary: RunSummary) -> String {
        let acted = summary.actedOn
        let failed = summary.failed
        if failed > 0 {
            if acted == 0 {
                return failed == 1 ? localized("1 file failed") : localized("\(failed) files failed")
            }
            return acted == 1
                ? localized("1 file processed, \(failed) failed")
                : localized("\(acted) files processed, \(failed) failed")
        }
        if acted > 0 {
            let verb = summary.dominantVerb ?? localized("processed")
            return acted == 1 ? localized("1 file \(verb)") : localized("\(acted) files \(verb)")
        }
        if let error = summary.ruleErrors.first {
            let more = summary.ruleErrors.count - 1
            return more > 0 ? localized("\(error) (and \(more) more)") : error
        }
        if summary.skippedProcessed > 0 {
            return localized("No new matching files")
        }
        return localized("No matching files")
    }
}

/// Merges file-event summaries of the same rule that arrive within a short
/// window, so dropping 20 files gives one notification, not 20 (spec §8.8).
/// Other runs pass straight through. The caller calls `due(at:)` when
/// `nextDeadline` passes.
public struct NotificationCoalescer: Sendable {
    public static let defaultWindow: TimeInterval = 5

    public let window: TimeInterval
    private var pending: [UUID: (summary: RunSummary, deadline: Date)] = [:]

    public init(window: TimeInterval = NotificationCoalescer.defaultWindow) {
        self.window = window
    }

    /// Returns the summary to post now, or nil if it is held for merging.
    public mutating func add(_ summary: RunSummary, now: Date) -> RunSummary? {
        guard summary.trigger == .fileEvent else { return summary }
        if let existing = pending[summary.ruleID] {
            pending[summary.ruleID] = (existing.summary.merged(with: summary), existing.deadline)
        } else {
            pending[summary.ruleID] = (summary, now.addingTimeInterval(window))
        }
        return nil
    }

    /// Removes and returns held summaries whose window ended, oldest first.
    public mutating func due(at now: Date) -> [RunSummary] {
        let ready = pending.filter { $0.value.deadline <= now }
        for id in ready.keys { pending[id] = nil }
        return ready.values.sorted { $0.deadline < $1.deadline }.map(\.summary)
    }

    /// When the next held summary is due, or nil if none is held.
    public var nextDeadline: Date? {
        pending.values.map(\.deadline).min()
    }

    public var isEmpty: Bool { pending.isEmpty }
}

extension RunSummary {
    /// Adds another run's counts to this one (for coalescing).
    public func merged(with other: RunSummary) -> RunSummary {
        var result = self
        result.startedAt = min(startedAt, other.startedAt)
        result.finishedAt = max(finishedAt, other.finishedAt)
        result.matched += other.matched
        result.actedOn += other.actedOn
        result.skippedProcessed += other.skippedProcessed
        result.skippedOther += other.skippedOther
        result.failed += other.failed
        for error in other.ruleErrors where !result.ruleErrors.contains(error) {
            result.ruleErrors.append(error)
        }
        switch (dominantVerb, other.dominantVerb) {
        case (nil, let verb), (let verb, nil):
            result.dominantVerb = verb
        case let (mine?, theirs?):
            // Different actions across the merged runs: fall back to the plain verb.
            result.dominantVerb = mine == theirs ? mine : localized("processed")
        }
        result.note = result.note ?? other.note
        return result
    }
}
