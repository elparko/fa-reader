import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var code: Int32 = 0
    public var description: String { message }
}

public struct Row {
    let columns: [String: Int]
    let values: [Any?]

    public subscript(_ name: String) -> Any? { columns[name].flatMap { values[$0] } }
    public func int(_ name: String) -> Int { (self[name] as? Int64).map(Int.init) ?? 0 }
    public func double(_ name: String) -> Double { (self[name] as? Double) ?? (self[name] as? Int64).map(Double.init) ?? 0 }
    public func string(_ name: String) -> String { (self[name] as? String) ?? "" }
    public func optionalString(_ name: String) -> String? { self[name] as? String }
}

public final class Database {
    let handle: OpaquePointer
    public let path: String

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw DatabaseError(message: "cannot open \(path)")
        }
        handle = db
        self.path = path
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close_v2(handle) }

    private var lastError: DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)), code: sqlite3_extended_errcode(handle) & 0xFF)
    }

    public var userVersion: Int { Int((try? scalar("PRAGMA user_version") as? Int64) ?? 0) }

    public func migrate(_ steps: [(Database) throws -> Void]) throws {
        let current = userVersion
        if current > steps.count {
            throw DatabaseError(message: "This book's saved data was made by a newer version of Rowlight (schema \(current)). Update the app to open it.")
        }
        guard current < steps.count else { return }
        try transaction {
            for step in steps[current...] { try step(self) }
            try exec("PRAGMA user_version=\(steps.count)")
        }
    }

    public static func openRecovering(path: String, setup: (Database) throws -> Void) throws -> Database {
        do {
            let db = try Database(path: path)
            try setup(db)
            return db
        } catch let error as DatabaseError where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try FileManager.default.moveItem(atPath: path + suffix, toPath: "\(path).corrupt-\(stamp)\(suffix)")
            }
            let db = try Database(path: path)
            try setup(db)
            return db
        }
    }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(arg!)", -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    public func run(_ sql: String, _ args: Any?...) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    public func query(_ sql: String, _ args: Any?...) throws -> [Row] {
        try query(sql, arguments: args)
    }

    public func query(_ sql: String, arguments args: [Any?]) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let count = sqlite3_column_count(stmt)
        var columns: [String: Int] = [:]
        for i in 0..<count { columns[String(cString: sqlite3_column_name(stmt, i))] = Int(i) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError }
            var values: [Any?] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: values.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: values.append(String(cString: sqlite3_column_text(stmt, i)))
                default: values.append(nil)
                }
            }
            rows.append(Row(columns: columns, values: values))
        }
        return rows
    }

    public func scalar(_ sql: String, _ args: Any?...) throws -> Any? {
        try query(sql, arguments: args).first?.values.first ?? nil
    }

    private var depth = 0

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        depth += 1
        defer { depth -= 1 }
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
