// ColumnValueFilterTests.swift
// A join without aliases can return two columns with the same name. The category filter
// is per result column index, so hiding a value in one column leaves rows that only
// match that value in the other column on screen. An empty filter does not drop rows
// and does not rewrite the loaded result's row count.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Column value filter")
@MainActor
struct ColumnValueFilterTests {
  @Test("Same-named columns filter by index; an empty filter keeps every loaded row")
  func duplicateNamesFilterByColumnIndex() {
    let columns = [
      ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "id", type: "int4"),
    ]
    let rows: [[CellValue]] = [
      [.int(1), .int(9)],
      [.int(2), .int(1)],
      [.int(1), .int(1)],
      [.int(4), .int(4)],
    ]
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    let hiddenKey = ColumnValueFilter.categoryKey(for: .int(1))
    let filter = ColumnValueFilter().settingHidden([hiddenKey], for: 1)

    let filtered = ResultGridModel(
      result: result, sortColumn: nil, ascending: true, valueFilter: filter)
    // Row 0 matches the hidden value only in column 0, so it stays. Rows whose column 1
    // is 1 drop. The loaded result's row count is not replaced by the displayed count.
    #expect(filtered.rowCount == 2)
    #expect(filtered.row(at: 0) == [.int(1), .int(9)])
    #expect(filtered.row(at: 1) == [.int(4), .int(4)])
    #expect(result.rowCount == rows.count)
    #expect(result.rows.count == rows.count)

