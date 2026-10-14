// MySQLEndToEndTests.swift
// MySQL 8.4 (3307) and MariaDB 11.4 (3308) end to end, through WorkspaceManager, its
// DatabaseConnectionManager and the tab view models as the app wires them: staged insert / edit
// / delete and an inline cell save in a data viewer (plus a filter on a `Z` timestamp), editor
// runs (capped read keeps the session, cancel keeps the session), CSV import in INSERT batches
// into an existing and a new table, the referenced-row (FK) lookup, and Protected mode refusing
// DDL while DML is pending (nothing committed, the DML stays pending and rolls back). History
// rows carry the right source, kind and status. Opt-in (`.requiresMySQL`). Tables use `e2e_`.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLEndToEndTests {
  typealias Server = MySQLSessionTests.Server

  private static let database = TestMySQLDatabase.database

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - Data viewer

  @Test(
    "Data viewer: staged insert / edit / delete commit, inline save, Z filter; history",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func dataViewerEdits(server: Server) async throws {
    let table = Self.tableName("items")
    try await withWorkspace(
      server,
      setup: [
        "CREATE TABLE \(table) (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(20), "
          + "seen DATETIME(6))",
        "INSERT INTO \(table) VALUES (1, 'a', '2024-01-02 03:04:05'), (2, 'b', NULL)",
      ],
      tables: [table]
    ) { workspace, observer, recorder in
      let viewModel = try await openViewer(table, in: workspace, recorder: recorder)

      #expect(await viewModel.addStagedRow() == nil)
      let added = try #require(viewModel.editorResult?.rows.count)
      #expect(viewModel.stageEdit(row: added, column: "name", value: .string("c")) == nil)
      #expect(
        viewModel.stageEdit(row: try row(1, viewModel), column: "name", value: .string("A")) == nil)
      #expect(viewModel.stageDelete(rows: [try row(2, viewModel)]) == nil)
      await viewModel.commitStaged()
      #expect(viewModel.dataViewer?.changeSet == nil)
      #expect(
        try await observer.executeInternal("SELECT id, name FROM \(table) ORDER BY id").rows
          == [[.int(1), .string("A")], [.int(3), .string("c")]])

      // Inline cell save, as the cell sidebar sends it.
      let result = try #require(viewModel.editorResult)
      let target = try #require(result.editTarget)
      let statement = try CellUpdateStatement.make(
        qualifiedName: target.qualifiedName, columnName: "name", newValue: "inline",
        primaryKeyColumns: target.primaryKeyColumns,
        rowData: CellResult.rowData(
          columns: result.columns, row: result.rows[try row(3, viewModel)]),
        updateOnly: target.updateOnly, dialect: .mysql)
      await viewModel.sendInlineEdit(
        PendingInlineEdit(
          statement: statement, columnNames: ["name"], tableName: target.qualifiedName, cellId: nil,
          connectionManager: workspace.connectionManager),
        target: target)
      #expect(
        try await observer.executeInternal("SELECT name FROM \(table) WHERE id = 3").rows
          == [[.string("inline")]])

      // A filter value with a `Z` suffix matches the DATETIME (UTC session).
      await viewModel.applyFilter(
        TableFilter(conditions: [FilterCondition(column: "seen", value: "2024-01-02T03:04:05Z")]))
      #expect(viewModel.editorResult?.error == nil)
      #expect(viewModel.editorResult?.rows.count == 1)
      #expect(viewModel.editorResult?.rows.first?.first == .int(1))

      // Page loads are internal: only the two writes are recorded.
      let entries = try await recorder.settled(count: 2)
      #expect(entries.map(\.source) == [.dataViewerEdit, .dataViewerEdit])
      #expect(entries.map(\.kind) == [.write, .write])
      #expect(entries.allSatisfy { $0.status == .success })
    }
  }

  // MARK: - Editor runs

  @Test(
    "Editor: capped read and cancel keep the session; history kinds and statuses",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func editorRuns(server: Server) async throws {
    let table = Self.tableName("nums")
    try await withWorkspace(
      server, rowCap: 100,
      setup: [
        "CREATE TABLE \(table) (n INT PRIMARY KEY)",
        "INSERT INTO \(table) (n) WITH RECURSIVE seq (n) AS "
          + "(SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 300) SELECT n FROM seq",
      ],
      tables: [table, table + "_new"]
    ) { workspace, _, recorder in
      let viewModel = try sqlTab(in: workspace, recorder: recorder)
      let manager = workspace.connectionManager
      let epoch = await manager.connectionEpoch

      await viewModel.executeEditorQuery("SELECT n FROM \(table) ORDER BY n")
      #expect(viewModel.editorResult?.error == nil)
      #expect(viewModel.editorResult?.wasLimited == true)
      #expect(viewModel.editorResult?.rows.count == 100)
      await viewModel.executeEditorQuery("SELECT COUNT(*) FROM \(table)")
      #expect(viewModel.editorResult?.rows == [[.int(300)]])
      #expect(await manager.connectionEpoch == epoch)

      // Cancel a long statement: the session, epoch and connection stay.
      viewModel.cancelQueryPrompt = { _ in true }
      let sleeping = Task { await viewModel.executeEditorQuery("SELECT SLEEP(30)") }
      while !(await manager.runningStatementStatus().inFlight) {
        try await Task.sleep(for: .milliseconds(10))
      }
      try await Task.sleep(for: .milliseconds(300))
      let start = ContinuousClock.now
      // A KILL sent before the statement reached the server stops nothing: repeat.
      while await manager.runningStatementStatus().inFlight {
        _ = await viewModel.cancelRunningStatement(cancelQueue: false)
        try await Task.sleep(for: .milliseconds(200))
      }
      await sleeping.value
      #expect(ContinuousClock.now - start < .seconds(5))
      #expect(viewModel.editorResult?.error != nil)
      #expect(await manager.connectionEpoch == epoch)
      #expect(await manager.isConnected)

      await viewModel.executeEditorQuery("UPDATE \(table) SET n = n + 1000 WHERE n = 1")
      #expect(viewModel.editorResult?.error == nil)
      await viewModel.executeEditorQuery("CREATE TABLE \(table)_new (id INT)")
      #expect(viewModel.editorResult?.error == nil)

      let entries = try await recorder.settled(count: 5)
      #expect(entries.allSatisfy { $0.source == .editor })
      // SLEEP() is a function call: the MySQL classifier cannot prove it reads, so `.other`.
      #expect(entries.map(\.kind) == [.read, .read, .other, .write, .schema])
      #expect(entries.map(\.status) == [.success, .success, .cancelled, .success, .success])
      #expect(entries.first?.rowCount == 100)
    }
  }

  // MARK: - CSV import

  @Test(
    "CSV import in INSERT batches into an existing and a new table (Z timestamps); history",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func csvImport(server: Server) async throws {
    let existing = Self.tableName("imp")
    let created = Self.tableName("impnew")
    try await withWorkspace(
      server,
      setup: ["CREATE TABLE \(existing) (id BIGINT PRIMARY KEY, seen DATETIME(6))"],
      tables: [existing, created]
    ) { workspace, observer, recorder in
      let viewModel = try sqlTab(in: workspace, recorder: recorder)

      // 1,500 rows: two INSERT statements (1,000 rows each at most).
      let rows = (1...1_500).map { "\($0),2024-01-02T03:04:05Z" }.joined(separator: "\n")
      let model = try await Self.importModel("id,seen\n" + rows + "\n")
      defer { try? FileManager.default.removeItem(at: model.fileURL!) }
      model.destination = .existing(schema: nil, table: existing)
      let batch = try await model.prepareBatch(dialect: .mysql, connectionEpoch: 0)
      #expect(batch.statements.map(\.expectedRows) == [1_000, 500])
      #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
      #expect(
        try await observer.executeInternal(
          "SELECT COUNT(*), MIN(seen) = '2024-01-02 03:04:05' FROM \(existing)"
        ).rows == [[.int(1_500), .int(1)]])

      let fresh = try await Self.importModel("id,seen,name\n1,2024-01-02T05:04:05.5+02:00,Ada\n")
      defer { try? FileManager.default.removeItem(at: fresh.fileURL!) }
      fresh.destination = .new(schema: nil, table: created)
      #expect(await fresh.submit(to: viewModel), "\(fresh.errorMessage ?? "")")
      #expect(
        try await observer.executeInternal("SELECT id, CAST(seen AS CHAR), name FROM \(created)")
          .rows == [[.int(1), .string("2024-01-02 03:04:05.500000"), .string("Ada")]])

      let entries = try await recorder.settled(count: 2)
      #expect(entries.map(\.source) == [.dataImport, .dataImport])
      // CREATE TABLE + INSERT: a write is kept over schema.
      #expect(entries.map(\.kind) == [.write, .write])
      #expect(entries.last?.sql.hasPrefix("CREATE TABLE") == true)
      #expect(entries.map(\.rowCount) == [1_500, 1])
    }
  }

  // MARK: - Foreign key lookup

  @Test(
    "The FK popover lookup finds the referenced row and is not recorded", .requiresMySQL,
    .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func foreignKeyLookup(server: Server) async throws {
    let parent = Self.tableName("parent")
    let child = Self.tableName("child")
    try await withWorkspace(
      server,
      setup: [
        "CREATE TABLE \(parent) (id INT PRIMARY KEY, label VARCHAR(20))",
        "CREATE TABLE \(child) (id INT PRIMARY KEY, parent_id INT, "
          + "FOREIGN KEY (parent_id) REFERENCES \(parent) (id))",
        "INSERT INTO \(parent) VALUES (7, 'seven'), (8, 'eight')",
        "INSERT INTO \(child) VALUES (1, 7)",
      ],
      tables: [child, parent]
    ) { workspace, _, recorder in
      try await Self.waitUntil {
        workspace.databaseForeignKeys.contains { $0.sourceTable == child }
      }
      let viewModel = try sqlTab(in: workspace, recorder: recorder)
      #expect(viewModel.databaseForeignKeys.contains { $0.targetTable == parent })

      await viewModel.executeEditorQuery("SELECT id, parent_id FROM \(child)")
      let result = try #require(viewModel.editorResult)
      #expect(result.error == nil)
      #expect(result.editTarget != nil)
      let found = try await viewModel.lookupReferencedRow(
        column: "parent_id", schema: Self.database, table: child, rowColumns: ["id", "parent_id"],
        values: CellResult.rowData(columns: result.columns, row: result.rows[0]))
      #expect(found?.rows == [[.int(7), .string("seven")]])

      let entries = try await recorder.settled(count: 1)
      #expect(entries.map(\.sql) == ["SELECT id, parent_id FROM \(child)"])
    }
  }

  // MARK: - Protected mode

  @Test(
    "Protected mode refuses DDL with DML pending: nothing commits, the DML rolls back",
    .requiresMySQL, .timeLimit(.minutes(1)), arguments: [Server.mysql, .mariadb])
  func protectedRefusesDDL(server: Server) async throws {
    let table = Self.tableName("prot")
    try await withWorkspace(
      server, protectedMode: true,
      setup: ["CREATE TABLE \(table) (id INT PRIMARY KEY)"],
      tables: [table, table + "_new"]
    ) { workspace, observer, recorder in
      let viewModel = try sqlTab(in: workspace, recorder: recorder)
      let manager = workspace.connectionManager
      func committed() async throws -> [[CellValue]] {
        try await observer.executeInternal("SELECT id FROM \(table)").rows
      }
      func newTableExists() async throws -> Bool {
        try await observer.executeInternal(
          """
          SELECT COUNT(*) FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '\(table)_new'
          """
        ).rows != [[.int(0)]]
      }

      await viewModel.executeEditorQuery("INSERT INTO \(table) VALUES (1)")
      #expect(viewModel.editorResult?.error == nil)
      #expect(await manager.transactionSnapshot().pending.count == 1)

      for ddl in ["CREATE TABLE \(table)_new (id INT)", "TRUNCATE TABLE \(table)"] {
        await viewModel.executeEditorQuery(ddl)
        #expect(viewModel.editorResult?.error?.contains("commits implicitly") == true, "\(ddl)")
        // No silent commit: the INSERT is still pending, invisible to another session.
        #expect(await manager.transactionSnapshot().pending.count == 1)
        #expect(try await committed().isEmpty)
        #expect(try await newTableExists() == false)
      }

      try await manager.rollbackAppTransaction()
      #expect(await manager.transactionSnapshot().isIdle)
      #expect(try await committed().isEmpty)

      let entries = try await recorder.settled(count: 3)
      #expect(entries.first?.kind == .write)
      #expect(entries.first?.status == .success)
      #expect(entries.dropFirst().allSatisfy { $0.status == .error })
      #expect(entries.dropFirst().first?.kind == .schema)
    }
  }

  // MARK: - Helpers

  private static func tableName(_ base: String) -> String {
    "e2e_\(base)_\(UUID().uuidString.prefix(6).lowercased())"
  }

  /// A workspace connected to `server` (Safe Mode silent, protection none, `protectedMode`),
  /// after `setup` ran on an unprotected observer, plus a history recorder for the tabs.
  /// `tables` are dropped and both connections close on every path.
  private func withWorkspace(
    _ server: Server, protectedMode: Bool = false, rowCap: Int? = nil, setup: [String],
    tables: [String],
    _ body: (WorkspaceManager, DatabaseConnectionManager, EndToEndHistoryRecorder) async throws
      -> Void
  ) async throws {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: MySQLManagerTests.config(server))
    let workspace = WorkspaceManager(
      workspace: Workspace.newUntitled(connection: nil), restoreTabs: false)
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    do {
      for table in tables {
        _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
      }
      for statement in setup {
        _ = try await observer.executeInternal(statement)
      }
      var config = MySQLManagerTests.config(server, protectedMode: protectedMode)
      config.safeMode = .silent
      config.rowCapOverride = rowCap
      try await workspace.connect(
        config: config, defaultCommitStyle: .immediate, hasPassword: false, hasTouchID: false)
      try await Self.waitUntil { !workspace.isLoadingSchema }
      try await body(workspace, observer, EndToEndHistoryRecorder())
    } catch {
      await Self.tearDown(workspace, observer, tables)
      throw error
    }
    await Self.tearDown(workspace, observer, tables)
  }

  private static func tearDown(
    _ workspace: WorkspaceManager, _ observer: DatabaseConnectionManager, _ tables: [String]
  ) async {
    try? await workspace.connectionManager.rollbackAppTransaction()
    _ = await workspace.disconnect(resolution: .rollback)
    for table in tables {
      _ = try? await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    }
    await observer.disconnect()
  }

  /// A new SQL tab of `workspace` recording history into `recorder`.
  private func sqlTab(
    in workspace: WorkspaceManager, recorder: EndToEndHistoryRecorder
  ) throws -> NotebookViewModel {
    let viewModel = try #require(workspace.viewModel(for: workspace.newSQLFile()))
    record(viewModel, into: recorder)
    return viewModel
  }

  /// The data viewer tab of `table`, loaded with a live edit target.
  private func openViewer(
    _ table: String, in workspace: WorkspaceManager, recorder: EndToEndHistoryRecorder
  ) async throws -> NotebookViewModel {
    workspace.openDataViewer(schema: Self.database, name: table, orderColumns: ["id"])
    let viewModel = try #require(workspace.activeViewModel)
    record(viewModel, into: recorder)
    try await Self.waitUntil {
      !viewModel.isEditorQueryRunning && viewModel.dataViewer?.totalRows != nil
        && viewModel.editorResult?.editTarget != nil
    }
    return viewModel
  }

  private func record(_ viewModel: NotebookViewModel, into recorder: EndToEndHistoryRecorder) {
    viewModel.historyRecorder = recorder
    let suiteName = "MySQLEndToEndTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let settings = AppSettings(defaults: defaults)
    settings.historyEnabled = true
    viewModel.historySettings = settings
  }

  private func row(_ id: Int, _ viewModel: NotebookViewModel) throws -> Int {
    let result = try #require(viewModel.editorResult)
    let column = try #require(result.columns.firstIndex { $0.name == "id" })
    return try #require(result.rows.firstIndex { $0[column] == .int(id) })
  }

  private static func importModel(_ csv: String) async throws -> TableImportModel {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-e2e-\(UUID().uuidString).csv")
    try Data(csv.utf8).write(to: url)
    let model = TableImportModel()
    await model.loadFile(url)
    return model
  }

  private static func waitUntil(
    timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("Timed out waiting for a condition")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// Every history row a tab records. Recording is fire-and-forget, so `settled` waits.
private actor EndToEndHistoryRecorder: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }

  /// The entries once `count` arrived and a short pause added none.
  func settled(count: Int) async throws -> [QueryHistoryEntry] {
    let deadline = ContinuousClock.now + .seconds(10)
    while entries.count < count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(entries.count == count, "\(entries.map(\.sql))")
    return entries
  }
}
