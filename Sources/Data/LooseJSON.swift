import Foundation

/// Lenient scalar decoding, the Swift counterpart of `lib/data/models/json.dart`.
///
/// Dispatcharr's OpenAPI schema types several numeric fields as `string`, and
/// its serialiser can emit Python's `"None"` for a null. `Codable` is strict by
/// default, so `try container.decode(Int.self, ...)` throws on real responses.
/// Everything numeric or optional therefore goes through `LooseScalar`, which
/// accepts whichever JSON type actually shows up and coerces afterwards.
enum LooseScalar: Decodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            // Arrays and objects reach here. They carry no scalar meaning, and
            // treating them as null is what the Dart helpers do too.
            self = .null
        }
    }

    /// Sentinels that mean "absent" even though a string arrived.
    private static let nullSentinels: Set<String> = ["", "none", "null", "nil"]

    var stringValue: String? {
        switch self {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.nullSentinels.contains(trimmed.lowercased()) ? nil : trimmed
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string: return doubleValue.map(Int.init)
        case .bool(let value): return value ? 1 : 0
        case .null: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string: return stringValue.flatMap(Double.init)
        case .bool(let value): return value ? 1 : 0
        case .null: return nil
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string:
            guard let text = stringValue?.lowercased() else { return false }
            return text == "true" || text == "1" || text == "yes"
        case .null: return false
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key` as a lenient scalar. Missing keys are `.null`, not errors —
    /// several of these fields are undocumented and simply absent on some rows.
    func loose(_ key: Key) -> LooseScalar {
        (try? decodeIfPresent(LooseScalar.self, forKey: key)) .flatMap { $0 } ?? .null
    }

    func looseString(_ key: Key) -> String? { loose(key).stringValue }
    func looseInt(_ key: Key) -> Int? { loose(key).intValue }
    func looseDouble(_ key: Key) -> Double? { loose(key).doubleValue }
    func looseBool(_ key: Key) -> Bool { loose(key).boolValue }

    /// ISO-8601 timestamps, with and without fractional seconds — the API emits
    /// both depending on the endpoint.
    func looseDate(_ key: Key) -> Date? {
        guard let text = looseString(key) else { return nil }
        // `try?` swallows the whole expression, so the two attempts have to be
        // separate statements rather than chained with `??`.
        if let parsed = try? Date(text, strategy: Date.iso8601Fractional) {
            return parsed
        }
        return try? Date(text, strategy: Date.iso8601Plain)
    }
}

extension Date {
    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the
    /// formatter classes are reference types with mutable options, so a shared
    /// `static let` is not `Sendable` and Swift 6 rejects it. These format-style
    /// values are immutable structs and safe to share across actors.
    static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let iso8601Plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}
