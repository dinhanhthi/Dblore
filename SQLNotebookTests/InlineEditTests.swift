// InlineEditTests.swift
// Inline grid edit (S6): primary-key-only UPDATE with bind parameters, routed through the
// protection gate and the Safe Mode confirmation flow.

import Foundation
import Testing

@testable import SQLNotebook

// MARK: - SQL builder

@Suite("Inline Edit - UPDATE builder")
struct CellUpdateStatementTests {

  @Test("Identifiers are double-quoted with embedded quotes doubled; values use $1/$2 binds")
  func quotesIdentifiersAndBindsValues() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: #"public."we""ird""#, columnName: "co\"l", newValue: "x'; DROP TABLE t; --",
      primaryKeyColumns: ["id"], rowData: ["id": .int(7), "co\"l": .string("old")])
    #expect(statement.sql == #"UPDATE public."we""ird" SET "co""l" = $1 WHERE "id" = $2"#)
    #expect(statement.values == ["x'; DROP TABLE t; --", "7"])
  }

  @Test("Schema-qualified table and composite primary key keep key order")
  func compositePrimaryKey() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "sales.orders", columnName: "qty", newValue: "5",
      primaryKeyColumns: ["order_id", "line_no"],
      rowData: ["order_id": .int(10), "line_no": .int(2), "qty": .int(1)])
    #expect(
      statement.sql
        == #"UPDATE sales.orders SET "qty" = $1 WHERE "order_id" = $2 AND "line_no" = $3"#)
    #expect(statement.values == ["5", "10", "2"])
  }

  @Test("A nil new value binds NULL")
  func nullNewValue() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.t", columnName: "note", newValue: nil, primaryKeyColumns: ["id"],
      rowData: ["id": .string("a1")])
    #expect(statement.values == [nil, "a1"])
  }

  @Test("No primary key is refused (no all-columns fallback)")
  func noPrimaryKeyRefused() {
    #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: [],
        rowData: ["a": .int(0), "b": .int(1)])
    }
  }

  @Test("A primary key column missing from the row is refused")
  func missingPrimaryKeyValueRefused() {
    #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
        rowData: ["a": .int(0)])
    }
  }

  @Test("A NULL primary key value is refused")
  func nullPrimaryKeyValueRefused() {
    #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
        rowData: ["id": .null, "a": .int(0)])
    }
  }

  @Test("Generated UPDATE classifies as one DML statement that readOnly blocks")
  func generatedSQLIsGated() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: #"public."we""ird""#, columnName: "a", newValue: "1",
      primaryKeyColumns: ["id"],
      rowData: ["id": .int(1)])
    let classified = SQLStatementClassifier.classify(statement.sql)
    #expect(classified.count == 1)
    #expect(classified.first?.kind == .dml)
    #expect(classified.first?.affectsAllRows == false)
    let decision = DatabaseConnectionManager.evaluate(
      classified, policy: ProtectionPolicy(protectionLevel: .readOnly))
    #expect(decision != .allowed)
    #expect(
      DatabaseConnectionManager.evaluate(
        classified, policy: ProtectionPolicy(protectionLevel: .schemaOnly)) == .allowed)
  }

  @Test("UPDATE ONLY (plain table) is emitted and gated like any UPDATE")
  func updateOnlyIsGated() throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1)], updateOnly: true)
    #expect(statement.sql == #"UPDATE ONLY public.t SET "a" = $1 WHERE "id" = $2"#)
    let classified = SQLStatementClassifier.classify(statement.sql)
    #expect(classified.count == 1)
    #expect(classified.first?.kind == .dml)
    #expect(classified.first?.affectsAllRows == false)
    #expect(
      DatabaseConnectionManager.evaluate(
        classified, policy: ProtectionPolicy(protectionLevel: .readOnly)) != .allowed)
    #expect(
      DatabaseConnectionManager.evaluate(
        classified, policy: ProtectionPolicy(protectionLevel: .schemaOnly)) == .allowed)
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(classified, safeMode: .alertRead) != nil)
  }

  @Test("Edited text: empty or 'null' on a NULL cell binds NULL, other text is kept")
  func bindTextForEditedValue() {
    #expect(NotebookViewModel.bindText(for: "", original: .null) == nil)
    #expect(NotebookViewModel.bindText(for: "NULL", original: .null) == nil)
    #expect(NotebookViewModel.bindText(for: "null", original: .string("a")) == "null")
    #expect(NotebookViewModel.bindText(for: "42", original: .int(1)) == "42")
  }

  // MARK: Actor gate

  @Test("Gated update under readOnly throws blockedByProtection before the connection check")
  func actorGateBlocksReadOnly() async throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1)])
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.executeGatedUpdate(
        statement, policy: ProtectionPolicy(protectionLevel: .readOnly), connectionEpoch: 0)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, let kind, _) {
      #expect(index == 0)
      #expect(kind == .dml)
    }
  }

  @Test("Gated update allowed by the policy reaches the connection check")
  func actorGateAllowsNone() async throws {
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1)])
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.executeGatedUpdate(
        statement, policy: ProtectionPolicy(protectionLevel: .schemaOnly), connectionEpoch: 0)
      Issue.record("Expected notConnected")
    } catch DatabaseError.notConnected {
      // expected
    }
  }
}

