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

    // The old index 1 now draws 3. Empty is a cleared selection; 0 is the same loaded row.
    let selected = tableView.selectedRowIndexes
    #expect(selected == IndexSet(integer: 99))
    if let row = selected.first {
      #expect(coordinator.model?.row(at: row) == [.int(2)])
    }
  }
}
