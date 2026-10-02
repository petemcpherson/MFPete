import Foundation
import SwiftData

/// Value copy of an `ActivityEntry`, safe to pass between actors.
public struct ActivityRecord: Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var ruleID: UUID
    public var ruleName: String
    public var action: String
    public var sourcePath: String
    public var destinationPath: String?
    public var result: ActivityResultKind
    public var message: String?
    public var detail: String
    public var runTrigger: RunTrigger

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        ruleID: UUID,
        ruleName: String,
        action: String,
        sourcePath: String,
        destinationPath: String? = nil,
        result: ActivityResultKind,
        message: String? = nil,
        detail: String = "",
        runTrigger: RunTrigger = .fileEvent
    ) {
        self.id = id
        self.timestamp = timestamp
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.action = action
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.result = result
        self.message = message
        self.detail = detail
        self.runTrigger = runTrigger
    }

    init(_ entry: ActivityEntry) {
        self.init(
            id: entry.id,
            timestamp: entry.timestamp,
            ruleID: entry.ruleID,
            ruleName: entry.ruleName,
            action: entry.action,
            sourcePath: entry.sourcePath,
            destinationPath: entry.destinationPath,
            result: entry.result,
            message: entry.message,
            detail: entry.detail,
            runTrigger: RunTrigger(rawValue: entry.runTrigger) ?? .fileEvent
        )
    }
}

/// Dashboard numbers for one rule, computed from the activity log.
public struct RuleStats: Hashable, Sendable {
    public var lastRun: Date?
    /// Files acted on successfully, within the log's retention window.
    public var fileCount: Int
    public var lastError: ActivityRecord?

    public init(lastRun: Date? = nil, fileCount: Int = 0, lastError: ActivityRecord? = nil) {
        self.lastRun = lastRun
        self.fileCount = fileCount
        self.lastError = lastError
    }
}

/// How long activity entries are kept (spec §8.4). Configurable in Phase 6.
public struct RetentionPolicy: Hashable, Sendable {
    public var maxAge: TimeInterval
    public var maxEntries: Int

    public init(maxAgeDays: Int = 30, maxEntries: Int = 10_000) {
        self.maxAge = TimeInterval(maxAgeDays) * 24 * 60 * 60
        self.maxEntries = maxEntries
    }
}

/// Writes and prunes the activity log off the main thread. The UI reads
/// through a main-context `@Query`.
@ModelActor
public actor ActivityStore {
    public func add(_ record: ActivityRecord) throws {
        try add([record])
    }

    public func add(_ records: [ActivityRecord]) throws {
        for record in records {
            modelContext.insert(ActivityEntry(
                id: record.id,
                timestamp: record.timestamp,
                ruleID: record.ruleID,
                ruleName: record.ruleName,
                action: record.action,
                sourcePath: record.sourcePath,
                destinationPath: record.destinationPath,
                result: record.result,
                message: record.message,
                detail: record.detail,
                runTrigger: record.runTrigger
            ))
        }
        try modelContext.save()
    }

    /// Newest first.
    public func recent(limit: Int, ruleID: UUID? = nil) throws -> [ActivityRecord] {
        var descriptor = FetchDescriptor<ActivityEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let ruleID {
            descriptor.predicate = #Predicate { $0.ruleID == ruleID }
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(ActivityRecord.init)
    }

    /// Rule stats for the dashboard, derived from the log (spec §9).
    /// All entries for one file in one run share a timestamp, so the file
    /// count is the number of distinct timestamps among successful entries.
    public func stats(ruleID: UUID) throws -> RuleStats {
        var newest = FetchDescriptor<ActivityEntry>(
            predicate: #Predicate { $0.ruleID == ruleID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        newest.fetchLimit = 1
        let lastRun = try modelContext.fetch(newest).first?.timestamp

        let success = ActivityResultKind.success.rawValue
        var succeeded = FetchDescriptor<ActivityEntry>(
            predicate: #Predicate { $0.ruleID == ruleID && $0.resultKind == success }
        )
        succeeded.propertiesToFetch = [\.timestamp]
        let fileCount = Set(try modelContext.fetch(succeeded).map(\.timestamp)).count

        let failed = ActivityResultKind.failed.rawValue
        var lastFailure = FetchDescriptor<ActivityEntry>(
            predicate: #Predicate { $0.ruleID == ruleID && $0.resultKind == failed },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        lastFailure.fetchLimit = 1
        let lastError = try modelContext.fetch(lastFailure).first.map(ActivityRecord.init)

        return RuleStats(lastRun: lastRun, fileCount: fileCount, lastError: lastError)
    }

    public func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ActivityEntry>())
    }

    /// Deletes entries older than `maxAge`, then the oldest beyond `maxEntries`.
    public func prune(policy: RetentionPolicy = RetentionPolicy(), now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        try modelContext.delete(model: ActivityEntry.self, where: #Predicate { $0.timestamp < cutoff })

        let total = try modelContext.fetchCount(FetchDescriptor<ActivityEntry>())
        let excess = total - policy.maxEntries
        if excess > 0 {
            var oldest = FetchDescriptor<ActivityEntry>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
            oldest.fetchLimit = excess
            for entry in try modelContext.fetch(oldest) {
                modelContext.delete(entry)
            }
        }
        try modelContext.save()
    }

    public func deleteAll() throws {
        try modelContext.delete(model: ActivityEntry.self)
        try modelContext.save()
    }
}
