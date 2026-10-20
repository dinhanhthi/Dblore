// RewindPlannerTests.swift
// The Data Rewind inverse statements: newest entry first and each entry's rows in reverse, with
// null-safe checks against the after-image, generated columns left out, PostgreSQL identity
// columns re-inserted with OVERRIDING SYSTEM VALUE, the MySQL row check repeating the whole
// WHERE, and the store file treated as untrusted input.

import Foundation
import Testing

@testable import Dblore

@Suite("RewindPlannerTests")
struct RewindPlannerTests {
  private static let start = Date(timeIntervalSince1970: 1_800_000_000)

  private static func entry(
    id: Int64, engine: DatabaseType, schema: String?, table: String, qualifiedName: String,
    columns: [RewindColumn], created: Date = start
  ) -> RewindEntry {
    RewindEntry(
      id: id, connectionKey: "k", schema: schema, table: table, qualifiedName: qualifiedName,
      engine: engine, created: created, state: .committed, editKind: .staged, statementCount: 1,
      columns: columns, notCaptured: false, notRewindableReason: nil)
  }

  // MARK: - SQLite

  private static let sqliteColumns = [
    RewindColumn(name: "id", typeName: "INTEGER"), RewindColumn(name: "label", typeName: "TEXT"),
    RewindColumn(name: "score", typeName: "REAL"), RewindColumn(name: "total", typeName: "REAL"),
  ]
  private static let sqliteTables = [
    RewindTableName(schema: "main", table: "items"): RewindTable(
      columns: ["id", "label", "score", "total"], primaryKey: ["id"], generatedColumns: ["total"])
  ]

  private static func sqliteEntry(id: Int64, created: Date) -> RewindEntry {
    entry(
      id: id, engine: .sqlite, schema: "main", table: "items",
      qualifiedName: "\"main\".\"items\"", columns: sqliteColumns, created: created)
  }

