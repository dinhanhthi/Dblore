// AIResultSessionKeyTests.swift
// `@results` reads a result only while it is stamped with the tab's `aiSessionKey`: a successful
// editor run and a cell run (one statement or several) stamp it, and the data viewer's row
// refresh after an edit keeps it. Fake sessions, no database needed.

import Foundation
import Testing

@testable import Dblore

@Suite("AI result session key")
@MainActor
struct AIResultSessionKeyTests {
  private static let sqlColumns = [ColumnInfo(name: "id", type: "int4")]
  private static let sqlRows: [[CellValue]] = [[.int(1)], [.int(2)]]

  private static func sqlConfig() -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  /// A view model on `config` through `factory`
  private static func connected(
    _ config: ConnectionConfig, factory: FakeDatabaseSessionFactory
  ) async throws -> (NotebookViewModel, DatabaseConnectionManager) {
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = config
    viewModel.toastPresenter = { _, _ in }
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    return (viewModel, manager)
  }

  private static func sqlConnected() async throws -> (NotebookViewModel, DatabaseConnectionManager)
  {
    try await connected(
      sqlConfig(),
      factory: FakeDatabaseSessionFactory(
        capabilities: .contract(), columns: sqlColumns, rows: sqlRows))
  }

  @Test("A successful editor run stamps the result and each statement with the tab's key")
  func editorRunStamps() async throws {
    let (viewModel, manager) = try await Self.sqlConnected()
    viewModel.viewMode = .editor
    let key = try #require(viewModel.aiSessionKey)

    await viewModel.executeEditorQuery("SELECT id FROM t")
    #expect(viewModel.editorResult?.error == nil)
    #expect(viewModel.editorResult?.aiSessionKey == key)
    #expect(viewModel.aiCurrentResult != nil)

    await viewModel.executeEditorQuery("SELECT id FROM t; SELECT id FROM u")
    let statements = viewModel.editorStatementResults
    #expect(statements.count == 2)
    #expect(statements.allSatisfy { $0.result.aiSessionKey == key })
    #expect(viewModel.aiCurrentResult != nil)
    await manager.disconnect()
  }

  @Test("A successful cell run stamps the result and each statement with the tab's key")
  func cellRunStamps() async throws {
    let (viewModel, manager) = try await Self.sqlConnected()
    viewModel.viewMode = .notebook
    let key = try #require(viewModel.aiSessionKey)
    viewModel.notebook.cells = [
      NotebookCell(cellType: .sql, content: "SELECT id FROM t"),
      NotebookCell(cellType: .sql, content: "SELECT id FROM t; SELECT id FROM u"),
    ]

    await viewModel.runCell(id: viewModel.notebook.cells[0].id)
    await viewModel.executionQueue.waitForIdle()
    let single = try #require(viewModel.notebook.cells[0].result)
    #expect(single.error == nil)
    #expect(single.aiSessionKey == key)

    await viewModel.runCell(id: viewModel.notebook.cells[1].id)
    await viewModel.executionQueue.waitForIdle()
    let statements = viewModel.notebook.cells[1].statementResults
    #expect(statements.count == 2)
    #expect(statements.allSatisfy { $0.result.aiSessionKey == key })
    await manager.disconnect()
  }

  // MARK: - Data viewer refresh

  private static let first = "0123456789abcdef01234567"
  private static let second = "89abcdef0123456789abcdef"
  private static let pageCommand = "db.users.find().sort({ _id: 1 }).limit(100)"

  @Test("The data viewer's row refresh after an edit keeps the result's key")
  func dataViewerRefreshKeepsKey() async throws {
    let config = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable)
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities,
      columns: [
        ColumnInfo(name: "_id", type: "objectId"), ColumnInfo(name: "name", type: "string"),
      ],
      rows: [[.string(Self.first), .string("ann")], [.string(Self.second), .string("bob")]],
      commandRows: { _ in 1 })
    let (viewModel, manager) = try await Self.connected(config, factory: factory)
    viewModel.viewMode = .editor
    var state = DataViewerState(schema: "db", name: "users", orderColumns: ["_id"])
    state.databaseType = .mongodb
    viewModel.dataViewer = state
    await viewModel.loadDataViewerPage()
    let key = try #require(viewModel.aiSessionKey)
    viewModel.editorResult?.aiSessionKey = key

    // With a change staged, an edit re-reads the rows instead of reloading the page
    #expect(viewModel.stageDelete(rows: [1]) == nil)
    let result = try #require(viewModel.editorResult)
    let column = try #require(result.columns.firstIndex { $0.name == "name" })
    viewModel.handleGridCellEdit(
      row: result.rows[0], column: column, newValue: "zoe", result: result, cellId: nil,
      connectionManager: manager)
    await viewModel.executePendingQuery()
    #expect(factory.statements.last == Self.pageCommand)
    #expect(viewModel.editorResult?.aiSessionKey == key)
    await manager.disconnect()
  }
}
