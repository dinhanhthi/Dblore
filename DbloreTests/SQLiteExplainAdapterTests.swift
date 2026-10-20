// SQLiteExplainAdapterTests.swift
// SQLite `EXPLAIN QUERY PLAN` rows (id, parent, notused, detail) from a real SQLite file become
// the plan tree; a user table with the same column names is never taken for a plan, and no
// condition from `detail` reaches the AI plan context.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite EXPLAIN QUERY PLAN adapter")
@MainActor
struct SQLiteExplainAdapterTests {
  private static let schema = [
    "CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT, c INT)",
    "CREATE INDEX ib ON t (b)",
    "CREATE TABLE u (x INT, y TEXT)",
    "CREATE TABLE v (p INT, q INT, r INT)",
    "CREATE INDEX ipqr ON v (p, q, r)",
  ]
  private static let columns = ["id", "parent", "notused", "detail"].map {
    ColumnInfo(name: $0, type: "")
  }

  @Test("A join, its index search and the ORDER BY temp b-tree hang under one Query plan root")
  func joinTree() async throws {
    let result = try await explain(
      "SELECT * FROM t AS tt JOIN u ON u.x = tt.c WHERE tt.b = 'dblore-eqp-literal' ORDER BY u.y")
    #expect(result.columns.map(\.name) == ["id", "parent", "notused", "detail"])
    let plan = try #require(ExplainResultPlan.parse(result))

    #expect(plan.root.nodeType == "Query plan")
    let types = plan.root.children.map(\.nodeType)
    #expect(types == ["Index Search", "Scan", "Temp B-Tree for ORDER BY"])
    let search = plan.root.children[0]
    #expect(search.relationName == "tt")
    #expect(search.indexName == "ib")
    #expect(search.indexCond?.hasPrefix("(b=?") == true)
    #expect(plan.root.children[1].relationName == "u")
    #expect(plan.root.children[1].indexName == nil)
    guard case .string(let detail)? = search.extras["Detail"] else {
      Issue.record("No detail line on \(search)")
      return
    }
    #expect(detail.hasPrefix("SEARCH tt USING INDEX ib (b=?"))

    // No cost or time: no share bar and no hot nodes.
    let analyzed = ExplainPlanAnalyzer.analyze(plan)
    #expect(analyzed.nodes.allSatisfy { !$0.hasMetric })
    #expect(analyzed.hotNodes.isEmpty)
  }

  @Test("Nested rows follow parent ids, and one top-level row is the root itself")
  func nestedTree() async throws {
    let result = try await explain(
      "SELECT * FROM t WHERE a = 1 UNION SELECT * FROM t WHERE c IN (SELECT x FROM u)")
    let plan = try #require(ExplainResultPlan.parse(result))
    // SQLite releases word the compound differently: COMPOUND QUERY or MERGE (UNION).
    #expect(["COMPOUND QUERY", "MERGE (UNION)"].contains(plan.root.nodeType ?? ""))
    #expect(plan.root.children.count == 2)
    let first = try #require(plan.root.children.first?.children.first)
    #expect(first.nodeType == "Primary Key Search")
    #expect(first.relationName == "t")
    #expect(first.indexCond == "(rowid=?)")
    let union = plan.root.children[1]
    #expect(union.children.map(\.nodeType).prefix(2) == ["Scan", "LIST SUBQUERY"])
  }

  @Test("A user table named like the plan columns, or a malformed row, is not a plan")
  func userTableIsNotAPlan() async throws {
    try await withSession { session in
      _ = try await session.command(
        "CREATE TABLE eqp (id INTEGER, parent INTEGER, notused INTEGER, detail TEXT)", binds: [])
      _ = try await session.command(
        "INSERT INTO eqp VALUES (2, 0, 0, 'SCAN t'), (3, 2, 0, 'SCAN u')", binds: [])
      let selected = try await query(session, "SELECT * FROM eqp")
      #expect(selected.columns.map(\.name) == ["id", "parent", "notused", "detail"])
      #expect(ExplainResultPlan.parse(selected) == nil)
    }

    let columns = ["id", "parent", "notused", "detail"].map { ColumnInfo(name: $0, type: "") }
    let explained = "EXPLAIN QUERY PLAN SELECT * FROM t"
    let textID = CellResult(
      columns: columns, rows: [[.string("2"), .int(0), .int(0), .string("SCAN t")]],
      rowCount: 1, sourceQuery: explained)
    #expect(ExplainResultPlan.parse(textID) == nil)
    let renamed = CellResult(
      columns: ["id", "parent", "unused", "detail"].map { ColumnInfo(name: $0, type: "") },
      rows: [[.int(2), .int(0), .int(0), .string("SCAN t")]], rowCount: 1, sourceQuery: explained)
    #expect(ExplainResultPlan.parse(renamed) == nil)
    let valid = CellResult(
      columns: columns, rows: [[.int(2), .int(0), .int(0), .string("SCAN t")]], rowCount: 1,
      sourceQuery: "  explain query plan SELECT * FROM t")
    #expect(ExplainResultPlan.parse(valid)?.root.nodeType == "Scan")
  }

