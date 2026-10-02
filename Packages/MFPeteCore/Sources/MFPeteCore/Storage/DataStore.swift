import Foundation
import SwiftData

/// Result of one logged action (spec §8.4: ✓ / ⚠︎ / ✕).
public enum ActivityResultKind: String, Codable, Hashable, Sendable {
    case success
    case skipped
    case failed
}

/// One action on one file, or one rule-level error (spec §9).
@Model
public final class ActivityEntry {
    public var id: UUID
    public var timestamp: Date
    public var ruleID: UUID
    /// Snapshot of the rule name; survives rename and delete.
    public var ruleName: String
    public var action: String
    public var sourcePath: String
    /// Kept so undo can come in v1.x (D7).
    public var destinationPath: String?
    /// Raw value of `ActivityResultKind`.
    public var resultKind: String
    /// Failure or skip reason.
    public var message: String?
    /// Extra free-form detail for the log's Details column.
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
        self.resultKind = result.rawValue
        self.message = message
        self.detail = detail
    }

    public var result: ActivityResultKind {
        ActivityResultKind(rawValue: resultKind) ?? .failed
    }
}

/// Marks that a rule already processed a file at a given modification date (D6).
@Model
public final class ProcessedRecord {
    /// `ruleID` + `fileKey`. Unique, so each rule has at most one record per file.
    @Attribute(.unique) public var key: String
    public var ruleID: UUID
    public var fileKey: String
    public var modifiedAt: Date

    public init(ruleID: UUID, fileKey: String, modifiedAt: Date) {
        self.key = ProcessedRecord.makeKey(ruleID: ruleID, fileKey: fileKey)
        self.ruleID = ruleID
        self.fileKey = fileKey
        self.modifiedAt = modifiedAt
    }

    public static func makeKey(ruleID: UUID, fileKey: String) -> String {
        "\(ruleID.uuidString)|\(fileKey)"
    }
}

/// Builds the SwiftData container for the activity log and processed records (D4).
public enum DataStore {
    public static let schema = Schema([ActivityEntry.self, ProcessedRecord.self])

    /// Container at `~/Library/Application Support/MFPete/MFPete.store`.
    public static func makeContainer(at url: URL = AppPaths.dataStoreFile) throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
