import Foundation

/// How the items of a condition group combine.
public enum Match: String, Codable, Hashable, Sendable, CaseIterable {
    /// AND: every item must match.
    case all
    /// OR: at least one item must match.
    case any
}

/// A list of conditions and nested groups (spec §4.1). An empty group matches
/// every file. The data model allows any depth; the editor shows one level (D12).
public struct ConditionGroup: Codable, Hashable, Sendable {
    public var match: Match
    public var items: [ConditionItem]

    public init(match: Match = .all, items: [ConditionItem] = []) {
        self.match = match
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case match, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decodeKnown(Match.self, forKey: .match)
        items = try container.decodeIfPresent([ConditionItem].self, forKey: .items) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(match, forKey: .match)
        try container.encode(items, forKey: .items)
    }

    /// True if any item at any depth is an unknown placeholder.
    public var containsUnknown: Bool {
        items.contains { item in
            switch item {
            case .condition: return false
            case .group(let group): return group.containsUnknown
            case .unknown: return true
            }
        }
    }
}

/// One row in a condition group.
public enum ConditionItem: Codable, Hashable, Sendable {
    case condition(Condition)
    case group(ConditionGroup)
    /// A condition from a newer app version (unknown attribute, operator, or
    /// value type). Kept as raw JSON; the containing rule loads disabled.
    case unknown(JSONValue)

    private enum Kind: String {
        case condition, group
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decodeKnown(Kind.self, forKey: .type) {
            case .condition: self = .condition(try Condition(from: decoder))
            case .group: self = .group(try ConditionGroup(from: decoder))
            }
        } catch is UnknownCaseError {
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .condition(let condition):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.condition.rawValue, forKey: .type)
            try condition.encode(to: encoder)
        case .group(let group):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.group.rawValue, forKey: .type)
            try group.encode(to: encoder)
        case .unknown(let raw):
            try raw.encode(to: encoder)
        }
    }
}

/// A test against one file attribute ("Extension is any of dmg, zip").
public struct Condition: Codable, Hashable, Sendable {
    public var attribute: Attribute
    public var op: Operator
    public var value: ConditionValue
    /// Reserved for v1.x "Match case". v1 always compares case-insensitively.
    public var caseSensitive: Bool

    public init(attribute: Attribute, op: Operator, value: ConditionValue = .none, caseSensitive: Bool = false) {
        self.attribute = attribute
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case attribute, op = "operator", value, caseSensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attribute = try container.decodeKnown(Attribute.self, forKey: .attribute)
        op = try container.decodeKnown(Operator.self, forKey: .op)
        value = try container.decodeIfPresent(ConditionValue.self, forKey: .value) ?? .none
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attribute.rawValue, forKey: .attribute)
        try container.encode(op.rawValue, forKey: .op)
        try container.encode(value, forKey: .value)
        try container.encode(caseSensitive, forKey: .caseSensitive)
    }

    /// True if the operator is allowed for the attribute and the value has the
    /// type that operator expects.
    public var isWellFormed: Bool {
        attribute.allows(op) && value.valueType == op.valueType(for: attribute)
    }
}

/// File attributes a condition can test (spec §4.2).
public enum Attribute: String, Codable, Hashable, Sendable, CaseIterable {
    case name
    case fullName
    case `extension`
    case kind
    case size
    case dateAdded
    case dateCreated
    case dateModified
    case tags
    case downloadedFrom
    case anyFile

    public var isDate: Bool {
        self == .dateAdded || self == .dateCreated || self == .dateModified
    }

    /// Operator validity table (spec §4.2). First entry is the editor default.
    public var allowedOperators: [Operator] {
        switch self {
        case .name, .fullName:
            return [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .matchesPattern]
        case .extension:
            return [.is, .isNot, .isAnyOf]
        case .kind:
            return [.is, .isNot]
        case .size:
            return [.greaterThan, .lessThan]
        case .dateAdded, .dateCreated, .dateModified:
            return [.inTheLast, .notInTheLast, .before, .after]
        case .tags:
            return [.containsTag, .doesNotContainTag, .hasNoTags]
        case .downloadedFrom:
            return [.contains, .doesNotContain, .is]
        case .anyFile:
            return [.always]
        }
    }

    public func allows(_ op: Operator) -> Bool {
        allowedOperators.contains(op)
    }

    /// Text attributes where `Condition.caseSensitive` applies.
    public var supportsMatchCase: Bool {
        self == .name || self == .fullName || self == .downloadedFrom
    }
}

/// Comparison operators. Which ones apply depends on the attribute
/// (see `Attribute.allowedOperators`).
public enum Operator: String, Codable, Hashable, Sendable, CaseIterable {
    case `is`
    case isNot
    case contains
    case doesNotContain
    case startsWith
    case endsWith
    case matchesPattern
    case isAnyOf
    case greaterThan
    case lessThan
    case inTheLast
    case notInTheLast
    case before
    case after
    case containsTag
    case doesNotContainTag
    case hasNoTags
    /// Used only by `Attribute.anyFile`.
    case always

    /// The value type this operator expects for the given attribute.
    public func valueType(for attribute: Attribute) -> ConditionValueType {
        switch self {
        case .always, .hasNoTags:
            return .none
        case .greaterThan, .lessThan:
            return .size
        case .inTheLast, .notInTheLast:
            return .duration
        case .before, .after:
            return .date
        case .containsTag, .doesNotContainTag:
            return .tags
        case .is, .isNot:
            return attribute == .kind ? .kind : .text
        case .contains, .doesNotContain, .startsWith, .endsWith, .matchesPattern, .isAnyOf:
            return .text
        }
    }
}

