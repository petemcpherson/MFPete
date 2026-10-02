import Foundation

/// Turns an exported rules file into rules ready to append to the dashboard
/// (spec §9): older versions are migrated, every rule gets a new ID so it
/// never collides with an existing one, imports go to the end of the order,
/// and every imported rule starts disabled so nothing runs by surprise.
public struct RuleImporter: Sendable {
    public struct Result: Sendable {
        public var rules: [Rule]
        /// Names of rules with parts this version does not understand.
        public var unknownRuleNames: [String]
    }

    public enum ImportError: LocalizedError, Equatable {
        case unreadable
        case newerVersion(Int)
        case noRules

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return localized("The file is not a MFPete rules file.")
            case .newerVersion:
                return localized("The file was made by a newer version of MFPete. Update MFPete, then import again.")
            case .noRules:
                return localized("The file contains no rules.")
            }
        }
    }

    private let migrator: RulesMigrator

    /// Folder paths written with `~` expand while decoding (`FolderRef`).
    public init(migrator: RulesMigrator = RulesMigrator()) {
        self.migrator = migrator
    }

    /// - Parameter startOrder: the `order` of the first imported rule
    ///   (the number of rules already on the dashboard).
    public func importRules(from data: Data, startOrder: Int, now: Date = Date()) throws -> Result {
        let file: RulesFile
        do {
            file = try RulesFile.decode(data, migrator: migrator)
        } catch RulesMigrator.MigrationError.unsupportedVersion(let version) {
            throw ImportError.newerVersion(version)
        } catch {
            throw ImportError.unreadable
        }
        guard !file.rules.isEmpty else { throw ImportError.noRules }

        var unknown: [String] = []
        let rules = file.rules
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { offset, original -> Rule in
                var rule = original
                rule.id = UUID()
                rule.isEnabled = false
                rule.order = startOrder + offset
                rule.modifiedAt = now
                if rule.containsUnknownElements { unknown.append(rule.name) }
                return rule
            }
        return Result(rules: rules, unknownRuleNames: unknown)
    }
}

/// One scope folder and the rules that use it, for Settings › Folders and
/// for rule badges on rules the engine has not run yet (spec §10).
public struct FolderUsage: Hashable, Sendable, Identifiable {
    public var folder: FolderRef
    public var ruleIDs: [UUID]
    public var ruleNames: [String]
    public var health: FolderHealth

    public var id: String { folder.path }
}

/// Central folder-status check shared by the dashboard, menu bar dot, and
/// Settings › Folders. The engine runs the same `FolderHealth.check`
/// before every run.
public enum FolderStatusChecker {
    /// Every distinct scope folder, sorted by path, with its health.
    public static func usages(
        for rules: [Rule],
        check: (FolderRef) -> FolderHealth = FolderHealth.check
    ) -> [FolderUsage] {
        var byPath: [String: FolderUsage] = [:]
        for rule in rules {
            for folder in rule.scope {
                if byPath[folder.path] == nil {
                    byPath[folder.path] = FolderUsage(folder: folder, ruleIDs: [], ruleNames: [], health: check(folder))
                }
                if byPath[folder.path]?.ruleIDs.contains(rule.id) == false {
                    byPath[folder.path]?.ruleIDs.append(rule.id)
                    byPath[folder.path]?.ruleNames.append(rule.name)
                }
            }
        }
        return byPath.values.sorted { $0.folder.path < $1.folder.path }
    }

    /// Status of each rule from its folders: the first problem folder wins.
    /// Rules whose folders are all fine are left out.
    public static func ruleStatuses(from usages: [FolderUsage], rules: [Rule]) -> [UUID: RuleStatus] {
        let byPath = Dictionary(uniqueKeysWithValues: usages.map { ($0.folder.path, $0) })
        var statuses: [UUID: RuleStatus] = [:]
        for rule in rules {
            for folder in rule.scope {
                guard let usage = byPath[folder.path], let status = usage.health.ruleStatus(for: folder) else { continue }
                statuses[rule.id] = status
                break
            }
        }
        return statuses
    }
}

extension FolderHealth {
    /// Matching rule status, or nil when the folder is fine.
    public func ruleStatus(for folder: FolderRef) -> RuleStatus? {
        let path = folder.tildeAbbreviated()
        switch self {
        case .ok: return nil
        case .missing: return .folderMissing(path)
        case .noPermission: return .noPermission(path)
        case .unavailable: return .folderUnavailable(path)
        }
    }
}
