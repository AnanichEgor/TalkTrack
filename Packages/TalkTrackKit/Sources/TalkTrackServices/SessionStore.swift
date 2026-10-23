import Foundation
import CryptoKit
import TalkTrackDomain

public actor SessionStore {
    static let schemaVersion = 3
    static let applicationID = 0x54414C4B
    public nonisolated let library: OpenedLibrary
    private var connection: SQLiteConnection?
    private var finalJobOwners: [UUID: UUID] = [:]
    /// Standard voices per final checkpoint (by job ID); checkpoints of
    /// completed jobs do not change, so one computation serves the session.
    private var voiceGroups: [UUID: SpeakerVoiceGroups] = [:]
    private var replyClusters: [UUID: ReplyClusters] = [:]
    private var db: SQLiteConnection {
        get throws {
            guard let connection else { throw StoreError.database("Library is closed") }
            return connection
        }
    }

    private init(library: OpenedLibrary) { self.library = library }

    public static func open(_ library: OpenedLibrary) async throws -> SessionStore {
        let store = SessionStore(library: library)
        try await store.prepare()
        return store
    }

    private func prepare() throws {
        let directory = try DirectoryHandle.openAbsolute(library.directory)
        let path = DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        let file = "/" + path + "/Library.sqlite3"
        let existing = directory.exists("Library.sqlite3")
        // With a WAL present, only SQLite can read the committed schema. With
        // no journal, refuse newer/foreign headers without creating sidecars.
        if existing {
            if !directory.exists("Library.sqlite3-wal") && !directory.exists("Library.sqlite3-journal") {
                let header = try SQLiteConnection.closedHeader(in: directory)
                guard header.version <= Self.schemaVersion else { throw StoreError.unsupportedSchema(header.version) }
                guard header.applicationID == Self.applicationID else { throw StoreError.wrongLibrary }
            } else {
                try validateDatabase(SQLiteConnection(path: file, readOnly: true))
            }
        }
        let db = try SQLiteConnection(path: file)
        if existing { try validateDatabase(db) }
        let version = try db.integer("PRAGMA user_version")
        let libraryID = library.manifest.libraryID.uuidString
        if version == 0 {
            try db.transaction {
                try db.execute("PRAGMA application_id = \(Self.applicationID)")
                try db.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try db.execute("INSERT INTO metadata VALUES ('libraryID', ?)", [.text(libraryID)])
                try db.execute("CREATE TABLE meetings (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                try db.execute("CREATE TABLE tombstones (id TEXT PRIMARY KEY, deleted_at REAL NOT NULL)")
                try db.execute("CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, scope TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
                try db.execute("CREATE TABLE heads (meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, kind TEXT NOT NULL, scope TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(meeting_id,kind,scope))")
                try db.execute("PRAGMA user_version = 1")
            }
        }
        try migrate(db, file: file)
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = FULL")
        connection = db
        _ = try recoverInterruptedJobs()
        // Files of recordings deleted just before a crash; a failure is retried next launch.
        for (meetingID, recordingID) in try deletedRecordings() { try? removeRecordingFolder(meetingID: meetingID, recordingID: recordingID) }
    }

    private func validateDatabase(_ db: SQLiteConnection) throws {
        let version = try db.integer("PRAGMA user_version")
        guard version <= Self.schemaVersion else { throw StoreError.unsupportedSchema(version) }
        guard try db.integer("PRAGMA application_id") == Self.applicationID else { throw StoreError.wrongLibrary }
        guard case .text(let id) = try db.rows("SELECT value FROM metadata WHERE key = 'libraryID'").first?.first,
              id == library.manifest.libraryID.uuidString else { throw StoreError.wrongLibrary }
    }

    private func migrate(_ db: SQLiteConnection, file: String) throws {
        if try db.integer("PRAGMA user_version") == 1 {
            let backup = file + ".before-v2-\(UUID().uuidString).backup"
            try db.backup(to: backup)
            try db.transaction {
                try db.execute("CREATE TABLE pending_edits (meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE, payload BLOB NOT NULL)")
                try db.execute("CREATE INDEX records_meeting ON records(meeting_id,kind,scope)")
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if try db.integer("PRAGMA user_version") == 2 {
            try db.transaction {
                // A deleted recording's id, so a leftover audio folder is removed
                // instead of being recovered as an orphan recording.
                try db.execute("CREATE TABLE recording_tombstones (id TEXT PRIMARY KEY, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, deleted_at REAL NOT NULL)")
                try db.execute("PRAGMA user_version = 3")
            }
        }
    }

    public func checkpoint() throws {
        guard case .integer(0) = try db.rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.first else {
            throw StoreError.database("Library is busy; retry after pending writes finish")
        }
    }

    public func close() throws {
        try checkpoint()
        connection = nil
    }

    public func createMeeting(_ draft: MeetingDraft, id: UUID = UUID(), at date: Date = Date()) throws -> Meeting {
        let meeting = Meeting(id: id, draft: draft, createdAt: date)
        return try db.transaction {
            guard try db.rows("SELECT id FROM tombstones WHERE id = ?", [.text(id.uuidString)]).isEmpty else { throw StoreError.missingMeeting }
            try db.execute("INSERT INTO meetings(id,payload) VALUES (?,?)", [.text(id.uuidString), .blob(DomainCodec.encode(meeting))])
            return meeting
        }
    }

    public func meeting(_ id: UUID) throws -> Meeting {
        guard case .blob(let data) = try db.rows("SELECT payload FROM meetings WHERE id = ?", [.text(id.uuidString)]).first?.first else {
            throw StoreError.missingMeeting
        }
        return try DomainCodec.decode(Meeting.self, from: data)
    }

    public func meetings(search: String = "") throws -> [Meeting] {
        let values: [Meeting] = try db.rows("SELECT payload FROM meetings").map {
            guard case .blob(let data) = $0[0] else { throw StoreError.database("Invalid meeting record") }
            return try DomainCodec.decode(Meeting.self, from: data)
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let query = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return values.filter {
            query.isEmpty || ($0.title + "\n" + $0.description)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).contains(query)
        }.sorted {
            if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Changes the title and, when given, the description. Neither affects
    /// recordings, transcripts or generated outputs.
    public func renameMeeting(_ id: UUID, title: String, description: String? = nil) throws {
        let draft = try MeetingDraft(title: title, description: description ?? "")
        try db.transaction {
            var value = try meeting(id)
            value.title = draft.title
            if description != nil { value.description = draft.description }
            try update(value)
        }
    }

    public func setMeetingLanguage(_ id: UUID, language: MeetingLanguage) throws {
        try db.transaction {
            var value = try meeting(id)
            guard value.language != language else { return }
            value.language = language
            value.generation += 1
            try update(value)
        }
    }

    public func saveRecording(_ recording: Recording) throws {
        try db.transaction {
            var owner = try meeting(recording.meetingID)
            guard try !isDeletedRecording(recording.id) else { throw RecordingDeletionError.missing }
            if let previous: Recording = try record(.recording, id: recording.id) {
                if previous == recording { return }
                guard previous.meetingID == recording.meetingID, previous.startedAt == recording.startedAt,
                      recording.generation > previous.generation else { throw StoreError.staleSource }
            }
            try put(.recording, id: recording.id, meetingID: owner.id, scope: recording.id.uuidString, value: recording)
            owner.latestRecordingStartedAt = max(owner.latestRecordingStartedAt ?? .distantPast, recording.startedAt)
            owner.generation += 1
            try update(owner)
        }
    }

    public func recordings(meetingID: UUID) throws -> [Recording] {
        _ = try meeting(meetingID)
        return try records(.recording, meetingID: meetingID).sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
    }

    /// Tombstone and cascades commit together before any file cleanup. Late
    /// writers can only update existing meetings, never upsert the parent.
    public func deleteMeeting(_ id: UUID, at date: Date = Date()) throws {
        try db.transaction {
            _ = try meeting(id)
            try db.execute("INSERT INTO tombstones VALUES (?,?)", [.text(id.uuidString), .real(date.timeIntervalSince1970)])
            try db.execute("DELETE FROM meetings WHERE id = ?", [.text(id.uuidString)])
        }
        try cleanupDeletedMeeting(id)
    }

    /// Permanently removes one stopped recording: its audio, transcripts,
    /// checkpoints, jobs, summary and fragment names, and day speakers of capture
    /// days no other recording shares. The meeting translation is trimmed to the
    /// other recordings without a model. A tombstone commits with the rows, then
    /// the folder is removed; a crash or failure before that is finished at the next launch.
    /// Notes, other recordings and saved global voices stay.
    public func deleteRecording(meetingID: UUID, recordingID: UUID, at date: Date = Date()) throws {
        try db.transaction {
            var owner = try meeting(meetingID)
            guard let recording = try recordings(meetingID: meetingID).first(where: { $0.id == recordingID }) else {
                throw RecordingDeletionError.missing
            }
            guard [.complete, .interrupted].contains(recording.state) else { throw RecordingDeletionError.capturing }
            let m = SQLValue.text(meetingID.uuidString), r = SQLValue.text(recordingID.uuidString)
            try db.execute("INSERT INTO recording_tombstones VALUES (?,?,?)", [r, m, .real(date.timeIntervalSince1970)])
            // Translation first: it reads the transcript and speakers that go next.
            try trimTranslation(meetingID: meetingID, removing: recording)
            // Jobs of this recording with their sources and publication heads.
            let jobs = try jobs(meetingID: meetingID).filter { $0.snapshot.recordingID == recordingID }
            for job in jobs {
                let id = SQLValue.text(job.id.uuidString)
                try db.execute("DELETE FROM records WHERE meeting_id=? AND id=? AND kind IN ('job','summarySource','translationSource','finalCheckpoint')", [m, id])
                try db.execute("DELETE FROM heads WHERE meeting_id=? AND scope=?", [m, id])
            }
            // Fragment names and voices given to its replies.
            let anchors: [FragmentAnchor] = try records(.fragmentAnchor, meetingID: meetingID)
            for anchor in anchors where anchor.recordingID == recordingID {
                try db.execute("DELETE FROM records WHERE kind='fragmentAnchor' AND id=?", [.text(anchor.id.uuidString)])
                try db.execute("DELETE FROM heads WHERE kind='fragmentAnchor' AND meeting_id=? AND scope=?", [m, .text(anchor.segmentID.uuidString)])
            }
            // Day speakers whose capture days only this recording had.
            let remaining = Set(try recordings(meetingID: meetingID).filter { $0.id != recordingID }.flatMap { $0.days.map(\.id) })
            let speakers: [DaySpeaker] = try records(.daySpeaker, meetingID: meetingID)
            for speaker in speakers where Set(speaker.recordingDayIDs).union([speaker.dayID]).isDisjoint(with: remaining)
                && !Set(speaker.recordingDayIDs).union([speaker.dayID]).isDisjoint(with: recording.days.map(\.id)) {
                let id = SQLValue.text(speaker.id.uuidString)
                try db.execute("DELETE FROM records WHERE kind='daySpeaker' AND id=?", [id])
                try db.execute("DELETE FROM records WHERE meeting_id=? AND kind IN ('assignment','automaticVoiceMatch') AND scope=?", [m, id])
                try db.execute("DELETE FROM heads WHERE meeting_id=? AND scope=?", [m, id])
            }
            // The recording, its transcripts, publications, checkpoints and summaries.
            try db.execute("DELETE FROM records WHERE meeting_id=? AND scope=?", [m, r])
            try db.execute("DELETE FROM heads WHERE meeting_id=? AND scope=?", [m, r])
            // A translation still running covers this recording; it cannot publish.
            for var job in try self.jobs(meetingID: meetingID) where job.snapshot.kind == .translation
                && ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains(job.stage) {
                job.stage = .cancelled; job.lastError = "A recording of this meeting was deleted."
                try saveJob(job)
            }
            owner.generation += 1
            owner.latestRecordingStartedAt = try recordings(meetingID: meetingID).map(\.startedAt).max()
            try update(owner)
        }
        voiceGroups = [:]; replyClusters = [:]
        // The deletion is committed; files left by a failure are removed at the next launch.
        try? removeRecordingFolder(meetingID: meetingID, recordingID: recordingID)
    }

    /// Recordings deleted in this library, for recovery to skip.
    public func isDeletedRecording(_ id: UUID) throws -> Bool {
        !(try db.rows("SELECT id FROM recording_tombstones WHERE id = ?", [.text(id.uuidString)])).isEmpty
    }

    private func deletedRecordings() throws -> [(UUID, UUID)] {
        try db.rows("SELECT meeting_id, id FROM recording_tombstones").compactMap {
            guard case .text(let m) = $0[0], case .text(let r) = $0[1], let meeting = UUID(uuidString: m),
                  let recording = UUID(uuidString: r) else { return nil }
            return (meeting, recording)
        }
    }

    /// Removes `Meetings/<meeting>/Recordings/<recording>`; only a tombstoned recording.
    func removeRecordingFolder(meetingID: UUID, recordingID: UUID) throws {
        guard try isDeletedRecording(recordingID) else { throw StoreError.invalidResult }
        let meetings = try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
        guard meetings.exists(meetingID.uuidString) else { return }
        let meeting = try meetings.directory(meetingID.uuidString)
        guard meeting.exists("Recordings") else { return }
        try meeting.directory("Recordings").removeTree(recordingID.uuidString)
    }

    /// Keeps the translated utterances of the other recordings, with a frozen
    /// source and snapshot that no longer include this one, so the result is
    /// exactly as current (or outdated) as before. Nothing left: no translation.
    private func trimTranslation(meetingID: UUID, removing recording: Recording) throws {
        guard let output: GeneratedOutput = try head(.translation, meetingID: meetingID),
              let source: TranslationSource = try record(.translationSource, id: output.job.id) else { return }
        let revisions = source.revisions.filter { $0.recordingID != recording.id }
        guard revisions.count != source.revisions.count else { return }
        guard revisions.contains(where: { !$0.segments.isEmpty }) else {
            try db.execute("DELETE FROM heads WHERE meeting_id=? AND kind='translation' AND scope=''", [.text(meetingID.uuidString)])
            return
        }
        let removedSegments = Set(source.revisions.filter { $0.recordingID == recording.id }.flatMap(\.segments).map(\.id))
        let removedRevisions = Set(source.revisions.filter { $0.recordingID == recording.id }.map(\.id))
        let recordings = source.recordings.filter { $0.id != recording.id }
        // Voices the remaining text still uses, and the names given to them.
        let voices = Set(revisions.flatMap(\.segments).compactMap { segment -> UUID? in
            if case .system(let id) = segment.speaker { id } else { nil }
        })
        let removedDays = Set(recording.days.map(\.id)).subtracting(recordings.flatMap { $0.days.map(\.id) })
        let speakers = source.speakers.filter { voices.contains($0.id) || Set($0.recordingDayIDs).union([$0.dayID]).isDisjoint(with: removedDays) }
        let kept = Set(speakers.map(\.id))
        let old = output.job, snapshot = old.source
        var generations = snapshot.recordingGenerations
        generations[recording.id] = nil
        let job = ProcessingJobSnapshot(kind: old.kind, recordingID: old.recordingID,
            source: SourceSnapshot(meetingID: snapshot.meetingID, meetingGeneration: snapshot.meetingGeneration,
                cancellationGeneration: snapshot.cancellationGeneration, recordingGenerations: generations,
                transcriptRevisionIDs: snapshot.transcriptRevisionIDs.filter { !removedRevisions.contains($0) },
                notesRevisionID: snapshot.notesRevisionID),
            settings: old.settings, models: old.models, createdAt: old.createdAt)
        let trimmed = TranslationSource(job: job, recordings: recordings, revisions: revisions, speakers: speakers,
                                        assignments: source.assignments.filter { kept.contains($0.daySpeakerID) })
        let segments = output.translatedSegments.filter { !removedSegments.contains($0.sourceSegmentID) }
        let text = try trimmed.items(translations: segments).map(\.text).joined(separator: "\n\n")
        let result = GeneratedOutput(kind: .translation, job: job, text: text, translatedSegments: segments, createdAt: output.createdAt)
        try put(.translationSource, id: job.id, meetingID: meetingID, value: trimmed)
        try put(.translation, id: result.id, meetingID: meetingID, value: result)
        try setHead(.translation, meetingID: meetingID, id: result.id)
    }

    public func cleanupDeletedMeeting(_ id: UUID) throws {
        guard !(try db.rows("SELECT id FROM tombstones WHERE id = ?", [.text(id.uuidString)])).isEmpty else {
            throw StoreError.invalidResult
        }
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        let meetings = try owned.directory("Meetings")
        try meetings.removeTree(id.uuidString)
    }

    private func update(_ meeting: Meeting) throws {
        try db.execute("UPDATE meetings SET payload = ? WHERE id = ?", [.blob(DomainCodec.encode(meeting)), .text(meeting.id.uuidString)])
    }

    public func notes(meetingID: UUID) throws -> NotesRevision? {
        _ = try meeting(meetingID)
        return try head(.notes, meetingID: meetingID)
    }

    public func stageNotes(_ revision: NotesRevision) throws {
        _ = try meeting(revision.meetingID)
        // Independent recovery file survives a failed SQLite write. The UI
        // retains its in-memory text if the filesystem write itself fails.
        let recovery = try notesRecovery(revision.meetingID)
        try recovery.replace("notes.json", data: DomainCodec.encode(revision))
        try db.execute("INSERT INTO pending_edits VALUES (?,?) ON CONFLICT(meeting_id) DO UPDATE SET payload=excluded.payload",
            [.text(revision.meetingID.uuidString), .blob(DomainCodec.encode(revision))])
    }

    public func pendingNotes(meetingID: UUID) throws -> NotesRevision? {
        _ = try meeting(meetingID)
        let recovery = try notesRecovery(meetingID)
        if recovery.exists("notes.json") {
            let revision = try DomainCodec.decode(NotesRevision.self, from: recovery.read("notes.json", maximum: 64 * 1024 * 1024))
            guard revision.meetingID == meetingID else { throw StoreError.invalidResult }
            // A crash after commit but before cleanup is safe and idempotent.
            if try notes(meetingID: meetingID)?.id == revision.id { return nil }
            return revision
        }
        guard case .blob(let data) = try db.rows("SELECT payload FROM pending_edits WHERE meeting_id=?", [.text(meetingID.uuidString)]).first?.first else { return nil }
        return try DomainCodec.decode(NotesRevision.self, from: data)
    }

    public func commitNotes(_ revision: NotesRevision) throws {
        try db.transaction {
            var owner = try meeting(revision.meetingID)
            if try notes(meetingID: owner.id)?.id == revision.id { return }
            if let pending = try pendingNotes(meetingID: owner.id), pending.id != revision.id { throw StoreError.staleSource }
            try put(.notes, id: revision.id, meetingID: owner.id, value: revision)
            try setHead(.notes, meetingID: owner.id, id: revision.id)
            try db.execute("DELETE FROM pending_edits WHERE meeting_id=?", [.text(owner.id.uuidString)])
            owner.generation += 1
            try update(owner)
        }
        try notesRecovery(revision.meetingID).removeFile("notes.json")
    }

    private func notesRecovery(_ meetingID: UUID) throws -> DirectoryHandle {
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        return try owned.directory("Meetings").createDirectory(meetingID.uuidString).createDirectory("Recovery")
    }

    public func sourceSnapshot(meetingID: UUID) throws -> SourceSnapshot {
        let owner = try meeting(meetingID)
        let recordings = try recordings(meetingID: meetingID)
        let revisions: [UUID] = try recordings.compactMap { recording in
            let revision: TranscriptRevision? = try head(.transcript, meetingID: meetingID, scope: recording.id.uuidString)
            return revision?.id
        }
        return SourceSnapshot(meetingID: meetingID, meetingGeneration: owner.generation,
            cancellationGeneration: owner.cancellationGeneration,
            recordingGenerations: Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0.generation) }),
            transcriptRevisionIDs: revisions, notesRevisionID: try notes(meetingID: meetingID)?.id)
    }

    public static func fingerprint<T: Codable>(_ value: T) throws -> String {
        SHA256.hash(data: try DomainCodec.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    public func enqueue(kind: JobKind, meetingID: UUID, recordingID: UUID? = nil,
                        settings: ProcessingSettings, models: [ModelSnapshot]) throws -> ProcessingJob {
        try db.transaction {
            let source = try sourceSnapshot(meetingID: meetingID)
            if kind == .finalTranscription {
                guard let recordingID, source.recordingGenerations[recordingID] != nil else { throw StoreError.invalidResult }
            } else if recordingID != nil { throw StoreError.invalidResult }
            let job = ProcessingJob(snapshot: ProcessingJobSnapshot(kind: kind, recordingID: recordingID,
                source: source, settings: settings, models: models))
            try saveJob(job)
            return job
        }
    }

    /// Enqueue one recording's summary and freeze its source in one transaction.
    /// Stop only enqueues final transcription; this is reserved for explicit actions.
    public func enqueueSummary(meetingID: UUID, recordingID: UUID, settings: ProcessingSettings,
                               model: ModelSnapshot) throws -> ProcessingJob {
        try db.transaction { try writeSummaryJob(meetingID: meetingID, recordingID: recordingID, settings: settings, model: model) }
    }

    /// `Generate Summaries`: one job per recording whose final transcript is
    /// ready and whose summary is missing or outdated under `settings`.
    /// Recordings with an active summary job or unfinished final text are skipped.
    public func enqueueSummaries(meetingID: UUID, settings: ProcessingSettings, model: ModelSnapshot) throws -> [ProcessingJob] {
        try db.transaction {
            var queued: [ProcessingJob] = []
            for recording in try recordings(meetingID: meetingID) {
                guard (try? requireSummarySource(meetingID: meetingID, recordingID: recording.id)) != nil,
                      try activeSummaryJob(meetingID: meetingID, recordingID: recording.id) == nil else { continue }
                if let current = try summary(meetingID: meetingID, recordingID: recording.id),
                   try !isOutdated(current, settings: settings) { continue }
                queued.append(try writeSummaryJob(meetingID: meetingID, recordingID: recording.id, settings: settings, model: model))
            }
            return queued
        }
    }

    private func writeSummaryJob(meetingID: UUID, recordingID: UUID, settings: ProcessingSettings,
                                 model: ModelSnapshot) throws -> ProcessingJob {
        guard model.role == .summary,
              SummaryTemplates.template(settings.summaryType, version: settings.templateVersion) != nil else {
            throw SummaryGenerationError.invalidRequest
        }
        try requireSummarySource(meetingID: meetingID, recordingID: recordingID)
        guard try activeSummaryJob(meetingID: meetingID, recordingID: recordingID) == nil else { throw SummaryJobError.alreadyQueued }
        let transcript = try meetingTranscript(meetingID: meetingID)
        guard let recording = transcript.recordings.first(where: { $0.id == recordingID }),
              let revision = transcript.revisions.first(where: { $0.recordingID == recordingID }) else { throw SummaryJobError.finalRequired }
        let voices = Set(revision.segments.compactMap { segment -> UUID? in
            if case .system(let id) = segment.speaker { id } else { nil }
        })
        let job = ProcessingJob(snapshot: ProcessingJobSnapshot(kind: .summary, recordingID: recordingID,
            source: try sourceSnapshot(meetingID: meetingID), settings: settings, models: [model]))
        try saveJob(job)
        // Notes are not summary input (user decision, 2026-10-13).
        let source = SummarySource(job: job.snapshot, meeting: transcript.meeting, notes: nil,
            recordings: [recording], revisions: [revision],
            speakers: transcript.speakers.filter { voices.contains($0.id) },
            assignments: transcript.assignments.filter { voices.contains($0.daySpeakerID) })
        try put(.summarySource, id: job.id, meetingID: meetingID, value: source)
        return job
    }

    private func activeSummaryJob(meetingID: UUID, recordingID: UUID?) throws -> ProcessingJob? {
        try jobs(meetingID: meetingID).first {
            $0.snapshot.kind == .summary && $0.snapshot.recordingID == recordingID &&
                ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains($0.stage)
        }
    }

    /// One recording needs a current final head and no unfinished final attempt.
    public func requireSummarySource(meetingID: UUID, recordingID: UUID) throws {
        guard let recording = try recordings(meetingID: meetingID).first(where: { $0.id == recordingID }),
              [.complete, .interrupted].contains(recording.state),
              let revision = try transcript(meetingID: meetingID, recordingID: recording.id),
              revision.kind == .final, revision.sourceGeneration == recording.generation else {
            throw SummaryJobError.finalRequired
        }
        if let latest = try jobs(meetingID: meetingID).last(where: {
            $0.snapshot.kind == .finalTranscription && $0.snapshot.recordingID == recording.id
        }), latest.stage != .completed { throw SummaryJobError.finalRequired }
    }

    /// Every recording needs a current final head (translation covers them all).
    public func requireSummarySource(meetingID: UUID) throws {
        let recordings = try recordings(meetingID: meetingID)
        guard !recordings.isEmpty else { throw SummaryJobError.finalRequired }
        for recording in recordings { try requireSummarySource(meetingID: meetingID, recordingID: recording.id) }
    }

    /// The current summary of each recording that has one.
    public func summaries(meetingID: UUID) throws -> [UUID: GeneratedOutput] {
        var result: [UUID: GeneratedOutput] = [:]
        for recording in try recordings(meetingID: meetingID) {
            if let value = try summary(meetingID: meetingID, recordingID: recording.id) { result[recording.id] = value }
        }
        return result
    }

    public func summary(meetingID: UUID, recordingID: UUID) throws -> GeneratedOutput? {
        _ = try meeting(meetingID)
        return try head(.summary, meetingID: meetingID, scope: recordingID.uuidString)
    }

    public func summarySource(jobID: UUID) throws -> SummarySource {
        let job = try activeJob(jobID)
        guard job.snapshot.kind == .summary,
              let source: SummarySource = try record(.summarySource, id: jobID), source.job == job.snapshot else {
            throw StoreError.invalidResult
        }
        return source
    }

    public func requireTranslationSource(meetingID: UUID) throws {
        do { try requireSummarySource(meetingID: meetingID) }
        catch SummaryJobError.finalRequired { throw TranslationError.finalRequired }
    }

    public func enqueueTranslation(meetingID: UUID, settings: ProcessingSettings, model: ModelSnapshot) throws -> ProcessingJob {
        try db.transaction {
            guard model.role == .translation, settings.templateVersion == IndexedTranslation.version else {
                throw TranslationError.invalidRequest
            }
            try requireTranslationSource(meetingID: meetingID)
            guard !(try jobs(meetingID: meetingID)).contains(where: { $0.snapshot.kind == .translation &&
                ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains($0.stage) }) else {
                throw TranslationError.alreadyQueued
            }
            let transcript = try meetingTranscript(meetingID: meetingID)
            let job = ProcessingJob(snapshot: ProcessingJobSnapshot(kind: .translation,
                source: try sourceSnapshot(meetingID: meetingID), settings: settings, models: [model]))
            try saveJob(job)
            let source = TranslationSource(job: job.snapshot, recordings: transcript.recordings, revisions: transcript.revisions,
                speakers: transcript.speakers, assignments: transcript.assignments)
            try put(.translationSource, id: job.id, meetingID: meetingID, value: source)
            return job
        }
    }

    public func translationSource(jobID: UUID) throws -> TranslationSource {
        let job = try activeJob(jobID)
        guard job.snapshot.kind == .translation,
              let source: TranslationSource = try record(.translationSource, id: jobID), source.job == job.snapshot else {
            throw StoreError.invalidResult
        }
        return source
    }

    public func translatedItems(_ output: GeneratedOutput) throws -> [TranscriptDisplayItem] {
        _ = try meeting(output.job.source.meetingID)
        guard output.kind == .translation,
              let source: TranslationSource = try record(.translationSource, id: output.job.id), source.job == output.job else {
            throw StoreError.invalidResult
        }
        return try source.items(translations: output.translatedSegments)
    }

    public func job(_ id: UUID) throws -> ProcessingJob {
        guard let value: ProcessingJob = try record(.job, id: id) else { throw StoreError.cancelledJob }
        _ = try meeting(value.snapshot.source.meetingID)
        return value
    }

    public func jobs(meetingID: UUID) throws -> [ProcessingJob] {
        _ = try meeting(meetingID)
        let values: [ProcessingJob] = try records(.job, meetingID: meetingID)
        return values.sorted { $0.snapshot.createdAt == $1.snapshot.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.snapshot.createdAt < $1.snapshot.createdAt }
    }

    /// Queued jobs of one kind across all meetings, oldest first.
    public func queuedJobs(kind: JobKind) throws -> [ProcessingJob] {
        try meetings().flatMap { meeting -> [ProcessingJob] in try records(.job, meetingID: meeting.id) }
            .filter { $0.stage == .queued && $0.snapshot.kind == kind }
            .sorted { $0.snapshot.createdAt == $1.snapshot.createdAt
                ? $0.id.uuidString < $1.id.uuidString : $0.snapshot.createdAt < $1.snapshot.createdAt }
    }

    /// Final transcriptions of all meetings in the order the runner takes them:
    /// running ones first, then queued ones oldest first.
    public func finalQueue() throws -> [ProcessingJob] {
        let order: (ProcessingJob, ProcessingJob) -> Bool = { $0.snapshot.createdAt == $1.snapshot.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.snapshot.createdAt < $1.snapshot.createdAt }
        let jobs = try meetings().flatMap { meeting -> [ProcessingJob] in try records(.job, meetingID: meeting.id) }
            .filter { $0.snapshot.kind == .finalTranscription
                && ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains($0.stage) }
        return jobs.filter { $0.stage != .queued }.sorted(by: order) + jobs.filter { $0.stage == .queued }.sorted(by: order)
    }

    /// The user's Cancel: the meeting's queued and running final transcriptions
    /// become `cancelled`, so a running one stops at its next save. Other job
    /// kinds, the audio and published transcripts stay. Returns the cancelled jobs.
    public func cancelFinalTranscription(meetingID: UUID) throws -> [UUID] {
        try db.transaction {
            var cancelled: [UUID] = []
            for var job in try jobs(meetingID: meetingID) where job.snapshot.kind == .finalTranscription
                && ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains(job.stage) {
                job.stage = .cancelled
                job.lastError = "Cancelled."
                try saveJob(job)
                cancelled.append(job.id)
            }
            return cancelled
        }
    }

    public func updateJob(_ id: UUID, stage: JobStage, checkpoint: RelativePath? = nil, error: String? = nil) throws {
        try db.transaction {
            var value = try activeJob(id)
            guard stage != .completed else { throw StoreError.invalidResult }
            value.stage = stage
            value.checkpoint = checkpoint ?? value.checkpoint
            value.lastError = error
            try saveJob(value)
        }
    }

    public func retryJob(_ id: UUID) throws -> ProcessingJob {
        try db.transaction {
            var value = try job(id)
            guard [.failed, .interrupted, .waitingForModels].contains(value.stage) else { throw StoreError.invalidResult }
            if value.snapshot.kind == .translation, let source: TranslationSource = try record(.translationSource, id: id) {
                guard value.snapshot.source.cancellationGeneration == (try meeting(value.snapshot.source.meetingID)).cancellationGeneration,
                      source.job == value.snapshot else { throw StoreError.staleSource }
                guard !(try jobs(meetingID: value.snapshot.source.meetingID)).contains(where: {
                    $0.id != id && $0.snapshot.kind == .translation && ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains($0.stage)
                }) else { throw TranslationError.alreadyQueued }
                value.stage = .queued; value.lastError = nil
                try saveJob(value)
                return value
            }
            if value.snapshot.kind == .summary, let source: SummarySource = try record(.summarySource, id: id) {
                guard value.snapshot.source.cancellationGeneration == (try meeting(value.snapshot.source.meetingID)).cancellationGeneration,
                      source.job == value.snapshot else {
                    throw StoreError.staleSource
                }
                guard try activeSummaryJob(meetingID: value.snapshot.source.meetingID, recordingID: value.snapshot.recordingID) == nil
                else { throw SummaryJobError.alreadyQueued }
                value.stage = .queued; value.lastError = nil
                try saveJob(value)
                return value
            }
            if value.snapshot.kind == .finalTranscription {
                let source = value.snapshot.source
                let owner = try meeting(source.meetingID)
                guard source.cancellationGeneration == owner.cancellationGeneration,
                      let id = value.snapshot.recordingID,
                      let recording: Recording = try record(.recording, id: id),
                      recording.generation == source.recordingGenerations[id] else { throw StoreError.staleSource }
                let previous = try transcript(meetingID: owner.id, recordingID: id)
                guard previous == nil || source.transcriptRevisionIDs.contains(previous!.id) else { throw StoreError.staleSource }
            } else {
                guard value.snapshot.source == (try sourceSnapshot(meetingID: value.snapshot.source.meetingID)) else { throw StoreError.staleSource }
            }
            value.stage = .queued
            value.lastError = nil
            try saveJob(value)
            return value
        }
    }

    public func finalCheckpoint(jobID: UUID) throws -> FinalTranscriptionCheckpoint? {
        let job = try job(jobID)
        guard job.snapshot.kind == .finalTranscription else { throw StoreError.invalidResult }
        return try record(.finalCheckpoint, id: jobID)
    }

    func acquireFinalJob(_ id: UUID) throws -> UUID {
        _ = try activeJob(id)
        guard finalJobOwners[id] == nil else { throw FinalTranscriptionError.busy }
        let lease = UUID(); finalJobOwners[id] = lease
        return lease
    }

    func releaseFinalJob(_ id: UUID, lease: UUID) {
        if finalJobOwners[id] == lease { finalJobOwners.removeValue(forKey: id) }
    }

    /// Staging text and its durable stage advance in the same transaction. This
    /// operation never changes a transcript head or a meeting generation.
    public func saveFinalCheckpoint(_ checkpoint: FinalTranscriptionCheckpoint, stage: JobStage) throws {
        try db.transaction {
            var job = try activeJob(checkpoint.job.id)
            guard job.snapshot == checkpoint.job, job.snapshot.kind == .finalTranscription,
                  let id = job.snapshot.recordingID,
                  let recording: Recording = try record(.recording, id: id),
                  recording.meetingID == job.snapshot.source.meetingID,
                  job.snapshot.source.recordingGenerations[id] == recording.generation,
                  checkpoint.recordingFingerprint == (try Self.fingerprint(recording)),
                  [.decoding, .transcribing, .aligning, .diarizing, .correcting, .validating].contains(stage) else {
                throw StoreError.staleSource
            }
            try put(.finalCheckpoint, id: job.id, meetingID: recording.meetingID,
                    scope: id.uuidString, value: checkpoint)
            job.stage = stage; job.lastError = nil
            try saveJob(job)
        }
    }

    public func recoverInterruptedJobs() throws -> [ProcessingJob] {
        try db.transaction {
            var interrupted: [ProcessingJob] = []
            for meeting in try meetings() {
                let jobs: [ProcessingJob] = try records(.job, meetingID: meeting.id)
                for var job in jobs where ![.queued, .waitingForModels, .completed, .failed, .cancelled].contains(job.stage) {
                    job.stage = .interrupted
                    try saveJob(job)
                    interrupted.append(job)
                }
            }
            return interrupted
        }
    }

    public func cancelJobs(meetingID: UUID) throws {
        try db.transaction {
            var owner = try meeting(meetingID)
            owner.cancellationGeneration += 1
            try update(owner)
            let jobs: [ProcessingJob] = try records(.job, meetingID: meetingID)
            for var job in jobs where job.stage != .completed && job.stage != .cancelled {
                job.stage = .cancelled
                try saveJob(job)
            }
        }
    }

    public func transcript(meetingID: UUID, recordingID: UUID) throws -> TranscriptRevision? {
        _ = try meeting(meetingID)
        return try head(.transcript, meetingID: meetingID, scope: recordingID.uuidString)
    }

    public func transcriptRevision(_ id: UUID) throws -> TranscriptRevision? { try record(.transcript, id: id) }
    public func finalPublication(revisionID: UUID) throws -> FinalTranscriptPublication? { try record(.finalPublication, id: revisionID) }
    public func speakerAssignment(_ id: UUID) throws -> SpeakerAssignment? { try record(.assignment, id: id) }
    public func automaticVoiceMatch(assignmentID: UUID) throws -> AutomaticVoiceMatch? { try record(.automaticVoiceMatch, id: assignmentID) }

    func voiceRecognitionSource(meetingID: UUID) throws -> VoiceRecognitionSource {
        VoiceRecognitionSource(library: library, snapshot: try meetingTranscript(meetingID: meetingID))
    }

    func validateVoiceRecognitionSource(_ source: VoiceRecognitionSource) throws {
        guard source.library.manifest.libraryID == library.manifest.libraryID else { throw VoiceRecognitionError.changed }
        let current = try meetingTranscript(meetingID: source.snapshot.meeting.id)
        // Manual names and notes may change while models run. Audio, transcript
        // heads, speaker identity and cancellation must still be exactly current.
        guard current.recordings == source.snapshot.recordings, current.revisions == source.snapshot.revisions,
              current.speakers == source.snapshot.speakers,
              current.meeting.cancellationGeneration == source.snapshot.meeting.cancellationGeneration else {
            throw VoiceRecognitionError.changed
        }
    }

    /// Assignment plus immutable matching proof become visible together. Read
    /// manual heads inside this transaction: an intervening rename always wins.
    /// Only the recognition service can construct proposals; no model or PCM
    /// work runs inside this transaction and no profile vectors are persisted.
    func commitAutomaticVoiceMatches(source: VoiceRecognitionSource, proposals: [AutomaticVoiceMatch]) throws -> [SpeakerAssignment] {
        try Task.checkCancellation()
        return try db.transaction {
            try validateVoiceRecognitionSource(source)
            let current = try speakerAssignments(meetingID: source.snapshot.meeting.id)
            guard Set(proposals.map { $0.assignment.daySpeakerID }).count == proposals.count else { throw StoreError.invalidResult }
            var committed: [SpeakerAssignment] = []
            for match in proposals {
                try Task.checkCancellation()
                let assignment = match.assignment
                guard let speaker = source.speakers.first(where: { $0.id == assignment.daySpeakerID }),
                      assignment.meetingID == source.snapshot.meeting.id, assignment.dayID == speaker.dayID,
                      match.calibration.valid, assignment.name == match.profile.name,
                      case .automatic(let profileID, let revisionID, let similarity, let margin, let version) = assignment.origin,
                      profileID == match.profile.id, revisionID == match.profile.revisionID, version == match.calibration.version,
                      similarity.isFinite, margin.isFinite, similarity >= match.calibration.minimumSimilarity,
                      margin >= match.calibration.minimumMargin, similarity <= 1, margin <= 2,
                      match.rankedProfiles.first == VoiceProfileScore(profileID: profileID, revisionID: revisionID, similarity: similarity),
                      similarity - (match.rankedProfiles.dropFirst().first?.similarity ?? -1) == margin,
                      (2...8).contains(match.samples.count),
                      match.samples.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds,
                      match.samples.allSatisfy({ sample in source.snapshot.revisions.contains { revision in
                          revision.id == sample.transcriptRevisionID && revision.recordingID == sample.recordingID && revision.kind == .final &&
                          revision.modelRevisions.contains(match.calibration.segmentation) && revision.modelRevisions.contains(match.calibration.embedding) &&
                          SpeakerIntervals.subtract([sample.interval], removing: revision.segments.filter {
                              $0.track == .system && $0.speaker == .system(daySpeakerID: speaker.id) && $0.dayID == sample.dayID
                          }.map(\.interval)).isEmpty
                      } }) else { throw StoreError.invalidResult }
                // Existing manual and automatic assignments are immutable
                // decisions. A later explicit manual save may supersede either.
                if current.contains(where: { $0.daySpeakerID == speaker.id && $0.origin != .unknown }) { continue }
                let conflicts = (current + committed).contains { other in
                    guard case .automatic(let id, _, _, _, _) = other.origin else { return false }
                    return id == profileID && source.coactive(speaker.id, other.daySpeakerID)
                }
                guard !conflicts else { throw StoreError.invalidResult }
                try put(.assignment, id: assignment.id, meetingID: assignment.meetingID, scope: speaker.id.uuidString, value: assignment)
                try put(.automaticVoiceMatch, id: match.id, meetingID: assignment.meetingID, scope: speaker.id.uuidString, value: match)
                try setHead(.assignment, meetingID: assignment.meetingID, scope: speaker.id.uuidString, id: assignment.id)
                committed.append(assignment)
            }
            if !committed.isEmpty {
                var owner = try meeting(source.snapshot.meeting.id)
                owner.generation += 1; try update(owner)
            }
            try Task.checkCancellation()
            return committed
        }
    }

    /// Voices the current transcripts of the meeting's other recordings show.
    func speakersShown(meetingID: UUID, except recordingID: UUID) throws -> Set<UUID> {
        var ids: Set<UUID> = []
        for recording in try recordings(meetingID: meetingID) where recording.id != recordingID {
            for segment in try transcript(meetingID: meetingID, recordingID: recording.id)?.segments ?? [] {
                if case .system(let id) = segment.speaker { ids.insert(id) }
            }
        }
        return ids
    }

    public func daySpeakers(meetingID: UUID) throws -> [DaySpeaker] {
        _ = try meeting(meetingID)
        return try records(.daySpeaker, meetingID: meetingID)
    }

    public func speakerAssignments(meetingID: UUID) throws -> [SpeakerAssignment] {
        _ = try meeting(meetingID)
        return try db.rows("SELECT r.payload FROM heads h JOIN records r ON r.kind=h.kind AND r.id=h.id WHERE h.meeting_id=? AND h.kind='assignment'",
            [.text(meetingID.uuidString)]).map {
                guard case .blob(let data) = $0[0] else { throw StoreError.invalidResult }
                return try DomainCodec.decode(SpeakerAssignment.self, from: data)
            }
    }

    /// Every current named fragment of the library, as corrections for saved
    /// voices: a sample inside one belongs to its named person only.
    public func voiceCorrections() throws -> [VoiceCorrection] {
        try meetings().flatMap { meeting in
            try fragmentAnchors(meetingID: meeting.id).filter { $0.voiceID == nil }.map {
                VoiceCorrection(libraryID: library.manifest.libraryID, recordingID: $0.recordingID, interval: $0.interval,
                                person: NamedSpeech.person($0.name))
            }
        }
    }

    /// Current named fragments of the meeting.
    public func fragmentAnchors(meetingID: UUID) throws -> [FragmentAnchor] {
        _ = try meeting(meetingID)
        return try db.rows("SELECT r.payload FROM heads h JOIN records r ON r.kind=h.kind AND r.id=h.id WHERE h.meeting_id=? AND h.kind='fragmentAnchor'",
            [.text(meetingID.uuidString)]).map {
                guard case .blob(let data) = $0[0] else { throw StoreError.invalidResult }
                return try DomainCodec.decode(FragmentAnchor.self, from: data)
            }
    }

    /// Names one final system speech block (`Name This Fragment…`). The block's
    /// voice keeps its name; the fragment shows this one and guides Apply Names.
    @discardableResult
    public func nameFragment(meetingID: UUID, recordingID: UUID, segmentIDs: [UUID], name: String, at date: Date = Date()) throws -> MeetingTranscriptSnapshot {
        try db.transaction { try writeFragmentNames(meetingID: meetingID, recordingID: recordingID, segmentIDs: segmentIDs, name: name, at: date) }
    }

    /// Gives final system speech blocks (an Unidentified reply) to a voice of
    /// their day; the reply shows and groups with that voice, names nobody,
    /// and is dropped once that voice no longer exists (after reprocessing).
    @discardableResult
    public func assignFragment(meetingID: UUID, recordingID: UUID, segmentIDs: [UUID], voiceID: UUID, at date: Date = Date()) throws -> MeetingTranscriptSnapshot {
        try db.transaction {
            let snapshot = try meetingTranscript(meetingID: meetingID)
            guard let voice = snapshot.speakers.first(where: { $0.id == voiceID }), !voice.unidentified,
                  let revision = snapshot.revisions.first(where: { $0.recordingID == recordingID }),
                  segmentIDs.allSatisfy({ id in revision.segments.contains { $0.id == id && voice.recordingDayIDs.contains($0.dayID) } }) else {
                throw SpeakerRenameError.changed
            }
            let label = snapshot.assignments.first { $0.daySpeakerID == voiceID }?.name ?? "Voice\(voice.number)"
            return try writeFragmentNames(meetingID: meetingID, recordingID: recordingID, segmentIDs: segmentIDs, name: label, at: date, voiceID: voiceID)
        }
    }

    private func writeFragmentNames(meetingID: UUID, recordingID: UUID, segmentIDs: [UUID], name: String, at date: Date,
                                    voiceID: UUID? = nil) throws -> MeetingTranscriptSnapshot {
        let trimmed = try SpeakerRenameError.validatedName(name)
        do {
            let snapshot = try meetingTranscript(meetingID: meetingID)
            guard !segmentIDs.isEmpty, let revision = snapshot.revisions.first(where: { $0.recordingID == recordingID }) else { throw SpeakerRenameError.unavailable }
            let segments = try segmentIDs.map { id in
                guard let segment = revision.segments.first(where: { $0.id == id }) else { throw SpeakerRenameError.unavailable }
                guard segment.track == .system else { throw SpeakerRenameError.microphone }
                return segment
            }
            guard revision.kind == .final else { throw SpeakerRenameError.unavailable }
            let existing = try fragmentAnchors(meetingID: meetingID)
            for segment in segments {
                // Naming the block again replaces its fragment name.
                for old in existing where old.covers(segment) {
                    try db.execute("DELETE FROM heads WHERE kind='fragmentAnchor' AND meeting_id=? AND scope=?", [.text(meetingID.uuidString), .text(old.segmentID.uuidString)])
                }
                let anchor = FragmentAnchor(meetingID: meetingID, recordingID: recordingID, dayID: segment.dayID, segmentID: segment.id,
                                            interval: segment.interval, name: trimmed, createdAt: date, voiceID: voiceID)
                try put(.fragmentAnchor, id: anchor.id, meetingID: meetingID, scope: segment.id.uuidString, value: anchor)
                try setHead(.fragmentAnchor, meetingID: meetingID, scope: segment.id.uuidString, id: anchor.id)
            }
            var owner = snapshot.meeting
            owner.generation += 1; try update(owner)
            return try meetingTranscript(meetingID: meetingID)
        }
    }

    /// Names fragments and returns the confirmation for remembering that
    /// person's voice from all their named fragments of the meeting day.
    public func nameFragmentWithConfirmation(meetingID: UUID, recordingID: UUID, segmentIDs: [UUID], name: String,
                                             at date: Date = Date()) throws -> ConfirmedSpeakerRename {
        try db.transaction {
            let snapshot = try writeFragmentNames(meetingID: meetingID, recordingID: recordingID, segmentIDs: segmentIDs, name: name, at: date)
            let person = NamedSpeech.person(name)
            let days = snapshot.recordings.flatMap(\.days)
            guard let named = snapshot.anchors.first(where: { $0.recordingID == recordingID && segmentIDs.contains($0.segmentID) }),
                  let day = days.first(where: { $0.id == named.dayID }) else { throw SpeakerRenameError.unavailable }
            // The person's fragments of the same capture day, in any recording.
            let fragments = snapshot.anchors.filter { anchor in
                anchor.voiceID == nil && NamedSpeech.person(anchor.name) == person && days.contains { $0.id == anchor.dayID &&
                    $0.localDate == day.localDate && $0.timeZoneIdentifier == day.timeZoneIdentifier }
            }
            let revisions = snapshot.revisions.filter { revision in revision.kind == .final && fragments.contains { $0.recordingID == revision.recordingID } }
            let recordings = snapshot.recordings.filter { recording in revisions.contains { $0.recordingID == recording.id } }
            // One key per person and meeting day, so a later confirmation of the
            // same person's fragments supersedes this one in calibration.
            let key = "fragment-person:\(meetingID):\(day.localDate):\(day.timeZoneIdentifier):\(person)"
            let digest = Array(SHA256.hash(data: Data(key.utf8)))
            let speakerID = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
                                        (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
            let assignment = SpeakerAssignment(id: named.id, meetingID: meetingID, dayID: day.id, daySpeakerID: speakerID, name: named.name,
                origin: .manual, evidence: fragments.map { SpeechEvidence(recordingID: $0.recordingID, interval: $0.interval, embeddingFingerprint: nil) },
                createdAt: date)
            var confirmation = VoiceEnrollmentConfirmation(library: library, speakerID: speakerID, assignment: assignment,
                                                           recordings: recordings, revisions: revisions)
            confirmation.fragments = fragments
            return ConfirmedSpeakerRename(snapshot: snapshot, confirmation: confirmation)
        }
    }

    /// Removes the fragment name shown on this block; the record stays as history.
    @discardableResult
    public func removeFragmentName(meetingID: UUID, recordingID: UUID, segmentIDs: [UUID]) throws -> MeetingTranscriptSnapshot {
        try db.transaction {
            let snapshot = try meetingTranscript(meetingID: meetingID)
            let revision = snapshot.revisions.first { $0.recordingID == recordingID }
            let segments = revision?.segments.filter { segmentIDs.contains($0.id) } ?? []
            guard !segments.isEmpty else { throw SpeakerRenameError.unavailable }
            let covered = try fragmentAnchors(meetingID: meetingID).filter { anchor in segments.contains(where: anchor.covers) }
            guard !covered.isEmpty else { throw SpeakerRenameError.changed }
            for old in covered { try db.execute("DELETE FROM heads WHERE kind='fragmentAnchor' AND meeting_id=? AND scope=?", [.text(meetingID.uuidString), .text(old.segmentID.uuidString)]) }
            var owner = snapshot.meeting
            owner.generation += 1; try update(owner)
            return try meetingTranscript(meetingID: meetingID)
        }
    }

    /// Speech the user named: each named fragment, and the speech each current
    /// manual voice name was given for (its evidence, fixed when the user named
    /// it, so a rebuilt voice cannot widen it run by run) except where a
    /// fragment names someone else. Automatic and linked names are not the
    /// user's statements and take no part.
    public func namedSpeech(meetingID: UUID) throws -> [NamedSpeech] {
        // A reply given to a voice names nobody.
        let anchors = try fragmentAnchors(meetingID: meetingID).filter { $0.voiceID == nil }
        var result = anchors.map { NamedSpeech(name: $0.name, recordingID: $0.recordingID, intervals: [$0.interval]) }
        for assignment in try speakerAssignments(meetingID: meetingID) where assignment.origin == .manual {
            guard let name = assignment.name else { continue }
            let person = NamedSpeech.person(name)
            for recordingID in Set(assignment.evidence.map(\.recordingID)) {
                let others = anchors.filter { $0.recordingID == recordingID && NamedSpeech.person($0.name) != person }.map(\.interval)
                let intervals = SpeakerIntervals.subtract(assignment.evidence.filter { $0.recordingID == recordingID }.map(\.interval), removing: others)
                if !intervals.isEmpty { result.append(NamedSpeech(name: name, recordingID: recordingID, intervals: intervals)) }
            }
        }
        return result.sorted { ($0.recordingID.uuidString, $0.person) < ($1.recordingID.uuidString, $1.person) }
    }

    /// Why a recording with audio shows no text, so its separator (and its delete
    /// action) still appears in the transcript.
    private func emptyRecordingNotes(meetingID: UUID, recordings: [Recording],
                                     revisions: [TranscriptRevision]) throws -> [UUID: String] {
        let jobs = try jobs(meetingID: meetingID).filter { $0.snapshot.kind == .finalTranscription }
        var notes: [UUID: String] = [:]
        for recording in recordings where !revisions.contains(where: { $0.recordingID == recording.id && !$0.segments.isEmpty }) {
            switch recording.state {
            case .preparing, .recording, .paused: notes[recording.id] = "Recording…"
            default:
                guard !recording.chunks.isEmpty else { continue }
                let latest = jobs.last { $0.snapshot.recordingID == recording.id }
                if revisions.contains(where: { $0.recordingID == recording.id && $0.kind == .final }) || latest?.stage == .completed {
                    notes[recording.id] = "No speech found"
                } else if latest?.stage == .failed {
                    notes[recording.id] = "Transcription failed"
                } else {
                    notes[recording.id] = "Not transcribed"
                }
            }
        }
        return notes
    }

    /// One actor turn reads current heads and derives labels from assignments.
    public func meetingTranscript(meetingID: UUID) throws -> MeetingTranscriptSnapshot {
        let owner = try meeting(meetingID)
        let recordings = try recordings(meetingID: meetingID)
        let revisions = try recordings.compactMap { try transcript(meetingID: meetingID, recordingID: $0.id) }
        let speakers = try daySpeakers(meetingID: meetingID)
        let assignments = try speakerAssignments(meetingID: meetingID)
        let anchors = try fragmentAnchors(meetingID: meetingID)
        let items = try TranscriptFormatter.format(meetingID: meetingID, recordings: recordings,
            segments: revisions.flatMap(\.segments), speakers: speakers, assignments: assignments, anchors: anchors,
            emptyNotes: try emptyRecordingNotes(meetingID: meetingID, recordings: recordings, revisions: revisions))
        return MeetingTranscriptSnapshot(meeting: owner, recordings: recordings, revisions: revisions,
            speakers: speakers, assignments: assignments, anchors: anchors, items: items)
    }

    public func speakerRenameTarget(meetingID: UUID, recordingID: UUID, segmentID: UUID) throws -> SpeakerRenameTarget {
        let snapshot = try meetingTranscript(meetingID: meetingID)
        guard let revision = snapshot.revisions.first(where: { $0.recordingID == recordingID }),
              let segment = revision.segments.first(where: { $0.id == segmentID }) else {
            throw SpeakerRenameError.unavailable
        }
        guard segment.track == .system, case .system(let id) = segment.speaker else {
            throw SpeakerRenameError.microphone
        }
        guard revision.kind == .final else { throw SpeakerRenameError.unavailable }
        guard let speaker = snapshot.speakers.first(where: { $0.id == id }),
              let day = snapshot.recordings.flatMap(\.days).first(where: { $0.id == speaker.dayID }) else {
            throw SpeakerRenameError.unavailable
        }
        let assignment = snapshot.assignments.first { $0.daySpeakerID == id }
        return SpeakerRenameTarget(meetingID: meetingID, meetingTitle: snapshot.meeting.title,
            recordingID: recordingID, revisionID: revision.id, segmentID: segmentID, speakerID: id,
            day: day, label: assignment?.name ?? (speaker.unidentified ? "Unidentified" : "Voice\(speaker.number)"),
            name: assignment?.name, assignmentID: assignment?.id, assignmentOrigin: assignment?.origin)
    }

    /// Revalidate the exact selection and displayed scope inside the write
    /// transaction. Replacement transcripts and concurrent renames require a new
    /// selection rather than applying an old dialog to a different identity.
    public func renameSpeaker(_ target: SpeakerRenameTarget, name: String, at date: Date = Date()) throws -> MeetingTranscriptSnapshot {
        try renameSpeakerWithConfirmation(target, name: name, at: date).snapshot
    }

    /// The name commits first and survives every subsequent enrollment failure.
    /// The returned capability binds explicit manual confirmation to final heads.
    public func renameSpeakerWithConfirmation(_ target: SpeakerRenameTarget, name: String, at date: Date = Date()) throws -> ConfirmedSpeakerRename {
        let trimmed = try SpeakerRenameError.validatedName(name)
        return try db.transaction {
            let current = try speakerRenameTarget(meetingID: target.meetingID,
                recordingID: target.recordingID, segmentID: target.segmentID)
            guard current == target else { throw SpeakerRenameError.changed }
            let assignment = try writeSpeakerName(meetingID: target.meetingID, speakerID: target.speakerID, name: trimmed, at: date)
            let snapshot = try meetingTranscript(meetingID: target.meetingID)
            let revisions = snapshot.revisions.filter { $0.kind == .final && $0.segments.contains { $0.speaker == .system(daySpeakerID: target.speakerID) } }
            let recordings = snapshot.recordings.filter { recording in revisions.contains { $0.recordingID == recording.id } }
            return ConfirmedSpeakerRename(snapshot: snapshot, confirmation: VoiceEnrollmentConfirmation(library: library,
                speakerID: target.speakerID, assignment: assignment, recordings: recordings, revisions: revisions))
        }
    }

    /// Rechecked after asynchronous audio/model work. No automatic assignment
    /// can substitute for the exact manual confirmation that authorized it.
    public func validateVoiceConfirmation(_ value: VoiceEnrollmentConfirmation) throws {
        guard value.library.manifest.libraryID == library.manifest.libraryID,
              value.assignment.origin == .manual else { throw VoiceEnrollmentError.changed }
        let snapshot = try meetingTranscript(meetingID: value.assignment.meetingID)
        if value.fragments.isEmpty {
            guard snapshot.assignments.contains(value.assignment) else { throw VoiceEnrollmentError.changed }
        } else {
            guard value.fragments.allSatisfy(snapshot.anchors.contains) else { throw VoiceEnrollmentError.changed }
        }
        for recording in value.recordings {
            guard snapshot.recordings.contains(recording),
                  let revision = value.revisions.first(where: { $0.recordingID == recording.id }),
                  snapshot.revisions.contains(revision), revision.kind == .final else { throw VoiceEnrollmentError.changed }
        }
        guard !value.recordings.isEmpty, !value.revisions.isEmpty else { throw VoiceEnrollmentError.changed }
    }

    /// Service-level confirmation also used by reconciliation fixtures. All
    /// entry points share the same day/provenance checks and immutable storage.
    @discardableResult
    public func confirmSpeakerName(meetingID: UUID, speakerID: UUID, name: String, at date: Date = Date()) throws -> SpeakerAssignment {
        let trimmed = try SpeakerRenameError.validatedName(name)
        return try db.transaction {
            try writeSpeakerName(meetingID: meetingID, speakerID: speakerID, name: trimmed, at: date)
        }
    }

    /// Removes every current speaker name of the meeting, manual or automatic,
    /// so the next publication starts from unnamed voices. Earlier assignment
    /// records stay as history but no longer name anyone or anchor a voice.
    public func clearSpeakerNames(meetingID: UUID) throws -> MeetingTranscriptSnapshot {
        try db.transaction {
            var owner = try meeting(meetingID)
            let named = try !speakerAssignments(meetingID: meetingID).isEmpty || !fragmentAnchors(meetingID: meetingID).isEmpty
            guard named else {
                return try meetingTranscript(meetingID: meetingID)
            }
            try db.execute("DELETE FROM heads WHERE meeting_id=? AND kind IN (?,?)", [.text(meetingID.uuidString),
                .text(RecordKind.assignment.rawValue), .text(RecordKind.fragmentAnchor.rawValue)])
            owner.generation += 1; try update(owner)
            return try meetingTranscript(meetingID: meetingID)
        }
    }

    private func writeSpeakerName(meetingID: UUID, speakerID: UUID, name: String, at date: Date) throws -> SpeakerAssignment {
        // Formatting validates canonical day aliases, track and meeting scope.
        let snapshot = try meetingTranscript(meetingID: meetingID)
        guard let speaker = snapshot.speakers.first(where: { $0.id == speakerID }) else { throw StoreError.invalidResult }
        var evidence: [SpeechEvidence] = []
        for revision in snapshot.revisions {
            let publication: FinalTranscriptPublication? = try record(.finalPublication, id: revision.id)
            let bank = publication?.voiceEvidence.first { $0.speakerID == speakerID }
            let fingerprint = try bank?.fingerprint
            evidence += revision.segments.filter { $0.track == .system && $0.speaker == .system(daySpeakerID: speakerID) }.map {
                SpeechEvidence(recordingID: revision.recordingID, interval: $0.interval, embeddingFingerprint: fingerprint)
            }
        }
        guard !evidence.isEmpty else { throw StoreError.invalidResult }
        let assignment = SpeakerAssignment(meetingID: meetingID, dayID: speaker.dayID, daySpeakerID: speakerID,
            name: name, origin: .manual, evidence: evidence, createdAt: date)
        try put(.assignment, id: assignment.id, meetingID: meetingID, scope: speakerID.uuidString, value: assignment)
        try setHead(.assignment, meetingID: meetingID, scope: speakerID.uuidString, id: assignment.id)
        var owner = snapshot.meeting
        owner.generation += 1; try update(owner)
        return assignment
    }

    /// Reads validated staging and the latest confirmed names, then commits the
    /// revision, speaker provenance, affected head and job completion together.
    /// No caller-supplied transcript or mutable preferences can bypass staging.
    @discardableResult
    public func publishFinalTranscript(jobID: UUID, at date: Date = Date()) throws -> FinalTranscriptPublication {
        try Task.checkCancellation()
        return try db.transaction {
            let persisted = try job(jobID)
            if persisted.stage == .completed {
                guard let publication: FinalTranscriptPublication = try head(.finalPublication,
                    meetingID: persisted.snapshot.source.meetingID, scope: jobID.uuidString),
                    publication.job == persisted.snapshot else { throw StoreError.invalidResult }
                return publication
            }
            var job = try activeJob(jobID)
            guard finalJobOwners[jobID] == nil else { throw FinalTranscriptionError.busy }
            guard job.stage == .validating, job.snapshot.kind == .finalTranscription,
                  let checkpoint = try finalCheckpoint(jobID: jobID), checkpoint.readyForPublication,
                  checkpoint.version == 1, checkpoint.correctionPromptVersion == IndexedSpellingCorrection.promptVersion,
                  checkpoint.job == job.snapshot,
                  checkpoint.job.models.count == FinalTranscriptionPipeline.requiredRoles.count,
                  Set(checkpoint.job.models.map(\.role)) == Set(FinalTranscriptionPipeline.requiredRoles),
                  let id = job.snapshot.recordingID, let recording: Recording = try record(.recording, id: id),
                  recording.meetingID == job.snapshot.source.meetingID,
                  checkpoint.recordingFingerprint == (try Self.fingerprint(recording)),
                  job.snapshot.source.recordingGenerations[id] == recording.generation else { throw StoreError.staleSource }
            let previous = try transcript(meetingID: recording.meetingID, recordingID: id)
            guard previous == nil || job.snapshot.source.transcriptRevisionIDs.contains(previous!.id) else { throw StoreError.staleSource }
            try FinalTranscriptionPipeline.validateCoverage(checkpoint, recording: recording,
                requireCorrection: checkpoint.job.settings.spellingCorrection)
            let prior: FinalTranscriptPublication? = try previous.flatMap { try record(.finalPublication, id: $0.id) }
            let assignments = try speakerAssignments(meetingID: recording.meetingID)
            let anchors = try confirmedVoiceAnchors(recording: recording, assignments: assignments)
            let result = try FinalSpeakerReconciler.reconcile(checkpoint: checkpoint, recording: recording,
                previous: previous, previousPublication: prior, existingSpeakers: daySpeakers(meetingID: recording.meetingID),
                speakersInUse: try speakersShown(meetingID: recording.meetingID, except: recording.id),
                assignments: assignments, historicalEvidence: anchors,
                captureDays: recordings(meetingID: recording.meetingID).flatMap(\.days),
                named: try namedSpeech(meetingID: recording.meetingID).filter { $0.recordingID == recording.id },
                calibration: try mergeCalibration(),
                recognition: try checkpoint.job.models.first { $0.role == .embedding }.map { try replyRecognition(embedding: $0) },
                revisionID: UUID(), at: date)
            for speaker in result.publication.speakers {
                if let stored: DaySpeaker = try record(.daySpeaker, id: speaker.id) {
                    guard stored == speaker else { throw StoreError.invalidResult }
                } else {
                    try put(.daySpeaker, id: speaker.id, meetingID: recording.meetingID, scope: speaker.dayID.uuidString, value: speaker)
                }
            }
            for assignment in result.linked {
                try put(.assignment, id: assignment.id, meetingID: recording.meetingID, scope: assignment.daySpeakerID.uuidString, value: assignment)
                try setHead(.assignment, meetingID: recording.meetingID, scope: assignment.daySpeakerID.uuidString, id: assignment.id)
            }
            try put(.transcript, id: result.revision.id, meetingID: recording.meetingID, scope: id.uuidString, value: result.revision)
            try put(.finalPublication, id: result.publication.id, meetingID: recording.meetingID, scope: id.uuidString, value: result.publication)
            try setHead(.transcript, meetingID: recording.meetingID, scope: id.uuidString, id: result.revision.id)
            try setHead(.finalPublication, meetingID: recording.meetingID, scope: jobID.uuidString, id: result.publication.id)
            var owner = try meeting(recording.meetingID)
            owner.generation += 1; try update(owner)
            try Task.checkCancellation()
            job.stage = .completed; job.lastError = nil; try saveJob(job)
            return result.publication
        }
    }

    /// The voice-merge threshold learned from every meeting's names: pairs of
    /// standard voices (rebuilt from each current transcript's checkpoint) that
    /// the user's named speech labels as one person or different people.
    public func mergeCalibration() throws -> SpeakerMergeCalibration {
        try SpeakerMergeCalibration(pairs: namedVoicePairs())
    }

    public func namedVoicePairs() throws -> [NamedVoicePair] {
        var pairs: [NamedVoicePair] = []
        for meeting in try meetings() {
            let named = try namedSpeech(meetingID: meeting.id)
            guard !named.isEmpty else { continue }
            for recording in try recordings(meetingID: meeting.id) {
                guard let groups = try voiceGroups(meetingID: meeting.id, recordingID: recording.id) else { continue }
                pairs += SpeakerMergeCalibration.pairs(groups, named: named)
            }
        }
        return pairs
    }

    /// The standard voices behind a recording's current transcript, when its
    /// checkpoint is kept.
    public func voiceGroups(meetingID: UUID, recordingID: UUID) throws -> SpeakerVoiceGroups? {
        guard let revision = try transcript(meetingID: meetingID, recordingID: recordingID), revision.kind == .final,
              let publication: FinalTranscriptPublication = try record(.finalPublication, id: revision.id) else { return nil }
        if let cached = voiceGroups[publication.job.id] { return cached }
        guard let checkpoint: FinalTranscriptionCheckpoint = try record(.finalCheckpoint, id: publication.job.id),
              checkpoint.job == publication.job else { return nil }
        let groups = try SpeakerVoiceGroups(checkpoint: checkpoint)
        voiceGroups[publication.job.id] = groups
        return groups
    }

    /// The streaming clusters behind a recording's current transcript, when
    /// its checkpoint is kept.
    public func replyClusters(meetingID: UUID, recordingID: UUID) throws -> ReplyClusters? {
        guard let revision = try transcript(meetingID: meetingID, recordingID: recordingID), revision.kind == .final,
              let publication: FinalTranscriptPublication = try record(.finalPublication, id: revision.id) else { return nil }
        if let cached = replyClusters[publication.job.id] { return cached }
        guard let checkpoint: FinalTranscriptionCheckpoint = try record(.finalCheckpoint, id: publication.job.id),
              checkpoint.job == publication.job, let clusters = try ReplyClusters(checkpoint: checkpoint) else { return nil }
        replyClusters[publication.job.id] = clusters
        return clusters
    }

    /// Every named reply of the library as named clusters, and the reply
    /// recognition they calibrate (leave one reply out). Only clusters of the
    /// given speaker model take part.
    public func replyRecognition(embedding: ModelSnapshot) throws -> ReplyRecognition {
        var named: [NamedCluster] = [], names: [String: String] = [:], strangers: [String: [[[Float]]]] = [:]
        for meeting in try meetings() {
            let speech = try namedSpeech(meetingID: meeting.id)
            guard !speech.isEmpty else { continue }
            for item in speech where names[item.person] == nil { names[item.person] = item.name }
            for recording in try recordings(meetingID: meeting.id) {
                guard let clusters = try replyClusters(meetingID: meeting.id, recordingID: recording.id), clusters.embedding == embedding else { continue }
                let links = clusters.links(speech)
                for person in Set(links.values) { strangers[person, default: []] += clusters.strangers(of: person, links: links) }
                for (id, person) in links {
                    let own = clusters.clusters[id]!
                    // Speech within ten seconds is the same reply or its neighbour.
                    let near = clusters.clusters.values.filter { other in
                        other.id != id && other.activity.contains { a in own.activity.contains { b in
                            a.start.microseconds - 10_000_000 < b.end.microseconds && b.start.microseconds - 10_000_000 < a.end.microseconds } }
                    }.map(\.id)
                    named.append(NamedCluster(person: person, recordingID: recording.id, id: id, vectors: own.vectors, neighbours: Set(near)))
                }
            }
        }
        return ReplyRecognition(named: named.sorted { ($0.recordingID.uuidString, $0.id.uuidString) < ($1.recordingID.uuidString, $1.id.uuidString) },
                                names: names, strangers: strangers)
    }

    /// Recordings of the meeting whose voices `applyNames` can rebuild: the
    /// current transcript was published from a kept, complete checkpoint of
    /// the unchanged audio.
    public func namesApplicableRecordings(meetingID: UUID) throws -> [UUID] {
        try recordings(meetingID: meetingID).compactMap { recording in
            try reusableCheckpoint(recording) == nil ? nil : recording.id
        }
    }

    private func reusableCheckpoint(_ recording: Recording) throws -> FinalTranscriptionCheckpoint? {
        guard let revision = try transcript(meetingID: recording.meetingID, recordingID: recording.id), revision.kind == .final,
              let publication: FinalTranscriptPublication = try record(.finalPublication, id: revision.id),
              let checkpoint: FinalTranscriptionCheckpoint = try record(.finalCheckpoint, id: publication.job.id),
              checkpoint.job == publication.job, checkpoint.readyForPublication, checkpoint.version == 1,
              checkpoint.correctionPromptVersion == IndexedSpellingCorrection.promptVersion,
              checkpoint.recordingFingerprint == (try Self.fingerprint(recording)),
              checkpoint.job.source.recordingGenerations[recording.id] == recording.generation else { return nil }
        return checkpoint
    }

    /// `Apply Names`: publishes each applicable recording again from its kept
    /// checkpoint with the current names, named fragments and merge
    /// calibration. No model runs; the words are the same. A new job records
    /// the re-publication like any other final transcript.
    public func applyNames(meetingID: UUID, at date: Date = Date()) throws -> [FinalTranscriptPublication] {
        let meetingJobs = try jobs(meetingID: meetingID)
        guard !meetingJobs.contains(where: { $0.snapshot.kind == .finalTranscription && ![.completed, .failed, .cancelled].contains($0.stage) }) else {
            throw FinalTranscriptionError.busy
        }
        var publications: [FinalTranscriptPublication] = []
        for recording in try recordings(meetingID: meetingID) {
            guard let old = try reusableCheckpoint(recording) else { continue }
            let job = try db.transaction { () -> ProcessingJob in
                let source = try sourceSnapshot(meetingID: meetingID)
                var job = ProcessingJob(snapshot: ProcessingJobSnapshot(kind: .finalTranscription, recordingID: recording.id,
                    source: source, settings: old.job.settings, models: old.job.models))
                job.stage = .validating
                try saveJob(job)
                let copy = FinalTranscriptionCheckpoint(version: old.version, correctionPromptVersion: old.correctionPromptVersion,
                    job: job.snapshot, recordingFingerprint: old.recordingFingerprint, windows: old.windows,
                    completedTracks: old.completedTracks, speakerCheckpoint: old.speakerCheckpoint,
                    correctionBatches: old.correctionBatches, readyForPublication: true, systemLevels: old.systemLevels)
                try put(.finalCheckpoint, id: job.id, meetingID: meetingID, scope: recording.id.uuidString, value: copy)
                return job
            }
            do { publications.append(try publishFinalTranscript(jobID: job.id, at: date)) }
            catch {
                try? updateJob(job.id, stage: .failed, error: error.localizedDescription)
                throw error
            }
        }
        return publications
    }

    /// Resolve only requested confirmation fingerprints, one revision at a time.
    /// Repeated reruns cannot walk away from the original confirmed voice bank
    /// or require retaining the entire meeting's publication history in memory.
    private func confirmedVoiceAnchors(recording: Recording, assignments: [SpeakerAssignment]) throws -> [TranscriptVoiceEvidence] {
        let manual = assignments.filter { $0.origin == .manual }
        var wanted = Set(manual.flatMap(\.evidence).filter {
            $0.recordingID == recording.id
        }.compactMap(\.embeddingFingerprint))
        var cursor: Int64 = 0
        var result: [TranscriptVoiceEvidence] = []
        while !wanted.isEmpty {
            guard let row = try db.rows("SELECT rowid,payload FROM records WHERE meeting_id=? AND kind='finalPublication' AND scope=? AND rowid>? ORDER BY rowid LIMIT 1",
                [.text(recording.meetingID.uuidString), .text(recording.id.uuidString), .integer(cursor)]).first else { break }
            guard case .integer(let id) = row[0], case .blob(let payload) = row[1] else { throw StoreError.invalidResult }
            cursor = id
            let publication = try DomainCodec.decode(FinalTranscriptPublication.self, from: payload)
            for bank in publication.voiceEvidence where manual.contains(where: { $0.daySpeakerID == bank.speakerID }) {
                let fingerprint = try bank.fingerprint
                if wanted.remove(fingerprint) != nil { result.append(bank) }
            }
        }
        return result
    }

    /// Low-level revision import retained for persistence fixtures. Application
    /// final processing must use publishFinalTranscript to consume its staging.
    public func publishTranscript(_ revision: TranscriptRevision, jobID: UUID) throws {
        try db.transaction {
            var job = try activeJob(jobID)
            let snapshot = job.snapshot
            guard snapshot.kind == .finalTranscription, snapshot.recordingID == revision.recordingID,
                  revision.kind == .final, revision.modelRevisions == snapshot.models,
                  revision.sourceGeneration == snapshot.source.recordingGenerations[revision.recordingID],
                  let recording: Recording = try record(.recording, id: revision.recordingID),
                  recording.meetingID == snapshot.source.meetingID else { throw StoreError.invalidResult }
            guard recording.generation == revision.sourceGeneration else { throw StoreError.staleSource }
            let previous = try transcript(meetingID: recording.meetingID, recordingID: recording.id)
            if let previous, !snapshot.source.transcriptRevisionIDs.contains(previous.id) { throw StoreError.staleSource }
            guard revision.segments.allSatisfy({ segment in
                segment.recordingID == recording.id && recording.days.contains(where: { $0.id == segment.dayID })
                    && segment.interval.end <= recording.activeDuration
            }) else {
                throw StoreError.invalidResult
            }
            var owner = try meeting(recording.meetingID)
            try put(.transcript, id: revision.id, meetingID: owner.id, scope: recording.id.uuidString, value: revision)
            try setHead(.transcript, meetingID: owner.id, scope: recording.id.uuidString, id: revision.id)
            owner.generation += 1
            try update(owner)
            job.stage = .completed
            try saveJob(job)
        }
    }

    public func publishOutput(_ output: GeneratedOutput) throws {
        try db.transaction {
            try Task.checkCancellation()
            var job = try activeJob(output.job.id)
            let kind: RecordKind = output.kind == .summary ? .summary : .translation
            guard output.job == job.snapshot,
                  job.snapshot.kind == (output.kind == .summary ? .summary : .translation) else { throw StoreError.invalidResult }
            if output.kind == .translation, let source: TranslationSource = try record(.translationSource, id: job.id) {
                guard source.job == output.job else { throw StoreError.invalidResult }
                let items = try source.items(translations: output.translatedSegments)
                guard output.text == items.map(\.text).joined(separator: "\n\n") else { throw StoreError.invalidResult }
            }
            // A summary belongs to its recording; meeting-wide summaries (no
            // recording) predate per-recording summaries and keep the empty scope.
            let scope = output.kind == .summary ? job.snapshot.recordingID?.uuidString ?? "" : ""
            if let current: GeneratedOutput = try head(kind, meetingID: job.snapshot.source.meetingID, scope: scope) {
                guard current.job.createdAt < output.job.createdAt else { throw StoreError.staleSource }
            }
            try put(kind, id: output.id, meetingID: job.snapshot.source.meetingID, scope: scope, value: output)
            try setHead(kind, meetingID: job.snapshot.source.meetingID, scope: scope, id: output.id)
            job.stage = .completed
            job.lastError = nil
            try saveJob(job)
            try Task.checkCancellation()
        }
    }

    public func output(_ kind: GeneratedOutputKind, meetingID: UUID) throws -> GeneratedOutput? {
        _ = try meeting(meetingID)
        return try head(kind == .summary ? .summary : .translation, meetingID: meetingID)
    }

    public func isOutdated(_ output: GeneratedOutput, settings: ProcessingSettings) throws -> Bool {
        let source = try sourceSnapshot(meetingID: output.job.source.meetingID)
        let old = output.job.settings
        // `templateVersion` is per kind; an output is current only at its kind's current version.
        let currentVersion = output.kind == .summary ? SummaryTemplates.currentVersion : IndexedTranslation.version
        // A text server has no context limit; choosing between it and a local
        // model is a model choice, which never outdates a result.
        let contextChanged = old.contextLimit != settings.contextLimit
            && old.contextLimit != .unbounded && settings.contextLimit != .unbounded
        let settingsChanged = contextChanged || old.templateVersion != currentVersion ||
            (output.kind == .summary ? old.summaryLanguage != settings.summaryLanguage || old.summaryType != settings.summaryType :
                                      old.translationLanguage != settings.translationLanguage)
        if output.kind == .summary, let recordingID = output.job.recordingID {
            // Only this recording, its speaker names and the meeting header were input.
            guard let frozen: SummarySource = try record(.summarySource, id: output.job.id),
                  let revision = frozen.revisions.first else { return true }
            let owner = try meeting(source.meetingID)
            let voices = Set(frozen.speakers.map(\.id))
            let names = try speakerAssignments(meetingID: source.meetingID).filter { voices.contains($0.daySpeakerID) }
            let head = try transcript(meetingID: source.meetingID, recordingID: recordingID)
            return settingsChanged || source.recordingGenerations[recordingID] != output.job.source.recordingGenerations[recordingID]
                || head?.id != revision.id
                || Set(names.map(\.id)) != Set(frozen.assignments.map(\.id))
                || owner.title != frozen.meeting.title || owner.description != frozen.meeting.description
        }
        let metadataChanged: Bool
        if output.kind == .translation, let frozen: TranslationSource = try record(.translationSource, id: output.job.id) {
            // Translation does not consume notes, the title or description.
            metadataChanged = try speakerAssignments(meetingID: source.meetingID) != frozen.assignments
        } else { metadataChanged = source.meetingGeneration != output.job.source.meetingGeneration }
        return metadataChanged ||
            source.recordingGenerations != output.job.source.recordingGenerations ||
            source.transcriptRevisionIDs != output.job.source.transcriptRevisionIDs ||
            (output.kind == .summary && source.notesRevisionID != output.job.source.notesRevisionID) || settingsChanged
    }

    private func activeJob(_ id: UUID) throws -> ProcessingJob {
        let value = try job(id)
        guard ![.completed, .cancelled, .failed, .interrupted].contains(value.stage),
              value.snapshot.source.cancellationGeneration == (try meeting(value.snapshot.source.meetingID)).cancellationGeneration else {
            throw StoreError.cancelledJob
        }
        return value
    }

    private func saveJob(_ job: ProcessingJob) throws {
        try put(.job, id: job.id, meetingID: job.snapshot.source.meetingID, value: job)
    }

    private func head<T: Codable>(_ kind: RecordKind, meetingID: UUID, scope: String = "") throws -> T? {
        guard case .text(let id) = try db.rows("SELECT id FROM heads WHERE meeting_id=? AND kind=? AND scope=?",
            [.text(meetingID.uuidString), .text(kind.rawValue), .text(scope)]).first?.first,
              let uuid = UUID(uuidString: id) else { return nil }
        return try record(kind, id: uuid)
    }

    private func setHead(_ kind: RecordKind, meetingID: UUID, scope: String = "", id: UUID) throws {
        try db.execute("INSERT INTO heads(meeting_id,kind,scope,id) VALUES (?,?,?,?) ON CONFLICT(meeting_id,kind,scope) DO UPDATE SET id=excluded.id",
            [.text(meetingID.uuidString), .text(kind.rawValue), .text(scope), .text(id.uuidString)])
    }

    enum RecordKind: String { case recording, notes, transcript, assignment, job, summary, translation, finalCheckpoint, daySpeaker, finalPublication, automaticVoiceMatch, summarySource, translationSource, fragmentAnchor }

    private func put<T: Codable>(_ kind: RecordKind, id: UUID, meetingID: UUID, scope: String = "", value: T) throws {
        let mutable = kind == .recording || kind == .job || kind == .finalCheckpoint
        let conflict = mutable ? " ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload WHERE records.meeting_id=excluded.meeting_id AND records.scope=excluded.scope" : ""
        try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES (?,?,?,?,?)" + conflict,
            [.text(kind.rawValue), .text(id.uuidString), .text(meetingID.uuidString), .text(scope), .blob(DomainCodec.encode(value))])
    }

    private func record<T: Codable>(_ kind: RecordKind, id: UUID) throws -> T? {
        guard case .blob(let data) = try db.rows("SELECT payload FROM records WHERE kind=? AND id=?", [.text(kind.rawValue), .text(id.uuidString)]).first?.first else { return nil }
        return try DomainCodec.decode(T.self, from: data)
    }

    private func records<T: Codable>(_ kind: RecordKind, meetingID: UUID) throws -> [T] {
        try db.rows("SELECT payload FROM records WHERE kind=? AND meeting_id=?", [.text(kind.rawValue), .text(meetingID.uuidString)]).map {
            guard case .blob(let data) = $0[0] else { throw StoreError.database("Invalid stored record") }
            return try DomainCodec.decode(T.self, from: data)
        }
    }
}

public enum RecordingDeletionError: Error, Equatable, LocalizedError, Sendable {
    case missing, capturing

    public var errorDescription: String? {
        switch self {
        case .missing: "This recording has been deleted or is unavailable."
        case .capturing: "This recording is still being recorded."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missing: nil
        case .capturing: "Stop the recording before deleting it."
        }
    }
}
