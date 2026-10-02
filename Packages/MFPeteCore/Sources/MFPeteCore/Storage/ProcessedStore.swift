import Foundation
import SwiftData

/// Tracks which files each rule has already processed (D6, spec §5.5).
@ModelActor
public actor ProcessedStore {
    /// A file is processed if a record exists whose `modifiedAt` is not older
    /// than the file's current content modification date.
    public func isProcessed(ruleID: UUID, fileKey: String, modifiedAt: Date) throws -> Bool {
        guard let record = try fetch(ruleID: ruleID, fileKey: fileKey) else { return false }
        return record.modifiedAt >= modifiedAt
    }

    /// Inserts or updates the record for this rule and file.
    public func markProcessed(ruleID: UUID, fileKey: String, modifiedAt: Date) throws {
        if let record = try fetch(ruleID: ruleID, fileKey: fileKey) {
            record.modifiedAt = modifiedAt
        } else {
            modelContext.insert(ProcessedRecord(ruleID: ruleID, fileKey: fileKey, modifiedAt: modifiedAt))
        }
        try modelContext.save()
    }

    /// "Run Again on All Files": forget everything this rule processed.
    public func reset(ruleID: UUID) throws {
        try modelContext.delete(model: ProcessedRecord.self, where: #Predicate { $0.ruleID == ruleID })
        try modelContext.save()
    }

    /// Settings › Advanced › Reset processed-file history.
    public func resetAll() throws {
        try modelContext.delete(model: ProcessedRecord.self)
        try modelContext.save()
    }

    /// Drops records for files that no longer exist (pruned on scan).
    public func remove(ruleID: UUID, fileKeys: Set<String>) throws {
        for fileKey in fileKeys {
            if let record = try fetch(ruleID: ruleID, fileKey: fileKey) {
                modelContext.delete(record)
            }
        }
        try modelContext.save()
    }

    public func fileKeys(ruleID: UUID) throws -> Set<String> {
        let descriptor = FetchDescriptor<ProcessedRecord>(predicate: #Predicate { $0.ruleID == ruleID })
        return Set(try modelContext.fetch(descriptor).map(\.fileKey))
    }

    private func fetch(ruleID: UUID, fileKey: String) throws -> ProcessedRecord? {
        let key = ProcessedRecord.makeKey(ruleID: ruleID, fileKey: fileKey)
        var descriptor = FetchDescriptor<ProcessedRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
