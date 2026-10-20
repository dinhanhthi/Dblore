// MySQLExplainRequestTests.swift
// Explain on MySQL: `EXPLAIN FORMAT=JSON` (shown in the plan view) on a MySQL server, the tabular
// `EXPLAIN` on MariaDB or an unknown server, and `EXPLAIN ANALYZE` (a text tree) only on MySQL
// 8.0.18+ (never MariaDB, never an unknown server). Live cases (MySQL 8.4 on 3307, MariaDB 11.4
// on 3308) are opt-in (`.requiresMySQL`).

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLExplainRequestTests {
  typealias Server = MySQLSessionTests.Server

  private let open = ProtectionPolicy(protectionLevel: .none)

  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - Request building

  @Test("MySQL Explain is EXPLAIN, FORMAT=JSON or EXPLAIN ANALYZE; never PG syntax")
  func mysqlRequestText() throws {
    let tabular = try ExplainRequest(
      statement: "SELECT 1;", analyze: false, buffers: true, dialect: .mysql)
    #expect(tabular.sql == "EXPLAIN SELECT 1")
    let json = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: true, jsonFormat: true, dialect: .mysql)
    #expect(json.sql == "EXPLAIN FORMAT=JSON SELECT 1")
    let analyzed = try ExplainRequest(
      statement: "SELECT 1", analyze: true, buffers: true, jsonFormat: true, dialect: .mysql,
      mysqlServer: MySQLServerInfo(version: "8.4.11"))
    #expect(analyzed.sql == "EXPLAIN ANALYZE SELECT 1")
    let auto = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: true, dialect: .mysql,
      mysqlServer: MySQLServerInfo(version: "8.4.11"))
    #expect(auto.sql == "EXPLAIN FORMAT=JSON SELECT 1")
    for request in [tabular, json, analyzed, auto] {
      #expect(!request.sql.contains("("), "\(request.sql)")
      #expect(!request.sql.contains("FORMAT JSON"), "\(request.sql)")
    }
  }

  @Test("Explain asks a MySQL server for FORMAT=JSON; MariaDB and an unknown server stay tabular")
  func jsonFormatFollowsFlavor() throws {
    func sql(
      _ server: MySQLServerInfo?, json: Bool? = nil, analyze: Bool = false
    ) throws
      -> String
    {
      try ExplainRequest(
        statement: "SELECT 1", analyze: analyze, buffers: analyze, jsonFormat: json,
        dialect: .mysql, mysqlServer: server
      ).sql
    }
    let mysql = MySQLServerInfo(version: "8.4.11")
    #expect(try sql(mysql) == "EXPLAIN FORMAT=JSON SELECT 1")
    #expect(try sql(MySQLServerInfo(version: "5.7.44")) == "EXPLAIN FORMAT=JSON SELECT 1")
    #expect(try sql(MySQLServerInfo(version: "11.4.13-MariaDB-ubu2404")) == "EXPLAIN SELECT 1")
    #expect(try sql(nil) == "EXPLAIN SELECT 1")
    #expect(try sql(mysql, json: false) == "EXPLAIN SELECT 1")
    #expect(try sql(mysql, analyze: true) == "EXPLAIN ANALYZE SELECT 1")
    // Other engines ignore the MySQL server.
    let postgres = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: false, dialect: .postgresql,
      mysqlServer: mysql)
    #expect(postgres.sql == "EXPLAIN (FORMAT JSON) SELECT 1")
  }

  @Test(
    "EXPLAIN ANALYZE needs MySQL 8.0.18 or later, never MariaDB or an unknown server",
    arguments: [
      ("8.0.18", true), ("8.4.11", true), ("9.1.0", true), ("8.0.17", false),
      ("5.7.44", false), ("11.4.13-MariaDB-ubu2404", false), ("", false),
    ])
  func analyzeGate(version: String, allowed: Bool) {
    let server = MySQLServerInfo(version: version)
    let reason = ExplainRequest.analyzeUnavailableReason(dialect: .mysql, mysqlServer: server)
    #expect((reason == nil) == allowed, "\(version): \(reason ?? "nil")")
    let built = Result {
      try ExplainRequest(
        statement: "DELETE FROM t", analyze: true, buffers: false, dialect: .mysql,
        mysqlServer: server)
    }
    switch built {
    case .success(let request):
      #expect(allowed, "\(version)")
      #expect(request.wrappedSQL == "BEGIN; EXPLAIN ANALYZE DELETE FROM t; ROLLBACK;")
    case .failure(let error):
      #expect(!allowed, "\(version)")
      #expect(error as? ExplainRequestError == .analyzeUnavailable(reason ?? ""))
    }
    // Plain EXPLAIN never depends on the server version.
    #expect(
      (try? ExplainRequest(
        statement: "SELECT 1", analyze: false, buffers: false, dialect: .mysql,
        mysqlServer: server)) != nil)
  }

  @Test("PostgreSQL, SQLite and DuckDB Explain text needs no server info")
  func otherEnginesUnchanged() throws {
    let cases: [(SQLDialect, Bool, String)] = [
      (.postgresql, false, "EXPLAIN (FORMAT JSON) SELECT 1"),
      (.postgresql, true, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT 1"),
      (.sqlite, false, "EXPLAIN QUERY PLAN SELECT 1"),
      (.duckdb, false, "EXPLAIN (FORMAT JSON) SELECT 1"),
      (.duckdb, true, "EXPLAIN (ANALYZE, FORMAT JSON) SELECT 1"),
    ]
    for (dialect, analyze, expected) in cases {
      let request = try ExplainRequest(
        statement: "SELECT 1", analyze: analyze, buffers: analyze, dialect: dialect)
      #expect(request.sql == expected)
      #expect(ExplainRequest.analyzeUnavailableReason(dialect: dialect, mysqlServer: nil) == nil)
    }
  }

  @Test("The Explain Analyze action follows the connected MySQL server")
  func viewModelGate() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(connectionConfig: MySQLSessionTests.config(port: 3307)))
    #expect(viewModel.canExplainAnalyze == false)
    #expect(viewModel.explainAnalyzeUnavailableReason != nil)
    viewModel.mysqlServerInfo = MySQLServerInfo(version: "8.4.11")
    #expect(viewModel.canExplainAnalyze)
    #expect(viewModel.explainAnalyzeUnavailableReason == nil)
    viewModel.mysqlServerInfo = MySQLServerInfo(version: "11.4.13-MariaDB")
    #expect(viewModel.canExplainAnalyze == false)

    let postgres = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: ConnectionConfig()))
    #expect(postgres.canExplainAnalyze)
  }

  @Test("A MySQL JSON plan opens the plan view; a tabular plan or text tree does not")
  func planView() throws {
    let json = CellResult(
      columns: [ColumnInfo(name: "EXPLAIN", type: "JSON")],
      rows: [[.json(#"{"query_block": {"select_id": 1}}"#)]], rowCount: 1)
    #expect(ExplainResultPlan.parse(json)?.root.nodeType == "Result")
    // MySQL types the plan column as text.
    let text = CellResult(
      columns: [ColumnInfo(name: "EXPLAIN", type: "TEXT")],
      rows: [[.string(ExplainFixtures.mysqlJoin)]], rowCount: 1)
    let plan = try #require(ExplainResultPlan.parse(text))
    #expect(plan.root.nodeType == "Nested Loop")
    #expect(plan == MySQLExplainAdapter.plan(fromJSON: ExplainFixtures.mysqlJoin))
    // Only a single EXPLAIN column goes through the MySQL adapter.
    let renamed = CellResult(
      columns: [ColumnInfo(name: "QUERY PLAN", type: "TEXT")],
      rows: [[.string(ExplainFixtures.mysqlJoin)]], rowCount: 1)
    #expect(ExplainResultPlan.parse(renamed) == nil)
    let tree = CellResult(
      columns: [ColumnInfo(name: "EXPLAIN", type: "TEXT")],
      rows: [[.string("-> Rows fetched before execution  (cost=0..0 rows=1)")]], rowCount: 1)
    #expect(ExplainResultPlan.parse(tree) == nil)
    // A PostgreSQL plan still opens through its own column.
    let postgres = CellResult(
      columns: [ColumnInfo(name: "QUERY PLAN", type: "JSON")],
      rows: [[.json(ExplainFixtures.seqScan)]], rowCount: 1)
    #expect(ExplainResultPlan.parse(postgres)?.root.nodeType == "Seq Scan")
    let tabular = CellResult(
      columns: ["id", "select_type", "table"].map { ColumnInfo(name: $0, type: "VARCHAR") },
      rows: [[.int(1), .string("SIMPLE"), .null]], rowCount: 1)
    #expect(ExplainResultPlan.parse(tabular) == nil)
  }

  // MARK: - Live

  @Test(
    "MySQL 8.4 runs EXPLAIN, FORMAT=JSON and ANALYZE through the manager",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func liveMySQL() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: MySQLManagerTests.config(.mysql))
    defer { Task { await manager.disconnect() } }
    let server = await manager.mysqlServerInfo
    #expect(server?.supportsExplainAnalyze == true)

    func run(_ analyze: Bool, json: Bool = false) async throws -> CellResult {
      let request = try ExplainRequest(
        statement: "SELECT 1 AS one", analyze: analyze, buffers: analyze, jsonFormat: json,
        dialect: .mysql, mysqlServer: server)
      let result = try await manager.execute(userSQL: request.sql, policy: open)
      return CellResult(columns: result.columns, rows: result.rows, rowCount: result.rows.count)
    }

    let tabular = try await run(false)
    #expect(tabular.columns.map(\.name).starts(with: ["id", "select_type", "table"]))
    #expect(ExplainResultPlan.parse(tabular) == nil)

    let json = try await run(false, json: true)
    #expect(json.columns.map(\.name) == ["EXPLAIN"])
    #expect(ExplainResultPlan.parse(json)?.root.nodeType == "Result")
    // MySQL types the plan column as text, so the grid shows the JSON document as text.
    guard case .string(let text)? = json.rows.first?.first else {
      Issue.record("Expected JSON text, got \(String(describing: json.rows.first))")
      return
    }
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    #expect((object as? [String: Any])?["query_block"] != nil)

    let analyzed = try await run(true)
    #expect(analyzed.columns.map(\.name) == ["EXPLAIN"])
    #expect(ExplainResultPlan.parse(analyzed) == nil)
    guard case .string(let tree)? = analyzed.rows.first?.first else {
      Issue.record("Expected a text tree, got \(String(describing: analyzed.rows.first))")
      return
    }
    #expect(tree.hasPrefix("->"), "\(tree)")
  }

  @Test(
    "MariaDB hides Explain Analyze and its server rejects EXPLAIN ANALYZE",
    .requiresMySQL, .timeLimit(.minutes(1)))
  func liveMariaDB() async throws {
    let config = MySQLManagerTests.config(.mariadb)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer { Task { await manager.disconnect() } }
    let server = try #require(await manager.mysqlServerInfo)
    #expect(server.flavor == .mariadb)
    #expect(throws: ExplainRequestError.self) {
      try ExplainRequest(
        statement: "SELECT 1", analyze: true, buffers: true, dialect: .mysql,
        mysqlServer: server)
    }
    let plain = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: false, dialect: .mysql,
      mysqlServer: server)
    let tabular = try await manager.execute(userSQL: plain.sql, policy: open)
    #expect(tabular.columns.map(\.name).starts(with: ["id", "select_type", "table"]))
    await #expect(throws: DatabaseError.self) {
      try await manager.execute(userSQL: "EXPLAIN ANALYZE SELECT 1", policy: open)
    }

    // The view model refuses before sending anything and says why.
    let viewModel = NotebookViewModel(notebook: .newDocument())
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.notebook.connectionConfig = config
    viewModel.mysqlServerInfo = server
    viewModel.notebook.cells[0].content = "SELECT 1"
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    #expect(viewModel.canExplainAnalyze == false)
    await viewModel.explainSelectedStatement(analyze: true)
    #expect(viewModel.notebook.cells[0].result == nil)
    #expect(toasts.contains { $0.contains("MariaDB") }, "\(toasts)")
  }
}
