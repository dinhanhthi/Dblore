// ResultGridHeaderTests.swift
// The two-line grid header: column name (key icon for the primary key of an editable result,
// search highlight on a column-name match) over the column type, hidden by hideColumnTypes.
// The header is 54 pt with types, 28 pt without, with the same gap above and below the lines,
// and keeps the sort indicator.

import AppKit
import Testing

@testable import Dblore

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
        ? EditTarget(
          qualifiedName: "public.users", tableID: .postgresql(oid: 1), primaryKeyColumns: ["id"])
        : nil)
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

  @Test("Each column gets a header cell with its content after an update")
  func headerCells() {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(
      tableView, result: result(editable: true), sortColumn: nil, ascending: true,
      searchQuery: "name", caseSensitive: false, currentMatch: columnNameMatch("user_name"))
    let cells = tableView.tableColumns.dropFirst().map { $0.headerCell as? ResultGridHeaderCell }
    #expect(tableView.tableColumns.map(\.title) == ["#", "id", "user_name"])
    #expect(cells[0]?.content.isPrimaryKey == true)
    #expect(cells[1]?.content.isCurrentMatch == true)
    #expect(cells[1]?.content.type == "text")

    coordinator.update(
      tableView, result: result(editable: true), sortColumn: nil, ascending: true,
      hideColumnTypes: true)
    #expect(cells[1]?.content.type == nil)
    #expect(cells[1]?.content.isHighlighted == false)
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
