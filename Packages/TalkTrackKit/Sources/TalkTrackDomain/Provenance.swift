import Foundation

public enum DomainError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case invalidTime
    case reversedInterval
    case invalidTimeZone(String)
    case unsupportedSchema(Int)
    case invalidAudioFrames
}

/// A library/model-root relative file reference. Resolving symlinks belongs to
/// the owning file service; syntactic validity alone never grants file access.
public struct RelativePath: Codable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("~"), !value.contains("\\"),
              !value.contains("\0"), !value.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DomainError.invalidRelativePath(value)
        }
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Integer microseconds keep the exact two-second grouping boundary stable.
public struct MediaTime: Codable, Hashable, Comparable, Sendable {
    public let microseconds: Int64
    public static let zero = Self(unchecked: 0)
    public var seconds: Double { Double(microseconds) / 1_000_000 }

    public init(microseconds: Int64) throws {
        guard microseconds >= 0 else { throw DomainError.invalidTime }
        self.microseconds = microseconds
    }

    public init(seconds: Double) throws {
        let scaled = (seconds * 1_000_000).rounded()
        guard seconds.isFinite, seconds >= 0, scaled < Double(Int64.max) else {
            throw DomainError.invalidTime
        }
        try self.init(microseconds: Int64(scaled))
    }

    fileprivate init(unchecked: Int64) { microseconds = unchecked }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.microseconds < rhs.microseconds }

    public init(from decoder: any Decoder) throws {
        try self.init(microseconds: decoder.singleValueContainer().decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(microseconds)
    }
}

public struct MediaInterval: Codable, Hashable, Sendable {
    public let start: MediaTime
    public let end: MediaTime
    public var duration: MediaTime { MediaTime(unchecked: end.microseconds - start.microseconds) }

    public init(start: MediaTime, end: MediaTime) throws {
        guard end >= start else { throw DomainError.reversedInterval }
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey { case start, end }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(MediaTime.self, forKey: .start), end: c.decode(MediaTime.self, forKey: .end))
    }
}

/// Captured once and persisted. Display never reinterprets this day in today's zone.
public struct RecordingDay: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let localDate: String
    public let timeZoneIdentifier: String
    public let utcOffsetSeconds: Int
    public let calendarIdentifier: String

    public init(id: UUID = UUID(), capturedAt: Date, timeZoneIdentifier: String) throws {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw DomainError.invalidTimeZone(timeZoneIdentifier)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: capturedAt)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw DomainError.invalidTime
        }
        self.id = id
        localDate = String(format: "%04d-%02d-%02d", year, month, day)
        self.timeZoneIdentifier = timeZoneIdentifier
        utcOffsetSeconds = zone.secondsFromGMT(for: capturedAt)
        calendarIdentifier = "gregorian"
    }
}

/// Versioned JSON payloads used inside structured storage and recovery files.
public enum DomainCodec {
    private struct Envelope<T: Codable>: Codable {
        let schemaVersion: Int
        let value: T
    }
    private struct Header: Decodable { let schemaVersion: Int }

    public static func encode<T: Codable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(schemaVersion: 1, value: value))
    }

    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).schemaVersion
        guard version == 1 else { throw DomainError.unsupportedSchema(version) }
        return try decoder.decode(Envelope<T>.self, from: data).value
    }
}
