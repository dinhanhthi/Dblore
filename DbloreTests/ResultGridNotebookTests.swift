// ResultGridNotebookTests.swift
// The result grid inside a notebook cell: fixed height (at most 15 rows plus the header),
// vertical scroll handed to the notebook list at the grid's edges, header sort, details button
// to the sidebar and search highlights.

import AppKit
import Testing

@testable import Dblore

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
    #expect(button.isHidden)  // no onShowRowDetails: nothing on "#"

    tableView.updateDetailsButton(at: NSPoint(x: 10, y: 500))  // below the rows
    #expect(button.isHidden)
  }

  @Test("With row details, hovering \"#\" shows the button; its click shows that row's details")
  func rowDetailsButtonHover() {
    let coordinator = ResultGridCoordinator()
    let tableView = ResultGridView.makeTableView(coordinator: coordinator)
    coordinator.update(tableView, result: result, sortColumn: "id", ascending: true)
    tableView.frame = NSRect(x: 0, y: 0, width: 400, height: 78)
    var shownRow: (row: [CellValue], originalRow: Int)?
    var shownCell: (originalRow: Int, column: Int)?
    coordinator.onShowRowDetails = { shownRow = ($0, $1) }
    coordinator.onShowCellDetails = { shownCell = ($1, $2) }

    // Row 1 of the "#" column
    tableView.updateDetailsButton(at: NSPoint(x: tableView.rect(ofColumn: 0).midX, y: 30))
    let button = tableView.detailsButton
    #expect(!button.isHidden)
    #expect(button.toolTip == "Show row details")
    #expect(
      button.frame
        == ResultGridTableView.detailsButtonFrame(
          cellRect: tableView.frameOfCell(atColumn: 0, row: 1), visibleRect: tableView.visibleRect))
    button.sendAction(button.action, to: button.target)
    // Displayed row 1 of the ascending sort is id 2 (original row 2)
    #expect(shownRow?.row == [.int(2), .null])
    #expect(shownRow?.originalRow == 2)
    #expect(shownCell == nil)
    #expect(tableView.selectedRowIndexes == [1])

    // A data cell keeps the cell details
    tableView.updateDetailsButton(at: NSPoint(x: tableView.rect(ofColumn: 1).midX, y: 30))
    #expect(button.toolTip == "Show details")
    button.sendAction(button.action, to: button.target)
    #expect(shownCell?.originalRow == 2)
    #expect(shownCell?.column == 0)
  }

  @Test("Right-clicking \"#\" selects the row and opens the gutter menu; a data cell its menu")
  func gutterContextMenu() throws {
    let coordinator = ResultGridCoordinator()
    let tableView = ResultGridView.makeTableView(coordinator: coordinator)
    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    tableView.frame = NSRect(x: 0, y: 0, width: 400, height: 78)
    func rightClick(column: Int) throws -> NSMenu? {
      let point = NSPoint(x: tableView.rect(ofColumn: column).midX, y: 30)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: tableView.convert(point, to: nil), modifierFlags: [],
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      return tableView.menu(for: event)
    }

    // Without row details "#" has no menu and leaves the selection
    #expect(try rightClick(column: 0) == nil)
    #expect(tableView.selectedRowIndexes.isEmpty)

    coordinator.onShowRowDetails = { _, _ in }
    let gutter = try rightClick(column: 0)
    #expect(gutter?.items.map(\.title).contains("Show Row Details") == true)
    #expect(gutter?.items.map(\.title).contains("See More") == false)
    #expect(tableView.selectedRowIndexes == [1])

    let cell = try rightClick(column: 1)
    #expect(cell?.items.map(\.title).contains("See More") == true)
  }

  @Test("With row details, \"#\" is never narrower than the details button needs")
  func rowNumberWidthFitsDetailsButton() {
    let minimum = ResultGridTableView.detailsButtonSize + 2 * Spacing.xs
    func width(fontSize: CGFloat, showsRowDetails: Bool) -> CGFloat {
      ResultGridCoordinator.rowNumberWidth(
        rowCount: 3, showsRowDetails: showsRowDetails,
        font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular))
    }
    // Smallest row-number font the settings reach (9pt)
    let smallest = AppSettings.resultRowNumberFontSize(
      for: CGFloat(AppSettings.fontSizeRange.lowerBound))
    #expect(width(fontSize: smallest, showsRowDetails: true) >= minimum)
    // Digits narrower than the button: the floor applies only with row details
    #expect(width(fontSize: 7, showsRowDetails: false) < minimum)
    #expect(width(fontSize: 7, showsRowDetails: true) == minimum)
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
