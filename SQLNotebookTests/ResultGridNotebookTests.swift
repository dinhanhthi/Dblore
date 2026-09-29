// ResultGridNotebookTests.swift
// The result grid inside a notebook cell: fixed height (at most 15 rows plus the header),
// vertical scroll handed to the notebook list at the grid's edges, header sort, details button
// to the sidebar and search highlights.

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

  @Test(
    "Height is min(rows, 15) rows plus the header and the legacy horizontal scroller",
    arguments: [false, true], [NSScroller.Style.overlay, .legacy])
  func height(hideColumnTypes: Bool, scrollerStyle: NSScroller.Style) {
    // A legacy (always shown) horizontal scroller sits inside the grid height; overlay floats
    let scroller =
      scrollerStyle == .legacy
      ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    let header = ResultGridView.headerHeight(hideColumnTypes: hideColumnTypes) + scroller
    func height(_ rowCount: Int) -> CGFloat {
      ResultGridView.height(
        rowCount: rowCount, hideColumnTypes: hideColumnTypes, scrollerStyle: scrollerStyle)
    }
    #expect(height(0) == header)
    #expect(height(1) == ResultGridView.rowHeight + header)
    #expect(height(10) == 10 * ResultGridView.rowHeight + header)
    #expect(height(100) == 15 * ResultGridView.rowHeight + header)
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

  @Test("Show details delivers the displayed (sorted) row and the result column")
  func showCellDetails() {
    let (coordinator, _) = makeGrid(sortColumn: "id")
    var shown: (row: [CellValue], originalRow: Int, column: Int)?
    coordinator.onShowCellDetails = { shown = ($0, $1, $2) }
    coordinator.showCellDetails(row: 0, column: 1)
    #expect(shown?.row == [.int(1), .string("ab")])
    #expect(shown?.originalRow == 1)
    #expect(shown?.column == 1)
    coordinator.showCellDetails(row: -1, column: 0)  // outside a row
    #expect(shown?.row == [.int(1), .string("ab")])
  }

  @Test("A click only selects and a double click only edits: neither shows the details")
  func clickDoesNotShowDetails() {
    let tableView = ResultGridView.makeTableView(coordinator: ResultGridCoordinator())
    #expect(tableView.action == nil)
    #expect(tableView.doubleAction == #selector(ResultGridTableView.editClickedCell(_:)))
  }

  @Test("The details button sits at the trailing edge of the visible part of the cell")
  func detailsButtonFrame() {
    let size = ResultGridTableView.detailsButtonSize
    let cell = NSRect(x: 100, y: 26, width: 150, height: 26)
    let frame = ResultGridTableView.detailsButtonFrame(
      cellRect: cell, visibleRect: NSRect(x: 0, y: 0, width: 1000, height: 500))
    #expect(
      frame == NSRect(x: 250 - Spacing.xs - size, y: 39 - size / 2, width: size, height: size))
    // Cell cut by the right edge of the visible area: the button stays visible
    let clipped = ResultGridTableView.detailsButtonFrame(
      cellRect: cell, visibleRect: NSRect(x: 0, y: 0, width: 200, height: 500))
    #expect(clipped?.maxX == 200 - Spacing.xs)
    // Cell scrolled out of view
    #expect(
      ResultGridTableView.detailsButtonFrame(
        cellRect: cell, visibleRect: NSRect(x: 300, y: 0, width: 200, height: 500)) == nil)
  }

  @Test("Hovering a cell shows the details button; its click shows that cell's details")
  func detailsButtonHover() {
    let coordinator = ResultGridCoordinator()
    let tableView = ResultGridView.makeTableView(coordinator: coordinator)
    coordinator.update(tableView, result: result, sortColumn: "id", ascending: true)
    tableView.frame = NSRect(x: 0, y: 0, width: 400, height: 78)
    tableView.moveColumn(1, toColumn: 2)  // on screen: #, name, id
    var shown: (originalRow: Int, column: Int)?
    coordinator.onShowCellDetails = { shown = ($1, $2) }

    // Row 1, second on-screen result column
    tableView.updateDetailsButton(at: NSPoint(x: tableView.rect(ofColumn: 2).midX, y: 30))
    let button = tableView.detailsButton
    #expect(!button.isHidden)
    #expect(
      button.frame
        == ResultGridTableView.detailsButtonFrame(
          cellRect: tableView.frameOfCell(atColumn: 2, row: 1), visibleRect: tableView.visibleRect))
    button.sendAction(button.action, to: button.target)
    // Displayed row 1 of the ascending sort is id 2 (original row 2), column "id" is 0
    #expect(shown?.originalRow == 2)
    #expect(shown?.column == 0)

    tableView.updateDetailsButton(at: NSPoint(x: tableView.rect(ofColumn: 0).midX, y: 30))
    #expect(button.isHidden)  // the "#" column has no details

    tableView.updateDetailsButton(at: NSPoint(x: 10, y: 500))  // below the rows
    #expect(button.isHidden)
  }

  @Test("Search highlights the matching text of a cell, case-insensitively")
  func searchHighlight() {
    let (coordinator, tableView) = makeGrid(searchQuery: "B")
    let view = coordinator.tableView(tableView, viewFor: tableView.tableColumns[2], row: 1)
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
      let view = coordinator.tableView(tableView, viewFor: tableView.tableColumns[2], row: row)
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
