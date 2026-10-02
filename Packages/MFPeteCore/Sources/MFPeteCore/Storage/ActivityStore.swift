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
        detail: String = ""
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
            detail: entry.detail
        )
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
                detail: record.detail
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
