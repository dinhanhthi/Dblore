// TableHealthReportTests.swift
// Table Health's structure checks: a table without a primary key, and a foreign key no index
// covers. An index covers a foreign key when the key's columns are its leading key columns, in any
// order inside that prefix; a partial index or an expression in that prefix does not count.
// Statistic rows from PostgreSQL and MySQL map to unused-index, dead-row and redundant-index
// findings, and a server without the statistics gives one note instead.

import Foundation
import Testing

@testable import Dblore

struct TableHealthReportTests {
  private static func index(
    _ keys: [TableStructure.Index.Key], partial: Bool = false
  ) -> TableStructure.Index {
    TableStructure.Index(
      name: "child_idx", keys: keys, isUnique: false, isPrimary: false, method: "btree",
      isPartial: partial, predicate: partial ? "(a > 0)" : nil)
  }

  private static func structure(
    foreignKey: [String], indexes: [TableStructure.Index],
    primaryKey: [String] = ["id"]
  ) -> TableStructure {
    var constraints: [TableStructure.Constraint] = [
      .init(
        name: "child_parent_fk",
        kind: .foreignKey(
          .init(
            schema: "public", table: "parent", columns: foreignKey.map { "p_\($0)" },
            onUpdate: .noAction, onDelete: .noAction)),
        columns: foreignKey)
    ]
    if !primaryKey.isEmpty {
      constraints.append(.init(name: "child_pkey", kind: .primaryKey, columns: primaryKey))
    }
    return TableStructure(
      tableID: .postgresql(oid: 16_400), schema: "public", name: "child", columns: [],
      indexes: indexes, constraints: constraints)
  }

  struct CoveringCase: Sendable, CustomTestStringConvertible {
    let name: String
    let foreignKey: [String]
    let index: TableStructure.Index
    var primaryKey: [String] = ["id"]
    let covered: Bool
    var testDescription: String { name }
  }

  static let coveringCases: [CoveringCase] = [
    .init(name: "exact match", foreignKey: ["a"], index: index([.column("a")]), covered: true),
    .init(
      name: "longer index with the key as its prefix, in another order",
      foreignKey: ["a", "b"], index: index([.column("b"), .column("a"), .column("c")]),
      covered: true),
    .init(
      name: "key columns not leading", foreignKey: ["a", "b"],
      index: index([.column("c"), .column("a"), .column("b")]), covered: false),
    .init(
      name: "partial index", foreignKey: ["a"], index: index([.column("a")], partial: true),
      covered: false),
    .init(
      name: "expression inside the prefix", foreignKey: ["a", "b"],
      index: index([.column("a"), .expression("lower(b)")]), covered: false),
    .init(
      name: "composite key, index on its first column only", foreignKey: ["a", "b"],
      index: index([.column("a")]), covered: false),
    // A SQLite INTEGER PRIMARY KEY is the rowid: no index is listed for it
    .init(
      name: "rowid primary key on the key column", foreignKey: ["a"],
      index: index([.column("z")]), primaryKey: ["a"], covered: true),
  ]

  @Test(
    "An index covers a foreign key only through its leading plain columns", arguments: coveringCases
  )
  func coveringIndexRule(_ testCase: CoveringCase) {
    let findings = TableHealthReport.structureFindings(
      Self.structure(
        foreignKey: testCase.foreignKey, indexes: [testCase.index],
        primaryKey: testCase.primaryKey))
    let flagged = findings.filter { $0.kind == .foreignKeyWithoutIndex }
    #expect(flagged.count == (testCase.covered ? 0 : 1))
    #expect(flagged.allSatisfy { $0.objectName == "child_parent_fk" && $0.table == "child" })
  }

  @Test("A table without a primary key is flagged; one with a primary key index is not")
  func noPrimaryKey() {
    let bare = Self.structure(
      foreignKey: ["a"], indexes: [Self.index([.column("a")])], primaryKey: [])
    #expect(TableHealthReport.structureFindings(bare).map(\.kind) == [.noPrimaryKey])
    #expect(TableHealthReport.structureFindings(bare).first?.severity == .warning)
    // Only the index says it backs the primary key
    var keyed = bare
    keyed.indexes.append(
      .init(
        name: "child_pkey", keys: [.column("id")], isUnique: true, isPrimary: true,
        method: "btree", isPartial: false, predicate: nil))
    #expect(TableHealthReport.structureFindings(keyed).isEmpty)
  }

  private static func session(_ rows: [[CellValue]]) -> FakeDatabaseSession {
    FakeDatabaseSession(capabilities: .contract(), columns: [], rows: rows, slowQueries: false)
  }

  private static func keys(_ findings: [TableHealthFinding]) -> [String] {
    findings.map { "\($0.kind) \($0.schema).\($0.table) \($0.objectName ?? "-")" }
  }

