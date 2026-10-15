import Foundation

/// Maps transcript speech blocks to the meeting's continuous playback timeline
/// and back. A block's source interval spans its segments in recording active
/// time; blocks of recordings that are not on the timeline (still being
/// captured, or not playable) have no timing and are never highlighted.
public struct TranscriptPlaybackIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public let itemID: String
        public let recordingID: UUID
        public let global: MediaInterval
    }

    /// Ordered by global start, then by transcript order.
    public let entries: [Entry]
    /// Running maximum of `entries[...i].global.end`, so overlap lookups stop
    /// as soon as no earlier block can still contain the position.
    private let furthestEnd: [MediaTime]
    private let byID: [String: Int]

    public init(timeline: MeetingTimeline, items: [TranscriptDisplayItem]) {
        var entries: [Entry] = []
        for item in items {
            guard case .speech(let block) = item, let first = block.segments.first,
                  let recording = timeline.recordings.first(where: { $0.recordingID == block.recordingID }) else { continue }
            let length = recording.global.duration
            let start = block.segments.map(\.interval.start).min() ?? first.interval.start
            let end = block.segments.map(\.interval.end).max() ?? first.interval.end
            guard start < length,
                  let globalStart = try? timeline.globalTime(recordingID: block.recordingID, activeTime: start),
                  let globalEnd = try? timeline.globalTime(recordingID: block.recordingID, activeTime: min(max(end, start), length)),
                  let interval = try? MediaInterval(start: globalStart, end: globalEnd) else { continue }
            entries.append(Entry(itemID: item.id, recordingID: block.recordingID, global: interval))
        }
        // Stable: equal starts keep transcript order.
        entries = entries.enumerated().sorted {
            $0.element.global.start != $1.element.global.start ? $0.element.global.start < $1.element.global.start : $0.offset < $1.offset
        }.map(\.element)
        self.entries = entries
        var furthest: [MediaTime] = [], running = MediaTime.zero
        for entry in entries { running = max(running, entry.global.end); furthest.append(running) }
        furthestEnd = furthest
        byID = Dictionary(entries.enumerated().map { ($0.element.itemID, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    /// The timeline position where a block's speech begins.
    public func start(of itemID: String) -> MediaTime? { byID[itemID].map { entries[$0].global.start } }

    /// The block being heard at `time`: of the blocks whose half-open interval
    /// contains it (system and microphone speech may overlap), the one that
    /// started last. Nil between blocks and at the end of the meeting.
    public func activeItem(at time: MediaTime) -> String? {
        var low = 0, high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].global.start <= time { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        while index >= 0, furthestEnd[index] > time {
            if entries[index].global.end > time { return entries[index].itemID }
            index -= 1
        }
        return nil
    }
}
