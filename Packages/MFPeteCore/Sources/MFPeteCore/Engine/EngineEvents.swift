import Foundation

/// Things the engine tells the UI about without being asked (Phase 4 shows
/// them; Phase 6 turns summaries into notifications).
public enum EngineEvent: Hashable, Sendable {
    /// An automatic run finished (file event, schedule, fallback scan). Only
    /// runs that matched files or hit errors are reported. Runs the user
    /// started (Run Now, Apply, an approved bulk run) return their summary
    /// to the caller instead.
    case runFinished(RunSummary)
    /// An automatic run would act on too many files (spec §5.6).
    case bulkApprovalRequested(BulkApprovalRequest)
    /// A file-event rule was created or enabled with matching files already
    /// in its folders (spec §3.4).
    case applyExistingRequested(ApplyExistingRequest)
    /// The loop guard stopped a chain (spec §5.6).
    case loopDetected(LoopAlert)
}

/// "Rule 'Clean Downloads' wants to act on 312 files." Preview / Run / Cancel.
/// Answer with `RuleEngine.resolveBulkApproval(_:approve:)`.
public struct BulkApprovalRequest: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ruleID: UUID
    public var ruleName: String
    public var fileCount: Int
    public var trigger: RunTrigger

    public init(id: UUID = UUID(), ruleID: UUID, ruleName: String, fileCount: Int, trigger: RunTrigger) {
        self.id = id
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.fileCount = fileCount
        self.trigger = trigger
    }
}

/// "Apply this rule to the N files already in Downloads that match?"
/// Preview / Apply / Only new files. The engine already treats the files as
/// processed (the safe default); answer with
/// `TriggerCoordinator.resolveApplyExisting(ruleID:apply:)`.
public struct ApplyExistingRequest: Identifiable, Hashable, Sendable {
    public var ruleID: UUID
    public var ruleName: String
    public var fileCount: Int
    /// Scope folder names, for the prompt text.
    public var folderNames: [String]

    public var id: UUID { ruleID }

    public init(ruleID: UUID, ruleName: String, fileCount: Int, folderNames: [String]) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.fileCount = fileCount
        self.folderNames = folderNames
    }
}

/// "Possible rule loop between Rule A and Rule B".
public struct LoopAlert: Hashable, Sendable {
    public var ruleIDs: [UUID]
    public var ruleNames: [String]
    public var filePath: String
    public var message: String

    public init(ruleIDs: [UUID], ruleNames: [String], filePath: String) {
        self.ruleIDs = ruleIDs
        self.ruleNames = ruleNames
        self.filePath = filePath
        self.message = LoopAlert.message(for: ruleNames)
    }

    static func message(for names: [String]) -> String {
        switch names.count {
        case 0:
            return localized("Possible rule loop")
        case 1:
            return localized("Possible rule loop in \(names[0])")
        default:
            let first = names.dropLast().joined(separator: ", ")
            return localized("Possible rule loop between \(first) and \(names[names.count - 1])")
        }
    }
}
