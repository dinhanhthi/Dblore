// ResultGridCoordinatorTests.swift
// The NSTableView coordinator reads rows, NULL text and TSV through ResultGridModel: every
// table row is a displayed (sorted) row.

import AppKit
import Testing

@testable import SQLNotebook

@Suite("Result grid coordinator")
@MainActor
struct ResultGridCoordinatorTests {
  private let result = CellResult(
    columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
    rows: [[.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .null]],
    rowCount: 3)

  private func makeGrid(
    sortColumn: String?, ascending: Bool = true
  ) -> (
    ResultGridCoordinator, NSTableView
  ) {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(tableView, result: result, sortColumn: sortColumn, ascending: ascending)
    return (coordinator, tableView)
  }

  private func cell(
    _ grid: (ResultGridCoordinator, NSTableView), row: Int, column: Int
  )
    -> NSTextField?
  {
    let (coordinator, tableView) = grid
    let view = coordinator.tableView(
      tableView, viewFor: tableView.tableColumns[column], row: row)
    return (view as? NSTableCellView)?.textField
  }

  @Test("Rows and columns map through the coordinator, sorted rows included")
  func rowColumnMapping() {
    let unsorted = makeGrid(sortColumn: nil)
    #expect(unsorted.0.numberOfRows(in: unsorted.1) == 3)
    #expect(unsorted.1.tableColumns.map { $0.title } == ["id", "name"])
    #expect(cell(unsorted, row: 0, column: 1)?.stringValue == "c")

    let descending = makeGrid(sortColumn: "id", ascending: false)
    #expect((0..<3).map { cell(descending, row: $0, column: 0)?.stringValue } == ["3", "2", "1"])
    #expect(cell(descending, row: 2, column: 1)?.stringValue == "a")
  }

  @Test("NULL shows as NULL in the dimmed design color")
  func nullRendering() {
    let grid = makeGrid(sortColumn: "id")
    let nullCell = cell(grid, row: 1, column: 1)
    #expect(nullCell?.stringValue == "NULL")
    #expect(nullCell?.textColor == ResultGridCoordinator.nullTextColor)
    #expect(cell(grid, row: 0, column: 1)?.textColor == ResultGridCoordinator.textColor)
    #expect(ResultGridCoordinator.nullTextColor != ResultGridCoordinator.textColor)
  }

  @Test("Copy of a 2x2 selection is the TSV of the selected displayed rows")
  func tsvCopy() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    #expect(coordinator.selectionTSV(tableView) == "1\ta\n3\tc")
  }

  @Test("Update reloads only when the result or the sort changes")
  func reloadOnlyOnChange() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    #expect(!coordinator.update(tableView, result: result, sortColumn: "id", ascending: true))
    #expect(coordinator.update(tableView, result: result, sortColumn: "id", ascending: false))
  }
}
