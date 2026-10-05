// CellQueryParameterTests.swift
// Parameter values live on each cell. A run binds only that cell's values, and a
// missing value opens that cell's inline form instead of the right sidebar.

import Foundation
import Testing

@testable import Dblore

@Suite("Cell Query Parameter Tests")
@MainActor
struct CellQueryParameterTests {
  private let namedSQL = "SELECT id FROM t WHERE id = :id"
  private let rewrittenSQL = "SELECT id FROM t WHERE id = $1"

  @Test("Two cells bind their own :id on a plain run")
  func plainRunBindsEachCellValue() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, values: ["first", "second"])
    let firstId = viewModel.notebook.cells[0].id
    let secondId = viewModel.notebook.cells[1].id

    _ = await viewModel.executeTask(ExecutionTask(cellId: firstId, query: namedSQL))
    _ = await viewModel.executeTask(ExecutionTask(cellId: secondId, query: namedSQL))

    #expect(session.statements == [rewrittenSQL, rewrittenSQL])
    #expect(session.statementBinds == [[.text("first")], [.text("second")]])
  }

  @Test("Two cells bind their own :id on a confirmed run")
  func confirmedRunBindsEachCellValue() async throws {
    let sql = "DELETE FROM t WHERE id = :id"
    let rewritten = "DELETE FROM t WHERE id = $1"
    let (viewModel, session) = try await connectedViewModel(
      sql: sql, values: ["first", "second"])
    let firstId = viewModel.notebook.cells[0].id
    let secondId = viewModel.notebook.cells[1].id

    viewModel.confirmAndRunCell(id: firstId)
    #expect(viewModel.queryConfirmationState.showDialog)
    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()

    viewModel.confirmAndRunCell(id: secondId)
    #expect(viewModel.queryConfirmationState.showDialog)
    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements == [rewritten, rewritten])
    #expect(session.statementBinds == [[.text("first")], [.text("second")]])
  }

  @Test("Run All binds each cell's own :id")
  func runAllBindsEachCellValue() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, values: ["first", "second"])

    await viewModel.runAllCells(bypass: true)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements == [rewrittenSQL, rewrittenSQL])
    #expect(session.statementBinds == [[.text("first")], [.text("second")]])
  }

  @Test("Explain on a cell binds that cell's :id")
  func explainBindsCellValue() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, values: ["first", "second"])
    let secondId = viewModel.notebook.cells[1].id

    await viewModel.explain(statement: namedSQL, analyze: false, buffers: false, cellId: secondId)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements == ["EXPLAIN (FORMAT JSON) \(rewrittenSQL)"])
    #expect(session.statementBinds == [[.text("second")]])
  }

  @Test("A missing value refuses that cell even when another cell has one")
  func missingValueRefusesOnlyThatCell() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, values: ["first", nil])
    let firstId = viewModel.notebook.cells[0].id
    let secondId = viewModel.notebook.cells[1].id

    _ = await viewModel.executeTask(ExecutionTask(cellId: firstId, query: namedSQL))
    let refused = await viewModel.executeTask(ExecutionTask(cellId: secondId, query: namedSQL))

    let error = try #require(refused?.error)
    #expect(error.contains("id"))
    #expect(error.contains("Nothing was executed"))
    #expect(session.statements == [rewrittenSQL])
    #expect(session.statementBinds == [[.text("first")]])
  }

  @Test("A refusal opens only that cell's form and keeps the sidebar closed")
  func refusalOpensOnlyThatCellsForm() async throws {
    let (viewModel, _) = try await connectedViewModel(
      sql: namedSQL, values: [nil, "first"])
    let firstId = viewModel.notebook.cells[0].id

    _ = await viewModel.executeTask(ExecutionTask(cellId: firstId, query: namedSQL))

    #expect(viewModel.openParameterFormCellIds == [firstId])
    #expect(!viewModel.isRightSidebarVisible)
    #expect(viewModel.rightSidebarContent != .parameters)
  }

  @Test("toggleParameterForm opens, closes, and holds two cells open")
  func toggleParameterFormTracksOpenCells() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [
        NotebookCell(cellType: .sql, content: namedSQL),
        NotebookCell(cellType: .sql, content: namedSQL),
      ]))
    let firstId = viewModel.notebook.cells[0].id
    let secondId = viewModel.notebook.cells[1].id

    viewModel.toggleParameterForm(cellId: firstId)
    #expect(viewModel.openParameterFormCellIds == [firstId])

    viewModel.toggleParameterForm(cellId: secondId)
    #expect(viewModel.openParameterFormCellIds == [firstId, secondId])

    viewModel.toggleParameterForm(cellId: firstId)
    #expect(viewModel.openParameterFormCellIds == [secondId])
  }

  @Test("hasStoredParameterValues counts only a stored entry for a used name")
  func hasStoredParameterValuesTracksUsedNames() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [NotebookCell(cellType: .sql, content: namedSQL)]))
    let cellId = viewModel.notebook.cells[0].id

    #expect(!viewModel.hasStoredParameterValues(cellId: cellId))
    #expect(!viewModel.hasStoredParameterValues(cellId: UUID()))

    viewModel.notebook.cells[0].parameters = [QueryParameter(name: "unused", value: "x")]
    #expect(!viewModel.hasStoredParameterValues(cellId: cellId))

    viewModel.notebook.cells[0].parameters = [QueryParameter(name: "id", value: nil)]
    #expect(viewModel.hasStoredParameterValues(cellId: cellId))

    viewModel.notebook.cells[0].parameters = [QueryParameter(name: "id", value: "7")]
    #expect(viewModel.hasStoredParameterValues(cellId: cellId))
  }

  @Test("setSavesParameterValues flips the flag and marks dirty")
  func setSavesParameterValuesMarksDirty() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [NotebookCell(cellType: .sql, content: namedSQL)]))
    let cellId = viewModel.notebook.cells[0].id
    var notifications = 0
    viewModel.onDocumentChanged = { notifications += 1 }

    viewModel.setSavesParameterValues(true, cellId: cellId)
    #expect(viewModel.notebook.cells[0].savesParameterValues)
    #expect(notifications == 1)

    viewModel.setSavesParameterValues(false, cellId: cellId)
    #expect(!viewModel.notebook.cells[0].savesParameterValues)
    #expect(notifications == 2)
  }

  @Test("Duplicating a cell copies its parameters and save flag")
  func duplicateCellCopiesParameters() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [
        NotebookCell(
          cellType: .sql, content: namedSQL,
          parameters: [QueryParameter(name: "id", value: "7")],
          savesParameterValues: true)
      ]))
    let originalId = viewModel.notebook.cells[0].id

    viewModel.duplicateCell(id: originalId)

    let duplicate = viewModel.notebook.cells[1]
    #expect(duplicate.id != originalId)
    #expect(duplicate.parameters == [QueryParameter(name: "id", value: "7")])
    #expect(duplicate.savesParameterValues)
  }

  @Test("Deleting a cell removes its id from openParameterFormCellIds")
  func deleteCellClearsOpenForm() {
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(cells: [
        NotebookCell(cellType: .sql, content: namedSQL),
        NotebookCell(cellType: .sql, content: namedSQL),
      ]))
    let firstId = viewModel.notebook.cells[0].id
    let secondId = viewModel.notebook.cells[1].id
    viewModel.toggleParameterForm(cellId: firstId)
    viewModel.toggleParameterForm(cellId: secondId)

    viewModel.deleteCell(id: firstId)

    #expect(viewModel.openParameterFormCellIds == [secondId])
  }

  @Test("A notebook Explain with no cell and no selection toasts and opens nothing")
  func orphanExplainRefusalToasts() async throws {
    let (viewModel, session) = try await connectedViewModel(
      sql: namedSQL, values: [nil])
    viewModel.selectedCellId = nil
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }

    await viewModel.explain(statement: namedSQL, analyze: false, buffers: false)
    await viewModel.executionQueue.waitForIdle()

    #expect(session.statements.isEmpty)
    let toast = try #require(toasts.last)
    #expect(toast.contains("id"))
    #expect(toast.contains("Nothing was executed"))
    #expect(!viewModel.isRightSidebarVisible)
    #expect(viewModel.rightSidebarContent != .parameters)
    #expect(viewModel.openParameterFormCellIds.isEmpty)
  }

  /// Connected view model whose cells all run `sql`; `values[i]` is the stored `:id`
  /// value of cell i (nil stores no entry, so its run is refused).
  private func connectedViewModel(
    sql: String, values: [String?]
  ) async throws -> (NotebookViewModel, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .alertRead,
      protectedMode: false)
    try await manager.connect(config: config)
    let viewModel = NotebookViewModel(
      notebook: DbloreNotebook(
        cells: values.map { value in
          NotebookCell(
            cellType: .sql, content: sql,
            parameters: value.map { [QueryParameter(name: "id", value: $0)] } ?? [])
        },
        connectionConfig: config))
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    let session = try #require(factory.sessions.first)
    return (viewModel, session)
  }
}