  @Test("SQLite: newest entry first, rows undone in reverse, null-safe checks on the after-image")
  func sqliteInverse() throws {
    let older = Self.sqliteEntry(id: 1, created: Self.start)
    let newer = Self.sqliteEntry(id: 2, created: Self.start.addingTimeInterval(60))
    let update = RewindRow(
      operation: .update, primaryKey: ["id": "1"],
      before: ["id": "1", "label": "'a'", "score": "1.5", "total": "3.0"],
      after: ["id": "1", "label": "'z'", "score": "1.5", "total": "3.0"])
    let delete = RewindRow(
      operation: .delete, primaryKey: ["id": "2"],
      before: ["id": "2", "label": "NULL", "score": "2.25", "total": "4.5"], after: nil)
    let insert = RewindRow(
      operation: .insert, primaryKey: ["id": "10"], before: nil,
      after: ["id": "10", "label": "'n'", "score": "NULL", "total": "NULL"])

    let plan = try RewindPlanner.plan(
      [(older, [update]), (newer, [delete, insert])], tables: Self.sqliteTables, engine: .sqlite)

    #expect(
      plan.statements == [
        BoundStatement(
          sql: "DELETE FROM \"main\".\"items\" WHERE \"id\" = CAST(?1 AS INTEGER)"
            + " AND quote(\"label\") IS ?2 AND quote(\"score\") IS ?3",
          values: ["10", "'n'", "NULL"]),
        BoundStatement(
          sql: "INSERT INTO \"main\".\"items\" (\"id\", \"label\", \"score\")"
            + " VALUES (CAST(?1 AS INTEGER), ?2, CAST(?3 AS REAL))",
          values: ["2", nil, "2.25"]),
        BoundStatement(
          sql: "UPDATE \"main\".\"items\" SET \"label\" = ?1"
            + " WHERE \"id\" = CAST(?2 AS INTEGER) AND quote(\"label\") IS ?3",
          values: ["a", "1", "'z'"]),
      ])
    #expect(plan.entryIDs == [2, 1])
    #expect(plan.origins.map(\.entryID) == [2, 2, 1])
    #expect(plan.origins.map(\.operation) == [.insert, .delete, .update])
    #expect(plan.origins.map(\.key) == ["id = 10", "id = 2", "id = 1"])
    #expect(plan.skipped.isEmpty)
    #expect(
      plan.previews.last
        == "UPDATE \"main\".\"items\" SET \"label\" = 'a'"
        + " WHERE \"id\" = CAST('1' AS INTEGER) AND quote(\"label\") IS '''z''';")
    // Classified and checked by the gate like any other write
    #expect(
      DatabaseConnectionManager.evaluateBatch(
        plan.statements, policy: ProtectionPolicy(protectionLevel: .none), dialect: .sqlite)
        == .allowed)
    #expect(
      DatabaseConnectionManager.evaluateBatch(
        plan.statements, policy: ProtectionPolicy(protectionLevel: .readOnly), dialect: .sqlite)
        != .allowed)
    // DuckDB and MongoDB record no edits, so they have nothing to rewind
    #expect(!DatabaseType.duckdb.supportsDataRewind && !DatabaseType.mongodb.supportsDataRewind)
  }

  @Test("Rows without their images or key are listed as skipped, never planned")
  func uncapturedRowsAreSkipped() throws {
    var entry = Self.sqliteEntry(id: 3, created: Self.start)
    entry.notCaptured = true
    entry.notRewindableReason = RewindPlan.generatedKeyReason
    let rows = [
      RewindRow(operation: .update, primaryKey: [:], before: nil, after: nil),
      RewindRow(operation: .insert, primaryKey: [:], before: nil, after: nil),
      RewindRow(
        operation: .update, primaryKey: ["id": "1"],
        before: ["id": "1", "label": "'a'", "score": "1.5", "total": "3.0"],
        after: ["id": "1", "label": "'b'", "score": "1.5", "total": "3.0"]),
    ]

    // An explicit key whose read after the INSERT found nothing: no generated key in the entry
    var explicit = Self.sqliteEntry(id: 4, created: Self.start.addingTimeInterval(-60))
    explicit.notCaptured = true
    let unread = RewindRow(operation: .insert, primaryKey: [:], before: nil, after: nil)

    let plan = try RewindPlanner.plan(
      [(entry, rows), (explicit, [unread])], tables: Self.sqliteTables, engine: .sqlite)

    #expect(plan.statements.count == 1)
    #expect(plan.skipped.map(\.origin.entryID) == [3, 3, 4])
    #expect(plan.skipped.map(\.origin.operation) == [.insert, .update, .insert])
    #expect(plan.skipped.map(\.reason) == ["generated key", "not captured", "not captured"])
    #expect(plan.entryIDs == [3, 4])
  }

  // MARK: - PostgreSQL

  private static let postgresColumns = [
    RewindColumn(name: "id", typeName: "int4"), RewindColumn(name: "label", typeName: "text"),
    RewindColumn(name: "doc", typeName: "json"),
  ]
  private static let postgresTables = [
    RewindTableName(schema: "public", table: "items"): RewindTable(
      columns: ["id", "label", "doc"], primaryKey: ["id"], identityAlwaysColumns: ["id"])
  ]

  @Test("PostgreSQL: the relation is rebuilt, identity re-inserted, columns compared as text")
  func postgresInverse() throws {
    // `format('%I.%I')` leaves plain lowercase names unquoted
    let entry = Self.entry(
      id: 4, engine: .postgresql, schema: "public", table: "items",
      qualifiedName: "public.items", columns: Self.postgresColumns)
    let rows = [
      RewindRow(
        operation: .delete, primaryKey: ["id": "7"],
        before: ["id": "7", "label": "", "doc": "{\"a\": 1}"], after: nil),
      RewindRow(
        operation: .update, primaryKey: ["id": "8"],
        before: ["id": "8", "label": "old", "doc": nil],
        after: ["id": "8", "label": "new", "doc": nil]),
    ]

    let plan = try RewindPlanner.plan(
      [(entry, rows)], tables: Self.postgresTables, engine: .postgresql)

    #expect(
      plan.statements == [
        BoundStatement(
          sql: "UPDATE \"public\".\"items\" SET \"label\" = $1"
            + " WHERE \"id\" = $2 AND \"label\"::text COLLATE \"C\" IS NOT DISTINCT FROM $3",
          values: ["old", "8", "new"]),
        BoundStatement(
          sql: "INSERT INTO \"public\".\"items\" (\"id\", \"label\", \"doc\")"
            + " OVERRIDING SYSTEM VALUE VALUES ($1, $2, $3)",
          values: ["7", "", "{\"a\": 1}"]),
      ])
    #expect(plan.statements.allSatisfy { $0.rowCheck == nil && $0.expectedRows == 1 })
    // Byte-exact whatever the column's collation: a nondeterministic one can fold case
    #expect(plan.statements[0].sql.contains("::text COLLATE \"C\" IS NOT DISTINCT FROM"))
  }

  // MARK: - MySQL

  @Test("MySQL: the row check of an undo UPDATE repeats the key and every conflict predicate")
  func mysqlRowCheckRepeatsTheWhere() throws {
    let entry = Self.entry(
      id: 5, engine: .mysql, schema: "shop", table: "items", qualifiedName: "`shop`.`items`",
      columns: [
        RewindColumn(name: "id", typeName: "int"), RewindColumn(name: "label", typeName: "varchar"),
        RewindColumn(name: "data", typeName: "varbinary"),
      ])
    let row = RewindRow(
      operation: .update, primaryKey: ["id": "5"],
      before: ["id": "5", "label": "a", "data": "00FF"],
      after: ["id": "5", "label": "b", "data": "0A"])
    let tables = [
      RewindTableName(schema: "shop", table: "items"): RewindTable(
        columns: ["id", "label", "data"], primaryKey: ["id"])
    ]

    let plan = try RewindPlanner.plan([(entry, [row])], tables: tables, engine: .mysql)

    // Byte-exact on both servers: a `_bin` collation pads with spaces, so 'b' would match 'b  '
    let condition =
      "`id` = ? AND CAST(CAST(`label` AS CHAR) AS BINARY) <=> CAST(? AS BINARY)"
      + " AND HEX(`data`) <=> ?"
    #expect(
      plan.statements == [
        BoundStatement(
          sql: "UPDATE `shop`.`items` SET `label` = ?, `data` = UNHEX(?) WHERE \(condition)",
          values: ["a", "00FF", "5", "b", "0A"],
          rowCheck: RowExistenceCheck(
            sql: "SELECT 1 FROM `shop`.`items` WHERE \(condition) FOR UPDATE",
            values: ["5", "b", "0A"]))
      ])
    #expect(
      plan.statements.allSatisfy {
        !$0.sql.contains("COLLATE") && !($0.rowCheck?.sql.contains("COLLATE") ?? true)
      })
  }

  // MARK: - Untrusted store

  /// One way a tampered (or stale) store file differs from what the live table allows
  enum Tamper: String, CaseIterable, Sendable {
    case injectedName
    case otherTable
    case nulInColumn
    case droppedColumn
    case otherKey
    case partialImage
    case otherEngine
    case badLiteral
  }

  @Test(
    "An entry the store or the live table cannot vouch for is refused", arguments: Tamper.allCases)
  func tamperedEntryIsRefused(_ tamper: Tamper) {
    var entry = Self.sqliteEntry(id: 6, created: Self.start)
    var row = RewindRow(
      operation: .update, primaryKey: ["id": "1"],
      before: ["id": "1", "label": "'a'", "score": "1.5", "total": "3.0"],
      after: ["id": "1", "label": "'z'", "score": "1.5", "total": "3.0"])
    var engine = DatabaseType.sqlite
    switch tamper {
    case .injectedName:
      entry.qualifiedName = "\"main\".\"items\"; DROP TABLE \"items\"; --"
    case .otherTable:
      entry.qualifiedName = "\"main\".\"secrets\""
    case .nulInColumn:
      entry.columns[1].name = "la\0bel"
    case .droppedColumn:
      entry.columns.append(RewindColumn(name: "gone", typeName: "TEXT"))
      row.before?.updateValue("NULL", forKey: "gone")
      row.after?.updateValue("NULL", forKey: "gone")
    case .otherKey:
      row.primaryKey = ["label": "'z'"]
    case .partialImage:
      row.after?.removeValue(forKey: "score")
    case .otherEngine:
      engine = .postgresql
    case .badLiteral:
      row.before?.updateValue("1); DROP TABLE items; --", forKey: "label")
    }

    #expect(throws: RewindPlannerError.self) {
      try RewindPlanner.plan([(entry, [row])], tables: Self.sqliteTables, engine: engine)
    }
  }
}
