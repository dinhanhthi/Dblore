// ResultGridCoordinatorTests.swift
// The NSTableView coordinator reads rows, NULL text and TSV through ResultGridModel: every
// table row is a displayed (sorted) row.

import AppKit
import Testing

@testable import Dblore

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
    // Table column 0 is the "#" row number column
    let view = coordinator.tableView(
      tableView, viewFor: tableView.tableColumns[column + 1], row: row)
    return (view as? NSTableCellView)?.textField
  }

  @Test("Rows and columns map through the coordinator, sorted rows included")
  func rowColumnMapping() {
    let unsorted = makeGrid(sortColumn: nil)
    #expect(unsorted.0.numberOfRows(in: unsorted.1) == 3)
    #expect(unsorted.1.tableColumns.map { $0.title } == ["#", "id", "name"])
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

  @Test("The context menu contains Copy as INSERT and Copy as IN list")
  func contextMenuCopySQL() {
    let (coordinator, _) = makeGrid(sortColumn: nil)
    let titles = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    #expect(titles.contains("Copy Value"))
    #expect(titles.contains("Copy as INSERT"))
    #expect(titles.contains("Copy as IN list"))
  }

  @Test("Copy as IN list is enabled for one column and disabled across more than one")
  func contextMenuINListFollowsColumnSelection() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    tableView.allowsColumnSelection = true
    tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

    // Table column 0 is the "#" gutter; result columns start at 1
    tableView.selectColumnIndexes(IndexSet([1]), byExtendingSelection: false)
    let single = coordinator.contextMenu(row: 0, column: 0)?.items.first {
      $0.title == "Copy as IN list"
    }
    #expect(single?.isEnabled == true)

    tableView.selectColumnIndexes(IndexSet([1, 2]), byExtendingSelection: false)
    let many = coordinator.contextMenu(row: 0, column: 0)?.items.first {
      $0.title == "Copy as IN list"
    }
    #expect(many?.isEnabled == false)
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
    tableView.moveColumn(2, toColumn: 1)
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
    #expect(tableView.tableColumns.map(\.isHidden) == [false, false, true])
    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["rowNumber", "0", "1"])

    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    #expect(tableView.tableColumns.map(\.isHidden) == [false, false, false])
    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["rowNumber", "0", "1"])
  }

  @Test("A hidden column follows its identifier after a column move")
  func hiddenColumnAfterMove() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    tableView.moveColumn(2, toColumn: 1)
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true, hiddenColumns: ["name"])
    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["rowNumber", "1", "0"])
    #expect(tableView.tableColumns.map(\.isHidden) == [false, true, false])
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

  @Test("The \"#\" column numbers the displayed rows, stays first and is not copied")
  func rowNumberColumn() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id", ascending: false)
    let rowNumber = tableView.tableColumns[0]
    #expect(rowNumber.identifier == ResultGridCoordinator.rowNumberIdentifier)
    #expect(rowNumber.sortDescriptorPrototype == nil)
    let numbers = (0..<3).map {
      (coordinator.tableView(tableView, viewFor: rowNumber, row: $0) as? NSTableCellView)?
        .textField?.stringValue
    }
    #expect(numbers == ["1", "2", "3"])
    #expect(!coordinator.tableView(tableView, shouldReorderColumn: 0, toColumn: 1))
    #expect(!coordinator.tableView(tableView, shouldReorderColumn: 2, toColumn: 0))
    #expect(coordinator.tableView(tableView, shouldReorderColumn: 2, toColumn: 1))
    tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
    #expect(coordinator.selectionTSV(tableView) == "3\tc")
  }

  private func fitWidth(
    _ values: [CellValue], headerWidth: CGFloat = 0, minWidth: CGFloat = 40
  ) -> CGFloat {
    let result = CellResult(
      columns: [ColumnInfo(name: "c", type: "text")], rows: values.map { [$0] },
      rowCount: values.count)
    return ResultGridCoordinator.fitWidth(
      column: 0, model: ResultGridModel(result: result, sortColumn: nil, ascending: true),
      headerWidth: headerWidth, minWidth: minWidth)
  }

  @Test("Divider double-click fits short values at the column min width")
  func fitWidthShortValues() {
    #expect(fitWidth([.int(1), .int(7), .int(3)]) == 40)
  }

  @Test("Divider double-click stops a long value at the max fit width")
  func fitWidthLongValue() {
    #expect(
      fitWidth([.string(String(repeating: "x", count: 200))]) == ResultGridCoordinator.maxFitWidth)
  }

  @Test("Divider double-click fits a value between min and max")
  func fitWidthMediumValue() {
    let width = fitWidth([.int(1), .string(String(repeating: "x", count: 15))])
    #expect(width > 40 && width < ResultGridCoordinator.maxFitWidth)
  }

  @Test("A header wider than the cells decides the fit width")
  func fitWidthHeader() {
    #expect(fitWidth([.int(1)], headerWidth: 120) == 120)
  }

  @Test("An empty result fits the header, never below the min width")
  func fitWidthEmpty() {
    #expect(fitWidth([], headerWidth: 90) == 90)
    #expect(fitWidth([], headerWidth: 10) == 40)
  }

  @Test("Only the first fitRowLimit rows are measured")
  func fitWidthRowLimit() {
    let values =
      Array(repeating: CellValue.int(1), count: ResultGridCoordinator.fitRowLimit)
      + [.string(String(repeating: "x", count: 200))]
    #expect(fitWidth(values) == 40)
  }

  @Test("Divider double-click keeps the \"#\" width and fits a result column to its header")
  func sizeToFitDelegate() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    let rowNumber = tableView.tableColumns[0]
    #expect(coordinator.tableView(tableView, sizeToFitWidthOfColumn: 0) == rowNumber.width)
    let header = tableView.tableColumns[1].headerCell as? ResultGridHeaderCell
    let headerWidth = header?.fittingWidth() ?? 0
    #expect(headerWidth > 0)
    #expect(
      coordinator.tableView(tableView, sizeToFitWidthOfColumn: 1) == max(ceil(headerWidth), 40))
  }

  @Test("New columns fit their content; a sort change or re-run keeps a dragged width")
  func autoFitOnNewColumns() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    let column = tableView.tableColumns[1]
    #expect(column.width == coordinator.tableView(tableView, sizeToFitWidthOfColumn: 1))
    column.width = 250
    coordinator.update(tableView, result: result, sortColumn: "id", ascending: true)
    #expect(column.width == 250)
    let rerun = CellResult(columns: result.columns, rows: result.rows, rowCount: result.rowCount)
    coordinator.update(tableView, result: rerun, sortColumn: "id", ascending: true)
    #expect(column.width == 250)
    let other = CellResult(
      columns: [ColumnInfo(name: "other", type: "text")], rows: [[.string("x")]], rowCount: 1)
    coordinator.update(tableView, result: other, sortColumn: nil, ascending: true)
    #expect(
      tableView.tableColumns[1].width
        == coordinator.tableView(tableView, sizeToFitWidthOfColumn: 1))
  }
}
