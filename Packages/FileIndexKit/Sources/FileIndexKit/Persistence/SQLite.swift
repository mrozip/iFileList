import Foundation
import SQLite3

/// An error reported by SQLite, with its result code and message.
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A single SQLite connection. Not thread-safe: callers serialize access.
final class SQLiteConnection {
    let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        return SQLiteStatement(handle: stmt, connection: self)
    }

    /// Runs a query returning a single integer, or nil when it returns no row or NULL.
    func scalarInt(_ sql: String) throws -> Int64? {
        let stmt = try prepare(sql)
        guard try stmt.step(), !stmt.isNull(0) else { return nil }
        return stmt.int64(0)
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: lastErrorMessage)
    }
}

/// A prepared statement. Bind, step until it returns false, then reset before reuse.
final class SQLiteStatement {
    let handle: OpaquePointer
    private let connection: SQLiteConnection

    fileprivate init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func bind(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(handle, index, value)
    }

    func bind(_ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(handle, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(handle, index)
        }
    }

    /// Binds UTF-8 bytes without copying; they must stay valid until the statement is stepped.
    func bind(_ index: Int32, utf8 bytes: UnsafeBufferPointer<UInt8>) {
        let base = UnsafeRawPointer(bytes.baseAddress) ?? UnsafeRawPointer(bitPattern: 1)!
        sqlite3_bind_text(handle, index, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count), nil)
    }

    /// Advances the statement. Returns true when a row is available.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.error(rc)
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Steps to completion and resets the statement.
    func run() throws {
        defer { reset() }
        while try step() {}
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }

    /// The column's UTF-8 bytes, valid until the next step or reset.
    func textBytes(_ column: Int32) -> UnsafeBufferPointer<UInt8> {
        let text = sqlite3_column_text(handle, column)
        let count = Int(sqlite3_column_bytes(handle, column))
        return UnsafeBufferPointer(start: text, count: text == nil ? 0 : count)
    }
}
