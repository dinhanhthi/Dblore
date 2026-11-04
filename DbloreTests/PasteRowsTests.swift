// PasteRowsTests.swift
// Paste Rows: clipboard text staged as typed inserts in one undo step, or nothing at all.

import Foundation
import Testing

@testable import Dblore

@Suite("Paste rows")
@MainActor
struct PasteRowsTests {
  @Test("TSV with a header stages typed inserts in one undo step")
  func tsvHeaderStagesTypedInserts() async {
    let viewModel = makeViewModel()
    let reason = await paste(viewModel, "NAME\tage\tactive\nann\t31\ttrue\nbob\t42\tfalse\n")

    #expect(reason == nil)
    #expect(
      inserts(viewModel) == [
        ["name": .string("ann"), "age": .int(31), "active": .bool(true)],
        ["name": .string("bob"), "age": .int(42), "active": .bool(false)],
      ])
    #expect(viewModel.undoManager.undoActionName == "Paste Rows")
    viewModel.undoCellChange()
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(!viewModel.undoManager.canUndo)
  }

  @Test("CSV without a header maps by position from the first column")
  func csvWithoutHeaderMapsByPosition() async {
    let viewModel = makeViewModel()
    let reason = await paste(viewModel, "7,ann,31,true\n8,\"doe, bob\",42,false")

    #expect(reason == nil)
    #expect(
      inserts(viewModel) == [
        ["id": .int(7), "name": .string("ann"), "age": .int(31), "active": .bool(true)],
        ["id": .int(8), "name": .string("doe, bob"), "age": .int(42), "active": .bool(false)],
      ])
  }

  /// Regression A5: a naive timestamp pastes as the wall clock its text shows, not as the Mac's
  /// local time (the read runs detached, so it sees the Mac's own zone, not a task's)
  @Test("A naive timestamp pastes as its wall clock")
  func naiveTimestampPastesAsWallClock() async {
    let viewModel = makeViewModel()
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "INTEGER",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 1)),
        ColumnInfo(
          name: "at", type: "TIMESTAMP",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 2), wallClock: true),
      ],
      rows: [[.int(1), .null]], rowCount: 1, editTarget: viewModel.editorResult?.editTarget)
    let reason = await paste(viewModel, "id\tat\n7\t2026-10-15 12:00:00.5\n")

    #expect(reason == nil)
    #expect(
      inserts(viewModel) == [
        ["id": .int(7), "at": .date(Date(timeIntervalSince1970: 1_792_065_600.5))]
      ])
  }

  @Test("Without a header, fields follow the grid's on-screen column order")
  func positionalFieldsFollowOnScreenOrder() async {
    let viewModel = makeViewModel()
    // The grid shows age before name (a column moved), as Copy Rows then writes them
    let reason = await paste(viewModel, "7,31,ann,true", columnOrder: [0, 2, 1, 3])

    #expect(reason == nil)
    #expect(
      inserts(viewModel) == [
        ["id": .int(7), "name": .string("ann"), "age": .int(31), "active": .bool(true)]
      ])
  }

  @Test(
    "A column-count mismatch stages nothing",
    arguments: zip(
      ["1,ann,31,true,extra", "1,ann\n2"],
      [
        "The pasted rows have 5 values, the table has 4 columns",
        "The pasted rows do not all have the same number of values",
      ]))
  func columnCountMismatchStagesNothing(text: String, message: String) async {
    let viewModel = makeViewModel()
    let reason = await paste(viewModel, text)

    #expect(reason == message)
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(viewModel.undoManager.undoActionName != "Paste Rows")
  }

  @Test("An invalid typed value names its row and column and stages nothing")
  func invalidValueStagesNothing() async {
    let viewModel = makeViewModel()
    let reason = await paste(viewModel, "name,age\nann,31\nbob,old")

    #expect(reason == "Row 2, column \"age\": Invalid integer format")
    #expect(viewModel.dataViewer?.changeSet == nil)
    #expect(viewModel.undoManager.undoActionName != "Paste Rows")
  }

  @Test("An unquoted NULL is SQL NULL while a quoted \"NULL\" is text")
  func unquotedNullIsSQLNull() async {
    let viewModel = makeViewModel()
    let reason = await paste(viewModel, "name,age\n\"NULL\",NULL\nNULL,5")

    #expect(reason == nil)
    #expect(
      inserts(viewModel) == [
        ["name": .string("NULL"), "age": .null],
        ["name": .null, "age": .int(5)],
      ])
  }

  @Test("An empty field is the empty string on a text column and NULL otherwise")
  func emptyFieldRule() async {
    let viewModel = makeViewModel()
    let reason = await paste(viewModel, "name\tage\tactive\n\t\t")

    #expect(reason == nil)
    #expect(inserts(viewModel) == [["name": .string(""), "age": .null, "active": .null]])
  }

  @Test("More than 10,000 rows is refused, 10,000 rows are staged")
  func rowCap() async {
    let viewModel = makeViewModel()
    let refused = await paste(
      viewModel,
      "name\n" + Array(repeating: "ann", count: 10_001).joined(separator: "\n"))

    #expect(refused == PastedRows.tooManyRows)
    #expect(viewModel.dataViewer?.changeSet == nil)

    let reason = await paste(
      viewModel,
      "name\n" + Array(repeating: "ann", count: 10_000).joined(separator: "\n"))
    #expect(reason == nil)
    #expect(viewModel.dataViewer?.changeSet?.inserts.count == 10_000)
  }

  @Test("Refused on a read-only connection")
  func refusedOnReadOnly() async {
    let viewModel = makeViewModel(protectionLevel: .readOnly)
    let reason = await paste(viewModel, "name\nann")

    #expect(reason == NotebookViewModel.connectionIsReadOnly)
    #expect(viewModel.dataViewer?.changeSet == nil)
  }

  @Test("Refused on a tab without row staging", arguments: [DatabaseType.duckdb, .mongodb])
  func refusedWithoutRowStaging(databaseType: DatabaseType) async {
    let viewModel = makeViewModel(databaseType: databaseType)
    let reason = await paste(viewModel, "name\nann")

    #expect(reason == "Pasting rows is not available for \(databaseType.displayName) connections")
    #expect(viewModel.dataViewer?.changeSet == nil)
  }

  private static let usersID = TableRef.postgresql(oid: 1)

  private func inserts(_ viewModel: NotebookViewModel) -> [[String: CellValue]] {
    viewModel.dataViewer?.changeSet?.inserts.map(\.values) ?? []
  }

  private func makeViewModel(
    databaseType: DatabaseType = .postgresql, protectionLevel: ConnectionProtectionLevel = .none
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.undoManager.groupsByEvent = false
    viewModel.toastPresenter = { _, _ in }
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      databaseType: databaseType, host: "localhost", port: 5432, database: "app",
      username: "ana", password: "x", protectionLevel: protectionLevel, safeMode: .silent,
      protectedMode: false)
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"], databaseType: databaseType)
    let columns = [("id", "INTEGER"), ("name", "TEXT"), ("age", "INTEGER"), ("active", "BOOLEAN")]
    viewModel.editorResult = CellResult(
      columns: columns.enumerated().map { index, column in
        ColumnInfo(
          name: column.0, type: column.1,
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: index + 1))
      },
      rows: [[.int(1), .string("old"), .int(30), .bool(true)]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
        connectionEpoch: 0, updateOnly: true))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }

  /// Stages inside an undo group, as one event does (`groupsByEvent` is off)
  private func paste(
    _ viewModel: NotebookViewModel, _ text: String, columnOrder: [Int]? = nil
  ) async -> String? {
    viewModel.undoManager.beginUndoGrouping()
    let reason = await viewModel.stagePastedRows(text, columnOrder: columnOrder)
    viewModel.undoManager.endUndoGrouping()
    return reason
  }
}
