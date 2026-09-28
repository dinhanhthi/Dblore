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

  @Test(
    "A header click sorts ascending, then descending, then clears; another column starts ascending",
    arguments: [
      // (current column, current ascending, clicked, next column, next ascending)
      (String?.none, true, "id", String?("id"), true),
      ("id", true, "id", "id", false),
      ("id", false, "id", nil, true),
      ("id", false, "name", "name", true),
      ("id", true, "name", "name", true),
    ])
  func nextSort(
    column: String?, ascending: Bool, clicked: String, nextColumn: String?, nextAscending: Bool
  ) {
    let next = ResultGridCoordinator.nextSort(
      current: (column, ascending), clicked: clicked)
    #expect(next.column == nextColumn)
    #expect(next.ascending == nextAscending)
  }

  @Test("The third header click clears the sort indicator and reports no sort once")
  func thirdClickClearsSort() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id", ascending: false)
    var reported: [(column: String?, ascending: Bool)] = []
    coordinator.onSortChange = { reported.append(($0, $1)) }
    // A header click on the descending column flips it to ascending
    tableView.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
    #expect(tableView.sortDescriptors.isEmpty)
    #expect(reported.count == 1)
    #expect(reported.first?.column == nil)
    #expect(reported.first?.ascending == true)
  }

  @Test("Numbers are right-aligned, other values left-aligned")
  func numericAlignment() {
    let grid = makeGrid(sortColumn: nil)
    #expect(cell(grid, row: 0, column: 0)?.alignment == .right)
    #expect(cell(grid, row: 0, column: 1)?.alignment == .left)
    #expect(cell(grid, row: 2, column: 1)?.alignment == .left)
    #expect(ResultGridCoordinator.alignment(for: .double(1.5)) == .right)
    #expect(ResultGridCoordinator.alignment(for: .null) == .left)
  }

  @Test("Copy follows the on-screen column order after a column is moved")
  func tsvCopyColumnOrder() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    tableView.moveColumn(1, toColumn: 0)
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    #expect(coordinator.selectionTSV(tableView) == "a\t1\nc\t3")
  }

  @Test("Update reloads only when the result or the sort changes")
  func reloadOnlyOnChange() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    #expect(!coordinator.update(tableView, result: result, sortColumn: "id", ascending: true))
    #expect(coordinator.update(tableView, result: result, sortColumn: "id", ascending: false))
  }

  @Test("Hidden columns hide their table column and keep the result column identifiers")
  func hiddenColumns() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true, hiddenColumns: ["name"])
    #expect(tableView.tableColumns.map(\.isHidden) == [false, true])
    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["0", "1"])

    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    #expect(tableView.tableColumns.map(\.isHidden) == [false, false])
    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["0", "1"])
  }

  @Test("A hidden column follows its identifier after a column move")
  func hiddenColumnAfterMove() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    tableView.moveColumn(1, toColumn: 0)
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true, hiddenColumns: ["name"])
    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["1", "0"])
    #expect(tableView.tableColumns.map(\.isHidden) == [true, false])
  }

  @Test("Odd displayed rows get the design-system alternate row view, even rows don't")
  func alternateRows() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    let rowViews = (0..<3).map {
      coordinator.tableView(tableView, rowViewForRow: $0) as? ResultGridRowView
    }
    #expect(rowViews.map { $0?.isAlternate } == [false, true, false])
  }

  @Test("The grid table leaves alternating rows to the row views")
  func noSystemAlternatingRows() {
    let tableView = ResultGridView.makeTableView(coordinator: ResultGridCoordinator())
    #expect(!tableView.usesAlternatingRowBackgroundColors)
  }
}
