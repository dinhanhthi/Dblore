// ResultGridEditTests.swift
// Inline edit in the NSTableView grid: a commit delivers the displayed (sorted) row to the view
// model's handleCellValueEdit path; results that canEdit refuses (no PK, read-only) never edit.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Result grid - inline edit")
@MainActor
struct ResultGridEditTests {
  private let cellId = UUID()

  private static let usersID = TableRef.postgresql(oid: 16_400)

  /// `name` is the name of row id 1, displayed first once sorted by id
  private func makeResult(
    primaryKeyColumns: [String], name: CellValue = .string("a"),
    nameColumn: ColumnInfo = ColumnInfo(
      name: "name", type: "text", origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 2))
  ) -> CellResult {
    CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 1)),
        nameColumn,
      ],
      rows: [[.int(3), .string("c")], [.int(1), name], [.int(2), .string("b")]],
      rowCount: 3, sourceQuery: "SELECT * FROM users", tableName: "public.users",
      primaryKeyColumns: primaryKeyColumns,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: primaryKeyColumns))
  }

  private func makeViewModel(result: CellResult, config: ConnectionConfig) -> NotebookViewModel {
    let notebook = DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: cellId, cellType: .sql, content: "SELECT * FROM users", executionCount: 1,
          result: result)
      ],
      metadata: NotebookMetadata(createdAt: Date(), modifiedAt: Date(), title: "Grid edit"),
      connectionConfig: config, settings: NotebookSettings())
    return NotebookViewModel(notebook: notebook)
  }

  /// Grid sorted by id ascending, editable per the view model's canEdit, committing to the VM
  private func makeGrid(
    _ viewModel: NotebookViewModel, result: CellResult
  ) -> (ResultGridCoordinator, NSTableView) {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.isEditable = viewModel.canEdit(result)
    coordinator.onCommitEdit = { [cellId] row, column, newValue in
      viewModel.handleGridCellEdit(
        row: row, column: column, newValue: newValue, result: result, cellId: cellId,
        connectionManager: DatabaseConnectionManager())
    }
    coordinator.update(tableView, result: result, sortColumn: "id", ascending: true)
    return (coordinator, tableView)
  }

  @Test("A commit on a sorted grid reaches handleCellValueEdit with the displayed row's key")
  func commitReachesHandleCellValueEdit() {
    let result = makeResult(primaryKeyColumns: ["id"])
    let viewModel = makeViewModel(
      result: result, config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    let (coordinator, _) = makeGrid(viewModel, result: result)
    #expect(coordinator.isEditable)

    // Unchanged text sends nothing
    coordinator.commitEdit(row: 0, column: 1, newValue: "a")
    #expect(viewModel.rightSidebarContent == nil)

    // Displayed row 0 is id 1 (result.rows[1]), not result.rows[0] (id 3)
    coordinator.commitEdit(row: 0, column: 1, newValue: "new")
    guard case .cellInfo(_, _, let value, _, let rowData, _, _) = viewModel.rightSidebarContent
    else {
      Issue.record("the edit did not reach handleCellValueEdit")
      return
    }
    #expect(value == .string("new"))
    #expect(rowData?["id"] == .int(1))
  }

  @Test(
    "No primary key or a read-only connection: the grid refuses to edit",
    arguments: [
      (["id"], ConnectionProtectionLevel.readOnly), ([String](), ConnectionProtectionLevel.none),
    ])
  func notEditable(primaryKeyColumns: [String], protectionLevel: ConnectionProtectionLevel) {
    let result = makeResult(primaryKeyColumns: primaryKeyColumns)
    let viewModel = makeViewModel(
      result: result,
      config: ConnectionConfig(protectionLevel: protectionLevel, safeMode: .alertRead))
    let (coordinator, tableView) = makeGrid(viewModel, result: result)
    #expect(coordinator.isEditable == false)
    #expect(coordinator.beginEditing(tableView, row: 0, column: 1) == false)

    var delivered = false
    coordinator.onCommitEdit = { _, _, _ in delivered = true }
    coordinator.commitEdit(row: 0, column: 1, newValue: "new")
    #expect(delivered == false)
  }

  /// The inline field took a value of any size: an 18 MB geometry hung the main thread there
  @Test(
    "A 1 MB text or any binary value opens the sidebar Cell Value editor; a small value edits inline",
    arguments: [
      (CellValue.string(String(repeating: "x", count: 1 << 20)), true),
      (CellValue.data(Data(count: 16)), true), (CellValue.string("small"), false),
    ])
  func inlineOrSidebar(value: CellValue, opensSidebar: Bool) {
    let result = makeResult(primaryKeyColumns: ["id"], name: value)
    let viewModel = makeViewModel(
      result: result, config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    let (coordinator, tableView) = makeGrid(viewModel, result: result)
    var detailsColumn: Int?
    coordinator.onShowCellDetails = { _, _, column, _ in detailsColumn = column }

    coordinator.beginEditing(tableView, row: 0, column: 1)

    #expect(coordinator.isEditing == !opensSidebar)
    #expect(detailsColumn == (opensSidebar ? 1 : nil))
  }

  /// Regression A5: the editor opens on the displayed timestamp text, and closing it unchanged
  /// sends nothing, fraction included
  @Test("A timestamp edits as its display text and an unchanged close sends nothing")
  func timestampEditsAsDisplayText() {
    let at = Date(timeIntervalSince1970: Double(1_792_065_600_123_456) / 1_000_000)
    for wallClock in [true, false] {
      let result = makeResult(
        primaryKeyColumns: ["id"], name: .date(at),
        nameColumn: ColumnInfo(
          name: "at", type: "timestamp",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 2), wallClock: wallClock))
      let viewModel = makeViewModel(
        result: result, config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
      let (coordinator, tableView) = makeGrid(viewModel, result: result)
      let text = CellValue.date(at).displayString(wallClock: wallClock)

      coordinator.beginEditing(tableView, row: 0, column: 1)
      let field = tableView.tableColumns.firstIndex { $0.identifier.rawValue == "1" }.flatMap {
        (tableView.view(atColumn: $0, row: 0, makeIfNecessary: false) as? NSTableCellView)?
          .textField
      }
      #expect(field?.stringValue == text)

      coordinator.commitEdit(row: 0, column: 1, newValue: text)
      #expect(viewModel.rightSidebarContent == nil)
    }
  }

  @Test("A loaded data-viewer row goes through the cell edit and is not staged")
  func dataViewerLoadedRowIsNotStaged() {
    let result = makeResult(primaryKeyColumns: ["id"])
    let viewModel = makeViewModel(
      result: result, config: ConnectionConfig(protectionLevel: .none, safeMode: .alertRead))
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = result

    viewModel.handleGridCellEdit(
      row: [.int(1), .string("a")], column: 1, newValue: "neo", result: result, cellId: nil,
      connectionManager: DatabaseConnectionManager())

    #expect(viewModel.dataViewer?.changeSet == nil)
    guard case .cellInfo(_, _, let value, _, let rowData, _, _) = viewModel.rightSidebarContent
    else {
      Issue.record("the edit did not reach handleCellValueEdit")
      return
    }
    #expect(value == .string("neo"))
    #expect(rowData?["id"] == .int(1))
  }

  // MARK: - Column source labels

  @Test("A join's columns are labelled from their tables; an expression or a view has none")
  func columnSourceLabels() async {
    let users = TableRef.postgresql(oid: 100)
    let orders = TableRef.postgresql(oid: 200)
    let joined = [
      ColumnInfo(name: "id", type: "int4", origin: ColumnOrigin(tableID: users, columnOrdinal: 1)),
      ColumnInfo(
        name: "total", type: "numeric", origin: ColumnOrigin(tableID: orders, columnOrdinal: 3)),
      ColumnInfo(
        name: "n", type: "int8",
        origin: ColumnOrigin(tableID: .postgresql(oid: 0), columnOrdinal: 0)
      ),
    ]
    let names: [UInt32: ColumnMaskRule.Origin] = [
      100: ColumnMaskRule.Origin(schema: "public", table: "users"),
      200: ColumnMaskRule.Origin(schema: "sales", table: "orders"),
    ]
    let tables: [String: EditTable] = [
      "users": EditTable(
        oid: 100, attributeNames: [1: "id", 2: "name"], primaryKeyColumns: ["id"],
        schema: "public", name: "users"),
      "orders": EditTable(
        oid: 200, attributeNames: [1: "id", 3: "total"], primaryKeyColumns: ["id"],
        schema: "sales", name: "orders"),
    ]
    let postgres = await NotebookViewModel.columnSourceLabels(
      joined, databaseType: .postgresql, cachedTable: { _ in nil },
      origins: { columns in
        columns.map { $0.tableOrigin?.tableID.postgresOID.flatMap { names[$0] } }
      },
      fetchTable: { _, origin in tables[origin.table] })
    #expect(postgres == [0: "public.users.id", 1: "sales.orders.total"])

    // MySQL: only the sources the BASE TABLE check confirms; a view's columns stay unlabelled
    let mysql = [
      ColumnInfo(
        name: "email", type: "varchar",
        sourceName: ColumnSourceName(schema: "shop", table: "customers", column: "email")),
      ColumnInfo(
        name: "total", type: "decimal",
        sourceName: ColumnSourceName(schema: "shop", table: "order_totals", column: "total")),
      ColumnInfo(name: "n", type: "bigint"),
    ]
    let confirmed = await NotebookViewModel.columnSourceLabels(
      mysql, databaseType: .mysql, cachedTable: { _ in nil },
      origins: { columns in
        columns.map { column in
          column.sourceName.flatMap {
            $0.table == "customers"
              ? ColumnMaskRule.Origin(schema: $0.schema, table: $0.table) : nil
          }
        }
      },
      fetchTable: nil)
    #expect(confirmed == [0: "shop.customers.email"])
  }

  /// Set once the awaited label task returned
  @MainActor private final class Flag {
    var isSet = false
  }

  @Test("An editor join run labels both tables' columns after it is shown, not the expression")
  func editorRunLabelsJoinColumns() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-source-labels-\(UUID().uuidString).sqlite")
    let config = ConnectionConfig(
      databaseType: .sqlite, database: url.path, username: "", protectionLevel: .none,
      safeMode: .silent, protectedMode: false)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    defer {
      for suffix in ["", "-journal", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    for statement in [
      "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)",
      "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, total REAL)",
      "INSERT INTO users VALUES (1, 'a')",
      "INSERT INTO orders VALUES (10, 1, 2.5)",
    ] {
      _ = try await manager.executeInternal(statement)
    }
    var notebook = DbloreNotebook.newDocument()
    notebook.connectionConfig = config
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.connectionManager = manager

    await viewModel.executeEditorQuery(
      "SELECT u.name, o.total, o.total * 2 AS doubled FROM users u JOIN orders o ON o.user_id = u.id"
    )
    // Bounded: a label task that never ends fails here instead of hanging the suite
    let done = Flag()
    let waiter = Task { @MainActor in
      await viewModel.awaitColumnSourceLabels()
      done.isSet = true
    }
    let deadline = ContinuousClock.now + .seconds(45)
    while !done.isSet, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(done.isSet, "the label task did not finish")
    let shown = try #require(viewModel.editorResult)
    #expect(shown.rows.count == 1)
    #expect(shown.columnSourceLabels == [0: "main.users.name", 1: "main.orders.total"])
    waiter.cancel()
    await manager.disconnect()
  }
}
