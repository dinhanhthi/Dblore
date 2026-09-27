// ResultGridHeaderTests.swift
// The two-line grid header: column name (key icon for the primary key of an editable result,
// search highlight on a column-name match) over the column type, hidden by hideColumnTypes.
// The header is 54 pt with types (6 pt of room below the type line), 28 pt without, and keeps
// the sort indicator.

import AppKit
import Testing

@testable import SQLNotebook

@Suite("Result grid - header")
@MainActor
struct ResultGridHeaderTests {
  private let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "user_name", type: "text"),
  ]

  private func result(editable: Bool) -> CellResult {
    CellResult(
      columns: columns, rows: [[.int(1), .string("a")]], rowCount: 1, tableName: "users",
      primaryKeyColumns: ["id"],
      editTarget: editable
        ? EditTarget(qualifiedName: "public.users", oid: 1, primaryKeyColumns: ["id"]) : nil)
  }

  private func columnNameMatch(_ name: String) -> SearchMatch {
    SearchMatch(
      cellId: UUID(), matchType: .columnName(name), matchRange: name.startIndex..<name.endIndex,
      contextText: name, lineNumber: nil)
  }

  private func content(
    _ column: Int, result: CellResult, hideColumnTypes: Bool = false, searchQuery: String = "",
    currentMatch: SearchMatch? = nil
  ) -> ResultGridHeaderContent {
    ResultGridCoordinator.headerContent(
      for: columns[column], result: result, hideColumnTypes: hideColumnTypes,
      searchQuery: searchQuery, caseSensitive: false, currentMatch: currentMatch)
  }

  @Test("Header is 54 pt with column types and 28 pt without")
  func headerHeight() {
    #expect(ResultGridView.headerHeight(hideColumnTypes: false) == 54)
    #expect(ResultGridView.headerHeight(hideColumnTypes: true) == 28)
  }

  @Test("The coordinator sets the header view height from the flag")
  func headerViewHeight() {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    let result = result(editable: false)
    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    #expect(tableView.headerView?.frame.height == 54)
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true, hideColumnTypes: true)
    #expect(tableView.headerView?.frame.height == 28)
  }

  @Test("Header cells draw over the full header height, not AppKit's one-line strip")
  func fullHeightFrame() {
    let frame = ResultGridHeaderCell.fullHeightFrame(
      NSRect(x: 40, y: 6, width: 120, height: 36), in: NSRect(x: 0, y: 0, width: 600, height: 54))
    #expect(frame == NSRect(x: 40, y: 0, width: 120, height: 54))
  }

  @Test("Line 1 is the column name, line 2 the type, nil when types are hidden")
  func titleAndType() {
    let shown = content(1, result: result(editable: false))
    #expect(shown.title == "user_name")
    #expect(shown.type == "text")
    #expect(content(1, result: result(editable: false), hideColumnTypes: true).type == nil)
  }

  @Test("The key icon marks primary-key columns of an editable result only")
  func primaryKey() {
    #expect(content(0, result: result(editable: true)).isPrimaryKey)
    #expect(!content(1, result: result(editable: true)).isPrimaryKey)
    // A result read from a file keeps primaryKeyColumns but has no live edit target
    #expect(!content(0, result: result(editable: false)).isPrimaryKey)
  }

  @Test("A column name containing the search query is highlighted, case-insensitively")
  func highlighted() {
    let result = result(editable: false)
    #expect(content(1, result: result, searchQuery: "NAME").isHighlighted)
    #expect(!content(0, result: result, searchQuery: "NAME").isHighlighted)
    #expect(!content(1, result: result).isHighlighted)
  }

  @Test("The current column-name match is the current match of that column only")
  func currentMatch() {
    let result = result(editable: false)
    let match = columnNameMatch("user_name")
    #expect(content(1, result: result, searchQuery: "name", currentMatch: match).isCurrentMatch)
    #expect(!content(0, result: result, searchQuery: "name", currentMatch: match).isCurrentMatch)
    let dataMatch = SearchMatch(
      cellId: UUID(), matchType: .tableData(rowIndex: 0, columnName: "user_name"),
      matchRange: "a".startIndex..<"a".endIndex, contextText: "a", lineNumber: nil)
    #expect(
      !content(1, result: result, searchQuery: "a", currentMatch: dataMatch).isCurrentMatch)
  }

  @Test("Each column gets a header cell with its content after an update")
  func headerCells() {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(
      tableView, result: result(editable: true), sortColumn: nil, ascending: true,
      searchQuery: "name", caseSensitive: false, currentMatch: columnNameMatch("user_name"))
    let cells = tableView.tableColumns.map { $0.headerCell as? ResultGridHeaderCell }
    #expect(tableView.tableColumns.map(\.title) == ["id", "user_name"])
    #expect(cells[0]?.content.isPrimaryKey == true)
    #expect(cells[1]?.content.isCurrentMatch == true)
    #expect(cells[1]?.content.type == "text")

    coordinator.update(
      tableView, result: result(editable: true), sortColumn: nil, ascending: true,
      hideColumnTypes: true)
    #expect(cells[1]?.content.type == nil)
    #expect(cells[1]?.content.isHighlighted == false)
  }

  @Test("The header cell draws the sort indicator of the sorted column in its direction")
  func sortIndicator() {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    let result = result(editable: false)
    coordinator.update(tableView, result: result, sortColumn: "user_name", ascending: false)
    let id = tableView.tableColumns[0]
    let name = tableView.tableColumns[1]
    #expect(ResultGridHeaderCell.sortAscending(for: name, in: tableView) == false)
    #expect(ResultGridHeaderCell.sortAscending(for: id, in: tableView) == nil)

    coordinator.update(tableView, result: result, sortColumn: "id", ascending: true)
    #expect(ResultGridHeaderCell.sortAscending(for: id, in: tableView) == true)
    #expect(ResultGridHeaderCell.sortAscending(for: name, in: tableView) == nil)
  }

  @Test("A copied header cell keeps its content (AppKit copies header cells)")
  func copyKeepsContent() {
    let cell = ResultGridHeaderCell(textCell: "user_name")
    cell.content = content(1, result: result(editable: false), searchQuery: "name")
    for _ in 0..<100 {
      let copy = cell.copy() as? ResultGridHeaderCell
      #expect(copy?.content == cell.content)
    }
    #expect(cell.content.title == "user_name")
  }
}
