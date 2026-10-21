import Foundation

/// The clipboard contents from before a dictation, kept in memory only when
/// Keep Previous Clipboard is on. Restore is offered only while the clipboard
/// still holds the dictated text (its change count is unchanged) and for at
/// most five minutes; nothing is ever restored automatically.
public struct ClipboardSnapshot: Sendable {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumRepresentations = 256
    public static let lifetime: Duration = .seconds(300)

    /// Each pasteboard item as its types and data, in order.
    public let items: [[(type: String, data: Data)]]
    /// The pasteboard change count after the dictated text was written.
    public private(set) var dictatedChangeCount: Int?
    public let taken: ContinuousClock.Instant

    /// Nil when the contents exceed the bounds; the dictation goes on without a snapshot.
    public init?(items: [[(type: String, data: Data)]], taken: ContinuousClock.Instant = .now) {
        let representations = items.reduce(0) { $0 + $1.count }
        let bytes = items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
        guard representations <= Self.maximumRepresentations, bytes <= Self.maximumBytes else { return nil }
        self.items = items
        self.taken = taken
    }

    public mutating func dictatedTextWritten(changeCount: Int) {
        dictatedChangeCount = changeCount
    }

    public func isRestorable(changeCount: Int, now: ContinuousClock.Instant = .now) -> Bool {
        dictatedChangeCount == changeCount && now - taken < Self.lifetime
    }

    /// Whether to keep it at all: an expired or overwritten snapshot is discarded.
    public func isStale(changeCount: Int, now: ContinuousClock.Instant = .now) -> Bool {
        !isRestorable(changeCount: changeCount, now: now)
    }
}
