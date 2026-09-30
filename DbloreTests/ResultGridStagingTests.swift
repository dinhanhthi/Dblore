// ResultGridStagingTests.swift
// Staged inserts, deletes, and cell edits over the result grid's loaded rows.

import AppKit
import SwiftUI
import Testing

@testable import Dblore

@Suite("Result grid staging")
@MainActor
struct ResultGridStagingTests {
  private let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text"),
  ]
  private let rows: [[CellValue]] = [
    [.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .null],
  ]

  private var target: EditTarget {
    EditTarget(
      qualifiedName: "public.items", oid: 42, primaryKeyColumns: ["id"],
      generation: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
  }

  private func model(
    rows: [[CellValue]]? = nil, sortColumn: String? = nil, ascending: Bool = true
  ) -> ResultGridModel {
    let values = rows ?? self.rows
    return ResultGridModel(
      result: CellResult(columns: columns, rows: values, rowCount: values.count),
      sortColumn: sortColumn, ascending: ascending)
  }

  @Test("Staged inserts are appended after the loaded rows")
  func insertsAppendedAfterLoadedRows() {
    var grid = model(sortColumn: "id", ascending: true)
    var set = RowChangeSet(target: target)
    set.stageInsert(values: ["id": .int(0), "name": .string("new")])

    let dirty = grid.apply(changeSet: set)

    #expect(grid.rowCount == 4)
    #expect(grid.value(row: 0, column: 0) == .int(1))
    #expect(grid.value(row: 1, column: 0) == .int(2))
    #expect(grid.value(row: 2, column: 0) == .int(3))
    #expect(grid.rowState(at: 0) == .normal)
    #expect(grid.rowState(at: 3) == .inserted)
    #expect(grid.value(row: 3, column: 0) == .int(0))
    #expect(grid.value(row: 3, column: 1) == .string("new"))
    #expect(grid.displayText(row: 3, column: 1) == "new")
    #expect(dirty == IndexSet(integer: 3))
    #expect(grid.changedRows == IndexSet(integer: 3))
  }

  @Test("A deleted row stays visible and is marked deleted")
  func deletedRowStaysVisible() {
    var grid = model(sortColumn: "id", ascending: true)
    var set = RowChangeSet(target: target)
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(1)]))

    grid.apply(changeSet: set)

    #expect(grid.rowCount == 3)
    #expect(grid.rowState(at: 0) == .deleted)
    #expect(grid.value(row: 0, column: 0) == .int(1))
    #expect(grid.value(row: 0, column: 1) == .string("a"))
    #expect(grid.rowState(at: 1) == .normal)
    #expect(grid.rowState(at: 2) == .normal)
    #expect(grid.changedRows == IndexSet(integer: 0))
  }

  @Test("An edited cell shows the staged value")
  func editedCellShowsStagedValue() throws {
    var grid = model(sortColumn: "id", ascending: true)
    #expect(grid.displayText(row: 2, column: 1) == "c")

    var set = RowChangeSet(target: target)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(3)]), column: "name", value: .string("z"),
      original: .string("c"))
    grid.apply(changeSet: set)

    #expect(grid.value(row: 2, column: 1) == .string("z"))
    #expect(grid.displayText(row: 2, column: 1) == "z")
    #expect(grid.value(row: 2, column: 0) == .int(3))
    #expect(grid.rowState(at: 2) == .edited)
    #expect(grid.isCellEdited(row: 2, column: 1))
    #expect(!grid.isCellEdited(row: 2, column: 0))
    #expect(grid.rowState(at: 0) == .normal)
    #expect(grid.displayText(row: 0, column: 1) == "a")
  }

  @Test("Nil and an empty change set restore the loaded value")
  func revertRestoresLoadedValue() throws {
    var grid = model()
    let loaded = grid.row(at: 0)
    #expect(grid.apply(changeSet: nil).isEmpty)
    #expect(grid.row(at: 0) == loaded)
    #expect(grid.rowCount == 3)
    #expect(grid.displayText(row: 0, column: 1) == "c")

    var set = RowChangeSet(target: target)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(3)]), column: "name", value: .string("z"),
      original: .string("c"))
    grid.apply(changeSet: set)
    #expect(grid.displayText(row: 0, column: 1) == "z")

    grid.apply(changeSet: nil)
    #expect(grid.value(row: 0, column: 1) == .string("c"))
    #expect(grid.displayText(row: 0, column: 1) == "c")
    #expect(grid.rowState(at: 0) == .normal)
    #expect(!grid.isCellEdited(row: 0, column: 1))

    grid.apply(changeSet: set)
    grid.apply(changeSet: RowChangeSet(target: target))
    #expect(grid.value(row: 0, column: 1) == .string("c"))
    #expect(grid.displayText(row: 0, column: 1) == "c")
    #expect(grid.rowState(at: 0) == .normal)
  }

  @Test("A one-cell edit marks only that row changed")
  func oneCellEditMarksOnlyThatRow() throws {
    let count = 1000
    let rows: [[CellValue]] = (0..<count).map { [.int($0), .string("n\($0)")] }
    var grid = model(rows: rows)
    let before = (0..<count).map { grid.rowIdentity(at: $0) }

    var set = RowChangeSet(target: target)
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(42)]), column: "name", value: .string("edited"),
      original: .string("n42"))
    let dirty = grid.apply(changeSet: set)

    #expect(dirty == IndexSet(integer: 42))
    #expect(grid.changedRows == IndexSet(integer: 42))
    #expect(grid.value(row: 42, column: 1) == .string("edited"))
    #expect(grid.value(row: 41, column: 1) == .string("n41"))
    let after = (0..<count).map { grid.rowIdentity(at: $0) }
    let changed = zip(before, after).enumerated().compactMap { offset, pair in
      pair.0 == pair.1 ? nil : offset
    }
    #expect(changed == [42])

    let again = grid.apply(changeSet: set)
    #expect(again.isEmpty)
    #expect(grid.changedRows.isEmpty)
    #expect((0..<count).map { grid.rowIdentity(at: $0) } == after)
  }

  @Test("Staged row painting uses the design-system tints and selection wins")
  func stagedRowPainting() {
    #expect(ResultGridRowView.insertedColor == NSColor(Color.success.opacity(0.14)))
    #expect(ResultGridRowView.deletedColor == NSColor(Color.destructive.opacity(0.14)))
    #expect(ResultGridRowView.editedCellColor == NSColor(Color.warning.opacity(0.18)))

    let row = ResultGridRowView()
    let cell = NSTableCellView()
    let field = NSTextField(labelWithString: "gone")
    cell.textField = field
    cell.addSubview(field)
    row.addSubview(cell)

    row.stagingState = .inserted
    #expect(row.stagingTint == ResultGridRowView.insertedColor)
    row.isSelected = true
    #expect(row.stagingTint == nil)
    row.editedColumns = [1]
    #expect(row.editedCellTint(column: 1) == nil)

    row.isSelected = false
    row.stagingState = .deleted
    #expect(row.stagingTint == ResultGridRowView.deletedColor)
    #expect(hasStrikethrough(field))
    #expect(row.editedCellTint(column: 1) == ResultGridRowView.editedCellColor)
    #expect(row.editedCellTint(column: 0) == nil)

    row.stagingState = .normal
    #expect(row.stagingTint == nil)
    #expect(field.stringValue == "gone")
    #expect(!hasStrikethrough(field))
  }

  private func hasStrikethrough(_ field: NSTextField) -> Bool {
    let text = field.attributedStringValue
    guard text.length > 0 else { return false }
    return text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
  }
}