  @Test("Conditions in detail never reach the AI plan context")
  func conditionsStayOutOfAIContext() async throws {
    let marker = "dblore-leak-7731"
    let columns = ["id", "parent", "notused", "detail"].map { ColumnInfo(name: $0, type: "") }
    let rows: [[CellValue]] = [
      [.int(2), .int(0), .int(0), .string("SEARCH t USING INDEX ib (b='\(marker)')")],
      [.int(5), .int(0), .int(0), .string("BLOOM FILTER ON u (x='\(marker)')")],
      [.int(7), .int(0), .int(0), .string("SCAN u VIRTUAL TABLE INDEX 1:\(marker)")],
      [.int(9), .int(0), .int(0), .string("CORRELATED SCALAR SUBQUERY 3 (\(marker))")],
    ]
    let crafted = CellResult(
      columns: columns, rows: rows, rowCount: rows.count,
      sourceQuery: "EXPLAIN QUERY PLAN SELECT 1")
    let plan = try #require(ExplainResultPlan.parse(crafted))
    let context = AIQueryContext.render(structures: [], plan: plan)
    #expect(context.contains("Index Search using ib on t"))
    #expect(!context.contains(marker))

    let real = try #require(
      ExplainResultPlan.parse(try await explain("SELECT * FROM t WHERE b = 'dblore-eqp-literal'")))
    let realContext = AIQueryContext.render(structures: [], plan: real)
    #expect(realContext.contains("using ib on t"))
    #expect(!realContext.contains("b=?"))
    #expect(!realContext.contains("dblore-eqp-literal"))
  }

  @Test("Duplicate ids are not a plan, so the tree can never grow wider than the rows")
  func duplicateIDsAreNotAPlan() throws {
    let twins: [[CellValue]] = [
      [.int(2), .int(0), .int(0), .string("SCAN t")],
      [.int(2), .int(0), .int(0), .string("SCAN u")],
    ]
    try #require(SQLiteExplainAdapter.plan(rows: twins) == nil)
    // Each level would double: two rows with id 2 under id 1, two with id 1 under id 2.
    let doubling: [[CellValue]] = [
      [.int(1), .int(0), .int(0), .string("SCAN a")],
      [.int(2), .int(1), .int(0), .string("SCAN b")],
      [.int(2), .int(1), .int(0), .string("SCAN c")],
      [.int(1), .int(2), .int(0), .string("SCAN d")],
      [.int(1), .int(2), .int(0), .string("SCAN e")],
    ]
    #expect(SQLiteExplainAdapter.plan(rows: doubling) == nil)
  }

  @Test("More rows than the cap is not a plan; exactly the cap still is")
  func rowCapFailsClosed() {
    func rows(_ count: Int) -> [[CellValue]] {
      (1...count).map { [.int($0), .int(0), .int(0), .string("SCAN t\($0)")] }
    }
    let cap = SQLiteExplainAdapter.maxRows
    #expect(SQLiteExplainAdapter.plan(rows: rows(cap))?.root.children.count == cap)
    #expect(SQLiteExplainAdapter.plan(rows: rows(cap + 1)) == nil)
  }

  @Test("A nested row-value condition is cut at its own parenthesis, not at the last one")
  func nestedConditionStaysWhole() async throws {
    let real = try #require(
      ExplainResultPlan.parse(
        try await explain("SELECT * FROM v WHERE p = 1 AND (q, r) > (2, 3)")))
    let search = real.root
    #expect(search.relationName == "v")
    #expect(search.indexName == "ipqr")
    #expect(search.indexCond?.hasPrefix("(") == true)
    #expect(search.indexCond?.hasSuffix(")") == true)
    let realContext = AIQueryContext.render(structures: [], plan: real)
    #expect(realContext.contains("using ipqr on v"))
    #expect(!realContext.contains("?"))
    #expect(!realContext.contains("(q"))

    let marker = "dblore-leak-2290"
    let lines = [
      "SEARCH v USING COVERING INDEX ipqr (p=? AND (q,r)>(?,?))",
      "SEARCH v USING INDEX ipqr ((p,q)>(?,?) AND (p,q)<(?,?))",
      "SEARCH v USING INDEX ipqr (p='\(marker)' AND ((q,r)>('\(marker)',?)))",
    ]
    let rows = lines.enumerated().map { offset, line -> [CellValue] in
      [.int(offset + 2), .int(0), .int(0), .string(line)]
    }
    let crafted = CellResult(
      columns: Self.columns, rows: rows, rowCount: rows.count,
      sourceQuery: "EXPLAIN QUERY PLAN SELECT 1")
    let plan = try #require(ExplainResultPlan.parse(crafted))
    #expect(plan.root.children.map(\.indexName) == ["ipqr", "ipqr", "ipqr"])
    #expect(plan.root.children.map(\.relationName) == ["v", "v", "v"])
    #expect(plan.root.children[0].indexCond == "(p=? AND (q,r)>(?,?))")
    #expect(plan.root.children[1].indexCond == "((p,q)>(?,?) AND (p,q)<(?,?))")
    let context = AIQueryContext.render(structures: [], plan: plan)
    #expect(context.contains("using ipqr on v"))
    #expect(!context.contains(marker))
    #expect(!context.contains("?"))
    #expect(!context.contains("(q"))
  }

  @Test("Only a source that is exactly one EXPLAIN statement makes plan-shaped rows a plan")
  func multiStatementSourceIsNotAPlan() async throws {
    try await withSession { session in
      _ = try await session.command(
        "CREATE TABLE eqp (id INTEGER, parent INTEGER, notused INTEGER, detail TEXT)", binds: [])
      _ = try await session.command(
        "INSERT INTO eqp VALUES (2, 0, 0, 'SCAN t'), (3, 2, 0, 'SCAN u')", binds: [])
      let selected = try await query(session, "SELECT * FROM eqp")
      for script in [
        "EXPLAIN QUERY PLAN SELECT 1; SELECT * FROM eqp",
        "explain query plan select 1;\nselect * from eqp;",
        "EXPLAIN QUERY PLAN SELECT 1 /* ; */; SELECT * FROM eqp",
        "-- EXPLAIN QUERY PLAN\nSELECT * FROM eqp",
        "/* EXPLAIN */ SELECT * FROM eqp",
      ] {
        let disguised = CellResult(
          columns: selected.columns, rows: selected.rows, rowCount: selected.rowCount,
          sourceQuery: script)
        #expect(ExplainResultPlan.parse(disguised) == nil, "\(script)")
      }
      for script in [
        "EXPLAIN QUERY PLAN SELECT * FROM t",
        "/* plan */ EXPLAIN QUERY PLAN SELECT * FROM t",
        "-- plan\nEXPLAIN QUERY PLAN SELECT * FROM t;",
      ] {
        let explained = CellResult(
          columns: selected.columns, rows: selected.rows, rowCount: selected.rowCount,
          sourceQuery: script)
        #expect(ExplainResultPlan.parse(explained)?.root.nodeType == "Scan", "\(script)")
      }
    }
  }

  // MARK: - Helpers

  /// The Explain action's SQL for `statement` on a fresh file with `schema`, as a cell result.
  private func explain(_ statement: String) async throws -> CellResult {
    let request = try ExplainRequest(
      statement: statement, analyze: false, buffers: false, dialect: .sqlite)
    var result: CellResult?
    try await withSession { session in
      for sql in Self.schema {
        _ = try await session.command(sql, binds: [])
      }
      result = try await query(session, request.sql)
    }
    return try #require(result)
  }

  private func query(_ session: SQLiteSession, _ sql: String) async throws -> CellResult {
    let source = try await session.query(sql, binds: [])
    var rows: [[CellValue]] = []
    for try await row in source.rows {
      rows.append(row)
    }
    return CellResult(
      columns: source.columns, rows: rows, rowCount: rows.count, sourceQuery: sql)
  }

  private func withSession(_ body: (SQLiteSession) async throws -> Void) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-explain-\(UUID().uuidString).db")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-journal"))
    }
    let session = SQLiteSession(
      config: ConnectionConfig(
        databaseType: .sqlite, database: url.path, username: "unused", password: "",
        sslMode: .disable, statementTimeoutSeconds: 60))
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }
}
