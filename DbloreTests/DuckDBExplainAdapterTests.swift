// DuckDBExplainAdapterTests.swift
// DuckDB `EXPLAIN (FORMAT JSON)` and `EXPLAIN (ANALYZE, FORMAT JSON)` map onto the plan tree
// (captured fixtures, no plugin needed), only a real EXPLAIN result is detected, filter literals
// never reach the AI plan context, and (opt-in `.requiresDuckDBPlugin`) the Explain action's SQL
// on a real in-memory session opens the plan view.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB EXPLAIN JSON adapter")
struct DuckDBExplainAdapterTests {
  private static let columns = ["explain_key", "explain_value"].map {
    ColumnInfo(name: $0, type: "VARCHAR")
  }

  private func result(
    _ json: String, sourceQuery: String? = "EXPLAIN (FORMAT JSON) SELECT 1"
  )
    -> CellResult
  {
    CellResult(
      columns: Self.columns, rows: [[.string("physical_plan"), .string(json)]], rowCount: 1,
      sourceQuery: sourceQuery)
  }

  private func first(_ node: ExplainNode, _ type: String) -> ExplainNode? {
    if node.nodeType == type { return node }
    return node.children.lazy.compactMap { first($0, type) }.first
  }

  private func near(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 1e-9
  }

  @Test("A FORMAT JSON plan keeps operators, tables, join type, filter and estimates, no time")
  func plainPlan() throws {
    let plan = try #require(
      ExplainResultPlan.parse(result(DuckDBExplainFixtures.joinFilterAggregateJSON)))
    #expect(plan.root.nodeType == "PROJECTION")
    #expect(plan.executionTime == nil)
    let join = try #require(first(plan.root, "HASH_JOIN"))
    #expect(join.joinType == "INNER")
    #expect(join.extras["Conditions"] == .string("(i % 3) = id"))
    #expect(join.children.map(\.relationName) == ["memory.main.t", "memory.main.cats"])
    let scan = join.children[0]
    #expect(scan.nodeType == "SEQ_SCAN")
    #expect(scan.filter == "flag")
    #expect(scan.planRows == 200)
    #expect(scan.output == ["i", "d"])
    #expect(scan.extras["Type"] == .string("Sequential Scan"))
    #expect(scan.extras["Table"] == nil)
    #expect(scan.extras["Filters"] == nil)
    #expect(scan.actualTotalTime == nil)
    #expect(ExplainPlanAnalyzer.analyze(plan).hotNodes.isEmpty)
  }

  @Test("An ANALYZE profile skips the EXPLAIN_ANALYZE wrapper and rolls operator time up in ms")
  func analyzedPlan() throws {
    let plan = try #require(
      ExplainResultPlan.parse(
        result(
          DuckDBExplainFixtures.joinAnalyzeJSON,
          sourceQuery: "EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1")))
    #expect(plan.root.nodeType == "PROJECTION")
    #expect(near(plan.executionTime, 1.170792))
    let join = try #require(first(plan.root, "HASH_JOIN"))
    #expect(join.actualRows == 500)
    #expect(near(join.actualTotalTime, 0.289709 + 0.005917 + 0.003))
    #expect(near(plan.root.actualTotalTime, 0.000292 + 0.289709 + 0.005917 + 0.003))
    #expect(join.children.first?.planRows == 200)

    let analyzed = ExplainPlanAnalyzer.analyze(plan)
    #expect(analyzed.nodes.allSatisfy { $0.hasMetric })
    #expect(analyzed.hotNodes.first?.node.nodeType == "HASH_JOIN")
    #expect(near(analyzed.hotNodes.first?.exclusive, 0.289709))
  }

  @Test("Only a one-row EXPLAIN result holding JSON is a plan")
  func detection() {
    let json = DuckDBExplainFixtures.joinFilterAggregateJSON
    #expect(ExplainResultPlan.parse(result(json, sourceQuery: "SELECT * FROM kv")) == nil)
    #expect(ExplainResultPlan.parse(result(json, sourceQuery: nil)) == nil)
    let text =
      "┌───────────────────────────┐\n│         SEQ_SCAN          │\n└───────────────────────────┘"
    #expect(ExplainResultPlan.parse(result(text, sourceQuery: "EXPLAIN SELECT 1")) == nil)
    #expect(ExplainResultPlan.parse(result(#"[{"other": 1}]"#)) == nil)
    let twoRows = CellResult(
      columns: Self.columns,
      rows: [
        [.string("physical_plan"), .string(json)], [.string("physical_plan"), .string(json)],
      ],
      rowCount: 2, sourceQuery: "EXPLAIN (FORMAT JSON) SELECT 1")
    #expect(ExplainResultPlan.parse(twoRows) == nil)
  }

  @Test("Filter, condition and projection literals never reach the AI plan context")
  func literalsStayOutOfAIContext() throws {
    let marker = "dblore-leak-4410"
    let json = """
      [{"name": "HASH_JOIN", "extra_info": {"Join Type": "INNER",
          "Conditions": "label = '\(marker)'", "Estimated Cardinality": "1"},
        "children": [
          {"name": "SEQ_SCAN", "children": [], "extra_info": {"Table": "memory.main.t",
            "Filters": ["label='\(marker)'", "i>3"], "Projections": ["'\(marker)'"],
            "Order By": "'\(marker)'", "Estimated Cardinality": "2"}},
          {"name": "FILTER", "children": [], "extra_info": {"Expression": "(x = '\(marker)')"}}
        ]}]
      """
    let plan = try #require(ExplainResultPlan.parse(result(json)))
    #expect(plan.root.children[0].filter?.contains(marker) == true)
    let context = AIQueryContext.render(structures: [], plan: plan)
    #expect(context.contains("SEQ_SCAN on memory.main.t"))
    #expect(!context.contains(marker))
  }

  @Test("Only a source that is exactly one EXPLAIN statement makes a plan-shaped row a plan")
  func multiStatementSourceIsNotAPlan() {
    let json = DuckDBExplainFixtures.joinFilterAggregateJSON
    for script in [
      "EXPLAIN (FORMAT JSON) SELECT 1; SELECT * FROM kv",
      "EXPLAIN (FORMAT JSON) SELECT 1 /* ; */; SELECT * FROM kv",
      "-- EXPLAIN\nSELECT * FROM kv",
    ] {
      #expect(ExplainResultPlan.parse(result(json, sourceQuery: script)) == nil, "\(script)")
    }
    for script in [
      "EXPLAIN (FORMAT JSON) SELECT 1;", "/* plan */ EXPLAIN (FORMAT JSON) SELECT 1",
    ] {
      #expect(ExplainResultPlan.parse(result(json, sourceQuery: script)) != nil, "\(script)")
    }
  }

  @Test("JSON over the size limit, or more nodes than the cap, is not a plan")
  func limitsFailClosed() {
    let cap = DuckDBExplainAdapter.maxNodes
    func flat(_ count: Int) -> String {
      let child = #"{"name": "SEQ_SCAN", "children": []}"#
      return "[{\"name\": \"UNION\", \"children\": ["
        + Array(repeating: child, count: count).joined(separator: ",") + "]}]"
    }
    #expect(DuckDBExplainAdapter.plan(fromJSON: flat(cap - 1))?.root.children.count == cap - 1)
    #expect(DuckDBExplainAdapter.plan(fromJSON: flat(cap)) == nil)
    let padding = String(repeating: " ", count: DuckDBExplainAdapter.maxJSONBytes)
    #expect(DuckDBExplainAdapter.plan(fromJSON: flat(1) + padding) == nil)
  }

  @Test(
    "The Explain action's SQL on a real session shows a tree, ANALYZE with time",
    .requiresDuckDBPlugin, arguments: [false, true])
  func livePlan(analyze: Bool) async throws {
    let marker = "dblore-live-leak-5521"
    let session = DuckDBSession(
      config: ConnectionConfig(
        databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
        statementTimeoutSeconds: 60)
    ) { try DuckDBTestPlugin.library() }
    try await session.open()
    do {
      for sql in [
        "CREATE TABLE t AS SELECT range AS i, 'row-' || range AS label FROM range(100)",
        "CREATE TABLE cats AS SELECT range AS id, 'cat-' || range AS name FROM range(3)",
      ] {
        _ = try await session.command(sql, binds: [])
      }
      let request = try ExplainRequest(
        statement: "SELECT c.name, count(*) FROM t JOIN cats c ON c.id = t.i % 3 "
          + "WHERE t.label <> '\(marker)' GROUP BY c.name",
        analyze: analyze, buffers: analyze, dialect: .duckdb)
      #expect(
        request.wrappedSQL.hasPrefix(
          analyze ? "EXPLAIN (ANALYZE, FORMAT JSON) " : "EXPLAIN (FORMAT JSON) "))
      let source = try await session.query(request.wrappedSQL, binds: [])
      var rows: [[CellValue]] = []
      for try await row in source.rows { rows.append(row) }
      let cell = CellResult(
        columns: source.columns, rows: rows, rowCount: rows.count,
        sourceQuery: request.wrappedSQL)

      let plan = try #require(ExplainResultPlan.parse(cell))
      let join = try #require(first(plan.root, "HASH_JOIN"))
      #expect(Set(join.children.compactMap(\.relationName)).contains("memory.main.t"))
      #expect((plan.root.actualTotalTime != nil) == analyze)
      #expect((plan.executionTime != nil) == analyze)
      let context = AIQueryContext.render(structures: [], plan: plan)
      #expect(context.contains("HASH_JOIN"))
      #expect(!context.contains(marker))
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }
}
