import Foundation

/// In-process access to recording folders (compact-library-storage D7).
///
/// Anything that reads receipts and opens chunk files, moves, splits or
/// deletes a recording folder, or copies the library holds *reading* access.
/// Reading never waits for other readers. Chunk compaction takes *writing*
/// access without waiting, one chunk at a time, and skips the recording when
/// someone reads it. A reader that arrives during a chunk's replacement waits
/// for that one chunk; compaction then gives the recording up.
///
/// The `.writer.lock` file lock separately keeps compaction away from a
/// recording being captured or recovered.
public final class RecordingAccess: @unchecked Sendable {
    public static let shared = RecordingAccess()

    private let condition = NSCondition()
    private var readers: [UUID: Int] = [:]
    private var libraryReaders: [UUID: Int] = [:]
    private var writing: Set<UUID> = []
    private var waiting: [UUID: Int] = [:]
    private var waitingLibraries: [UUID: Int] = [:]

    init() {}

    /// Runs `body` with reading access to `recordingID`, waiting while one
    /// chunk of it is being replaced.
    public func reading<T>(_ recordingID: UUID, _ body: () throws -> T) rethrows -> T {
        condition.lock()
        while writing.contains(recordingID) {
            waiting[recordingID, default: 0] += 1
            condition.wait()
            waiting[recordingID, default: 1] -= 1
            if waiting[recordingID] == 0 { waiting[recordingID] = nil }
        }
        readers[recordingID, default: 0] += 1
        condition.unlock()
        defer { release(recordingID) }
        return try body()
    }

    /// Reading access to every recording of one library (meeting delete,
    /// library migration).
    public func readingLibrary<T>(_ libraryID: UUID, _ body: () throws -> T) rethrows -> T {
        beginReadingLibrary(libraryID)
        defer { endReadingLibrary(libraryID) }
        return try body()
    }

    /// `readingLibrary` for callers that suspend in between; pair with `endReadingLibrary`.
    /// Waits for chunks being replaced anywhere (at most one per recording).
    public func beginReadingLibrary(_ libraryID: UUID) {
        condition.lock()
        while !writing.isEmpty {
            waitingLibraries[libraryID, default: 0] += 1
            condition.wait()
            waitingLibraries[libraryID, default: 1] -= 1
            if waitingLibraries[libraryID] == 0 { waitingLibraries[libraryID] = nil }
        }
        libraryReaders[libraryID, default: 0] += 1
        condition.unlock()
    }

    public func endReadingLibrary(_ libraryID: UUID) {
        condition.lock()
        libraryReaders[libraryID, default: 1] -= 1
        if libraryReaders[libraryID] == 0 { libraryReaders[libraryID] = nil }
        condition.broadcast()
        condition.unlock()
    }

    /// Writing access when nobody reads or waits for the recording or its
    /// library; never waits.
    func tryWriting(_ recordingID: UUID, library libraryID: UUID) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard libraryReaders[libraryID] == nil, waitingLibraries[libraryID] == nil, readers[recordingID] == nil,
              waiting[recordingID] == nil, !writing.contains(recordingID) else { return false }
        writing.insert(recordingID)
        return true
    }

    func endWriting(_ recordingID: UUID) {
        condition.lock()
        writing.remove(recordingID)
        condition.broadcast()
        condition.unlock()
    }

    /// Someone reads or waits for the recording: compaction should give it up.
    func isWanted(_ recordingID: UUID, library libraryID: UUID) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return libraryReaders[libraryID] != nil || waitingLibraries[libraryID] != nil
            || readers[recordingID] != nil || waiting[recordingID] != nil
    }

    private func release(_ recordingID: UUID) {
        condition.lock()
        readers[recordingID, default: 1] -= 1
        if readers[recordingID] == 0 { readers[recordingID] = nil }
        condition.broadcast()
        condition.unlock()
    }
}
