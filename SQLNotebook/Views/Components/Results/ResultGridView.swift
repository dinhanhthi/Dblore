//
//  ResultGridView.swift
//  SQLNotebook
//
//  NSTableView-based result grid: view-based cell reuse renders only the visible rows.
//  Columns can be resized and reordered; Cmd+C copies the selected rows as TSV.
//  Double-click or Return edits a cell when `isEditable` (see NotebookViewModel.canEdit).
//  A click reports the cell (`onCellClick`), a header click the sort (`onSortChange`).
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
  /// Receives the column and direction chosen by a header click
  var onSortChange: ((_ column: String?, _ ascending: Bool) -> Void)? = nil
  /// Receives the displayed row values and the result column index of a clicked cell
  var onCellClick: ((_ row: [CellValue], _ column: Int) -> Void)? = nil
  /// Text highlighted in the cells (search)
  var searchQuery = ""
  var caseSensitive = false

  /// Fixed row height of the grid
  static let rowHeight: CGFloat = 26
  /// Fixed header height (set on the header view)
  static let headerHeight: CGFloat = 28
  /// Rows shown at once by a grid of `height(rowCount:)`; more rows scroll inside the grid
  static let maxVisibleRows = 15

  /// Height of the rows only (no header), for a grid placed in a List or LazyVStack
  static func rowsHeight(rowCount: Int) -> CGFloat {
    CGFloat(rowCount) * rowHeight
  }

  /// Fixed height of a grid in a List or LazyVStack: at most `maxVisibleRows` rows plus header
  static func height(rowCount: Int) -> CGFloat {
    rowsHeight(rowCount: min(rowCount, maxVisibleRows)) + headerHeight
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
    tableView.action = #selector(ResultGridTableView.clickCell(_:))
    tableView.doubleAction = #selector(ResultGridTableView.editClickedCell(_:))
    tableView.headerView?.frame.size.height = Self.headerHeight

    let scrollView = ResultGridScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    configure(context.coordinator, tableView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tableView = scrollView.documentView as? NSTableView else { return }
    configure(context.coordinator, tableView)
  }

  private func configure(_ coordinator: ResultGridCoordinator, _ tableView: NSTableView) {
    coordinator.isEditable = isEditable
    coordinator.onCommitEdit = onCommitEdit
    coordinator.onSortChange = onSortChange
    coordinator.onCellClick = onCellClick
    coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending,
      searchQuery: searchQuery, caseSensitive: caseSensitive)
  }
}

/// Scroll view that hands a vertical scroll gesture to the enclosing scroll view (the notebook
/// list) when the grid can't scroll that way, so the list keeps scrolling over a result.
/// The choice is made once per gesture; horizontal scrolling stays in the grid.
final class ResultGridScrollView: NSScrollView {
  private var forwardsGesture: Bool?

  /// Whether a vertical scroll of `deltaY` (> 0 toward the top) at `offsetY` (0 = top) goes to
  /// the parent: the content fits, or the grid is already at the edge it scrolls toward
  /// (within 1 pt, for fractional offsets)
  static func shouldForward(deltaY: CGFloat, offsetY: CGFloat, maxOffsetY: CGFloat) -> Bool {
    maxOffsetY < 1 || (deltaY > 0 && offsetY < 1) || (deltaY < 0 && offsetY > maxOffsetY - 1)
  }

  override func scrollWheel(with event: NSEvent) {
    let startsGesture =
      event.phase == .mayBegin || event.phase == .began
      || (event.phase.isEmpty && event.momentumPhase.isEmpty)
    if startsGesture { forwardsGesture = nil }
    let deltaX = event.scrollingDeltaX
    let deltaY = event.scrollingDeltaY
    // Shift+wheel is a horizontal scroll (mouse), handled by the grid
    if forwardsGesture == nil, deltaX != 0 || deltaY != 0, !event.modifierFlags.contains(.shift) {
      let insets = contentView.contentInsets
      let bounds = contentView.bounds
      let maxOffsetY =
        (documentView?.frame.height ?? 0) + insets.top + insets.bottom - bounds.height
      forwardsGesture =
        abs(deltaY) > abs(deltaX)
        && Self.shouldForward(
          deltaY: deltaY, offsetY: bounds.origin.y + insets.top, maxOffsetY: maxOffsetY)
    }
    if forwardsGesture == true {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}

/// Table view that answers the copy: action with the coordinator's TSV, reports a cell click,
/// and starts an inline edit on double-click or Return (in the last clicked column)
final class ResultGridTableView: NSTableView {
  weak var coordinator: ResultGridCoordinator?
  private var lastClickedColumn = 0

  override func mouseDown(with event: NSEvent) {
    let column = self.column(at: convert(event.locationInWindow, from: nil))
    if column >= 0 { lastClickedColumn = column }
    super.mouseDown(with: event)
  }

  @objc func clickCell(_ sender: Any?) {
    guard tableColumns.indices.contains(clickedColumn),
      let column = Int(tableColumns[clickedColumn].identifier.rawValue)
    else { return }
    coordinator?.cellClicked(row: clickedRow, column: column)
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
