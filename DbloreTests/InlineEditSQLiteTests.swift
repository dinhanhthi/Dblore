// InlineEditSQLiteTests.swift
// Inline edits sent through the view model to a SQLite file (no server): a binary cell edited as
// base64 stores the decoded bytes, invalid base64 sends nothing, the editor result is re-read
// after an edit (a trigger's change included) unless its statement is not a read, sidebar
// edits not re-read in between bind by the value the sidebar shows, an edit that stores
// nothing shows the stored value in the sidebar again, and an edit retyped after a dialog closed
// without Cancel shows the value being confirmed.

import Foundation
import Testing

@testable import Dblore

@Suite("Inline Edit - SQLite")
@MainActor
struct InlineEditSQLiteTests {
  private static let original = Data([0x01, 0x02])
  private static let edited = Data([0xDE, 0xAD, 0xBE, 0xEF])

  /// An editor tab on `main.items` (row 1 holds `original` in the BLOB `payload`; an AFTER UPDATE
  /// trigger sets `note` to "touched"), its `SELECT id, payload, note FROM items` result shown
  /// with a live edit target. Commit style Confirm:
  /// a sent edit waits in `pendingInlineEdit`. The file is closed and deleted afterwards.
  /// History and Data Rewind are off.
  private func withItems(
    _ body: (
      _ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager, _ toasts: Toasts
    ) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-inline-edit-\(UUID().uuidString).sqlite")
    var config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      protectedMode: false)
    config.applyCommitStyle(.confirm)
    let manager = DatabaseConnectionManager()
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    try await manager.connect(config: config)
    for statement in [
      "CREATE TABLE items (id INTEGER PRIMARY KEY, payload BLOB, note TEXT)",
      """
      CREATE TRIGGER items_touch AFTER UPDATE OF payload ON items
      BEGIN UPDATE items SET note = 'touched' WHERE id = NEW.id; END
      """,
      "INSERT INTO items VALUES (1, x'0102', NULL)",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionState = .connected
    viewModel.connectionManager = manager
    let toasts = Toasts()
    viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
    let suiteName = "InlineEditSQLiteTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = false
    settings.rewindEnabled = false
    viewModel.historySettings = settings
    do {
      await viewModel.executeEditorQuery("SELECT id, payload, note FROM items")
      await viewModel.awaitResultTargets()
      try await body(viewModel, manager, toasts)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  /// Edits `payload` of the first row shown from the Cell Value sidebar with `text`
  private func editPayload(_ viewModel: NotebookViewModel, _ text: String) throws {
    let result = try #require(viewModel.editorResult)
    let target = try #require(result.editTarget)
    viewModel.cellDetailEditTarget = target
    viewModel.handleCellValueEdit(
      columnName: "payload", columnType: "BLOB", newValue: text,
      originalValue: .data(Self.original),
      tableName: result.tableName,
      rowData: CellResult.rowData(columns: result.columns, row: result.rows[0]),
      primaryKeyColumns: result.primaryKeyColumns, cellId: nil,
      connectionManager: viewModel.connectionManager, wallClock: false)
  }

  /// Edits the cell the Cell Value sidebar shows with `text` (nil: Set NULL), passing its value
  /// and row back as the sidebar does
  private func editFromSidebar(_ viewModel: NotebookViewModel, _ text: String?) throws {
    guard
      case .cellInfo(
        let column, let type, let value, let table, let rowData, let keys, let cellId) =
        viewModel.rightSidebarContent
    else {
      Issue.record("The Cell Value sidebar is not shown")
      return
    }
    viewModel.handleCellValueEdit(
      columnName: column, columnType: type, newValue: text, originalValue: value,
      tableName: table, rowData: rowData, primaryKeyColumns: keys, cellId: cellId,
      connectionManager: viewModel.connectionManager, wallClock: false)
  }

  /// Shows `payload` of the first row of the editor result in the Cell Value sidebar
  private func showPayload(_ viewModel: NotebookViewModel) throws {
    let result = try #require(viewModel.editorResult)
    let index = try #require(result.columns.firstIndex { $0.name == "payload" })
    viewModel.cellDetailEditTarget = result.editTarget
    viewModel.rightSidebarContent = .cellInfo(
      columnName: "payload", columnType: result.columns[index].type, value: result.rows[0][index],
      tableName: result.tableName,
      rowData: CellResult.rowData(columns: result.columns, row: result.rows[0]),
      primaryKeyColumns: result.primaryKeyColumns, cellId: nil)
  }

  private func sidebarValue(_ viewModel: NotebookViewModel) -> CellValue? {
    guard case .cellInfo(_, _, let value, _, _, _, _) = viewModel.rightSidebarContent else {
      return nil
    }
    return value
  }

  /// Storage class and hex of `payload` in row `id`
  private func stored(
    _ manager: DatabaseConnectionManager, id: Int
  ) async throws -> [CellValue]? {
    try await manager.executeInternal(
      "SELECT typeof(payload), hex(payload) FROM items WHERE id = \(id)"
    ).rows.first
  }

  private func storedHex(
    _ manager: DatabaseConnectionManager, id: Int = 1
  ) async throws -> CellValue? {
    try await manager.executeInternal("SELECT hex(payload) FROM items WHERE id = \(id)").rows
      .first?.first
  }

  @Test("A base64 edit of a BLOB stores the decoded bytes and shows them")
  func base64EditStoresBytes() async throws {
    try await withItems { viewModel, manager, toasts in
      try editPayload(viewModel, Self.edited.base64EncodedString())
      let edit = try #require(viewModel.pendingInlineEdit)
      #expect(edit.statement.sql.contains("UNHEX("))
      #expect(edit.statement.values.first == "deadbeef")

      await viewModel.executePendingQuery()

      #expect(toasts.messages.isEmpty)
      #expect(try await storedHex(manager) == .string("DEADBEEF"))
      guard case .cellInfo(_, _, let value, _, _, _, _) = viewModel.rightSidebarContent else {
        Issue.record("The Cell Value sidebar is not shown")
        return
      }
      #expect(value == .data(Self.edited))
    }
  }

  @Test("Invalid base64 is refused with a message and nothing is sent")
  func invalidBase64SendsNothing() async throws {
    try await withItems { viewModel, manager, toasts in
      try showPayload(viewModel)
      try editPayload(viewModel, "not base64!")

      #expect(viewModel.pendingInlineEdit == nil)
      #expect(toasts.messages.contains { $0.contains("not valid base64") })
      #expect(sidebarValue(viewModel) == .data(Self.original))
      await viewModel.executePendingQuery()
      #expect(try await storedHex(manager) == .string("0102"))
    }
  }

  @Test("Set NULL on a NOT NULL column fails; the sidebar shows the stored bytes and binds by them")
  func failedEditRestoresSidebar() async throws {
    try await withItems { viewModel, manager, toasts in
      for statement in [
        "CREATE TABLE locked (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)",
        "INSERT INTO locked VALUES (1, x'0102')",
      ] {
        _ = try await manager.executeInternal(statement)
      }
      await viewModel.executeEditorQuery("SELECT id, payload FROM locked")
      await viewModel.awaitResultTargets()
      try showPayload(viewModel)
      let locked = "SELECT typeof(payload), hex(payload) FROM locked WHERE id = 1"

      try editFromSidebar(viewModel, nil)
      #expect(sidebarValue(viewModel) == .null)
      await viewModel.executePendingQuery()
      #expect(toasts.messages.last?.hasPrefix("Failed to update 'payload'") == true)
      #expect(sidebarValue(viewModel) == .data(Self.original))
      #expect(
        try await manager.executeInternal(locked).rows.first == [.string("blob"), .string("0102")])

      // The sidebar shows bytes again: the next text is base64 for them
      try editFromSidebar(viewModel, Self.edited.base64EncodedString())
      await viewModel.executePendingQuery()
      #expect(
        try await manager.executeInternal(locked).rows.first
          == [.string("blob"), .string("DEADBEEF")])
    }
  }

