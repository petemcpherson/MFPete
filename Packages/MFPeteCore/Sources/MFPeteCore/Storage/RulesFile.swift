import Foundation

/// Top-level shape of `rules.json` and of export files (spec §9).
public struct RulesFile: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var rules: [Rule]

    public init(version: Int = RulesFile.currentVersion, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case version, rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try RulesFile.makeEncoder().encode(self)
    }

    /// Decodes rules file data of any supported version, migrating older
    /// versions to the current one.
    public static func decode(_ data: Data, migrator: RulesMigrator = RulesMigrator()) throws -> RulesFile {
        let migrated = try migrator.migrate(data)
        return try makeDecoder().decode(RulesFile.self, from: migrated)
    }
}

/// Upgrades older `rules.json` versions to `RulesFile.currentVersion`.
/// Each step converts version N to N + 1 on the raw JSON. Empty for v1.
public struct RulesMigrator: Sendable {
    public typealias Step = @Sendable (JSONValue) throws -> JSONValue

    public enum MigrationError: Error, Equatable {
        case notAnObject
        case unsupportedVersion(Int)
        case missingStep(from: Int)
    }

    public var currentVersion: Int
    /// Keyed by the version the step migrates *from*.
    public var steps: [Int: Step]

    public init(currentVersion: Int = RulesFile.currentVersion, steps: [Int: Step] = [:]) {
        self.currentVersion = currentVersion
        self.steps = steps
    }

    /// Returns JSON data at `currentVersion`. A missing `version` counts as 1.
    public func migrate(_ data: Data) throws -> Data {
        var json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let fields) = json else { throw MigrationError.notAnObject }

        var version = 1
        if case .number(let number)? = fields["version"] {
            version = Int(number)
        }
        if version > currentVersion {
            throw MigrationError.unsupportedVersion(version)
        }
        if version == currentVersion {
            return data
        }
        while version < currentVersion {
            guard let step = steps[version] else { throw MigrationError.missingStep(from: version) }
            json = try step(json)
            version += 1
        }
        guard case .object(var migrated) = json else { throw MigrationError.notAnObject }
        migrated["version"] = .number(Double(currentVersion))
        return try JSONEncoder().encode(JSONValue.object(migrated))
    }
}
