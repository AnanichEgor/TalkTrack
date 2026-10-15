import Foundation
import Darwin
import SQLite3

public enum StoreError: Error, Equatable, LocalizedError, Sendable {
    case database(String)
    case missingMeeting
    case staleSource
    case cancelledJob
    case invalidResult
    case unsupportedSchema(Int)
    case wrongLibrary

    public var errorDescription: String? {
        switch self {
        case .database(let message): "Could not save the library: \(message). Keep the app open and retry after checking disk space and access."
        case .missingMeeting: "This meeting has been deleted or is unavailable."
        case .staleSource: "The source changed during processing. Retry with the current recording."
        case .cancelledJob: "This processing task was cancelled or replaced."
        case .invalidResult: "The processing result does not match its saved task."
        case .unsupportedSchema(let version): "Database format \(version) requires a newer version of TalkTrack."
        case .wrongLibrary: "The database belongs to a different library. Restore its matching manifest."
        }
    }
}

enum SQLValue {
    case text(String), blob(Data), integer(Int64), real(Double), null
}

/// Single owner, used synchronously only within SessionStore's actor executor.
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            sqlite3_close(handle)
            handle = nil
            throw StoreError.database("\(message): \(path)")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    /// Only for a closed database with no WAL/rollback journal. On macOS 27,
    /// READONLY cannot read a WAL-mode main file after its sidecars are removed.
    /// Read just the documented header to refuse future/foreign files before a
    /// writable SQLite connection can create sidecars. SQLite then revalidates
    /// the actual schema and library UUID before any application write.
    static func closedHeader(in directory: DirectoryHandle, fileName: String = "Library.sqlite3") throws -> (version: Int, applicationID: Int) {
        let file = openat(directory.fd, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw LibraryError.unsafePath(fileName) }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 100 else { throw StoreError.wrongLibrary }
        var bytes = [UInt8](repeating: 0, count: 100), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { pread(file, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LibraryError.io(operation: "read database header", code: errno) }
            offset += count
        }
        guard Array(bytes.prefix(16)) == Array("SQLite format 3\0".utf8),
              [1, 2].contains(bytes[18]), [1, 2].contains(bytes[19]) else { throw StoreError.wrongLibrary }
        func integer(_ start: Int) -> Int { bytes[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        return (integer(60), integer(68))
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure() }
    }

    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var output: [[SQLValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [SQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    let data = Data(bytes: sqlite3_column_text(statement, index), count: count)
                    row.append(.text(String(decoding: data, as: UTF8.self)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row.append(.blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count)))
                default: row.append(.null)
                }
            }
            output.append(row)
        }
    }

    func integer(_ sql: String) throws -> Int {
        guard case .integer(let value) = try rows(sql).first?.first else { throw StoreError.database("Missing schema metadata") }
        return Int(value)
    }

    func transaction<T>(isolation: isolated (any Actor)? = #isolation, _ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func backup(to path: String) throws {
        let destination = try SQLiteConnection(path: path)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else { throw destination.failure() }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw destination.failure() }
        // Backup must be a standalone file, including when the source uses WAL.
        try destination.execute("PRAGMA journal_mode = DELETE")
        guard case .text("ok") = try destination.rows("PRAGMA quick_check").first?.first else {
            throw StoreError.database("Backup integrity check failed")
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let statement = result else { throw failure() }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let code: Int32
                switch value {
                case .text(let text):
                    code = text.utf8CString.withUnsafeBufferPointer {
                        sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient)
                    }
                case .blob(let data):
                    code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
                case .real(let number): code = sqlite3_bind_double(statement, index, number)
                case .null: code = sqlite3_bind_null(statement, index)
                }
                guard code == SQLITE_OK else { throw failure() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func failure() -> StoreError {
        let file = sqlite3_db_filename(handle, "main").map { String(cString: $0) } ?? "unknown database"
        return .database("\(String(cString: sqlite3_errmsg(handle))) (\(sqlite3_extended_errcode(handle))): \(file)")
    }
}
