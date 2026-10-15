import Darwin
import Foundation
import TalkTrackDomain

/// Small independent SQLite database. Production uses the real home; fixtures
/// inject a private home while retaining the same Application Support layout.
/// Reads of an absent registry never create folders or a database.
public actor VoiceProfileStore {
    public nonisolated let databaseURL: URL
    private let rootURL: URL
    private static let applicationID = 0x54545650
    private static let fileName = "Speakers.sqlite3"
    private static let migrationBackup = "Speakers.v1-backup.sqlite3"
    private var recognitionCommit = false

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rootURL = home.appendingPathComponent("Library/Application Support/TalkTrack", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent(Self.fileName)
    }

    public func profiles() throws -> [VoiceProfile] {
        guard let db = try open(create: false) else { return [] }
        return try profiles(in: db)
    }

    public func savedVoices(segmentation: ModelSnapshot, embedding: ModelSnapshot) throws -> [SavedVoice] {
        guard let db = try open(create: false) else { return [] }
        return try db.transaction {
            try recognitionProfiles(in: db).map { item in
                SavedVoice(profile: item.profile, needsNewSpeech: item.revision.segmentation != segmentation ||
                    item.revision.embedding != embedding || item.revision.preprocessingVersion != VoiceEnrollmentPolicy.preprocessing ||
                    item.revision.enrollmentPolicyVersion != VoiceEnrollmentPolicy.version || !item.isAdequate)
            }
        }
    }

    public func savedVoices() throws -> [SavedVoice] {
        let catalog = try ModelCatalog.bundled()
        return try savedVoices(segmentation: catalog.model(for: .segmentation).snapshot(for: .segmentation),
            embedding: catalog.model(for: .embedding).snapshot(for: .embedding))
    }

    public func rename(_ expected: VoiceProfile, name: String, at date: Date = Date()) throws -> VoiceProfile {
        let name = try SpeakerRenameError.validatedName(name)
        guard !recognitionCommit else { throw VoiceProfileSettingsError.busy }
        guard let db = try open(create: false) else { throw VoiceProfileSettingsError.changed }
        return try db.transaction {
            try requireCurrent(expected, in: db)
            let next = VoiceProfile(id: expected.id, name: name, revisionID: expected.revisionID, updatedAt: date)
            try db.execute("UPDATE profiles SET name=?,payload=? WHERE id=?", [.text(name), .blob(DomainCodec.encode(next)), .text(expected.id.uuidString)])
            try Task.checkCancellation()
            return next
        }
    }

    /// All revisions are removed, including superseded embedding banks. SQLite
    /// secure_delete clears freed cells; DELETE journaling leaves no old WAL.
    /// Only non-vector enrollment receipts survive to prevent replay training.
    public func delete(_ expected: VoiceProfile) throws {
        guard !recognitionCommit else { throw VoiceProfileSettingsError.busy }
        guard let db = try open(create: false) else { throw VoiceProfileSettingsError.changed }
        try db.transaction {
            try requireCurrent(expected, in: db)
            try db.execute("DELETE FROM revisions WHERE profile_id=?", [.text(expected.id.uuidString)])
            try db.execute("DELETE FROM profiles WHERE id=?", [.text(expected.id.uuidString)])
            try Task.checkCancellation()
        }
    }

    private func requireCurrent(_ expected: VoiceProfile, in db: SQLiteConnection) throws {
        guard try profiles(in: db).contains(expected) else { throw VoiceProfileSettingsError.changed }
    }

    private func profiles(in db: SQLiteConnection) throws -> [VoiceProfile] {
        return try db.rows("SELECT id, revision_id, payload FROM profiles ORDER BY name COLLATE NOCASE, id").map {
            guard case .text(let id) = $0[0], case .text(let revisionID) = $0[1], case .blob(let bytes) = $0[2] else { throw VoiceEnrollmentError.damagedProfile }
            let profile = try DomainCodec.decode(VoiceProfile.self, from: bytes)
            guard profile.id.uuidString == id, profile.revisionID.uuidString == revisionID,
                  let revision = try revision(profile.revisionID, in: db), revision.id == profile.revisionID,
                  revision.profileID == profile.id else { throw VoiceEnrollmentError.damagedProfile }
            _ = try SpeakerRenameError.validatedName(profile.name)
            return profile
        }
    }

    func recognitionProfiles(corrections: [VoiceCorrection] = []) throws -> [VoiceRecognitionProfile] {
        guard let db = try open(create: false) else { return [] }
        return try db.transaction { try recognitionProfiles(in: db).map { $0.applying(corrections) } }
    }

    private func recognitionProfiles(in db: SQLiteConnection) throws -> [VoiceRecognitionProfile] {
        // A day speaker's latest confirmation wins: renaming Voice3 from Dima
        // to Nikolai removes that speech from Dima's bank (user correction).
        var latest: [String: VoiceProfileRevision] = [:]
        for row in try db.rows("SELECT payload FROM revisions") {
            guard case .blob(let bytes) = row[0] else { throw VoiceEnrollmentError.damagedProfile }
            let revision = try DomainCodec.decode(VoiceProfileRevision.self, from: bytes)
            let key = "\(revision.libraryID)/\(revision.meetingID)/\(revision.daySpeakerID)"
            if let current = latest[key], (current.createdAt, current.id.uuidString) > (revision.createdAt, revision.id.uuidString) { continue }
            latest[key] = revision
        }
        let current = Set(latest.values.map(\.id))
        return try profiles(in: db).map { profile in
            guard let revision = try revision(profile.revisionID, in: db) else { throw VoiceEnrollmentError.damagedProfile }
            // Earlier confirmations stay in the bank: walk the immutable chain.
            var history = [revision], seen: Set<UUID> = [revision.id]
            while let previous = history.last?.previousRevisionID {
                guard seen.insert(previous).inserted, let older = try self.revision(previous, in: db),
                      older.id == previous, older.profileID == profile.id else { throw VoiceEnrollmentError.damagedProfile }
                history.append(older)
            }
            return VoiceRecognitionProfile(profile: profile, revision: revision, history: history.filter { current.contains($0.id) })
        }
    }

    /// Calibration from the user's confirmations for the current speaker models.
    /// Reading never creates the registry.
    public func recognitionStatus(segmentation: ModelSnapshot, embedding: ModelSnapshot) throws -> VoiceRecognitionStatus {
        VoiceProfileCalibrator.status(try recognitionProfiles(), segmentation: segmentation, embedding: embedding)
    }

    public func recognitionStatus() throws -> VoiceRecognitionStatus {
        let models = try Self.currentSpeakerModels()
        return try recognitionStatus(segmentation: models.segmentation, embedding: models.embedding)
    }

    static func currentSpeakerModels() throws -> (segmentation: ModelSnapshot, embedding: ModelSnapshot) {
        let catalog = try ModelCatalog.bundled()
        return (try catalog.model(for: .segmentation).snapshot(for: .segmentation),
                try catalog.model(for: .embedding).snapshot(for: .embedding))
    }

    /// Lock the exact current registry until the session transaction finishes.
    /// The registry is not modified. Concurrent updates/removal cannot turn a
    /// deleted or superseded voice into a new automatic assignment after review.
    func withRecognitionSnapshot<T: Sendable>(_ expected: [VoiceRecognitionProfile], corrections: [VoiceCorrection] = [],
        operation: @Sendable () async throws -> T) async throws -> T {
        guard !recognitionCommit else { throw VoiceRecognitionError.busy }
        guard let db = try open(create: false) else { throw VoiceRecognitionError.changed }
        recognitionCommit = true; defer { recognitionCommit = false }
        try db.execute("BEGIN IMMEDIATE")
        do {
            guard try recognitionProfiles(in: db).map({ $0.applying(corrections) }) == expected else { throw VoiceRecognitionError.changed }
            let result = try await operation()
            try db.execute("COMMIT")
            return result
        } catch { try? db.execute("ROLLBACK"); throw error }
    }

    public func revision(_ id: UUID) throws -> VoiceProfileRevision? {
        guard let db = try open(create: false) else { return nil }
        return try revision(id, in: db)
    }

    private func revision(_ id: UUID, in db: SQLiteConnection) throws -> VoiceProfileRevision? {
        guard let row = try db.rows("SELECT payload FROM revisions WHERE id=?", [.text(id.uuidString)]).first else { return nil }
        guard case .blob(let bytes) = row[0] else { throw VoiceEnrollmentError.damagedProfile }
        return try DomainCodec.decode(VoiceProfileRevision.self, from: bytes)
    }

    /// Internal: only the enrollment service can supply newly verified samples.
    /// Revision plus head plus replay guard commit together, or all roll back.
    func enroll(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice,
                segmentation: ModelSnapshot, embedding: ModelSnapshot,
                samples: [VoiceProfileSample], at date: Date = Date()) throws -> VoiceProfile {
        try Task.checkCancellation()
        guard !recognitionCommit else { throw VoiceRecognitionError.busy }
        // A corrected fragment added to an existing voice may be short: the
        // voice already has enough speech (checked below); it only adds data.
        let correction = VoiceEnrollmentPolicy.isCorrection(confirmation, choice)
        guard confirmation.assignment.origin == .manual, let proposedName = confirmation.assignment.name,
              segmentation.role == .segmentation, embedding.role == .embedding,
              ((correction ? 1 : 2)...VoiceEnrollmentPolicy.maximumSamples).contains(samples.count),
              samples.allSatisfy({ VoiceEnrollmentPolicy.validVector($0.vector) && $0.interval.duration.microseconds >= 1_000_000 }),
              correction || samples.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds else {
            throw VoiceEnrollmentError.insufficientSpeech
        }
        let name = try SpeakerRenameError.validatedName(proposedName)
        guard let db = try open(create: true) else { throw VoiceEnrollmentError.unavailable }
        return try db.transaction {
            // A repeated confirmation cannot silently train twice or train a
            // second person. A fresh explicit Save creates a new confirmation.
            guard try db.rows("SELECT assignment_id FROM enrollment_receipts WHERE library_id=? AND assignment_id=?", [
                .text(confirmation.library.manifest.libraryID.uuidString), .text(confirmation.assignment.id.uuidString)]).isEmpty else {
                throw VoiceEnrollmentError.changed
            }
            let id: UUID, previous: UUID?, displayName: String
            switch choice {
            case .newProfile: id = UUID(); previous = nil; displayName = name
            case .existing(let profileID, let revisionID), .replaceIncompatible(let profileID, let revisionID):
                guard let row = try db.rows("SELECT revision_id, payload FROM profiles WHERE id=?", [.text(profileID.uuidString)]).first,
                      case .text(let current) = row[0], current == revisionID.uuidString,
                      case .blob(let bytes) = row[1] else { throw VoiceEnrollmentError.changed }
                let profile = try DomainCodec.decode(VoiceProfile.self, from: bytes)
                guard profile.id == profileID, profile.revisionID == revisionID,
                      let old = try revision(revisionID, in: db), old.id == revisionID, old.profileID == profileID else { throw VoiceEnrollmentError.changed }
                let compatible = try old.embedding == embedding && old.segmentation == segmentation &&
                    old.preprocessingVersion == VoiceEnrollmentPolicy.preprocessing && old.enrollmentPolicyVersion == VoiceEnrollmentPolicy.version &&
                    recognitionProfiles(in: db).first { $0.profile.id == profileID }?.isAdequate == true
                if case .existing = choice, !compatible { throw VoiceEnrollmentError.incompatibleModels }
                if case .replaceIncompatible = choice, compatible { throw VoiceEnrollmentError.changed }
                id = profileID; previous = revisionID; displayName = profile.name
            }
            let revision = VoiceProfileRevision(id: UUID(), profileID: id, previousRevisionID: previous, createdAt: date,
                libraryID: confirmation.library.manifest.libraryID, meetingID: confirmation.assignment.meetingID,
                daySpeakerID: confirmation.speakerID, assignmentID: confirmation.assignment.id,
                segmentation: segmentation, embedding: embedding, preprocessingVersion: VoiceEnrollmentPolicy.preprocessing,
                enrollmentPolicyVersion: VoiceEnrollmentPolicy.version, calibrationVersion: nil, samples: samples)
            let profile = VoiceProfile(id: id, name: displayName, revisionID: revision.id, updatedAt: date)
            try db.execute("INSERT INTO enrollment_receipts VALUES (?,?)", [.text(revision.libraryID.uuidString), .text(revision.assignmentID.uuidString)])
            try db.execute("INSERT INTO revisions VALUES (?,?,?,?,?)", [.text(revision.id.uuidString), .text(id.uuidString),
                .text(revision.libraryID.uuidString), .text(revision.assignmentID.uuidString), .blob(DomainCodec.encode(revision))])
            try db.execute("INSERT INTO profiles VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, revision_id=excluded.revision_id, payload=excluded.payload", [
                .text(id.uuidString), .text(displayName), .text(revision.id.uuidString), .blob(DomainCodec.encode(profile))])
            try Task.checkCancellation()
            return profile
        }
    }

    private func open(create: Bool) throws -> SQLiteConnection? {
        guard rootURL.isFileURL else { throw LibraryError.unsafePath(rootURL.absoluteString) }
        let parts = DirectoryHandle.physicalComponents(rootURL)
        guard !parts.contains(".."), !parts.contains(".") else { throw LibraryError.unsafePath(rootURL.path) }
        var directory = try DirectoryHandle.openAbsolute(URL(fileURLWithPath: "/"))
        for part in parts.dropFirst() {
            if !directory.exists(part) && !create { return nil }
            directory = try create ? directory.createDirectory(part) : directory.directory(part)
        }
        let existing = directory.exists(Self.fileName)
        if !existing && !create { return nil }
        // Reject links/non-regular leaves and sidecars before SQLite opens any.
        for name in [Self.fileName, Self.migrationBackup].flatMap({ [$0, $0 + "-journal", $0 + "-wal", $0 + "-shm"] }) where directory.exists(name) {
            var info = stat()
            guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw LibraryError.unsafePath(name) }
        }
        let path = "/" + parts.dropFirst().joined(separator: "/") + "/" + Self.fileName
        if existing {
            if !directory.exists(Self.fileName + "-wal") && !directory.exists(Self.fileName + "-journal") {
                let header = try SQLiteConnection.closedHeader(in: directory, fileName: Self.fileName)
                guard header.version <= 2 else { throw StoreError.unsupportedSchema(header.version) }
                guard header.applicationID == Self.applicationID, (1...2).contains(header.version) else { throw VoiceEnrollmentError.damagedProfile }
            } else { try validate(SQLiteConnection(path: path, readOnly: true)) }
        }
        if directory.exists(Self.migrationBackup) {
            guard !["-journal", "-wal", "-shm"].contains(where: { directory.exists(Self.migrationBackup + $0) }) else {
                throw VoiceEnrollmentError.damagedProfile
            }
            let header = try SQLiteConnection.closedHeader(in: directory, fileName: Self.migrationBackup)
            guard header.applicationID == Self.applicationID, header.version == 1 else { throw VoiceEnrollmentError.damagedProfile }
        }
        let db = try SQLiteConnection(path: path)
        if existing { try validate(db) }
        try db.execute("PRAGMA synchronous = FULL")
        guard case .text("delete") = try db.rows("PRAGMA journal_mode = DELETE").first?.first else { throw VoiceEnrollmentError.unavailable }
        try db.execute("PRAGMA secure_delete = ON")
        if !existing {
            try db.transaction {
                try db.execute("PRAGMA application_id = \(Self.applicationID)")
                try db.execute("CREATE TABLE profiles (id TEXT PRIMARY KEY, name TEXT NOT NULL, revision_id TEXT NOT NULL, payload BLOB NOT NULL)")
                try db.execute("CREATE TABLE revisions (id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, library_id TEXT NOT NULL, assignment_id TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(library_id,assignment_id))")
                try db.execute("CREATE TABLE enrollment_receipts (library_id TEXT NOT NULL, assignment_id TEXT NOT NULL, PRIMARY KEY(library_id,assignment_id))")
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if try db.integer("PRAGMA user_version") == 1 {
            // Keep a standalone backup only while upgrading. A completed v2
            // open removes it before any deletion can report success.
            if !directory.exists(Self.migrationBackup) {
                try db.backup(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(Self.migrationBackup).path)
            }
            try db.transaction {
                try db.execute("CREATE TABLE enrollment_receipts (library_id TEXT NOT NULL, assignment_id TEXT NOT NULL, PRIMARY KEY(library_id,assignment_id))")
                try db.execute("INSERT INTO enrollment_receipts SELECT library_id,assignment_id FROM revisions")
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if directory.exists(Self.migrationBackup) {
            guard case .text("ok") = try db.rows("PRAGMA quick_check").first?.first else { throw VoiceEnrollmentError.damagedProfile }
            let backupHeader = try SQLiteConnection.closedHeader(in: directory, fileName: Self.migrationBackup)
            guard backupHeader.applicationID == Self.applicationID, backupHeader.version == 1 else { throw VoiceEnrollmentError.damagedProfile }
            // Do not leave an app-created copy of deleted reusable vectors.
            try directory.removeFile(Self.migrationBackup)
        }
        return db
    }

    private func validate(_ db: SQLiteConnection) throws {
        let version = try db.integer("PRAGMA user_version")
        guard version <= 2 else { throw StoreError.unsupportedSchema(version) }
        guard (1...2).contains(version), try db.integer("PRAGMA application_id") == Self.applicationID else { throw VoiceEnrollmentError.damagedProfile }
    }
}