public enum ConditionValueType: String, Hashable, Sendable {
    case none, text, size, duration, date, kind, tags
}

/// The value side of a condition.
public enum ConditionValue: Codable, Hashable, Sendable {
    case none
    /// Text to compare. For "Extension is any of", a comma-separated list.
    case text(String)
    case size(Double, SizeUnit)
    case duration(Int, DurationUnit)
    case date(Date)
    case kind(FileKind)
    case tags([String])

    public var valueType: ConditionValueType {
        switch self {
        case .none: return .none
        case .text: return .text
        case .size: return .size
        case .duration: return .duration
        case .date: return .date
        case .kind: return .kind
        case .tags: return .tags
        }
    }

    /// An empty value of the given type, used when the editor switches operator.
    public static func empty(_ type: ConditionValueType) -> ConditionValue {
        switch type {
        case .none: return .none
        case .text: return .text("")
        case .size: return .size(1, .mb)
        case .duration: return .duration(1, .days)
        case .date: return .date(Date())
        case .kind: return .kind(.document)
        case .tags: return .tags([])
        }
    }

    private enum Kind: String {
        case none, text, size, duration, date, kind, tags
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, amount, unit, date, kind, tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeKnown(Kind.self, forKey: .type) {
        case .none:
            self = .none
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .size:
            self = .size(
                try container.decode(Double.self, forKey: .amount),
                try container.decodeKnown(SizeUnit.self, forKey: .unit)
            )
        case .duration:
            self = .duration(
                try container.decode(Int.self, forKey: .amount),
                try container.decodeKnown(DurationUnit.self, forKey: .unit)
            )
        case .date:
            self = .date(try container.decode(Date.self, forKey: .date))
        case .kind:
            self = .kind(try container.decodeKnown(FileKind.self, forKey: .kind))
        case .tags:
            self = .tags(try container.decode([String].self, forKey: .tags))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none.rawValue, forKey: .type)
        case .text(let text):
            try container.encode(Kind.text.rawValue, forKey: .type)
            try container.encode(text, forKey: .text)
        case .size(let amount, let unit):
            try container.encode(Kind.size.rawValue, forKey: .type)
            try container.encode(amount, forKey: .amount)
            try container.encode(unit.rawValue, forKey: .unit)
        case .duration(let amount, let unit):
            try container.encode(Kind.duration.rawValue, forKey: .type)
            try container.encode(amount, forKey: .amount)
            try container.encode(unit.rawValue, forKey: .unit)
        case .date(let date):
            try container.encode(Kind.date.rawValue, forKey: .type)
            try container.encode(date, forKey: .date)
        case .kind(let kind):
            try container.encode(Kind.kind.rawValue, forKey: .type)
            try container.encode(kind.rawValue, forKey: .kind)
        case .tags(let tags):
            try container.encode(Kind.tags.rawValue, forKey: .type)
            try container.encode(tags, forKey: .tags)
        }
    }
}

/// Size units. Decimal (1 KB = 1000 bytes) to match Finder.
public enum SizeUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case kb, mb, gb

    public var bytes: Double {
        switch self {
        case .kb: return 1_000
        case .mb: return 1_000_000
        case .gb: return 1_000_000_000
        }
    }
}

public enum DurationUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case minutes, hours, days, weeks, months
}

/// File kinds for the Kind attribute (spec §4.2).
public enum FileKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Anything but a folder. Never a classification result; see `includes(_:)`.
    case file
    case folder
    case image
    case movie
    case audio
    case pdf
    case text
    case document
    case archive
    case diskImage
    case application
    case alias
    case other

    public var displayName: String {
        switch self {
        case .file: return localized("File")
        case .folder: return localized("Folder")
        case .image: return localized("Image")
        case .movie: return localized("Movie")
        case .audio: return localized("Audio")
        case .pdf: return localized("PDF")
        case .text: return localized("Text")
        case .document: return localized("Document")
        case .archive: return localized("Archive")
        case .diskImage: return localized("Disk Image")
        case .application: return localized("Application")
        case .alias: return localized("Alias")
        case .other: return localized("Other")
        }
    }

    /// Typical extensions shown next to the name so users know what a kind
    /// covers. Illustrative only: classification goes by UTType.
    public var sampleExtensions: [String] {
        switch self {
        case .image: return ["jpg", "png", "heic"]
        case .movie: return ["mp4", "mov"]
        case .audio: return ["mp3", "m4a", "wav"]
        case .text: return ["txt", "md", "csv"]
        case .document: return ["docx", "pages", "xlsx"]
        case .archive: return ["zip", "rar", "7z"]
        case .diskImage: return ["dmg", "iso"]
        case .application: return ["app"]
        case .file, .folder, .pdf, .alias, .other: return []
        }
    }

    /// Display name plus sample extensions, e.g. "Disk Image (.dmg, .iso)".
    public var displayNameWithSamples: String {
        if self == .file { return localized("File (anything but a folder)") }
        guard !sampleExtensions.isEmpty else { return displayName }
        let samples = sampleExtensions.map { "." + $0 }.joined(separator: ", ")
        return "\(displayName) (\(samples))"
    }
}
