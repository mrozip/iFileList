import Foundation
import SQLite3

/// An indexed volume as recorded in the cache.
public struct VolumeRecord: Sendable, Equatable {
    public var id: Int64
    /// Volume UUID, or the mount path for volumes without one.
    public var key: String
    public var mountPath: String
    public var rootEntry: EntryID
    /// FSEvents database UUID of the volume when it was scanned; a mismatch means history was reset.
    public var eventStreamUUID: String?
    public var isComplete: Bool
}

/// An entry row read back from the cache. `name` is only valid inside the callback that receives it.
public struct StoredEntry {
    public var id: EntryID
    public var parent: EntryID
    public var volume: Int64
    public var flags: EntryFlags
    public var size: Int64
    public var mtime: Int64
    public var crtime: Int64
    public var name: UnsafeBufferPointer<UInt8>
}

/// The persistent file list cache (SQLite).
///
/// Every method takes an internal lock, so the coordinator and scanner threads can share the one
/// connection. Inserts made while a transaction is open (see `beginTransaction()`) join it.
public final class IndexDatabase: @unchecked Sendable {
    public static let schemaVersion: Int64 = 2

    public let url: URL
    private let lock = NSLock()
    private let db: SQLiteConnection
    private let insertEntryStatement: SQLiteStatement
    private let updateEntryStatement: SQLiteStatement
    private let deleteEntryStatement: SQLiteStatement
    private let childStatement: SQLiteStatement
    private let childIgnoringCaseStatement: SQLiteStatement
    private let descendantsStatement: SQLiteStatement

    /// Opens the cache at `url`, recreating it if it is unreadable or uses another schema version.
    public static func open(at url: URL) throws -> IndexDatabase {
        do {
            return try IndexDatabase(url: url)
        } catch {
            removeFiles(at: url)
            return try IndexDatabase(url: url)
        }
    }

