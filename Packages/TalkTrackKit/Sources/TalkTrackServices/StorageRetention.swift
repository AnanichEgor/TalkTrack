import Foundation
import os
import TalkTrackAudio
import TalkTrackDomain

/// What one prune removed (compact-library-storage D1).
public struct ProcessingStatePrune: Equatable, Sendable {
    public var checkpoints = 0
    public var revisions = 0
    public var publications = 0
    public var drafts = 0

    public var isEmpty: Bool { checkpoints + revisions + publications + drafts == 0 }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(checkpoints: lhs.checkpoints + rhs.checkpoints, revisions: lhs.revisions + rhs.revisions,
             publications: lhs.publications + rhs.publications, drafts: lhs.drafts + rhs.drafts)
    }
}

extension SessionStore {
    /// Keeps a recording's processing state only while something can use it
    /// (compact-library-storage D1). Runs inside the caller's transaction.
    ///
    /// Kept: the current transcript head and its publication; the checkpoint of
    /// that publication's job; checkpoints of later jobs that are neither
    /// completed nor cancelled (they can still be retried); the checkpoint of the
    /// recording's last final job when it completed (the workspace reads its
    /// unrecovered windows); and, for each voice bank a manual assignment's
    /// evidence names, the first publication holding it, because
    /// `confirmedVoiceAnchors` scans publications in that order.
    @discardableResult
    func pruneProcessingState(meetingID: UUID, recordingID: UUID) throws -> ProcessingStatePrune {
        let m = SQLValue.text(meetingID.uuidString), scope = SQLValue.text(recordingID.uuidString)
        var result = ProcessingStatePrune()
        // Freed pages of pruned voice vectors are overwritten even without VACUUM.
        try db.execute("PRAGMA secure_delete = ON")
        defer { try? db.execute("PRAGMA secure_delete = OFF") }

        let head = try transcript(meetingID: meetingID, recordingID: recordingID)
        let current: FinalTranscriptPublication? = try head.flatMap { try record(.finalPublication, id: $0.id) }

        // Checkpoints.
        let finalJobs = try jobs(meetingID: meetingID).filter {
            $0.snapshot.kind == .finalTranscription && $0.snapshot.recordingID == recordingID
        }
        var keepJobs = Set<UUID>()
        var after = Date.distantPast
        if let current {
            keepJobs.insert(current.job.id)
            after = current.job.createdAt
        }
        for job in finalJobs where job.snapshot.createdAt > after && job.stage != .completed && job.stage != .cancelled {
            keepJobs.insert(job.id)
        }
        if let last = finalJobs.last, last.stage == .completed { keepJobs.insert(last.id) }
        for id in try ids(kind: .finalCheckpoint, meetingID: m, scope: scope) where !keepJobs.contains(id) {
            try deleteRecord(.finalCheckpoint, id: id)
            result.checkpoints += 1
        }

        // Transcript revisions: only the head.
        for id in try ids(kind: .transcript, meetingID: m, scope: scope) where id != head?.id {
            try deleteRecord(.transcript, id: id)
            result.revisions += 1
        }

        // Publications: the current one and the first holder of each bank a
        // manual assignment refers to, as `confirmedVoiceAnchors` finds it.
        var keepPublications = Set<UUID>()
        if let current { keepPublications.insert(current.id) }
        let manual: [SpeakerAssignment] = try records(.assignment, meetingID: meetingID).filter { $0.origin == .manual }
        let wanted = Set(manual.flatMap(\.evidence).filter { $0.recordingID == recordingID }.compactMap(\.embeddingFingerprint))
        let speakers = Set(manual.map(\.daySpeakerID))
        var found = Set<String>()
        let publications = try db.rows("SELECT id, payload FROM records WHERE kind='finalPublication' AND meeting_id=? AND scope=? ORDER BY rowid",
                                       [m, scope])
        for row in publications {
            guard case .text(let text) = row[0], let id = UUID(uuidString: text) else { throw StoreError.invalidResult }
            guard !wanted.isEmpty, case .blob(let payload) = row[1] else { continue }
            let publication = try DomainCodec.decode(FinalTranscriptPublication.self, from: payload)
            for bank in publication.voiceEvidence where speakers.contains(bank.speakerID) {
                let fingerprint = try bank.fingerprint
                let pair = bank.speakerID.uuidString + ":" + fingerprint
                guard wanted.contains(fingerprint), found.insert(pair).inserted else { continue }
                keepPublications.insert(id)
            }
        }
        for row in publications {
            guard case .text(let text) = row[0], let id = UUID(uuidString: text) else { continue }
            guard !keepPublications.contains(id) else { continue }
            try deleteRecord(.finalPublication, id: id)
            result.publications += 1
        }
        return result
    }

    /// Prunes every recording and removes drafts no head refers to. Each
    /// recording commits on its own; a failure leaves the rest for next launch.
    @discardableResult
    func pruneLibrary() throws -> ProcessingStatePrune {
        var total = ProcessingStatePrune()
        for meeting in try meetings() {
            for recording in try recordings(meetingID: meeting.id) {
                total = total + (try db.transaction { try pruneProcessingState(meetingID: meeting.id, recordingID: recording.id) })
            }
        }
        total.drafts = try db.transaction {
            try db.execute("PRAGMA secure_delete = ON")
            defer { try? db.execute("PRAGMA secure_delete = OFF") }
            let orphans = try db.rows("SELECT r.id FROM records r WHERE r.kind='liveDraft' AND NOT EXISTS (SELECT 1 FROM heads h WHERE h.kind='liveDraft' AND h.id=r.id)")
            for row in orphans {
                guard case .text(let id) = row[0] else { continue }
                try db.execute("DELETE FROM records WHERE kind='liveDraft' AND id=?", [.text(id)])
            }
            return orphans.count
        }
        return total
    }

