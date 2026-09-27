//
//  ResultGridView.swift
//  SQLNotebook
//
//  NSTableView-based result grid: view-based cell reuse renders only the visible rows.
//  Columns can be resized and reordered; Cmd+C copies the selected rows as TSV.
//  Double-click or Return edits a cell when `isEditable` (see NotebookViewModel.canEdit).
//

import AppKit
import SwiftUI

struct ResultGridView: NSViewRepresentable {
  let result: CellResult
  var sortColumn: String? = nil
  var ascending = true
  /// From `NotebookViewModel.canEdit(result)`; false keeps the grid read-only
  var isEditable = false
  /// Receives the displayed row values, the result column index and the new text of an edit
  var onCommitEdit: ((_ row: [CellValue], _ column: Int, _ newValue: String) -> Void)? =
    nil

  /// Fixed row height of the grid
  static let rowHeight: CGFloat = 26

  /// Height of the rows only (no header), for a grid placed in a List or LazyVStack
  static func rowsHeight(rowCount: Int) -> CGFloat {
    CGFloat(rowCount) * rowHeight
  }

  func makeCoordinator() -> ResultGridCoordinator {
    ResultGridCoordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let tableView = ResultGridTableView()
    tableView.coordinator = context.coordinator
    tableView.rowHeight = Self.rowHeight
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsColumnResizing = true
    tableView.allowsColumnReordering = true
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.style = .plain
    tableView.backgroundColor = NSColor(Color.cellBackground)
    tableView.target = tableView
    tableView.doubleAction = #selector(ResultGridTableView.editClickedCell(_:))

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    context.coordinator.isEditable = isEditable
    context.coordinator.onCommitEdit = onCommitEdit
    context.coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tableView = scrollView.documentView as? NSTableView else { return }
    context.coordinator.isEditable = isEditable
    context.coordinator.onCommitEdit = onCommitEdit
    context.coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending)
  }
}

/// Table view that answers the copy: action with the coordinator's TSV, and starts an inline
/// edit on double-click or Return (in the last clicked column)
final class ResultGridTableView: NSTableView {
  weak var coordinator: ResultGridCoordinator?
  private var lastClickedColumn = 0

  override func mouseDown(with event: NSEvent) {
    let column = self.column(at: convert(event.locationInWindow, from: nil))
    if column >= 0 { lastClickedColumn = column }
    super.mouseDown(with: event)
  }

  @objc func editClickedCell(_ sender: Any?) {
    edit(row: clickedRow, tableColumn: clickedColumn)
  }

  override func keyDown(with event: NSEvent) {
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    if isReturn, selectedRowIndexes.count == 1,
      edit(row: selectedRow, tableColumn: lastClickedColumn)
    {
      return
    }
    super.keyDown(with: event)
  }

  @discardableResult
  private func edit(row: Int, tableColumn: Int) -> Bool {
    guard let coordinator, row >= 0, tableColumns.indices.contains(tableColumn),
      let column = Int(tableColumns[tableColumn].identifier.rawValue)
    else { return false }
    return coordinator.beginEditing(self, row: row, column: column)
  }

  @objc func copy(_ sender: Any?) {
    coordinator?.copySelection(self)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) {
      return !selectedRowIndexes.isEmpty
    }
    return super.validateUserInterfaceItem(item)
  }
}