  @Test("PostgreSQL statistic rows map to findings, and track_counts off leaves only its note")
  func postgresStatisticRows() async throws {
    let unused = Self.session([[.string("public"), .string("orders"), .string("orders_note_idx")]])
    #expect(
      Self.keys(try await TableHealthQueries.postgresUnusedIndexes(in: unused))
        == ["unusedIndex public.orders orders_note_idx"])
    let dead = Self.session([
      [.string("public"), .string("events"), .int(30_000), .int(20_000)],
      [.string("public"), .string("logs"), .int(1_000_000), .int(20_000)],
    ])
    #expect(
      Self.keys(try await TableHealthQueries.postgresDeadTuples(in: dead))
        == ["deadTuples public.events -"])
    let reset = Self.session([[.bool(true), .bool(true)]])
    #expect(
      try await TableHealthQueries.postgresStatisticsState(in: reset)
        == .init(trackCounts: true, notes: [TableHealthQueries.recentResetNote]))
    let off = Self.session([[.bool(false), .bool(false)]])
    #expect(
      try await TableHealthQueries.postgresReport(in: off)
        == TableHealthReport(notes: [TableHealthQueries.trackCountsOffNote]))
    #expect(off.queries.count == 1)
  }

  @Test("MySQL sys rows map to findings for the bound schema; no sys schema gives one note")
  func mysqlStatisticRows() async throws {
    let unused = Self.session([[.string("orders"), .string("orders_note_idx")]])
    #expect(
      Self.keys(try await TableHealthQueries.mysqlUnusedIndexes(schema: "app", in: unused))
        == ["unusedIndex app.orders orders_note_idx"])
    #expect(unused.statementBinds == [[.text("app")]])
    let redundant = Self.session([
      [
        .string("orders"), .string("orders_a_idx"), .string("a"), .string("orders_a_b_idx"),
        .string("a,b"),
      ]
    ])
    #expect(
      Self.keys(try await TableHealthQueries.mysqlRedundantIndexes(schema: "app", in: redundant))
        == ["redundantIndex app.orders orders_a_idx"])
    // MariaDB without sys: performance_schema off and neither view found
    let missing = Self.session([[.int(0), .int(0)]])
    #expect(
      try await TableHealthQueries.mysqlReport(schema: "app", in: missing)
        == TableHealthReport(notes: [TableHealthQueries.sysUnavailableNote]))
    #expect(missing.queries.count == 1)
    // A failure that is no server answer (a lost connection) is thrown, never that note
    let lost = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [[.int(1), .int(2)]], slowQueries: false,
      failingQuery: "sys.schema_redundant_indexes")
    await #expect(throws: FakeQueryError.self) {
      try await TableHealthQueries.mysqlReport(schema: "app", in: lost)
    }
  }

  @Test("Unused indexes that are unique, primary or serve a foreign key are dropped from the run")
  func combinedKeepsOnlyDroppableUnusedIndexes() {
    var child = Self.structure(foreignKey: ["a"], indexes: [])
    child.indexes = [
      .init(
        name: "child_a_idx", keys: [.column("a"), .column("c")], isUnique: false,
        isPrimary: false, method: "btree", isPartial: false, predicate: nil),
      .init(
        name: "child_c_key", keys: [.column("c")], isUnique: true, isPrimary: false,
        method: "btree", isPartial: false, predicate: nil),
      .init(
        name: "child_note_idx", keys: [.column("note")], isUnique: false, isPrimary: false,
        method: "btree", isPartial: false, predicate: nil),
    ]
    // A partial index on a foreign key's columns serves no delete from the parent: that table's
    // key is flagged and the index stays droppable
    var other = Self.structure(foreignKey: ["a"], indexes: [])
    other.name = "other"
    other.indexes = [
      .init(
        name: "other_a_part_idx", keys: [.column("a")], isUnique: false, isPrimary: false,
        method: "btree", isPartial: true, predicate: "(a > 0)")
    ]
    let unused = ["child_a_idx", "child_c_key", "child_note_idx"].map {
      TableHealthFinding(
        schema: "public", table: "child", kind: .unusedIndex, objectName: $0, reason: "")
    }
    // A table the run did not read is left out
    let elsewhere = TableHealthFinding(
      schema: "audit", table: "log", kind: .unusedIndex, objectName: "log_idx", reason: "")
    let otherUnused = TableHealthFinding(
      schema: "public", table: "other", kind: .unusedIndex, objectName: "other_a_part_idx",
      reason: "")
    let report = TableHealthReport.combined(
      structures: [child, other],
      statistics: TableHealthReport(findings: unused + [otherUnused, elsewhere], notes: ["note"]))
    #expect(
      Self.keys(report.findings) == [
        "foreignKeyWithoutIndex public.other child_parent_fk",
        "unusedIndex public.child child_note_idx",
        "unusedIndex public.other other_a_part_idx",
      ])
    #expect(report.notes == ["note"])
  }
}