    private func ids(kind: RecordKind, meetingID: SQLValue, scope: SQLValue) throws -> [UUID] {
        try db.rows("SELECT id FROM records WHERE kind=? AND meeting_id=? AND scope=? ORDER BY rowid",
                    [.text(kind.rawValue), meetingID, scope]).compactMap {
            guard case .text(let id) = $0[0] else { return nil }
            return UUID(uuidString: id)
        }
    }

    /// Deletes a record and every head that points at it.
    func deleteRecord(_ kind: RecordKind, id: UUID) throws {
        try db.execute("DELETE FROM records WHERE kind=? AND id=?", [.text(kind.rawValue), .text(id.uuidString)])
        try db.execute("DELETE FROM heads WHERE kind=? AND id=?", [.text(kind.rawValue), .text(id.uuidString)])
    }
}

/// When freed database space is worth returning to the file system (D3).
struct VacuumPolicy: Sendable {
    var minimumFreeBytes: Int64 = 16 << 20
    var minimumFreeRatio = 0.25
    /// Free bytes on the library volume; nil when unknown (VACUUM is skipped).
    var availableBytes: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
    /// Runs just before VACUUM; tests throw here to stand for a failed VACUUM.
    var willVacuum: @Sendable () throws -> Void = {}
}

/// What opening the library reclaimed (D3), with the time of each step.
public struct DatabaseCompaction: Equatable, Sendable {
    public var pruned = ProcessingStatePrune()
    public var vacuumed = false
    public var bytesBefore: Int64 = 0
    public var bytesAfter: Int64 = 0
    /// Why pruning or VACUUM stopped, for logs and tests.
    public var failure: String?
    /// Pruning every recording and orphaned drafts.
    public var pruneTime: Duration = .zero
    /// The WAL checkpoint before VACUUM and the page count.
    public var checkpointTime: Duration = .zero
    /// VACUUM and the checkpoint after it.
    public var vacuumTime: Duration = .zero
}

extension SessionStore {
    static let storageLog = Logger(subsystem: CaptureLog.subsystem, category: "storage")

    /// Launch compaction: prune every recording, then VACUUM when the freed
    /// space is large, a quarter of the file and the volume holds twice the
    /// database. Failures are logged and retried at a later launch.
    @discardableResult
    func compactDatabase(policy: VacuumPolicy = VacuumPolicy()) -> DatabaseCompaction {
        var result = DatabaseCompaction()
        let clock = ContinuousClock(), start = clock.now
        do { result.pruned = try pruneLibrary() } catch {
            result.failure = String(describing: error)
            Self.storageLog.error("prune failed error=\(String(describing: error), privacy: .private)")
        }
        result.pruneTime = clock.now - start
        var mark = clock.now
        do {
            try checkpoint()
            let pageSize = Int64(try db.integer("PRAGMA page_size"))
            let pages = Int64(try db.integer("PRAGMA page_count"))
            let free = Int64(try db.integer("PRAGMA freelist_count")) * pageSize
            result.bytesBefore = pages * pageSize; result.bytesAfter = result.bytesBefore
            result.checkpointTime = clock.now - mark
            mark = clock.now
            let available = policy.availableBytes(library.directory) ?? 0
            if free >= policy.minimumFreeBytes, Double(free) >= Double(result.bytesBefore) * policy.minimumFreeRatio,
               available >= 2 * result.bytesBefore {
                try policy.willVacuum()
                try db.execute("VACUUM")
                result.vacuumed = true
                result.bytesAfter = Int64(try db.integer("PRAGMA page_count")) * pageSize
                // The WAL now holds the rewritten file; a busy reader only delays copying it back.
                try? checkpoint()
                result.vacuumTime = clock.now - mark
            }
        } catch {
            result.failure = String(describing: error)
            Self.storageLog.error("vacuum failed error=\(String(describing: error), privacy: .private)")
        }
        let p = result.pruned
        Self.storageLog.log("""
            compact checkpoints=\(p.checkpoints, privacy: .public) revisions=\(p.revisions, privacy: .public) \
            publications=\(p.publications, privacy: .public) drafts=\(p.drafts, privacy: .public) \
            vacuumed=\(result.vacuumed, privacy: .public) before=\(result.bytesBefore, privacy: .public) \
            after=\(result.bytesAfter, privacy: .public) ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)), privacy: .public) \
            prune=\(Int(result.pruneTime / .milliseconds(1)), privacy: .public) \
            checkpoint=\(Int(result.checkpointTime / .milliseconds(1)), privacy: .public) \
            vacuum=\(Int(result.vacuumTime / .milliseconds(1)), privacy: .public)
            """)
        return result
    }

    /// Launch recovery of interrupted chunk compaction (D6); failures are
    /// logged and the folder is retried at the next launch.
    func recoverAudioCompaction() {
        do {
            let count = try ChunkCompaction.recoverLibrary(DirectoryHandle.openAbsolute(library.directory))
            if count > 0 { Self.storageLog.log("compaction recovered recordings=\(count, privacy: .public)") }
        } catch {
            Self.storageLog.error("compaction recovery failed error=\(String(describing: error), privacy: .private)")
        }
    }
}
