import Foundation

public enum TranscriptFormattingError: Error, Equatable, Sendable {
    case inconsistentMetadata, missingRecording, missingDay, missingSpeaker, invalidWallClock
}

public struct TranscriptDateSeparator: Equatable, Sendable {
    public let recordingID: UUID
    public let dayID: UUID
    public let date: String
    public let isResumption: Bool
    public var text: String { "------------ [\(Self.display(date))]\(isResumption ? " resumption" : "") ------------" }

    /// "2026-09-24" → "September 24, 2026". The frozen capture-day string is
    /// formatted as a calendar date, independent of the current time zone.
    public static func display(_ localDate: String) -> String {
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return localDate }
        return "\(months[parts[1] - 1]) \(parts[2]), \(parts[0])"
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]
}

public struct TranscriptBlock: Equatable, Sendable {
    public let recordingID: UUID
    public let dayID: UUID
    public let speaker: SpeakerReference
    public let speakerLabel: String
    public let timestamp: String
    public let segments: [TranscriptSegment]
    /// The label comes from a name the user gave these fragments, not their voice.
    public var isNamedFragment = false
    /// The user chose this reply's voice (`FragmentAnchor.voiceID`).
    public var isAssignedFragment = false
    /// Too short or too mixed to match to a voice; the user can say who it was.
    public var isUnidentified = false
    public var text: String {
        "[\(timestamp)]: \(speakerLabel) - " + segments.map { $0.correctedText ?? $0.originalText }.joined(separator: " ")
    }
}

/// Presentation values retain source segments and identity separately from
/// their labels. Date separators can be centered independently in a native row.
public enum TranscriptDisplayItem: Equatable, Identifiable, Sendable {
    case date(TranscriptDateSeparator)
    case speech(TranscriptBlock)
    public var id: String {
        switch self {
        case .date(let day): "day:\(day.recordingID):\(day.dayID)"
        case .speech(let block): "speech:\(block.segments[0].id)"
        }
    }
    public var text: String {
        switch self { case .date(let day): day.text; case .speech(let block): block.text }
    }
}

