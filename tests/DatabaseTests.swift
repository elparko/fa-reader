import Foundation
import Testing
@testable import FACore

private func tempDatabase() throws -> Database {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("db-\(UUID().uuidString).sqlite").path
    return try Database(path: path)
}

private struct Boom: Error {}

@Test func databaseBindsAndReadsAllTypes() throws {
    let db = try tempDatabase()
    try db.exec("CREATE TABLE t(i INTEGER, r REAL, s TEXT, n TEXT, b INTEGER)")
    try db.run("INSERT INTO t VALUES(?,?,?,?,?)", 42, 2.5, "héllo #tag", nil, true)
    try db.run("INSERT INTO t VALUES(?,?,?,?,?)", Int64.max, -0.125, "", nil, false)
    let rows = try db.query("SELECT * FROM t ORDER BY rowid")
    #expect(rows[0].int("i") == 42)
    #expect(rows[0].double("r") == 2.5)
    #expect(rows[0].string("s") == "héllo #tag")
    #expect(rows[0]["n"] == nil)
    #expect(rows[0].optionalString("n") == nil)
    #expect(rows[0].int("b") == 1)
    #expect(rows[1].int("i") == Int.max)
    #expect(rows[1].double("r") == -0.125)
    #expect(rows[1].string("s") == "")
    #expect(rows[1].optionalString("s") == "")
    #expect(rows[1].int("b") == 0)
    #expect(rows[0].double("i") == 42)
    #expect(rows[0].string("missing") == "")
}

@Test func databaseScalarAndChanges() throws {
    let db = try tempDatabase()
    try db.exec("CREATE TABLE t(a INTEGER)")
    try db.run("INSERT INTO t VALUES(1),(2),(3)")
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 3)
    #expect(try db.scalar("SELECT a FROM t WHERE a=?", 99) == nil)
    try db.run("UPDATE t SET a=a+1 WHERE a>?", 1)
    #expect(db.changes == 2)
    try db.run("INSERT INTO t VALUES(?)", 10)
    #expect(db.lastInsertRowID == 4)
}

@Test func databaseThrowsOnBadSQL() throws {
    let db = try tempDatabase()
    #expect(throws: DatabaseError.self) { try db.exec("NOT SQL") }
    #expect(throws: DatabaseError.self) { try db.run("INSERT INTO missing VALUES(1)") }
    #expect(throws: DatabaseError.self) { _ = try db.query("SELECT * FROM missing") }
}

@Test func databaseTransactionCommits() throws {
    let db = try tempDatabase()
    try db.exec("CREATE TABLE t(a INTEGER)")
    let result = try db.transaction { () -> Int in
        try db.run("INSERT INTO t VALUES(1)")
        return 7
    }
    #expect(result == 7)
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 1)
}

@Test func databaseTransactionRollsBackOnThrow() throws {
    let db = try tempDatabase()
    try db.exec("CREATE TABLE t(a INTEGER)")
    try db.run("INSERT INTO t VALUES(1)")
    #expect(throws: Boom.self) {
        try db.transaction {
            try db.run("INSERT INTO t VALUES(2)")
            try db.run("INSERT INTO t VALUES(3)")
            throw Boom()
        }
    }
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 1)
    try db.transaction { try db.run("INSERT INTO t VALUES(4)") }
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 2)
}

@Test func databaseNestedTransactionJoinsOuter() throws {
    let db = try tempDatabase()
    try db.exec("CREATE TABLE t(a INTEGER)")
    try db.transaction {
        try db.run("INSERT INTO t VALUES(1)")
        try db.transaction { try db.run("INSERT INTO t VALUES(2)") }
    }
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 2)

    #expect(throws: Boom.self) {
        try db.transaction {
            try db.run("INSERT INTO t VALUES(3)")
            try db.transaction {
                try db.run("INSERT INTO t VALUES(4)")
                throw Boom()
            }
        }
    }
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 2)
}

@Test func databaseNestedInnerErrorCaughtByOuterStillCommits() throws {
    let db = try tempDatabase()
    try db.exec("CREATE TABLE t(a INTEGER)")
    try db.transaction {
        try db.run("INSERT INTO t VALUES(1)")
        _ = try? db.transaction { throw Boom() }
        try db.run("INSERT INTO t VALUES(2)")
    }
    #expect(try db.scalar("SELECT COUNT(*) FROM t") as? Int64 == 2)
}

@Test func databaseHasFTS5() throws {
    let db = try tempDatabase()
    try db.exec("CREATE VIRTUAL TABLE f USING fts5(text, prefix='2 3')")
    try db.run("INSERT INTO f(text) VALUES(?)", "Graves disease causes hyperthyroidism")
    try db.run("INSERT INTO f(text) VALUES(?)", "Hashimoto thyroiditis")
    let rows = try db.query("SELECT text FROM f WHERE f MATCH ?", "thyroid*")
    #expect(rows.count == 1)
    #expect(rows[0].string("text").hasPrefix("Hashimoto"))
    #expect(try db.query("SELECT text FROM f WHERE f MATCH ?", "graves").count == 1)
}

@Test func databaseUsesWriteAheadLogging() throws {
    let db = try tempDatabase()
    #expect(try db.scalar("PRAGMA journal_mode") as? String == "wal")
    #expect(try db.scalar("PRAGMA foreign_keys") as? Int64 == 1)
}

@Test func databaseReopenKeepsData() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("db-\(UUID().uuidString).sqlite").path
    do {
        let db = try Database(path: path)
        try db.exec("CREATE TABLE t(a INTEGER)")
        try db.run("INSERT INTO t VALUES(5)")
    }
    let db = try Database(path: path)
    #expect(try db.scalar("SELECT a FROM t") as? Int64 == 5)
}
