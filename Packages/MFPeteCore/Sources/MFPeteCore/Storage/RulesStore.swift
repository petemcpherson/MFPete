import Foundation

/// Loads and saves `rules.json` (D4) with a backup copy and corrupt-file
/// recovery (spec §13).
public struct RulesStore: Sendable {
    public static let fileName = "rules.json"
    public static let backupFileName = "rules.json.bak"

    /// What happened during `load()`, for the UI to surface.
    public enum LoadIssue: Equatable, Sendable {
        /// `rules.json` was unreadable; rules came from `rules.json.bak`.
        /// The bad file was kept at `corruptFile`.
        case recoveredFromBackup(corruptFile: URL?)
        /// Neither file was readable. Started empty. The bad file was kept at
        /// `corruptFile`. The UI must alert the user.
        case startedEmpty(corruptFile: URL?)
    }

    public struct LoadResult: Sendable {
        public var rules: [Rule]
        public var issue: LoadIssue?
        /// Names of rules that contain unknown actions or conditions and were
        /// loaded disabled.
        public var disabledUnknownRules: [String]
    }

    public let directory: URL
    private let migrator: RulesMigrator
    private let now: @Sendable () -> Date

    public init(
        directory: URL = AppPaths.supportDirectory,
        migrator: RulesMigrator = RulesMigrator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.migrator = migrator
        self.now = now
    }

    public var fileURL: URL { directory.appendingPathComponent(RulesStore.fileName) }
    public var backupURL: URL { directory.appendingPathComponent(RulesStore.backupFileName) }

    /// Loads rules sorted by `order`. Never throws: on failure it falls back
    /// to the backup, then to an empty list, and reports what happened.
    public func load() -> LoadResult {
        let fileManager = FileManager.default
        var issue: LoadIssue?
        var rules: [Rule] = []

        if let file = try? decodeFile(at: fileURL) {
            rules = file.rules
        } else {
            // Main file is missing or unreadable. Keep a bad file aside so the
            // next save does not copy it over the good backup.
            let mainExisted = fileManager.fileExists(atPath: fileURL.path)
            let corruptFile = mainExisted ? moveAsideCorruptFile() : nil

            if let backup = try? decodeFile(at: backupURL) {
                rules = backup.rules
                issue = .recoveredFromBackup(corruptFile: corruptFile)
            } else if mainExisted || fileManager.fileExists(atPath: backupURL.path) {
                issue = .startedEmpty(corruptFile: corruptFile)
            }
            // Neither file exists: first launch, no issue.
        }

        rules.sort { $0.order < $1.order }
        let disabled = rules.filter(\.containsUnknownElements).map(\.name)
        return LoadResult(rules: rules, issue: issue, disabledUnknownRules: disabled)
    }

    /// Saves rules. Copies the current file to `rules.json.bak` first, then
    /// writes the new file atomically.
    public func save(_ rules: [Rule]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try RulesFile(rules: rules).encoded()

        if fileManager.fileExists(atPath: fileURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func decodeFile(at url: URL) throws -> RulesFile {
        let data = try Data(contentsOf: url)
        return try RulesFile.decode(data, migrator: migrator)
    }

    /// Renames `rules.json` to `rules.corrupt-<timestamp>.json`.
    private func moveAsideCorruptFile() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())

        var destination = directory.appendingPathComponent("rules.corrupt-\(stamp).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("rules.corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