public enum TranscriptFormatter {
    /// Supply current speaker assignments, not their revision history. All
    /// inputs belong to one meeting; missing provenance is an explicit error.
    public static func format(meetingID: UUID, recordings: [Recording], segments: [TranscriptSegment],
                              speakers: [DaySpeaker], assignments: [SpeakerAssignment] = [],
                              anchors: [FragmentAnchor] = []) throws -> [TranscriptDisplayItem] {
        guard recordings.allSatisfy({ $0.meetingID == meetingID }), anchors.allSatisfy({ $0.meetingID == meetingID }),
              speakers.allSatisfy({ $0.meetingID == meetingID && $0.number > 0 }),
              assignments.allSatisfy({ $0.meetingID == meetingID }),
              Set(recordings.map(\.id)).count == recordings.count,
              Set(segments.map(\.id)).count == segments.count,
              Set(speakers.map(\.id)).count == speakers.count,
              Set(assignments.map(\.daySpeakerID)).count == assignments.count else {
            throw TranscriptFormattingError.inconsistentMetadata
        }
        let orderedRecordings = recordings.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        let recordingMap = Dictionary(uniqueKeysWithValues: orderedRecordings.map { ($0.id, $0) })
        let order = Dictionary(uniqueKeysWithValues: orderedRecordings.enumerated().map { ($1.id, $0) })
        let speakerMap = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: assignments.map { ($0.daySpeakerID, $0) })
        var capturedDays: [UUID: RecordingDay] = [:]
        for recording in recordings {
            guard Set(recording.days.map(\.id)).count == recording.days.count else {
                throw TranscriptFormattingError.inconsistentMetadata
            }
            for day in recording.days {
                if let previous = capturedDays[day.id], previous != day { throw TranscriptFormattingError.inconsistentMetadata }
                capturedDays[day.id] = day
            }
        }
        for segment in segments {
            guard let recording = recordingMap[segment.recordingID] else { throw TranscriptFormattingError.missingRecording }
            guard recording.days.contains(where: { $0.id == segment.dayID }) else { throw TranscriptFormattingError.missingDay }
            guard segment.wallClockStart.timeIntervalSinceReferenceDate.isFinite else {
                throw TranscriptFormattingError.invalidWallClock
            }
            if segment.track == .system {
                guard case .system(let id) = segment.speaker, let speaker = speakerMap[id], speaker.recordingDayIDs.contains(segment.dayID) else {
                    throw TranscriptFormattingError.missingSpeaker
                }
                guard let sourceDay = capturedDays[segment.dayID], let canonicalDay = capturedDays[speaker.dayID],
                      sourceDay.localDate == canonicalDay.localDate,
                      sourceDay.timeZoneIdentifier == canonicalDay.timeZoneIdentifier,
                      sourceDay.calendarIdentifier == canonicalDay.calendarIdentifier else {
                    throw TranscriptFormattingError.inconsistentMetadata
                }
                if let assignment = names[id], assignment.dayID != speaker.dayID {
                    throw TranscriptFormattingError.inconsistentMetadata
                }
            }
        }
        let ordered = segments.sorted {
            if order[$0.recordingID] != order[$1.recordingID] { return order[$0.recordingID]! < order[$1.recordingID]! }
            if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
            if $0.wallClockStart != $1.wallClockStart { return $0.wallClockStart < $1.wallClockStart }
            if $0.track != $1.track { return $0.track == .system }
            return $0.id.uuidString < $1.id.uuidString
        }
        // A named fragment shows its own name, whatever its voice (latest wins).
        // A reply given to a voice follows it while that voice exists.
        func fragment(_ segment: TranscriptSegment) -> FragmentAnchor? {
            anchors.filter { anchor in anchor.covers(segment) && anchor.voiceID.map { speakerMap[$0] != nil } ?? true }
                .max { $0.createdAt < $1.createdAt }
        }
        // Same-day voices the user gave one name are one person: they share
        // blocks. Unnamed voices stay keyed by their own identity.
        func voiceKey(_ id: UUID) -> String {
            if let name = names[id]?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "name:" + name.lowercased()
            }
            return "id:\(id)"
        }
        func person(_ segment: TranscriptSegment) -> String {
            guard case .system(let id) = segment.speaker else { return "microphone" }
            if let anchor = fragment(segment) {
                if let voice = anchor.voiceID { return voiceKey(voice) }
                return "name:" + anchor.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            return voiceKey(id)
        }
        var result: [TranscriptDisplayItem] = []
        var current: [TranscriptSegment] = []
        var furthestActiveEnd = MediaTime.zero
        var furthestWallEnd = Date.distantPast
        var previousDate: String?

        func flush() throws {
            guard let first = current.first else { return }
            let day = recordingMap[first.recordingID]!.days.first { $0.id == first.dayID }!
            let label: String
            let speaker: SpeakerReference
            let anchor = current.lazy.compactMap(fragment).first
            var unidentified = false
            if first.track == .microphone { speaker = .microphone; label = "You" }
            else {
                guard case .system(let own) = first.speaker else { throw TranscriptFormattingError.missingSpeaker }
                let id = anchor?.voiceID ?? own
                speaker = .system(daySpeakerID: id)
                guard let identity = speakerMap[id] else { throw TranscriptFormattingError.missingSpeaker }
                unidentified = anchor == nil && names[id]?.name == nil && identity.unidentified
                label = (anchor?.voiceID == nil ? anchor?.name : nil) ?? names[id]?.name
                    ?? (identity.unidentified ? "Unidentified" : "Voice\(identity.number)")
            }
            var block = TranscriptBlock(recordingID: first.recordingID, dayID: first.dayID,
                speaker: speaker, speakerLabel: label, timestamp: try timestamp(first.wallClockStart, day: day), segments: current)
            block.isNamedFragment = anchor != nil
            block.isAssignedFragment = anchor?.voiceID != nil
            block.isUnidentified = unidentified
            result.append(.speech(block))
            current = []
        }

        for segment in ordered {
            let recording = recordingMap[segment.recordingID]!
            let day = recording.days.first { $0.id == segment.dayID }!
            if let last = current.last {
                // Active gaps are integer microseconds. Wall-clock gaps also
                // prevent a pause (excluded from active time) joining speech.
                let activeGap = segment.interval.start.microseconds - furthestActiveEnd.microseconds
                let wallGap = (segment.wallClockStart.timeIntervalSince(furthestWallEnd) * 1_000_000).rounded()
                if last.recordingID != segment.recordingID || last.dayID != segment.dayID ||
                    last.track != segment.track || person(last) != person(segment) ||
                    activeGap > 2_000_000 || wallGap > 2_000_000 {
                    try flush()
                }
            }
            if previousDate != day.localDate {
                try flush()
                let resumption = previousDate.map { day.localDate > $0 && day.id == recording.days.first?.id } ?? false
                result.append(.date(TranscriptDateSeparator(recordingID: recording.id, dayID: day.id,
                    date: day.localDate, isResumption: resumption)))
                previousDate = day.localDate
            }
            let wallEnd = segment.wallClockStart.addingTimeInterval(segment.interval.duration.seconds)
            if current.isEmpty { furthestActiveEnd = segment.interval.end; furthestWallEnd = wallEnd }
            else {
                furthestActiveEnd = max(furthestActiveEnd, segment.interval.end)
                furthestWallEnd = max(furthestWallEnd, wallEnd)
            }
            current.append(segment)
        }
        try flush()
        return result
    }

    private static func timestamp(_ date: Date, day: RecordingDay) throws -> String {
        guard let zone = TimeZone(secondsFromGMT: day.utcOffsetSeconds) else {
            throw TranscriptFormattingError.invalidWallClock
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
            throw TranscriptFormattingError.invalidWallClock
        }
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}
