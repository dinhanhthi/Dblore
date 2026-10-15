// MySQLExplainAdapterTests.swift
// MySQL `EXPLAIN FORMAT=JSON` maps onto the plan tree: node types, names, filter, rows and
// costs from MySQL 8.4 captures, malformed input never crashes, and (opt-in `.requiresMySQL`)
// a live join on MySQL 8.4 opens the plan view.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLExplainAdapterTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  private func plan(_ text: String) throws -> ExplainPlan {
    try #require(MySQLExplainAdapter.plan(fromJSON: text))
  }

  private func near(_ value: Double?, _ expected: Double) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 0.0001
  }

  // MARK: - Fixtures

  @Test("A join is a Nested Loop over a Seq Scan and an Index Scan, in join order")
  func join() throws {
    let root = try plan(ExplainFixtures.mysqlJoin).root
    #expect(root.nodeType == "Nested Loop")
    #expect(near(root.totalCost, 1.20))
    #expect(root.children.count == 2)
    let outer = try #require(root.children.first)
    #expect(outer.nodeType == "Seq Scan")
    #expect(outer.relationName == "o")
    #expect(outer.indexName == nil)
    #expect(outer.planRows == 6)
    #expect(outer.filter?.contains("'open'") == true)
    #expect(near(outer.totalCost, 0.85))
    let inner = try #require(root.children.last)
    #expect(inner.nodeType == "Index Scan")
    #expect(inner.relationName == "c")
    #expect(inner.indexName == "PRIMARY")
    #expect(inner.planRows == 1)
    #expect(inner.filter == nil)
    // prefix_cost 1.20 minus the 0.85 of the table before it.
    #expect(near(inner.totalCost, 0.35))
    #expect(inner.extras["access_type"] == .string("eq_ref"))
  }

  @Test("No actual times: the analyzer scores a MySQL plan by cost, shares adding up to one")
  func analyzerUsesCost() throws {
    let analyzed = ExplainPlanAnalyzer.analyze(try plan(ExplainFixtures.mysqlJoin))
    #expect(analyzed.nodes.count == 3)
    #expect(analyzed.nodes.allSatisfy { $0.node.actualTotalTime == nil })
    let shares = analyzed.nodes.map(\.share)
    #expect(abs(shares.reduce(0, +) - 1) < 0.0001, "\(shares)")
    #expect(analyzed.hotNodes.first?.node.relationName == "o")
  }

  @Test("ORDER BY, GROUP BY and DISTINCT wrap their table in Sort, Aggregate and Unique")
  func operations() throws {
    let cases: [(String, String, String, String?, Double)] = [
      (ExplainFixtures.mysqlOrderBy, "Sort", "Seq Scan", nil, 6.85),
      (ExplainFixtures.mysqlGroupBy, "Aggregate", "Index Scan", "idx_customer", 0.85),
      (ExplainFixtures.mysqlDistinct, "Unique", "Seq Scan", nil, 0.85),
    ]
    for (fixture, operation, scan, index, cost) in cases {
      let root = try plan(fixture).root
      #expect(root.nodeType == operation)
      #expect(near(root.totalCost, cost), "\(operation): \(String(describing: root.totalCost))")
      #expect(root.children.count == 1)
      let table = try #require(root.children.first)
      #expect(table.nodeType == scan, "\(operation)")
      #expect(table.relationName == "dblore_explain_orders")
      #expect(table.indexName == index)
      #expect(table.planRows == 6)
      #expect(near(table.totalCost, 0.85))
    }
  }

  @Test("A derived table is a Subquery Scan over the plan of its subquery")
  func derived() throws {
    let root = try plan(ExplainFixtures.mysqlDerived).root
    #expect(root.nodeType == "Subquery Scan")
    #expect(root.relationName == "d")
    #expect(near(root.totalCost, 3.17))
    #expect(root.extras["materialized_from_subquery"] == nil)
    let aggregate = try #require(root.children.first)
    #expect(root.children.count == 1)
    #expect(aggregate.nodeType == "Aggregate")
    #expect(near(aggregate.totalCost, 0.85))
    let scan = try #require(aggregate.children.first)
    #expect(scan.nodeType == "Index Scan")
    #expect(scan.indexName == "idx_customer")
  }

  @Test("A covering index is an Index Only Scan; a full scan never is")
  func indexOnly() throws {
    func table(_ access: String) -> String {
      #"{"query_block": {"select_id": 1, "table": {"table_name": "t", "access_type": ""#
        + access + #"", "key": "idx", "using_index": true, "rows_examined_per_scan": 2}}}"#
    }
    for access in ["index", "range", "ref", "eq_ref", "const", "system"] {
      #expect(try plan(table(access)).root.nodeType == "Index Only Scan", "\(access)")
    }
    #expect(try plan(table("ALL")).root.nodeType == "Seq Scan")
  }

  @Test("Costs and row counts are read from strings or numbers")
  func numbers() throws {
    let root = try plan(
      #"{"query_block": {"cost_info": {"query_cost": 2.5}, "table": {"table_name": "t", "#
        + #""access_type": "ALL", "rows_examined_per_scan": "7", "#
        + #""cost_info": {"prefix_cost": 2.5}}}}"#
    ).root
    #expect(root.totalCost == 2.5)
    #expect(root.planRows == 7)
  }

  @Test("A query block without tables is a Result node that keeps the server message")
  func noTables() throws {
    let message = try plan(
      #"{"query_block": {"select_id": 1, "message": "No tables used"}}"#
    ).root
    #expect(message.nodeType == "Result")
    #expect(message.extras["message"] == .string("No tables used"))
    #expect(message.children.isEmpty)
    #expect(try plan(#"{"query_block": {"select_id": 1}}"#).root.nodeType == "Result")
    #expect(try plan(#"{"query_block": {"nested_loop": "x"}}"#).root.nodeType == "Result")
  }

  @Test(
    "Text that is not a MySQL JSON plan gives no plan",
    arguments: [
      "", "not json", "-> Rows fetched before execution", "[]", "{}", "42",
      #"{"query_block": "x"}"#, #"{"query_block": []}"#, #"[{"query_block": {}}]"#,
      #"[{"Plan": {"Node Type": "Seq Scan"}}]"#,
    ])
  func notAPlan(text: String) {
    #expect(MySQLExplainAdapter.plan(fromJSON: text) == nil)
  }

  @Test("Deeply nested JSON is cut at the depth bound instead of crashing")
  func depthBound() throws {
    let wrappers = 300
    let text =
      #"{"query_block": "#
      + String(repeating: #"{"ordering_operation": "#, count: wrappers)
      + #"{"table": {"table_name": "t", "access_type": "ALL"}}"#
      + String(repeating: "}", count: wrappers) + "}"
    let root = try plan(text).root
    func depth(_ node: ExplainNode) -> Int { 1 + (node.children.map(depth).max() ?? 0) }
    #expect(depth(root) <= MySQLExplainAdapter.maxDepth)
    #expect(depth(root) > 1)
  }

  // MARK: - Live

  @Test(
    "MySQL 8.4 Explain of a join is FORMAT=JSON and opens the plan view",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func liveJoin() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: MySQLManagerTests.config(.mysql))
    defer { Task { await manager.disconnect() } }
    let server = try #require(await manager.mysqlServerInfo)
    #expect(server.flavor == .mysql)

    let drop =
      "DROP TABLE IF EXISTS dblore_explain_adapter_orders, dblore_explain_adapter_customers"
    _ = try await manager.execute(userSQL: drop, policy: open)
    for sql in [
      "CREATE TABLE dblore_explain_adapter_customers (id INT PRIMARY KEY, name VARCHAR(50))",
      "CREATE TABLE dblore_explain_adapter_orders (id INT PRIMARY KEY, customer_id INT, "
        + "status VARCHAR(10), KEY idx_customer (customer_id))",
      "INSERT INTO dblore_explain_adapter_customers VALUES (1, 'a'), (2, 'b'), (3, 'c')",
      "INSERT INTO dblore_explain_adapter_orders VALUES (1, 1, 'open'), (2, 1, 'paid'), "
        + "(3, 2, 'open'), (4, 3, 'paid'), (5, 2, 'open'), (6, 3, 'open')",
      "ANALYZE TABLE dblore_explain_adapter_customers, dblore_explain_adapter_orders",
    ] {
      _ = try await manager.execute(userSQL: sql, policy: open)
    }

    let request = try ExplainRequest(
      statement: "SELECT c.name FROM dblore_explain_adapter_customers c "
        + "JOIN dblore_explain_adapter_orders o ON o.customer_id = c.id WHERE o.status = 'open'",
      analyze: false, buffers: false, dialect: .mysql, mysqlServer: server)
    #expect(request.sql.hasPrefix("EXPLAIN FORMAT=JSON "))
    let result = try await manager.execute(userSQL: request.sql, policy: open)
    _ = try? await manager.execute(userSQL: drop, policy: open)

    let cell = CellResult(columns: result.columns, rows: result.rows, rowCount: result.rows.count)
    let plan = try #require(ExplainResultPlan.parse(cell))
    #expect(plan.root.nodeType == "Nested Loop")
    #expect(plan.root.children.count == 2)
    #expect(Set(plan.root.children.compactMap(\.relationName)) == ["c", "o"])
    #expect(plan.root.totalCost ?? 0 > 0)
  }
}
