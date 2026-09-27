// ResultGridNotebookTests.swift
// The result grid inside a notebook cell: fixed height (at most 15 rows plus the header),
// vertical scroll handed to the notebook list at the grid's edges, header sort, cell click to
// the sidebar and search highlights.

import AppKit
import Testing

@testable import SQLNotebook

@Suite("Result grid - notebook cell")
@MainActor
struct ResultGridNotebookTests {
  private let result = CellResult(
    columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
    rows: [[.int(3), .string("c")], [.int(1), .string("ab")], [.int(2), .null]],
    rowCount: 3)

  private func makeGrid(
    sortColumn: String? = nil, ascending: Bool = true, searchQuery: String = ""
  ) -> (ResultGridCoordinator, NSTableView) {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending,
      searchQuery: searchQuery, caseSensitive: false)
    return (coordinator, tableView)
  }

  @Test("Height is min(rows, 15) rows plus the header")
  func height() {
    let header = ResultGridView.headerHeight
    #expect(ResultGridView.height(rowCount: 0) == header)
    #expect(ResultGridView.height(rowCount: 10) == 10 * ResultGridView.rowHeight + header)
    #expect(ResultGridView.height(rowCount: 100) == 15 * ResultGridView.rowHeight + header)
  }

  @Test(
    "Vertical scroll goes to the notebook list only when the grid can't scroll that way",
    arguments: [
      // (deltaY, offsetY, maxOffsetY, forwarded); deltaY > 0 scrolls toward the top
      (CGFloat(5), CGFloat(0), CGFloat(0), true),  // content fits
      (5, 0, 100, true),  // at the top, scrolling up
      (-5, 0, 100, false),  // at the top, scrolling down
      (-5, 100, 100, true),  // at the bottom, scrolling down
      (5, 100, 100, false),  // at the bottom, scrolling up
      (5, 50, 100, false),  // middle
    ])
  func scrollForwarding(deltaY: CGFloat, offsetY: CGFloat, maxOffsetY: CGFloat, forwarded: Bool) {
    #expect(
      ResultGridScrollView.shouldForward(deltaY: deltaY, offsetY: offsetY, maxOffsetY: maxOffsetY)
        == forwarded)
  }

  @Test("A header sort click reports the column and direction; the input sort shows in the header")
  func sortCallback() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id", ascending: true)
    #expect(tableView.sortDescriptors.first?.key == "id")
    var sort: (column: String?, ascending: Bool)?
    coordinator.onSortChange = { sort = ($0, $1) }
    tableView.sortDescriptors = [NSSortDescriptor(key: "id", ascending: false)]
    #expect(sort?.column == "id")
    #expect(sort?.ascending == false)
  }

  @Test("A cell click delivers the displayed (sorted) row and the result column")
  func cellClick() {
    let (coordinator, _) = makeGrid(sortColumn: "id")
    var clicked: (row: [CellValue], column: Int)?
    coordinator.onCellClick = { clicked = ($0, $1) }
    coordinator.cellClicked(row: 0, column: 1)
    #expect(clicked?.row == [.int(1), .string("ab")])
    #expect(clicked?.column == 1)
    coordinator.cellClicked(row: -1, column: 0)  // click outside a row
    #expect(clicked?.row == [.int(1), .string("ab")])
  }

  @Test("Search highlights the matching text of a cell, case-insensitively")
  func searchHighlight() {
    let (coordinator, tableView) = makeGrid(searchQuery: "B")
    let view = coordinator.tableView(tableView, viewFor: tableView.tableColumns[1], row: 1)
    let text = (view as? NSTableCellView)?.textField?.attributedStringValue
    #expect(text?.string == "ab")
    #expect(text?.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)
    #expect(text?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
  }

  @Test("The current search match scrolls to its displayed row and uses the current-match color")
  func currentMatch() {
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
      rows: (0..<30).map { [.int($0), .string("row\($0)")] },
      rowCount: 30)
    // Original row 20 is displayed at row 9 once sorted by id descending
    let match = SearchMatch(
      cellId: UUID(), matchType: .tableData(rowIndex: 20, columnName: "name"),
      matchRange: "row20".startIndex..<"row20".endIndex, contextText: "row20", lineNumber: nil)
    let coordinator = ResultGridCoordinator()
    let tableView = ScrollRecordingTableView()
    coordinator.update(
      tableView, result: result, sortColumn: "id", ascending: false, searchQuery: "row",
      caseSensitive: false, currentMatch: match)
    #expect(tableView.scrolledRows == [9])

    func background(row: Int) -> Any? {
      let view = coordinator.tableView(tableView, viewFor: tableView.tableColumns[1], row: row)
      return (view as? NSTableCellView)?.textField?.attributedStringValue
        .attribute(.backgroundColor, at: 0, effectiveRange: nil)
    }
    #expect(background(row: 9) as? NSColor == ResultGridCoordinator.currentMatchColor)
    #expect(background(row: 8) as? NSColor != ResultGridCoordinator.currentMatchColor)
    #expect(background(row: 8) != nil)
  }
}

/// Records the rows the coordinator asks to scroll to
private final class ScrollRecordingTableView: NSTableView {
  var scrolledRows: [Int] = []

  override func scrollRowToVisible(_ row: Int) {
    scrolledRows.append(row)
  }
}
