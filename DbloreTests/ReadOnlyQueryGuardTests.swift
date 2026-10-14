// ReadOnlyQueryGuardTests.swift
// The shared read-only guard: one read statement, no session or privilege change, no
// PostgreSQL side-effect function.

import Foundation
import Testing

@testable import Dblore

@Suite("ReadOnlyQueryGuard")
struct ReadOnlyQueryGuardTests {

  @Test func selectPassesAndReturnsTheStatement() throws {
    let statements = try ReadOnlyQueryGuard.check("SELECT * FROM users", dialect: .postgresql)
    #expect(statements.count == 1)
    #expect(statements.first?.kind == .read)
  }

  @Test(arguments: ["", "   \n\t"])
  func emptySQLIsRefused(sql: String) {
    #expect(throws: ReadOnlyQueryGuard.Refusal.empty) {
      try ReadOnlyQueryGuard.check(sql, dialect: .postgresql)
    }
  }

  @Test func multipleStatementsAreRefused() {
    #expect(throws: ReadOnlyQueryGuard.Refusal.multipleStatements) {
      try ReadOnlyQueryGuard.check("SELECT 1; SELECT 2", dialect: .postgresql)
    }
  }

  @Test(arguments: ["UPDATE t SET a = 1", "SET search_path = x", "GRANT SELECT ON t TO u"])
  func nonReadStatementsAreRefused(sql: String) {
    #expect(throws: ReadOnlyQueryGuard.Refusal.notRead) {
      try ReadOnlyQueryGuard.check(sql, dialect: .postgresql)
    }
  }

  @Test func postgresSideEffectFunctionIsRefused() {
    #expect(throws: ReadOnlyQueryGuard.Refusal.sideEffectFunction) {
      try ReadOnlyQueryGuard.check("SELECT pg_sleep(1)", dialect: .postgresql)
    }
  }

  @Test func sideEffectFunctionNamePassesOutsidePostgres() throws {
    let statements = try ReadOnlyQueryGuard.check("SELECT pg_sleep(1)", dialect: .sqlite)
    #expect(statements.count == 1)
  }

  @Test func columnListAliasPassesOnPostgres() throws {
    let statements = try ReadOnlyQueryGuard.check(
      "SELECT * FROM (VALUES (1, 2)) AS t(a, b)", dialect: .postgresql)
    #expect(statements.count == 1)
  }

  @Test func refusalsTellNothingWasSent() {
    let refusals: [ReadOnlyQueryGuard.Refusal] = [
      .empty, .multipleStatements, .notRead, .sideEffectFunction, .fileAccess,
    ]
    for refusal in refusals {
      #expect(refusal.localizedDescription.hasSuffix("Nothing was sent to the database."))
    }
  }

  @Test(arguments: [
    "SELECT * FROM read_csv('/etc/passwd')",
    "SELECT * FROM '/Users/x/.ssh/id_rsa'",
    "SELECT * FROM t JOIN read_text('a') r ON true",
    "SELECT * FROM glob('*')",
    "SELECT * FROM main.parquet_scan('x.parquet')",
    "SELECT * FROM \"/etc/passwd.csv\"",
    "SELECT * FROM \"data.parquet\"",
    "SELECT * FROM t, '/path/file.csv'",
    "SELECT * FROM t, \"x.csv\"",
    "SELECT * FROM (SELECT 1) s, \"~/notes.txt\"",
    "SELECT * FROM query_table('t')",
    "SELECT * FROM (SUMMARIZE 'f.csv')",
    "SELECT * FROM t, (DESCRIBE \"x.csv\") d",
    "SELECT * FROM (TABLE \"f.csv\") s",
    "SELECT * FROM (PIVOT 'f.csv' ON a USING sum(b))",
    "TABLE \"data.csv\"",
    "SUMMARIZE \"data.csv\"",
    "DESCRIBE \"data.csv\"",
    "PIVOT 'f.csv' ON a USING sum(b)",
    "SELECT * FROM (PIVOT_WIDER 'f.csv' ON a USING sum(b))",
    "SELECT * FROM (PIVOT_LONGER \"f.csv\" ON a, b)",
    "SELECT * FROM (SHOW 'f.csv')",
    "SELECT * FROM (\"data.csv\" CROSS JOIN t)",
    "SELECT * FROM t, ('x.csv')",
  ])
  func duckDBFileAccessIsRefusedWhenAsked(sql: String) throws {
    #expect(throws: ReadOnlyQueryGuard.Refusal.fileAccess) {
      try ReadOnlyQueryGuard.check(sql, dialect: .duckdb, refuseFileAccess: true)
    }
    #expect(try ReadOnlyQueryGuard.check(sql, dialect: .duckdb).count == 1)
  }

  @Test(arguments: [
    "SELECT read_count FROM t", "SELECT 'x' FROM t", "SELECT * FROM \"Orders\"",
    "SELECT a, b FROM t, u", "SELECT a, 'x.csv' FROM t WHERE b IN ('/a', 'b.csv')",
    "SELECT (SELECT max(a) FROM t), 'x.csv' FROM u", "SELECT 1",
    "WITH x AS (SELECT 1) SELECT * FROM x", "FROM t SELECT a", "(SELECT 1)", "VALUES (1)",
    "SELECT * FROM (SELECT 1) s", "SELECT * FROM (t CROSS JOIN u)",
  ])
  func duckDBColumnsAndStringsPassFileAccessCheck(sql: String) throws {
    let statements = try ReadOnlyQueryGuard.check(sql, dialect: .duckdb, refuseFileAccess: true)
    #expect(statements.count == 1)
  }

  @Test(arguments: ["SELECT * FROM query('SELECT 1')", "SELECT getenv('HOME')"])
  func duckDBQueryAndGetenvAreRefused(sql: String) {
    #expect(throws: ReadOnlyQueryGuard.Refusal.notRead) {
      try ReadOnlyQueryGuard.check(sql, dialect: .duckdb, refuseFileAccess: true)
    }
  }
}
