import Foundation
import SQLite3

/// Tiny SQLite wrapper (system libsqlite3). Not thread-safe by itself: owned by one actor.
nonisolated final class SQLiteDB {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private(set) var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    init(path: String) throws(Failure) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw Failure(description: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        cache.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(handle)
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws(Failure) {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw Failure(description: msg)
        }
    }

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null
    }

    /// Runs a statement, calling `row` for each result row. Statements are cached by SQL text.
    @discardableResult
    func run(_ sql: String, _ args: [Value] = [], row: ((Row) -> Void)? = nil) -> Result<Void, Failure> {
        let stmt: OpaquePointer
        if let s = cache[sql] {
            stmt = s
        } else {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
                return .failure(Failure(description: "\(errorMessage) in: \(sql)"))
            }
            cache[sql] = s
            stmt = s
        }
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row?(Row(stmt: stmt)); continue }
            if rc == SQLITE_DONE { return .success(()) }
            return .failure(Failure(description: "\(errorMessage) in: \(sql)"))
        }
    }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    func transaction(_ body: () -> Void) {
        _ = try? exec("BEGIN IMMEDIATE")
        body()
        _ = try? exec("COMMIT")
    }
}
