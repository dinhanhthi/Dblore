// RowStagingViewModelTests.swift
// Data-viewer row staging on NotebookViewModel. No database server: a disconnected
// connection manager only records whether commit reached executeGatedBatch (one keyless
// page reads a temporary SQLite file).

import Foundation
import Testing

@testable import Dblore

@Suite("Row staging view model")
@MainActor
struct RowStagingViewModelTests {
  @Test("No primary key disables staging and names the primary key")
  func noPrimaryKeyDisablesStaging() {
    let viewModel = makeViewModel(primaryKey: [])

    #expect(
      viewModel.rowStagingUnavailableReason?.contains("Table has no primary key") == true)
    #expect(viewModel.stageInsert()?.contains("Table has no primary key") == true)
    #expect(
      viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo"))?
        .contains("Table has no primary key") == true)
    #expect(viewModel.dataViewer?.changeSet == nil)
  }

  @Test("+ Row assigns the next integer when the database cannot be asked")
  func addRowAssignsTheNextInteger() async {
    let viewModel = makeViewModel(primaryKey: ["id"])

    #expect(await viewModel.addStagedRow() == nil)
    #expect(await viewModel.addStagedRow() == nil)

    let preview = viewModel.previewStagedSQL()
    #expect(preview.contains(#""id""#))
    #expect(preview.contains("2"))
    #expect(preview.contains("3"))
    #expect(viewModel.stageEdit(row: 0, column: "id", value: .int(9))?.contains("SQL") == true)
  }

  @Test("+ Row leaves the key empty when the loaded page is not the whole table")
  func addRowSkipsAPartialPage() async {
    let scenarios: [(DataViewerState) -> DataViewerState] = [
      {
        var state = $0
        state.pageSize = 1
        state.totalRows = 5
        return state
      },
      {
        var state = $0
        state.page = 2
        return state
      },
      {
        var state = $0
        state.filter = TableFilter(
          conditions: [FilterCondition(column: "nickname", value: "old")])
        return state
      },
    ]
    for scenario in scenarios {
      let viewModel = makeViewModel(primaryKey: ["id"])
      viewModel.dataViewer = viewModel.dataViewer.map(scenario)

      #expect(await viewModel.addStagedRow() == nil)

      #expect(!viewModel.previewStagedSQL().contains(#""id""#))
    }
  }

  @Test("Commit fills an integer key that + Row did not set")
  func commitFillsAMissingIntegerKey() async {
    let viewModel = makeViewModel(primaryKey: ["id"])
    #expect(viewModel.stageInsert() == nil)
    WorkspaceWindowManager.shared.dismissToast()

    await viewModel.commitStaged()

    let preview = viewModel.previewStagedSQL()
    #expect(preview.contains(#"INSERT INTO public.users ("id")"#))
    #expect(preview.contains("2"))
    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("Not connected")
        == true)
  }

  @Test("A text primary key is not given a number")
  func textPrimaryKeyIsNotNumbered() async {
    let viewModel = makeViewModel(primaryKey: ["nickname"])
    #expect(await viewModel.addStagedRow() == nil)
    #expect(viewModel.previewStagedSQL().contains("DEFAULT VALUES"))
  }

  @Test("A staged insert can set its primary key; an existing row cannot")
  func stagedInsertCanSetPrimaryKey() {
    let viewModel = makeViewModel(primaryKey: ["id"])
    #expect(viewModel.stageInsert() == nil)

    #expect(viewModel.stageEdit(row: 1, column: "id", value: .int(3)) == nil)
    #expect(viewModel.stageEdit(row: 1, column: "nickname", value: .string("chi")) == nil)
    let preview = viewModel.previewStagedSQL()
    #expect(preview.contains(#""id""#))
    #expect(preview.contains("3"))
    #expect(preview.contains("chi"))

    #expect(viewModel.stageEdit(row: 0, column: "id", value: .int(9))?.contains("SQL") == true)
  }

  @Test("A staged edit's preview names the column")
  func stagedEditPreviewNamesTheColumn() {
    let viewModel = makeViewModel(primaryKey: ["id"])

    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    #expect(viewModel.previewStagedSQL().contains("nickname"))
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
  }

  @Test("Setting several cells is one undo step")
  func settingSeveralCellsIsOneUndoStep() {
    let viewModel = makeViewModel(
      primaryKey: ["id"], rows: [[.int(1), .string("old")], [.int(2), .string("older")]])

    #expect(
      viewModel.stageEdits(
        rows: [0, 1], column: "nickname", values: Array(repeating: .value(.string("neo")), count: 2)
      )
        == nil)
    #expect(viewModel.dataViewer?.changeSet?.counts.edits == 2)

    viewModel.undoManager.undo()
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
  }

  @Test("Set Value text takes the cell's type, as a single-cell edit does")
  func setValueTextTakesTheCellType() {
    let viewModel = makeViewModel(
      primaryKey: ["nickname"], rows: [[.int(42), .string("a")], [.int(42), .string("b")]])

    #expect(
      viewModel.stageEdits(
        rows: [0, 1], column: "id", values: Array(repeating: .value(.string("42")), count: 2))
        == nil)
    #expect(viewModel.dataViewer?.changeSet == nil)

    #expect(
      viewModel.stageEdits(rows: [0], column: "id", values: [.value(.string("7"))]) == nil)
    #expect(
      viewModel.dataViewer?.changeSet?.edits[RowChangeSet.RowKey(values: [.string("a")])]?["id"]
        == .int(7))
  }

  @Test("Discard clears the change set")
  func discardClearsTheSet() {
    let viewModel = makeViewModel(primaryKey: ["id"])
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)

    viewModel.discardStaged()

    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(viewModel.previewStagedSQL().isEmpty)
  }

  @Test("Safe Mode holds the batch until confirm, then the connection is called")
  func safeModeConfirmCallsTheConnection() async {
    let viewModel = makeViewModel(primaryKey: ["id"], epoch: 1, safeMode: .alertRead)
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    WorkspaceWindowManager.shared.dismissToast()

    await viewModel.commitStaged()

    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(WorkspaceWindowManager.shared.toastState.currentToast == nil)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)

    await viewModel.executePendingQuery()

    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("connection changed")
        == true)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
  }

  @Test("A connection failure keeps the change set")
  func connectionFailureKeepsTheSet() async {
    let viewModel = makeViewModel(primaryKey: ["id"], epoch: 0, safeMode: .silent)
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    WorkspaceWindowManager.shared.dismissToast()

    await viewModel.commitStaged()

    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(
      WorkspaceWindowManager.shared.toastState.currentToast?.message.contains("Not connected")
        == true)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
  }

  @Test("A result whose columns name another table cannot be staged")
  func otherTableIdentityCannotBeStaged() {
    let viewModel = makeViewModel(
      primaryKey: ["id"], columnTableID: .postgresql(oid: 99))
    #expect(viewModel.rowStagingUnavailableReason == NotebookViewModel.tableHasNoPrimaryKey)
    #expect(viewModel.dataViewer?.changeSet == nil)
  }

  @Test("A page reload during the commit's key lookup keeps the staged set")
  func reloadDuringKeyLookupKeepsTheSet() async {
    let viewModel = makeViewModel(primaryKey: ["id"])
    #expect(viewModel.stageInsert() == nil)
    let loaded = viewModel.editorResult
    // The commit runs until the key lookup awaits the connection manager; the page then reloads.
    let commit = Task { await viewModel.commitStaged() }
    await Task.yield()
    viewModel.editorResult = nil

    await commit.value

    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
    viewModel.editorResult = loaded
    #expect(viewModel.hasPendingStagedChanges)
  }

  @Test("A table change during the commit's key lookup discards with a warning")
  func tableChangeDuringKeyLookupWarns() async {
    let viewModel = makeViewModel(primaryKey: ["id"])
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    #expect(viewModel.stageInsert() == nil)
    var changed = viewModel.editorResult
    changed?.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
      connectionEpoch: 5, updateOnly: true)
    // The table changes at the key lookup's await point, not after a scheduler-dependent yield.
    viewModel.keyLookupCheckpointForTesting = { [weak viewModel, changed] in
      viewModel?.editorResult = changed
    }

    await viewModel.commitStaged()

    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(toasts.contains { $0.contains("table changed") })
  }

  @Test("Two identical keyless rows: deleting one leaves the other editable, drawn apart")
  func keylessRowsHaveTheirOwnKeys() throws {
    let viewModel = makeKeylessViewModel()
    let result = try #require(viewModel.editorResult)
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }

    #expect(viewModel.stageDelete(rows: [0]) == nil)
    #expect(viewModel.stageEdit(row: 1, column: "nickname", value: .string("neo")) == nil)
    #expect(
      viewModel.stageEdit(row: 0, column: "nickname", value: .string("x"))
        == RowChangeError.deletedRow.message)
    viewModel.handleStagedGridCellEdit(row: 0, column: 1, newValue: "x", result: result)
    #expect(toasts == [RowChangeError.deletedRow.message])
    let set = try #require(viewModel.dataViewer?.changeSet)
    #expect(set.deletes.count == 1)
    #expect(set.edits.count == 1)
    let preview = viewModel.previewStagedSQL()
    #expect(preview.contains("(0,1)"))
    #expect(preview.contains("(0,2)"))

    var grid = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    grid.apply(changeSet: set)
    #expect(grid.rowState(at: 0) == .deleted)
    #expect(grid.rowState(at: 1) == .edited)
  }

  @Test("Reload asks to resolve staged keyless edits first; a keyed page re-reads and keeps them")
  func reloadBannerResolvesKeylessEditsFirst() async {
    let viewModel = makeKeylessViewModel()
    #expect(viewModel.stageEdit(row: 1, column: "nickname", value: .string("neo")) == nil)
    let staged = viewModel.dataViewer?.changeSet

    let reload = Task { await viewModel.reloadStaleDataViewer() }
    for _ in 0..<1000 where !viewModel.stagedLeavePromptVisible { await Task.yield() }
    #expect(viewModel.stagedLeavePromptVisible)
    #expect(viewModel.editorResult?.error == nil)
    viewModel.resolveStagedLeavePrompt(.cancel)
    await reload.value
    // Cancel: nothing read, the staged edit stays on the page it was made on
    #expect(viewModel.editorResult?.error == nil)
    #expect(viewModel.dataViewer?.changeSet == staged)

    let keyed = makeViewModel(primaryKey: ["id"])
    #expect(keyed.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    let keyedStaged = keyed.dataViewer?.changeSet
    await keyed.reloadStaleDataViewer()
    #expect(!keyed.stagedLeavePromptVisible)
    // Read again (this manager is not connected: the page shows its error)
    #expect(keyed.editorResult?.error != nil)
    #expect(keyed.dataViewer?.changeSet == keyedStaged)
  }

  @Test("The Rollback reload never asks: a keyless page with staged edits is only marked stale")
  func rollbackReloadMarksKeylessPageStale() async {
    let viewModel = makeKeylessViewModel()
    #expect(viewModel.stageEdit(row: 1, column: "nickname", value: .string("neo")) == nil)
    let staged = viewModel.dataViewer?.changeSet

    await viewModel.reloadPageAfterRollback()

    #expect(!viewModel.stagedLeavePromptVisible)
    #expect(viewModel.editorResult?.error == nil)
    #expect(viewModel.dataViewer?.changeSet == staged)
    #expect(viewModel.dataViewer?.isStale == true)

    let keyed = makeViewModel(primaryKey: ["id"])
    #expect(keyed.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    let keyedStaged = keyed.dataViewer?.changeSet
    await keyed.reloadPageAfterRollback()
    #expect(!keyed.stagedLeavePromptVisible)
    #expect(keyed.editorResult?.error != nil)
    #expect(keyed.dataViewer?.changeSet == keyedStaged)
    #expect(keyed.dataViewer?.isStale == false)
  }

  @Test("A keyless sidebar save names the row the sidebar shows; a grid of older rows is refused")
  func keylessSidebarSaveNamesTheShownRow() throws {
    let viewModel = makeKeylessViewModel()
    viewModel.notebook.connectionConfig?.applyCommitStyle(.confirm)
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    let result = try #require(viewModel.editorResult)
    viewModel.showGridCellInSidebar(
      row: result.rows[0], originalRow: 0, column: 1, result: result, cellId: nil)

    // A grid edit of row 1 shows row 1 in the sidebar; Cancel puts row 0 back with its row
    viewModel.handleStagedGridCellEdit(row: 1, column: 1, newValue: "neo", result: result)
    #expect(viewModel.pendingInlineEdit?.statement.values.contains("(0,2)") == true)
    #expect(viewModel.cellDetailRow == 1)
    viewModel.cancelPendingQuery()
    #expect(viewModel.cellDetailRow == 0)
    viewModel.handleStagedGridCellEdit(row: 1, column: 1, newValue: "neo", result: result)

    // The sidebar's own save of the cell it shows names row 1, never row 0
    guard
      case .cellInfo(let name, let type, let value, let table, let rowData, let keys, let id) =
        viewModel.rightSidebarContent
    else {
      Issue.record("The sidebar shows no cell")
      return
    }
    viewModel.handleCellValueEdit(
      columnName: name, columnType: type, newValue: "trinity", originalValue: value,
      tableName: table, rowData: rowData, primaryKeyColumns: keys, cellId: id,
      connectionManager: viewModel.connectionManager, wallClock: false)
    let values = viewModel.pendingInlineEdit?.statement.values ?? []
    #expect(values.contains("(0,2)"))
    #expect(!values.contains("(0,1)"))
    #expect(toasts.isEmpty)

    // The grid's rows are older than the live page: its row index is refused
    viewModel.editorResult?.dataRevision += 1
    viewModel.handleStagedGridCellEdit(row: 0, column: 1, newValue: "x", result: result)
    #expect(toasts == [NotebookViewModel.notEditableMessage])
    #expect(viewModel.pendingInlineEdit?.statement.values.contains("(0,1)") == false)
  }

  @Test("A keyless SQLite page shows SQL without locators and its re-read refreshes the sidebar")
  func keylessPageSQLAndSidebarRefresh() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-keyless-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    try await manager.connect(config: config)
    do {
      for statement in ["CREATE TABLE notes (body TEXT)", "INSERT INTO notes VALUES ('a'), ('b')"] {
        _ = try await manager.executeInternal(statement)
      }
      var notebook = DbloreNotebook.newDocument()
      notebook.connectionConfig = config
      let viewModel = NotebookViewModel(notebook: notebook)
      viewModel.viewMode = .editor
      viewModel.connectionManager = manager
      var state = DataViewerState(schema: "main", name: "notes", orderColumns: [])
      state.databaseType = .sqlite
      viewModel.dataViewer = state
      await viewModel.loadDataViewerPage()
      await viewModel.awaitResultTargets()
      await viewModel.awaitResultTargets()

      // Located and editable, while the SQL shown and pinned has no locator column
      let result = try #require(viewModel.editorResult)
      let target = try #require(result.editTarget)
      #expect(target.rowLocator != nil)
      #expect(result.truncation?.rowLocator == target.rowLocator)
      #expect(!result.typesPending)
      #expect(viewModel.canEdit(result))
      let shown = try #require(result.sourceQuery)
      #expect(!shown.contains("dblore_"))

      // The re-read after an edit under a staged batch: the sidebar cell shows its row's value
      viewModel.showGridCellInSidebar(
        row: result.rows[0], originalRow: 0, column: 0, result: result, cellId: nil)
      _ = try await manager.executeInternal("UPDATE notes SET body = 'c' WHERE body = 'a'")
      await viewModel.refreshDataViewerRows(
        target: target, connectionManager: manager, done: "Cell updated")
      if case .cellInfo(_, _, let value, _, _, _, _) = viewModel.rightSidebarContent {
        #expect(value == .string("c"))
      } else {
        Issue.record("The sidebar shows no cell")
      }
      #expect(viewModel.cellDetailRow == 0)

      // A locator read without its page state is never run as a plain query
      await viewModel.executeEditorQuery(
        #"SELECT rowid AS "dblore_rowid", * FROM notes"#, source: .internal)
      #expect(
        viewModel.editorResult?.error
          == NotebookViewModel.LazyPageError.unexpectedShape.errorDescription)
    } catch {
      await manager.disconnect()
      throw error
    }
    await manager.disconnect()
  }

  private static let usersID = TableRef.postgresql(oid: 1)

  /// Two identical rows of a keyless table, each located by its own tableoid, ctid and xmin
  /// (the page's side locator table)
  private func makeKeylessViewModel() -> NotebookViewModel {
    let viewModel = makeViewModel(
      primaryKey: [], rows: [[.int(1), .string("same")], [.int(1), .string("same")]])
    viewModel.editorResult?.editTarget = EditTarget(
      qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: [],
      updateOnly: true, rowLocator: .pgLocator)
    viewModel.editorResult?.truncation = DataViewerState.Truncation(
      rowLocator: .pgLocator,
      locators: ["(0,1)", "(0,2)"].map {
        RowChangeSet.RowKey(locator: RowLocatorValues(texts: ["16384", $0, "700"]))
      })
    viewModel.dataViewer?.rowLocator = .pgLocator
    return viewModel
  }

  private func makeViewModel(
    primaryKey: [String], epoch: UInt64 = 0, safeMode: SafeMode = .silent,
    columnTableID: TableRef = RowStagingViewModelTests.usersID,
    rows: [[CellValue]] = [[.int(1), .string("old")]]
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: safeMode, protectedMode: false)
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4",
          origin: ColumnOrigin(tableID: columnTableID, columnOrdinal: 1)),
        ColumnInfo(
          name: "nickname", type: "text",
          origin: ColumnOrigin(tableID: columnTableID, columnOrdinal: 2)),
      ],
      rows: rows,
      rowCount: rows.count,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: primaryKey,
        connectionEpoch: epoch, updateOnly: true))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }
}