// MARK: - ViewModel

@Suite("Inline Edit - ViewModel gate and confirmation")
@MainActor
struct InlineEditViewModelTests {

  private let cellId = UUID()
  private let rowData: [String: CellValue] = ["id": .int(1), "name": .string("old")]

  /// Notebook whose cell result carries a live edit target (as set by a live execution)
  private func makeViewModel(
    config: ConnectionConfig?, primaryKeyColumns: [String] = ["id"]
  ) -> NotebookViewModel {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
      rows: [[.int(1), .string("old")]], rowCount: 1, sourceQuery: "SELECT * FROM users",
      tableName: "public.users", primaryKeyColumns: primaryKeyColumns,
      editTarget: EditTarget(
        qualifiedName: "public.users", oid: 16_400, primaryKeyColumns: primaryKeyColumns))
    let notebook = SQLNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: cellId, cellType: .sql, content: "SELECT * FROM users", executionCount: 1,
          result: result)
      ],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Inline edit"),
      connectionConfig: config, settings: NotebookSettings())
    return NotebookViewModel(notebook: notebook)
  }

  /// Open the sidebar on the cell (captures the live target), then edit it
  private func edit(
    _ viewModel: NotebookViewModel, primaryKeyColumns: [String] = ["id"],
    tableName: String? = "users"
  ) {
    viewModel.showCellDetail(
      columnName: "name", columnType: "text", value: .string("old"), tableName: tableName,
      rowData: rowData, primaryKeyColumns: primaryKeyColumns,
      editTarget: viewModel.notebook.cells.first?.result?.editTarget, cellId: cellId)
    viewModel.handleCellValueEdit(
      columnName: "name", columnType: "text", newValue: "new", originalValue: .string("old"),
      tableName: tableName, rowData: rowData, primaryKeyColumns: primaryKeyColumns,
      cellId: cellId, connectionManager: DatabaseConnectionManager())
  }

  // MARK: canEdit

  @Test("canEdit: single table with PK present in the result")
  func canEditWithPrimaryKey() throws {
    let viewModel = makeViewModel(config: ConnectionConfig(protectionLevel: .none))
    let result = try #require(viewModel.notebook.cells[0].result)
    #expect(viewModel.canEdit(result))
  }

  @Test("canEdit is false without a primary key")
  func cannotEditWithoutPrimaryKey() {
    let viewModel = makeViewModel(config: ConnectionConfig(protectionLevel: .none))
    let result = CellResult(
      columns: [ColumnInfo(name: "a", type: "int4")], rows: [[.int(1)]], tableName: "t",
      primaryKeyColumns: [])
    #expect(viewModel.canEdit(result) == false)
  }

  @Test("canEdit is false when a PK column is not in the result")
  func cannotEditWhenPrimaryKeyNotSelected() {
    let viewModel = makeViewModel(config: ConnectionConfig(protectionLevel: .none))
    let result = CellResult(
      columns: [ColumnInfo(name: "name", type: "text")], rows: [[.string("x")]],
      tableName: "users", primaryKeyColumns: ["id"])
    #expect(viewModel.canEdit(result) == false)
  }

  @Test("canEdit is false without a single source table")
  func cannotEditWithoutTable() {
    let viewModel = makeViewModel(config: ConnectionConfig(protectionLevel: .none))
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")], rows: [[.int(1)]], tableName: nil,
      primaryKeyColumns: ["id"])
    #expect(viewModel.canEdit(result) == false)
  }

  @Test("canEdit is false on a read-only connection")
  func cannotEditReadOnly() throws {
    let viewModel = makeViewModel(config: ConnectionConfig(protectionLevel: .readOnly))
    let result = try #require(viewModel.notebook.cells[0].result)
    #expect(viewModel.canEdit(result) == false)
  }

  // MARK: Gate and confirmation

  @Test("readOnly blocks inline edit: error toast, no dialog, nothing pending")
  func readOnlyBlocksInlineEdit() {
    let viewModel = makeViewModel(config: ConnectionConfig(protectionLevel: .readOnly))
    WorkspaceWindowManager.shared.dismissToast()
    edit(viewModel)
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingInlineEdit == nil)
    let toast = WorkspaceWindowManager.shared.toastState.currentToast
    #expect(toast?.type == .error)
    #expect(toast?.message.contains("read-only") == true)
  }

  @Test("No primary key: edit refused with an error toast before sending")
  func noPrimaryKeyRefused() {
    let viewModel = makeViewModel(
      config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead),
      primaryKeyColumns: [])
    WorkspaceWindowManager.shared.dismissToast()
    edit(viewModel, primaryKeyColumns: [])
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingInlineEdit == nil)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
  }

  @Test("alertRead: confirmation with the UPDATE preview is shown before sending")
  func alertReadAsksBeforeSending() {
    let viewModel = makeViewModel(
      config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    edit(viewModel)
    let state = viewModel.queryConfirmationState
    #expect(state.showDialog)
    #expect(state.pendingInlineEdit != nil)
    #expect(state.pendingQuery == #"UPDATE public.users SET "name" = $1 WHERE "id" = $2"#)
    #expect(state.statements.first?.preview.hasPrefix("UPDATE") == true)
    #expect(state.requiresPassword == false)
  }

  @Test("safeRead: the edit confirmation requires the Safe Mode password")
  func safeReadRequiresPassword() {
    let viewModel = makeViewModel(
      config: ConnectionConfig(protectionLevel: .none, safeMode: .safeRead))
    edit(viewModel)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.requiresPassword)
    #expect(viewModel.queryConfirmationState.pendingInlineEdit != nil)
  }

  @Test("Cancelling the confirmation drops the pending edit")
  func cancelDropsPendingEdit() {
    let viewModel = makeViewModel(
      config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    edit(viewModel)
    viewModel.cancelPendingQuery()
    #expect(viewModel.queryConfirmationState.pendingInlineEdit == nil)
    #expect(viewModel.queryConfirmationState.showDialog == false)
  }

  @Test("A later cell confirmation replaces a stale pending edit")
  func laterConfirmationReplacesStaleEdit() {
    let viewModel = makeViewModel(
      config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    edit(viewModel)
    // Dialog dismissed without Cancel (only showDialog is reset by the binding)
    viewModel.queryConfirmationState.showDialog = false
    _ = viewModel.presentConfirmationIfNeeded(for: "DELETE FROM users WHERE id = 1", cellId: cellId)
    #expect(viewModel.queryConfirmationState.pendingInlineEdit == nil)
  }
}