    static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteConnection(path: url.path)
        try db.execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA temp_store=MEMORY;
            PRAGMA cache_size=-65536;
            """)
        let version = try db.scalarInt("PRAGMA user_version") ?? 0
        if version == 0 {
            try Self.createSchema(db)
        } else if version != Self.schemaVersion {
            throw SQLiteError(
                code: SQLITE_MISMATCH,
                message: "cache schema version \(version), expected \(Self.schemaVersion)")
        }

        insertEntryStatement = try db.prepare(
            "INSERT INTO entries(id, parent, volume, name, flags, size, mtime, crtime) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        updateEntryStatement = try db.prepare(
            "UPDATE entries SET flags = ?, size = ?, mtime = ?, crtime = ? WHERE id = ?")
        deleteEntryStatement = try db.prepare("DELETE FROM entries WHERE id = ?")
        childStatement = try db.prepare(
            "SELECT id, flags FROM entries WHERE parent = ? AND name = ? LIMIT 1")
        childIgnoringCaseStatement = try db.prepare(
            "SELECT id, flags FROM entries WHERE parent = ? AND name = ? COLLATE NOCASE LIMIT 1")
        descendantsStatement = try db.prepare("""
            WITH RECURSIVE sub(id) AS (
                SELECT id FROM entries WHERE parent = ?1
                UNION ALL
                SELECT e.id FROM entries e JOIN sub ON e.parent = sub.id
            )
            SELECT id FROM sub
            """)
    }

    private static func createSchema(_ db: SQLiteConnection) throws {
        try db.execute("""
            BEGIN;
            CREATE TABLE entries(
                id INTEGER PRIMARY KEY,
                parent INTEGER NOT NULL,
                volume INTEGER NOT NULL,
                name TEXT NOT NULL,
                flags INTEGER NOT NULL,
                size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                crtime INTEGER NOT NULL
            );
            CREATE INDEX entries_parent_name ON entries(parent, name);
            CREATE TABLE volumes(
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL,
                mount_path TEXT NOT NULL,
                root_entry INTEGER NOT NULL,
                event_uuid TEXT,
                complete INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version = \(schemaVersion);
            COMMIT;
            """)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Runs `body` in a transaction unless one is already open. Call with the lock held.
    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        if db.isInTransaction { return try body() }
        try db.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try db.execute("COMMIT")
            return result
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Transactions

    public func beginTransaction() throws {
        try locked { try db.execute("BEGIN IMMEDIATE") }
    }

    public func commit() throws {
        try locked { try db.execute("COMMIT") }
    }

    public func rollback() {
        locked { try? db.execute("ROLLBACK") }
    }

    // MARK: Entries

    public func insert(_ batch: EntryBatch, volume: Int64) throws {
        try locked {
            try inTransaction {
                let stmt = insertEntryStatement
                for i in 0..<batch.count {
                    stmt.bind(1, Int64(batch.ids[i]))
                    stmt.bind(2, Int64(batch.parents[i]))
                    stmt.bind(3, volume)
                    stmt.bind(5, Int64(batch.flags[i].intersection(.persistent).rawValue))
                    stmt.bind(6, batch.sizes[i])
                    stmt.bind(7, batch.mtimes[i])
                    stmt.bind(8, batch.crtimes[i])
                    try batch.withName(at: i) { name in
                        stmt.bind(4, utf8: name)
                        try stmt.run()
                    }
                }
            }
        }
    }

    public func updateEntry(_ id: EntryID, flags: EntryFlags, size: Int64, mtime: Int64, crtime: Int64) throws {
        try locked {
            let stmt = updateEntryStatement
            stmt.bind(1, Int64(flags.intersection(.persistent).rawValue))
            stmt.bind(2, size)
            stmt.bind(3, mtime)
            stmt.bind(4, crtime)
            stmt.bind(5, Int64(id))
            try stmt.run()
        }
    }

    public func deleteEntries(_ ids: [EntryID]) throws {
        guard !ids.isEmpty else { return }
        try locked {
            try inTransaction {
                for id in ids {
                    deleteEntryStatement.bind(1, Int64(id))
                    try deleteEntryStatement.run()
                }
            }
        }
    }

    /// Looks up a directory's child by name. Without `ignoringCase` the match is exact (byte-wise).
    public func child(of parent: EntryID, named name: String, ignoringCase: Bool = false)
        throws -> (id: EntryID, flags: EntryFlags)?
    {
        try locked {
            let stmt = ignoringCase ? childIgnoringCaseStatement : childStatement
            defer { stmt.reset() }
            stmt.bind(1, Int64(parent))
            stmt.bind(2, name)
            guard try stmt.step() else { return nil }
            return (EntryID(stmt.int64(0)), EntryFlags(rawValue: UInt8(truncatingIfNeeded: stmt.int64(1))))
        }
    }

    /// All entries below `id`, not including `id` itself.
    public func descendants(of id: EntryID) throws -> [EntryID] {
        try locked {
            let stmt = descendantsStatement
            defer { stmt.reset() }
            stmt.bind(1, Int64(id))
            var result: [EntryID] = []
            while try stmt.step() {
                result.append(EntryID(stmt.int64(0)))
            }
            return result
        }
    }

    /// Calls `body` for every entry in ID order.
    public func forEachEntry(_ body: (StoredEntry) throws -> Void) throws {
        try locked {
            let stmt = try db.prepare(
                "SELECT id, parent, volume, flags, size, mtime, crtime, name FROM entries ORDER BY id")
            while try stmt.step() {
                try body(StoredEntry(
                    id: EntryID(stmt.int64(0)),
                    parent: EntryID(stmt.int64(1)),
                    volume: stmt.int64(2),
                    flags: EntryFlags(rawValue: UInt8(truncatingIfNeeded: stmt.int64(3))),
                    size: stmt.int64(4),
                    mtime: stmt.int64(5),
                    crtime: stmt.int64(6),
                    name: stmt.textBytes(7)))
            }
        }
    }

    public func entryCount() throws -> Int {
        try locked { Int(try db.scalarInt("SELECT count(*) FROM entries") ?? 0) }
    }

    public func maxEntryID() throws -> EntryID {
        try locked { EntryID(try db.scalarInt("SELECT max(id) FROM entries") ?? 0) }
    }

    // MARK: Volumes

    public func volumes() throws -> [VolumeRecord] {
        try locked {
            let stmt = try db.prepare(
                "SELECT id, key, mount_path, root_entry, event_uuid, complete FROM volumes ORDER BY id")
            var result: [VolumeRecord] = []
            while try stmt.step() {
                result.append(VolumeRecord(
                    id: stmt.int64(0),
                    key: stmt.string(1) ?? "",
                    mountPath: stmt.string(2) ?? "",
                    rootEntry: EntryID(stmt.int64(3)),
                    eventStreamUUID: stmt.string(4),
                    isComplete: stmt.int64(5) != 0))
            }
            return result
        }
    }

    /// Records a volume whose scan is starting. It stays incomplete until `markVolumeComplete`.
    public func insertVolume(key: String, mountPath: String, rootEntry: EntryID, eventStreamUUID: String?)
        throws -> VolumeRecord
    {
        try locked {
            let stmt = try db.prepare(
                "INSERT INTO volumes(key, mount_path, root_entry, event_uuid, complete) VALUES (?, ?, ?, ?, 0)")
            stmt.bind(1, key)
            stmt.bind(2, mountPath)
            stmt.bind(3, Int64(rootEntry))
            stmt.bind(4, eventStreamUUID)
            try stmt.run()
            return VolumeRecord(
                id: sqlite3_last_insert_rowid(db.handle), key: key, mountPath: mountPath,
                rootEntry: rootEntry, eventStreamUUID: eventStreamUUID, isComplete: false)
        }
    }

    public func markVolumeComplete(_ id: Int64) throws {
        try locked {
            let stmt = try db.prepare("UPDATE volumes SET complete = 1 WHERE id = ?")
            stmt.bind(1, id)
            try stmt.run()
        }
    }

    /// Deletes a volume record and all of its entries.
    public func deleteVolume(_ id: Int64) throws {
        try locked {
            try inTransaction {
                let entries = try db.prepare("DELETE FROM entries WHERE volume = ?")
                entries.bind(1, id)
                try entries.run()
                let volume = try db.prepare("DELETE FROM volumes WHERE id = ?")
                volume.bind(1, id)
                try volume.run()
            }
        }
    }

    // MARK: Metadata

    public func value(forKey key: String) throws -> String? {
        try locked {
            let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?")
            stmt.bind(1, key)
            return try stmt.step() ? stmt.string(0) : nil
        }
    }

    public func setValue(_ value: String, forKey key: String) throws {
        try locked {
            let stmt = try db.prepare("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)")
            stmt.bind(1, key)
            stmt.bind(2, value)
            try stmt.run()
        }
    }

    // MARK: Maintenance

    /// Renumbers entries densely when deleted rows have left too many unused IDs.
    ///
    /// The in-memory index allocates one slot per ID, so gaps cost memory. Renumbering keeps
    /// ID order, which preserves the parent-before-child invariant.
    @discardableResult
    public func compactIDsIfNeeded(minimumWaste: Double = 0.3) throws -> Bool {
        try locked {
            let maxID = try db.scalarInt("SELECT max(id) FROM entries") ?? 0
            let count = try db.scalarInt("SELECT count(*) FROM entries") ?? 0
            guard maxID > 100_000, Double(maxID - count) / Double(maxID) > minimumWaste else { return false }
            try inTransaction {
                try db.execute("""
                    CREATE TEMP TABLE idmap(old INTEGER PRIMARY KEY, new INTEGER NOT NULL);
                    INSERT INTO idmap(old, new) SELECT id, ROW_NUMBER() OVER (ORDER BY id) FROM entries;
                    CREATE TABLE entries_new(
                        id INTEGER PRIMARY KEY,
                        parent INTEGER NOT NULL,
                        volume INTEGER NOT NULL,
                        name TEXT NOT NULL,
                        flags INTEGER NOT NULL,
                        size INTEGER NOT NULL,
                        mtime INTEGER NOT NULL,
                        crtime INTEGER NOT NULL
                    );
                    INSERT INTO entries_new(id, parent, volume, name, flags, size, mtime, crtime)
                        SELECT m.new, COALESCE(p.new, 0), e.volume, e.name, e.flags, e.size, e.mtime, e.crtime
                        FROM entries e
                        JOIN idmap m ON m.old = e.id
                        LEFT JOIN idmap p ON p.old = e.parent
                        ORDER BY m.new;
                    UPDATE volumes SET root_entry = COALESCE(
                        (SELECT new FROM idmap WHERE old = volumes.root_entry), 0);
                    DROP TABLE entries;
                    ALTER TABLE entries_new RENAME TO entries;
                    CREATE INDEX entries_parent_name ON entries(parent, name);
                    DROP TABLE idmap;
                    """)
            }
            return true
        }
    }
}