  @Test("The editor result is re-read after an edit and shows the trigger's change")
  func editorResultRefreshesAfterEdit() async throws {
    try await withItems { viewModel, _, toasts in
      try editPayload(viewModel, Self.edited.base64EncodedString())
      await viewModel.executePendingQuery()

      #expect(toasts.messages.isEmpty)
      let result = try #require(viewModel.editorResult)
      #expect(result.error == nil)
      #expect(result.rows.first?[1] == .data(Self.edited))
      #expect(result.rows.first?[2] == .string("touched"))
      #expect(result.editTarget != nil)
      #expect(result.editorNotice == nil)
    }
  }

  @Test("A result of a statement that is not a read is not re-run and asks to run again")
  func nonReadResultIsNotRerun() async throws {
    try await withItems { viewModel, manager, toasts in
      let target = try #require(viewModel.editorResult?.editTarget)
      await viewModel.executeEditorQuery(
        "INSERT INTO items VALUES (2, x'0102', NULL) RETURNING id, payload, note")
      // Only a single-table SELECT gets an edit target: the INSERT's result takes the SELECT's
      // live one, so the edit is sent and only the refresh decides
      viewModel.editorResult?.editTarget = target
      let shown = try #require(viewModel.editorResult)
      #expect(shown.rows.first?.first == .int(2))

      try editPayload(viewModel, Self.edited.base64EncodedString())
      await viewModel.executePendingQuery()

      #expect(toasts.messages.isEmpty)
      #expect(try await storedHex(manager, id: 2) == .string("DEADBEEF"))
      #expect(
        try await manager.executeInternal("SELECT count(*) FROM items").rows.first?.first
          == .int(2))
      let result = try #require(viewModel.editorResult)
      #expect(result.rows == shown.rows)
      #expect(result.staleAfterEdit)
      #expect(result.editorNotice == CellResult.runAgainToRefreshNotice)
    }
  }

  @Test("Sidebar edits not re-read in between, one cancelled, store what the sidebar shows")
  func sidebarEditsWithoutRerunStoreShownValue() async throws {
    try await withItems { viewModel, manager, toasts in
      let target = try #require(viewModel.editorResult?.editTarget)
      // Not a read: the result is never re-run, so the sidebar's row is never refreshed
      await viewModel.executeEditorQuery(
        "INSERT INTO items VALUES (2, x'0102', NULL) RETURNING id, payload, note")
      viewModel.editorResult?.editTarget = target
      let result = try #require(viewModel.editorResult)
      viewModel.cellDetailEditTarget = target
      viewModel.rightSidebarContent = .cellInfo(
        columnName: "payload", columnType: "BLOB", value: .data(Self.original),
        tableName: result.tableName,
        rowData: CellResult.rowData(columns: result.columns, row: result.rows[0]),
        primaryKeyColumns: result.primaryKeyColumns, cellId: nil)

      // Set NULL, then Cancel in the Confirm dialog: nothing sent, the stored value shows again
      try editFromSidebar(viewModel, nil)
      #expect(sidebarValue(viewModel) == .null)
      viewModel.cancelPendingQuery()
      #expect(sidebarValue(viewModel) == .data(Self.original))
      #expect(try await stored(manager, id: 2) == [.string("blob"), .string("0102")])

      try editFromSidebar(viewModel, Self.edited.base64EncodedString())
      await viewModel.executePendingQuery()
      #expect(try await stored(manager, id: 2) == [.string("blob"), .string("DEADBEEF")])
      #expect(sidebarValue(viewModel) == .data(Self.edited))

      try editFromSidebar(viewModel, nil)
      await viewModel.executePendingQuery()
      #expect(try await stored(manager, id: 2) == [.string("null"), .string("")])
      #expect(sidebarValue(viewModel) == .null)

      // The sidebar shows NULL (its row still holds the bytes): the typed text is the value,
      // never decoded as base64
      try editFromSidebar(viewModel, "abcd")
      await viewModel.executePendingQuery()
      #expect(try await stored(manager, id: 2) == [.string("text"), .string("61626364")])
      #expect(sidebarValue(viewModel) == .string("abcd"))

      #expect(toasts.messages.isEmpty)
      #expect(viewModel.editorResult?.staleAfterEdit == true)
    }
  }

  @Test("An edit left armed by a dialog closed without Cancel, then retyped, shows and stores it")
  func retypedEditAfterDismissedDialogShowsEditedValue() async throws {
    try await withItems { viewModel, manager, toasts in
      let target = try #require(viewModel.editorResult?.editTarget)
      // Not a read: the result is never re-run, so only the edit updates the sidebar
      await viewModel.executeEditorQuery(
        "INSERT INTO items VALUES (2, x'0102', NULL) RETURNING id, payload, note")
      viewModel.editorResult?.editTarget = target
      try showPayload(viewModel)
      let text = Self.edited.base64EncodedString()

      // Escape on the Confirm dialog: the edit stays armed, Cancel never runs
      try editFromSidebar(viewModel, text)
      #expect(viewModel.pendingInlineEdit != nil)
      viewModel.queryConfirmationState.showDialog = false

      // Retyped, then cancelled: the sidebar shows the stored value again
      try editFromSidebar(viewModel, text)
      viewModel.cancelPendingQuery()
      #expect(viewModel.pendingInlineEdit == nil)
      #expect(sidebarValue(viewModel) == .data(Self.original))

      // Escaped again, then retyped and confirmed
      try editFromSidebar(viewModel, text)
      viewModel.queryConfirmationState.showDialog = false
      try editFromSidebar(viewModel, text)
      #expect(viewModel.pendingInlineEdit != nil)
      #expect(sidebarValue(viewModel) == .data(Self.edited))

      await viewModel.executePendingQuery()
      #expect(toasts.messages.isEmpty)
      #expect(try await stored(manager, id: 2) == [.string("blob"), .string("DEADBEEF")])
      #expect(sidebarValue(viewModel) == .data(Self.edited))
    }
  }
}

/// Toast messages shown by the view model under test
@MainActor
private final class Toasts {
  var messages: [String] = []
}
