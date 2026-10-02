import Foundation

/// An arbitrary JSON value. Used to keep unknown rule elements intact so they
/// survive a load/save round trip from a newer app version.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The `"type"` discriminator, if this is an object that has one.
    public var typeName: String? {
        if case .object(let fields) = self, case .string(let type)? = fields["type"] {
            return type
        }
        return nil
    }
}

/// Thrown when a discriminator or raw value is not known to this app version.
/// Callers that support placeholders catch it and keep the raw JSON instead.
public struct UnknownCaseError: Error, Equatable {
    public var typeName: String
    public var value: String
}

extension KeyedDecodingContainer {
    /// Decodes a string raw value, throwing `UnknownCaseError` (not a generic
    /// decoding error) when the value is not a known case.
    func decodeKnown<T: RawRepresentable>(_ type: T.Type, forKey key: Key) throws -> T where T.RawValue == String {
        let raw = try decode(String.self, forKey: key)
        guard let value = T(rawValue: raw) else {
            throw UnknownCaseError(typeName: String(describing: T.self), value: raw)
        }
        return value
    }
}
