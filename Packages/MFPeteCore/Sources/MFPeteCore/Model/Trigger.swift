import Foundation

/// What starts a rule (spec §3). A rule has exactly one trigger.
public enum Trigger: Codable, Hashable, Sendable {
    case fileAdded
    case fileModified
    case fileRemoved
    /// Every N minutes. Minimum 5 (enforced by validation).
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)
    /// Weekdays use `Calendar` numbering: 1 = Sunday … 7 = Saturday.
    case weekly(weekdays: Set<Int>, hour: Int, minute: Int)

    public static let minimumIntervalMinutes = 5

    public var isFileEvent: Bool {
        switch self {
        case .fileAdded, .fileModified, .fileRemoved: return true
        case .interval, .daily, .weekly: return false
        }
    }

    public var isSchedule: Bool { !isFileEvent }

    private enum Kind: String {
        case fileAdded, fileModified, fileRemoved, interval, daily, weekly
    }

    private enum CodingKeys: String, CodingKey {
        case type, minutes, hour, minute, weekdays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeKnown(Kind.self, forKey: .type) {
        case .fileAdded: self = .fileAdded
        case .fileModified: self = .fileModified
        case .fileRemoved: self = .fileRemoved
        case .interval:
            self = .interval(minutes: try container.decode(Int.self, forKey: .minutes))
        case .daily:
            self = .daily(
                hour: try container.decode(Int.self, forKey: .hour),
                minute: try container.decode(Int.self, forKey: .minute)
            )
        case .weekly:
            self = .weekly(
                weekdays: Set(try container.decode([Int].self, forKey: .weekdays)),
                hour: try container.decode(Int.self, forKey: .hour),
                minute: try container.decode(Int.self, forKey: .minute)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fileAdded:
            try container.encode(Kind.fileAdded.rawValue, forKey: .type)
        case .fileModified:
            try container.encode(Kind.fileModified.rawValue, forKey: .type)
        case .fileRemoved:
            try container.encode(Kind.fileRemoved.rawValue, forKey: .type)
        case .interval(let minutes):
            try container.encode(Kind.interval.rawValue, forKey: .type)
            try container.encode(minutes, forKey: .minutes)
        case .daily(let hour, let minute):
            try container.encode(Kind.daily.rawValue, forKey: .type)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekdays, let hour, let minute):
            try container.encode(Kind.weekly.rawValue, forKey: .type)
            try container.encode(weekdays.sorted(), forKey: .weekdays)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        }
    }
}
