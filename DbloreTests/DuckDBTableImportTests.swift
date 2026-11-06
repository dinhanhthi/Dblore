// DuckDBTableImportTests.swift
// A real DuckDB session (dev plugin) behind the connection actor and a tab. A CSV import
// creates a table whose DECIMAL(p,s) column keeps every digit, and a keyed import updates the
// matched row. DuckDB has no savepoint, so an import with a transaction open or under Protected
// mode is refused before anything is sent. Staged row edits and Generate Rows stay refused.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB table import", .requiresDuckDBPlugin, .serialized)
@MainActor
struct DuckDBTableImportTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test("A CSV import keeps DECIMAL digits in a new table; a keyed import updates the matched row")
  func importsAndUpdates() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let config = duckDBConfig(path: dbPath(folder), protectedMode: false)
    let manager = try await connect(config: config)
    defer { Task { await manager.disconnect() } }
    let viewModel = makeViewModel(manager: manager, config: config)

    let prices = temporaryFile("name,price\nA,1234.567\nB,0.001\n", in: folder)
    let model = TableImportModel()
    await model.loadFile(prices)
    model.destination = .new(schema: "main", table: "prices")
    #expect(await model.submit(to: viewModel), "\(model.errorMessage ?? "")")
    let type = try await manager.executeInternal(
      "SELECT data_type FROM duckdb_columns() WHERE table_name = 'prices' "
        + "AND column_name = 'price'")
    #expect(type.rows == [[.string("DECIMAL(7,3)")]])
    let digits = try await manager.executeInternal(
      "SELECT name, CAST(price AS VARCHAR) FROM prices ORDER BY name")
    #expect(
      digits.rows == [[.string("A"), .string("1234.567")], [.string("B"), .string("0.001")]])

    _ = try await manager.executeInternal(
      "CREATE TABLE items (id INTEGER PRIMARY KEY, name VARCHAR); "
        + "INSERT INTO items VALUES (1, 'a'), (3, 'c')")
    let items = temporaryFile("id,name\n1,A\n2,B\n", in: folder)
    let keyed = TableImportModel()
    await keyed.loadFile(items)
    keyed.destination = .existing(schema: "main", table: "items")
    await keyed.loadMatchKeys { try await manager.fetchTableStructure(schema: $0, table: $1) }
    keyed.matchKey = keyed.matchKeys.first
    #expect(keyed.matchKey?.columns == ["id"])
    keyed.mode = .insertOrUpdate
    #expect(await keyed.submit(to: viewModel), "\(keyed.errorMessage ?? "")")
    let rows = try await manager.executeInternal("SELECT id, name FROM items ORDER BY id")
    #expect(
      rows.rows == [
        [.int(1), .string("A")], [.int(2), .string("B")], [.int(3), .string("c")],
      ])
  }

  @Test("An import with a transaction open or under Protected mode is refused before sending")
  func importInTransactionRefused() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = temporaryFile("name\nA\n", in: folder)

    // Safe Mode confirms writes: the sheet shows the reason before any confirmation
    var config = duckDBConfig(path: dbPath(folder), protectedMode: false)
    config.applyCommitStyle(.confirm)
    let manager = try await connect(config: config)
    let viewModel = makeViewModel(manager: manager, config: config)
    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let model = TableImportModel()
    await model.loadFile(file)
    model.destination = .new(schema: "main", table: "imported")
    #expect(await model.submit(to: viewModel) == false)
    #expect(
      model.errorMessage?.contains(DatabaseConnectionManager.duckDBImportTransactionOpenRefusal)
        == true, "\(model.errorMessage ?? "")")
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.pendingStagedBatch == nil)
    // The gate still refuses a data import sent past the sheet
    let create = BoundStatement(
      sql: "CREATE TABLE imported (name VARCHAR)", values: [], expectedRows: nil)
    let epoch = await manager.connectionEpoch
    let gateError = await #expect(throws: DatabaseError.self) {
      try await manager.executeGatedBatch(
        [create], policy: open, connectionEpoch: epoch, isDataImport: true)
    }
    guard case .sequentialBatchRefused(let reason) = gateError,
      reason == DatabaseConnectionManager.duckDBImportTransactionOpenRefusal
    else {
      Issue.record("Expected the transaction-open refusal, got \(String(describing: gateError))")
      return
    }
    _ = try await manager.execute(userSQL: "ROLLBACK", policy: open)
    try await expectNoImportedTable(manager)
    await manager.disconnect()

    let protected = duckDBConfig(path: dbPath(folder), protectedMode: true)
    let protectedManager = try await connect(config: protected)
    defer { Task { await protectedManager.disconnect() } }
    let protectedModel = TableImportModel()
    await protectedModel.loadFile(file)
    protectedModel.destination = .new(schema: "main", table: "imported")
    #expect(
      await protectedModel.submit(
        to: makeViewModel(manager: protectedManager, config: protected)) == false)
    #expect(
      protectedModel.errorMessage?.contains(
        DatabaseConnectionManager.duckDBImportProtectedModeRefusal) == true,
      "\(protectedModel.errorMessage ?? "")")
    #expect(await protectedManager.txState.isIdle)
    try await expectNoImportedTable(protectedManager)
  }

  @Test("Staged Add Row / Delete Row batches and Generate Rows are still refused at the gate")
  func rowEditsStillRefused() async throws {
    let manager = try await connect(
      config: duckDBConfig(path: DuckDBSession.inMemoryPath, protectedMode: false))
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)")
    let epoch = await manager.connectionEpoch
    let staged = [
      BoundStatement(sql: "INSERT INTO t (id) VALUES ($1)", values: ["2"], expectedRows: 1),
      BoundStatement(sql: "DELETE FROM t WHERE id = $1", values: ["1"], expectedRows: 1),
    ]
    let stagedError = await #expect(throws: DatabaseError.self) {
      try await manager.executeGatedBatch(staged, policy: open, connectionEpoch: epoch)
    }
    guard case .notEditable = stagedError else {
      Issue.record("Expected notEditable, got \(String(describing: stagedError))")
      return
    }
    let generated = StreamedBatch(
      relation: "t",
      nextChunk: {
        [BoundStatement(sql: "INSERT INTO t (id) VALUES (9)", values: [], expectedRows: 1)]
      })
    let generatedError = await #expect(throws: DatabaseError.self) {
      try await manager.executeGatedBatch(
        streamed: generated, policy: open, connectionEpoch: epoch)
    }
    guard case .notEditable = generatedError else {
      Issue.record("Expected notEditable, got \(String(describing: generatedError))")
      return
    }
    #expect(try await manager.executeInternal("SELECT id FROM t").rows == [[.int(1)]])
  }

  // MARK: - Helpers

  private func expectNoImportedTable(_ manager: DatabaseConnectionManager) async throws {
    let tables = try await manager.executeInternal(
      "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'imported'")
    #expect(tables.rows == [[.int(0)]])
  }

  /// The app's session factory with the dev plugin as the installed one.
  private func connect(config: ConnectionConfig) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: AppDatabaseSessionFactory(duckDBLibraryLoader: {
        { try DuckDBTestPlugin.library() }
      }))
    try await manager.connect(config: config)
    return manager
  }

  /// Read-write file (`readOnlyFile: false`): a refusal comes from the gate, not the file.
  private func duckDBConfig(path: String, protectedMode: Bool) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: path, sslMode: .disable, protectionLevel: .none,
      safeMode: .silent, protectedMode: protectedMode, statementTimeoutSeconds: 30,
      readOnlyFile: false)
  }

  private func makeViewModel(
    manager: DatabaseConnectionManager, config: ConnectionConfig
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: .newDocument())
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.notebook.connectionConfig = config
    return viewModel
  }

  private func temporaryFile(_ contents: String, in folder: URL) -> URL {
    let url = folder.appendingPathComponent("import-\(UUID().uuidString).csv")
    try! Data(contents.utf8).write(to: url)
    return url
  }

  private func dbPath(_ folder: URL) -> String {
    folder.appendingPathComponent("import.duckdb").path
  }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
