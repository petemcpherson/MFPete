import Foundation

/// Why a run happened. Stored on every activity entry (D15).
public enum RunTrigger: String, Codable, Hashable, Sendable, CaseIterable {
    case fileEvent
    case scheduled
    /// A scheduled run that happens after a missed time (spec §3.2).
    case scheduledLate
    /// Run Now (D14).
    case manual
    /// Apply-to-existing on enable (spec §3.4).
    case applyExisting

    public var displayName: String {
        switch self {
        case .fileEvent: return localized("File event")
        case .scheduled: return localized("Scheduled")
        case .scheduledLate: return localized("Ran late")
        case .manual: return localized("Manual")
        case .applyExisting: return localized("Apply to existing")
        }
    }
}

/// What one run of one rule did. Feeds the summary notification (spec §8.8)
/// and the dashboard.
public struct RunSummary: Hashable, Sendable {
    public var ruleID: UUID
    public var ruleName: String
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date
    /// Files that matched the conditions (including already processed ones).
    public var matched: Int = 0
    /// Files on which every action succeeded.
    public var actedOn: Int = 0
    /// Matching files skipped because this rule already processed them (D6).
    public var skippedProcessed: Int = 0
    /// Files skipped for other reasons (vanished, name exists).
    public var skippedOther: Int = 0
    /// Files on which an action failed.
    public var failed: Int = 0
    /// Rule-level errors (folder missing, no permission).
    public var ruleErrors: [String] = []
    /// Past-tense verb of the most common successful action, for
    /// notification text ("moved to Trash").
    public var dominantVerb: String?
    /// Set when the bulk guard held the run back (spec §5.6). Nothing ran.
    public var pendingApproval: BulkApprovalRequest?
    /// Extra context, such as "Ran late (missed 09:00)" (spec §3.2).
    public var note: String?

    public init(ruleID: UUID, ruleName: String, trigger: RunTrigger, startedAt: Date) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = startedAt
    }

    public var hasErrors: Bool { failed > 0 || !ruleErrors.isEmpty }

    /// Nothing matched and nothing went wrong.
    public var hadNoMatches: Bool { matched == 0 && ruleErrors.isEmpty }
}

/// Result of `RuleEngine.runNow(ruleID:)`.
public enum RunNowResult: Hashable, Sendable {
    case completed(RunSummary)
    /// The rule is already running. No queue (D14).
    case alreadyRunning
    case ruleNotFound
    /// "File removed" rules have no files to scan.
    case notAvailableForFileRemoved
    /// The rule has actions or conditions from a newer app version.
    case unsupportedElements
    /// The run would act on more files than the bulk guard allows. Nothing
    /// ran. Answer with `RuleEngine.resolveBulkApproval(_:approve:)`.
    case needsApproval(BulkApprovalRequest)
}

/// Health of a rule as the engine last saw it (spec §10, §13).
public enum RuleStatus: Hashable, Sendable {
    case ok
    case folderMissing(String)
    case noPermission(String)
    /// The folder is on a volume that is not mounted. Not an error: the rule
    /// resumes when the volume comes back (spec §11).
    case folderUnavailable(String)
    /// The last run had a failed action.
    case error(String)

    public var isError: Bool {
        switch self {
        case .ok, .folderUnavailable: return false
        case .folderMissing, .noPermission, .error: return true
        }
    }
}

/// Dry run of a rule (for Preview): what would happen to each matching file.
public struct PlannedFileResult: Hashable, Sendable {
    public var file: URL
    /// The rule already processed this unchanged file, so a real run skips it.
    public var alreadyProcessed: Bool
    public var steps: [PlannedStep]
}

public struct PlannedStep: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case willSucceed
        case willSkip(String)
        case willFail(String)
    }

    public var action: Action
    /// Where the file (or its copy) is predicted to end up.
    public var destination: URL?
    public var outcome: Outcome
}

extension Action {
    /// Past-tense verb for summaries: "3 files moved to Trash".
    public var pastTenseVerb: String {
        switch self {
        case .move(let folder, _): return localized("moved to \(folder.displayName)")
        case .copy(let folder, _): return localized("copied to \(folder.displayName)")
        case .rename, .changeExtension: return localized("renamed")
        case .trash: return localized("moved to Trash")
        case .sortIntoSubfolder: return localized("sorted")
        case .addTags: return localized("tagged")
        case .removeTags: return localized("untagged")
        case .unarchive: return localized("unarchived")
        case .open: return localized("opened")
        case .revealInFinder: return localized("revealed in Finder")
        case .notify, .unknown: return localized("processed")
        }
    }

    /// True if the action reads the file's contents, so an online-only
    /// placeholder must be downloaded first (spec §12).
    var needsContents: Bool {
        switch self {
        case .copy, .unarchive: return true
        default: return false
        }
    }

    /// True if the action moves the file out of its folder or deletes it.
    var removesFromFolder: Bool {
        switch self {
        case .move, .trash, .sortIntoSubfolder: return true
        case .unarchive(_, let trashArchive): return trashArchive
        default: return false
        }
    }
}
