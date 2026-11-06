import Foundation
import TalkTrackDomain

/// What a move left to do: a recording with audio but no current final
/// transcript should be queued for transcription in its new meeting.
public struct RecordingMoveResult: Equatable, Sendable {
    public let recording: Recording
    public let needsTranscription: Bool
}

public enum RecordingMoveError: Error, Equatable, LocalizedError, Sendable {
    case missing, capturing, sameMeeting

    public var errorDescription: String? {
        switch self {
        case .missing: "This recording or meeting is unavailable."
        case .capturing: "This recording is still being recorded."
        case .sameMeeting: "The recording is already in this meeting."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missing, .sameMeeting: nil
        case .capturing: "Stop the recording before moving it."
        }
    }
}

extension SessionStore {
    /// Moves one stopped recording, as it is, to another meeting (design D1 of
    /// move-recording): its audio, transcripts, publications, checkpoints,
    /// summary, draft, named fragments and the voices it uses with their names.
    /// No model runs. Rows are copied under the destination with a UUID remap
    /// (meeting id; fresh ids for voices, names and matches, so a voice shared
    /// with another source recording stays there too; canonical days of other
    /// recordings to this recording's day of the same date; the recording
    /// fingerprint), moved voices are numbered after the destination's voices of
    /// the same date, and the source loses the recording as deletion removes it.
    /// One transaction; then the audio folder is renamed, and a failure there is
    /// finished at the next launch.
    @discardableResult
    public func moveRecording(_ recordingID: UUID, from sourceID: UUID, to destinationID: UUID,
                              at date: Date = Date()) throws -> RecordingMoveResult {
        guard sourceID != destinationID else { throw RecordingMoveError.sameMeeting }
        let result = try db.transaction { () -> RecordingMoveResult in
            guard (try? meeting(destinationID)) != nil,
                  let recording = try recordings(meetingID: sourceID).first(where: { $0.id == recordingID }) else {
                throw RecordingMoveError.missing
            }
            guard [.complete, .interrupted].contains(recording.state) else { throw RecordingMoveError.capturing }
            let ownJobs = try jobs(meetingID: sourceID).filter { $0.snapshot.recordingID == recordingID }
            // Unfinished work stays as cancelled history (a late writer finds it
            // cancelled); the destination queues its own transcription.
            for var job in ownJobs where ![.completed, .cancelled].contains(job.stage) {
                job.stage = .cancelled; job.lastError = "The recording was moved to another meeting."
                try saveJob(job)
            }
            let final = try transcript(meetingID: sourceID, recordingID: recordingID)
            let needsTranscription = recording.activeDuration > .zero && !recording.chunks.isEmpty
                && !(final?.kind == .final && final?.sourceGeneration == recording.generation)

            // 1. The recording's rows and the heads that point at them.
            let s = sourceID.uuidString, r = recordingID.uuidString
            var rows: [MovedRow] = try db.rows("SELECT kind,id,scope,payload FROM records WHERE meeting_id=? AND scope=?",
                                               [.text(s), .text(r)]).map(MovedRow.init)
            let jobIDs = Set(ownJobs.map(\.id.uuidString))
            rows += try db.rows("SELECT kind,id,scope,payload FROM records WHERE meeting_id=? AND kind IN ('job','summarySource','finalCheckpoint')",
                                [.text(s)]).map(MovedRow.init).filter { jobIDs.contains($0.id) }
            let anchors: [FragmentAnchor] = try records(.fragmentAnchor, meetingID: sourceID)
            let anchorIDs = Set(anchors.filter { $0.recordingID == recordingID }.map(\.id.uuidString))
            rows += try db.rows("SELECT kind,id,scope,payload FROM records WHERE meeting_id=? AND kind='fragmentAnchor'",
                                [.text(s)]).map(MovedRow.init).filter { anchorIDs.contains($0.id) }
            rows = rows.reduce(into: [MovedRow]()) { list, row in
                if !list.contains(where: { $0.kind == row.kind && $0.id == row.id }) { list.append(row) }
            }
            // 2. Voices those rows mention, with their names and matches.
            let text = rows.map(\.payload).joined()
            let speakers = try daySpeakers(meetingID: sourceID).filter { text.contains($0.id.uuidString) }
            let speakerIDs = Set(speakers.map(\.id.uuidString))
            let named = try db.rows("SELECT kind,id,scope,payload FROM records WHERE meeting_id=? AND kind IN ('assignment','automaticVoiceMatch')",
                                    [.text(s)]).map(MovedRow.init).filter { speakerIDs.contains($0.scope) }
            rows += try db.rows("SELECT kind,id,scope,payload FROM records WHERE meeting_id=? AND kind='daySpeaker'",
                                [.text(s)]).map(MovedRow.init).filter { speakerIDs.contains($0.id) }
            rows += named
            let moved = Set(rows.map { $0.kind + "/" + $0.id })
            let heads = try db.rows("SELECT kind,scope,id FROM heads WHERE meeting_id=?", [.text(s)]).compactMap { row -> (String, String, String)? in
                guard case .text(let kind) = row[0], case .text(let scope) = row[1], case .text(let id) = row[2],
                      moved.contains(kind + "/" + id) else { return nil }
                return (kind, scope, id)
            }

            // 3. The remap.
            var remap: [String: String] = [s: destinationID.uuidString]
            for speaker in speakers { remap[speaker.id.uuidString] = UUID().uuidString }
            for row in named { remap[row.id] = UUID().uuidString }
            let ownDays = Set(recording.days.map(\.id))
            for speaker in speakers where !ownDays.contains(speaker.dayID) {
                guard let day = recording.days.first(where: { speaker.recordingDayIDs.contains($0.id) }) else { throw StoreError.invalidResult }
                remap[speaker.dayID.uuidString] = day.id.uuidString
            }
            let movedRecording = try DomainCodec.decode(Recording.self, from: Data(Self.remapped(
                rows.first { $0.kind == RecordKind.recording.rawValue }?.payload ?? "", remap).utf8))
            let oldPrint = try Self.fingerprint(recording), newPrint = try Self.fingerprint(movedRecording)

            // 4. Voice numbers after the destination's on the same date.
            let destinationDays = try recordings(meetingID: destinationID).flatMap(\.days)
            let localDate = Dictionary((destinationDays + recording.days + (try recordings(meetingID: sourceID).flatMap(\.days)))
                .map { ($0.id, $0.localDate) }, uniquingKeysWith: { first, _ in first })
            var numbers: [String: UInt] = [:]
            for (date, group) in Dictionary(grouping: speakers.filter { !$0.unidentified }, by: { localDate[$0.dayID] ?? "" }) {
                var next = try daySpeakers(meetingID: destinationID)
                    .filter { !$0.unidentified && localDate[$0.dayID] == date }.map(\.number).max() ?? 0
                for speaker in group.sorted(by: { $0.number < $1.number }) {
                    next += 1
                    numbers[remap[speaker.id.uuidString]!] = next
                }
            }

            // 5. The source loses the recording; the destination gains the copies.
            try removeRecordingRows(meetingID: sourceID, recording: recording, reason: "A recording of this meeting was moved to another meeting.")
            let d = SQLValue.text(destinationID.uuidString)
            for row in rows {
                var payload = Self.remapped(row.payload, remap).replacingOccurrences(of: oldPrint, with: newPrint)
                if numbers.keys.contains(where: { payload.contains($0) }) { payload = try Self.renumbered(payload, numbers) }
                if row.kind == RecordKind.assignment.rawValue {
                    // Names keep only this recording's speech as evidence.
                    let value = try DomainCodec.decode(SpeakerAssignment.self, from: Data(payload.utf8))
                    let own = SpeakerAssignment(id: value.id, meetingID: value.meetingID, dayID: value.dayID, daySpeakerID: value.daySpeakerID,
                        name: value.name, origin: value.origin, evidence: value.evidence.filter { $0.recordingID == recordingID },
                        createdAt: value.createdAt)
                    payload = String(decoding: try DomainCodec.encode(own), as: UTF8.self)
                }
                try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES (?,?,?,?,?)",
                    [.text(row.kind), .text(remap[row.id] ?? row.id), d, .text(Self.remapped(row.scope, remap)), .blob(Data(payload.utf8))])
            }
            for (kind, scope, id) in heads {
                try db.execute("INSERT INTO heads(meeting_id,kind,scope,id) VALUES (?,?,?,?) ON CONFLICT(meeting_id,kind,scope) DO UPDATE SET id=excluded.id",
                    [d, .text(kind), .text(Self.remapped(scope, remap)), .text(remap[id] ?? id)])
            }
            var owner = try meeting(destinationID)
            owner.latestRecordingStartedAt = max(owner.latestRecordingStartedAt ?? .distantPast, movedRecording.startedAt)
            owner.generation += 1
            try update(owner)
            // Anything inconsistent rolls the whole move back.
            _ = try meetingTranscript(meetingID: destinationID)
            _ = try meetingTranscript(meetingID: sourceID)
            return RecordingMoveResult(recording: movedRecording, needsTranscription: needsTranscription)
        }
        voiceGroups = [:]; replyClusters = [:]
        // Committed; a folder left behind is moved at the next launch.
        try? relocateRecordingFolder(recordingID, from: sourceID, to: destinationID)
        return result
    }

    /// The meeting a recording belongs to now, or nil when it is not recorded
    /// (deleted, or never published). Saved voices keep the meeting they were
    /// confirmed in; a moved recording is found here.
    public func recordingMeetingID(_ recordingID: UUID) throws -> UUID? {
        guard case .text(let id) = try db.rows("SELECT meeting_id FROM records WHERE kind='recording' AND id=?",
                                               [.text(recordingID.uuidString)]).first?.first else { return nil }
        return UUID(uuidString: id)
    }

    /// Renames `Meetings/<source>/Recordings/<recording>` into the destination
    /// and rewrites its manifest's meeting id. Nothing to do when it is absent.
    func relocateRecordingFolder(_ recordingID: UUID, from sourceID: UUID, to destinationID: UUID) throws {
        let name = recordingID.uuidString
        let meetings = try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
        guard meetings.exists(sourceID.uuidString) else { return }
        let source = try meetings.directory(sourceID.uuidString)
        guard source.exists("Recordings") else { return }
        let from = try source.directory("Recordings")
        guard from.exists(name) else { return }
        let to = try meetings.createDirectory(destinationID.uuidString).createDirectory("Recordings")
        guard renameatx_np(from.fd, name, to.fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw LibraryError.io(operation: "move the recording folder", code: errno)
        }
        try from.syncAudioDirectory(); try to.syncAudioDirectory()
        let folder = try to.directory(name)
        if folder.exists("manifest.json") {
            let manifest = String(decoding: try folder.read("manifest.json", maximum: 16_777_216), as: UTF8.self)
            try folder.replace("manifest.json", data: Data(manifest.replacingOccurrences(of: sourceID.uuidString, with: destinationID.uuidString).utf8))
        }
    }

    /// Launch: a recording whose folder is missing under its meeting but present
    /// under another meeting's folder (a move interrupted after its commit) gets
    /// its folder moved where the library says it is.
    func reconcileMovedRecordingFolders() throws {
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        guard owned.exists("Meetings") else { return }
        let meetings = try owned.directory("Meetings")
        let folders = try meetings.names().filter { UUID(uuidString: $0)?.uuidString == $0 }
        for row in try db.rows("SELECT meeting_id,id FROM records WHERE kind='recording'") {
            guard case .text(let meeting) = row[0], case .text(let id) = row[1],
                  let meetingID = UUID(uuidString: meeting), let recordingID = UUID(uuidString: id) else { continue }
            func has(_ folder: String) -> Bool {
                guard meetings.exists(folder), let handle = try? meetings.directory(folder), handle.exists("Recordings"),
                      let recordings = try? handle.directory("Recordings") else { return false }
                return recordings.exists(id)
            }
            guard !has(meeting), let holder = folders.first(where: { $0 != meeting && has($0) }),
                  let holderID = UUID(uuidString: holder) else { continue }
            try relocateRecordingFolder(recordingID, from: holderID, to: meetingID)
        }
    }

    /// Replaces every UUID that `remap` names; UUIDs are encoded uppercase.
    static func remapped(_ text: String, _ remap: [String: String]) -> String {
        text.replacing(/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/) { match in
            remap[String(match.output)] ?? String(match.output)
        }
    }

    /// Sets `number` on every encoded day speaker (an object with `id`, `dayID`
    /// and `number`) whose id `numbers` names, wherever it is embedded.
    static func renumbered(_ payload: String, _ numbers: [String: UInt]) throws -> String {
        func walk(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                for (key, child) in object { object[key] = walk(child) }
                if let id = object["id"] as? String, object["dayID"] != nil, object["number"] != nil, let number = numbers[id] {
                    object["number"] = number
                }
                return object
            }
            if let array = value as? [Any] { return array.map(walk) }
            return value
        }
        let tree = walk(try JSONSerialization.jsonObject(with: Data(payload.utf8)))
        return String(decoding: try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// One stored row as text, for copying under another meeting.
struct MovedRow {
    let kind: String, id: String, scope: String, payload: String

    init(_ row: [SQLValue]) throws {
        guard case .text(let kind) = row[0], case .text(let id) = row[1], case .text(let scope) = row[2],
              case .blob(let data) = row[3] else { throw StoreError.invalidResult }
        self.kind = kind; self.id = id; self.scope = scope
        payload = String(decoding: data, as: UTF8.self)
    }
}