    let shown = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(shown.rowCount == rows.count)
    #expect(result.rowCount == rows.count)
  }

  @Test("Values the grid draws the same are one category")
  func sameGridTextIsOneCategory() {
    let columns = [ColumnInfo(name: "n", type: "float8")]
    let rows: [[CellValue]] = [[.double(1.001)], [.double(1.004)], [.double(2.5)]]
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    let collapsed = ColumnValueFilter.categoryKey(for: .double(1.001))

    #expect(collapsed == ColumnValueFilter.categoryKey(for: .double(1.004)))
    #expect(CellValue.double(1.001).displayString == CellValue.double(1.004).displayString)
    let categories = ColumnValueFilter.categories(in: result, columnIndex: 0)
    #expect(categories.count == 2)
    #expect(categories.first { $0.key == collapsed }?.count == 2)

    let filtered = ResultGridModel(
      result: result, sortColumn: nil, ascending: true,
      valueFilter: ColumnValueFilter().settingHidden([collapsed], for: 0))
    #expect(filtered.rowCount == 1)
    #expect(filtered.row(at: 0) == [.double(2.5)])
    #expect(result.rowCount == rows.count)

    let stem = String(repeating: "a", count: 60)
    let jsonKey = ColumnValueFilter.categoryKey(for: .json(stem + "xxx"))
    #expect(jsonKey == ColumnValueFilter.categoryKey(for: .json(stem + "yyyy")))
    let jsonRows: [[CellValue]] = [[.json(stem + "xxx")], [.json(stem + "yyyy")], [.json("other")]]
    let json = CellResult(
      columns: [ColumnInfo(name: "j", type: "json")], rows: jsonRows, rowCount: jsonRows.count)
    let hiddenJSON = ResultGridModel(
      result: json, sortColumn: nil, ascending: true,
      valueFilter: ColumnValueFilter().settingHidden([jsonKey], for: 0))
    #expect(hiddenJSON.rowCount == 1)
    #expect(hiddenJSON.row(at: 0) == [.json("other")])

    let start = Date(timeIntervalSinceReferenceDate: 100)
    let sameSecond = start.addingTimeInterval(0.2)
    #expect(CellValue.date(start).displayString == CellValue.date(sameSecond).displayString)
    #expect(
      ColumnValueFilter.categoryKey(for: .date(start))
        == ColumnValueFilter.categoryKey(for: .date(sameSecond)))
  }

  @Test("Bytea categories are the bytes, not a process-local hash")
  func byteaIdentityIsTheBytes() {
    let left = Data([0x00, 0x01])
    let right = Data([0x00, 0x02])
    #expect(left.count == right.count)
    let leftKey = ColumnValueFilter.categoryKey(for: .data(left))
    let rightKey = ColumnValueFilter.categoryKey(for: .data(right))
    #expect(leftKey == ColumnValueFilter.categoryKey(for: .data(Data(left))))
    #expect(leftKey != rightKey)
    #expect(leftKey.contains(left.base64EncodedString()))
    var hasher = Hasher()
    hasher.combine(left)
    #expect(leftKey != "x:\(left.count):\(hasher.finalize())")

    let rows: [[CellValue]] = [[.data(left)], [.data(Data(left))], [.data(right)]]
    let result = CellResult(
      columns: [ColumnInfo(name: "b", type: "bytea")], rows: rows, rowCount: rows.count)
    let categories = ColumnValueFilter.categories(in: result, columnIndex: 0)
    #expect(categories.count == 2)
    #expect(categories.first { $0.key == leftKey }?.count == 2)
    // Same byte count still draws "<2 bytes>"; the bytes keep them distinct categories.
    #expect(categories.allSatisfy { $0.label == "<2 bytes>" })

    let filtered = ResultGridModel(
      result: result, sortColumn: nil, ascending: true,
      valueFilter: ColumnValueFilter().settingHidden([leftKey], for: 0))
    #expect(filtered.rowCount == 1)
    #expect(filtered.row(at: 0) == [.data(right)])
    #expect(result.rowCount == rows.count)
  }

  @Test("A hidden original row has no displayed row")
  func hiddenOriginalRowHasNoDisplayedRow() {
    let rows: [[CellValue]] = [[.int(1)], [.int(2)], [.int(3)]]
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")], rows: rows, rowCount: rows.count)
    let hidden = ColumnValueFilter.categoryKey(for: .int(2))
    let model = ResultGridModel(
      result: result, sortColumn: nil, ascending: true,
      valueFilter: ColumnValueFilter().settingHidden([hidden], for: 0))
    #expect(model.displayedRow(forOriginalRow: 1) == nil)
    #expect(model.displayedRow(forOriginalRow: 0) == 0)
    #expect(model.displayedRow(forOriginalRow: 2) == 1)
    #expect(result.rowCount == rows.count)
    #expect(model.rowCount == 2)
  }

  @Test("Filtering does not leave the selection on a different loaded row")
  func filterDoesNotKeepAStaleDisplayedIndex() {
    let rows: [[CellValue]] = [[.int(1)], [.int(2)], [.int(3)]]
    let result = CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")], rows: rows, rowCount: rows.count)
    let coordinator = ResultGridCoordinator()
    let tableView = ResultGridTableView()
    tableView.coordinator = coordinator
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView?.addSubview(tableView)
    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    // Displayed row 1 is the loaded value 2. Hiding 1 shifts that value to index 0.
    tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    #expect(tableView.selectedRowIndexes == IndexSet(integer: 1))

    let hidden = ColumnValueFilter.categoryKey(for: .int(1))
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true,
      valueFilter: ColumnValueFilter().settingHidden([hidden], for: 0))

    // Value 2 moved from displayed index 1 to 0. Index 1 would now be the loaded value 3.
    #expect(tableView.selectedRowIndexes == IndexSet(integer: 0))
    #expect(coordinator.model?.row(at: 0) == [.int(2)])
  }

  @Test("The checkbox list stops before one toggle per loaded row")
  func listedCategoriesAreCapped() {
    let categories = (0..<ColumnValueFilter.listedCategoryLimit + 40).map { index in
      ColumnCategory(key: "k\(index)", label: "v\(index)", count: 1)
    }
    let listed = ColumnValueFilter.listedCategories(categories)
    #expect(listed.count == ColumnValueFilter.listedCategoryLimit)
    #expect(listed.map(\.key) == categories.prefix(ColumnValueFilter.listedCategoryLimit).map(\.key))
  }

  @Test("A hidden search match moves to the next row the grid can show")
  func hiddenSearchMatchMovesToNextShownRow() {
    let columns = [
      ColumnInfo(name: "status", type: "text"), ColumnInfo(name: "name", type: "text"),
    ]
    let rows: [[CellValue]] = [
      [.string("hidden"), .string("find")],
      [.string("shown"), .string("other")],
      [.string("shown"), .string("find")],
    ]
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    let filter = ColumnValueFilter().settingHidden(
      [ColumnValueFilter.categoryKey(for: .string("hidden"))], for: 0)
    let model = ResultGridModel(
      result: result, sortColumn: nil, ascending: true, valueFilter: filter)
    #expect(model.displayedRow(forOriginalRow: 0) == nil)

    let cellId = UUID()
    let hidden = dataMatch(cellId: cellId, row: 0, column: "name", text: "find")
    let later = dataMatch(cellId: cellId, row: 2, column: "name", text: "find")
    #expect(model.shownSearchMatch(hidden, matches: [hidden]) == nil)
    #expect(model.shownSearchMatch(hidden, matches: [hidden, later])?.id == later.id)

    let coordinator = ResultGridCoordinator()
    let tableView = FilterScrollTableView()
    coordinator.update(
      tableView, result: result, sortColumn: nil, ascending: true, searchQuery: "find",
      currentMatch: hidden, valueFilter: filter, searchMatches: [hidden, later])
    #expect(model.displayedRow(forOriginalRow: 2) == 1)
    #expect(tableView.scrolledRows == [1])

    let viewModel = NotebookViewModel()
    viewModel.searchState.matches = [hidden, later]
    viewModel.searchState.currentMatchIndex = 0
    let shown = gridSearchMatchOnScreen(
      hidden, result: result, sortColumn: nil, ascending: true, valueFilter: filter,
      viewModel: viewModel)
    #expect(shown?.id == later.id)
    #expect(viewModel.searchState.currentMatchIndex == 1)
    #expect(viewModel.searchState.currentMatch?.id == later.id)
  }

  @Test("A hit handed to another cell is assigned there, not searched again")
  func hiddenSearchMatchHandsOffWithoutSearchingAgain() {
    let columns = [ColumnInfo(name: "name", type: "text")]
    let rows: [[CellValue]] = [[.string("find")], [.string("other")]]
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    let filter = ColumnValueFilter().settingHidden(
      [ColumnValueFilter.categoryKey(for: .string("find"))], for: 0)
    let hitA = dataMatch(cellId: UUID(), row: 0, column: "name", text: "find")
    let hitB = dataMatch(cellId: UUID(), row: 0, column: "name", text: "find")
    let viewModel = NotebookViewModel()
    viewModel.searchState.matches = [hitA, hitB]
    viewModel.searchState.currentMatchIndex = 0

    let shown = gridSearchMatchOnScreen(
      hitA, result: result, sortColumn: nil, ascending: true, valueFilter: filter,
      viewModel: viewModel)
    #expect(shown == nil)
    #expect(viewModel.searchState.currentMatchIndex == 1)

    // The receiving cell draws the hit only when its own filter still shows that row.
    // It does not call gridSearchMatchOnScreen again.
    #expect(
      assignedSearchMatch(
        hitB, cellId: hitB.cellId, result: result, sortColumn: nil, ascending: true,
        valueFilter: filter) == nil)
    #expect(
      assignedSearchMatch(
        hitB, cellId: hitB.cellId, result: result, sortColumn: nil, ascending: true,
        valueFilter: ColumnValueFilter())?.id == hitB.id)
  }
}

private func dataMatch(cellId: UUID, row: Int, column: String, text: String) -> SearchMatch {
  SearchMatch(
    cellId: cellId, matchType: .tableData(rowIndex: row, columnName: column),
    matchRange: text.startIndex..<text.endIndex, contextText: text, lineNumber: nil)
}

private final class FilterScrollTableView: NSTableView {
  var scrolledRows: [Int] = []

  override func scrollRowToVisible(_ row: Int) {
    scrolledRows.append(row)
  }
}
