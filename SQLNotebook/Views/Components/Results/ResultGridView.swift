//
//  ResultGridView.swift
//  SQLNotebook
//
//  NSTableView-based result grid: view-based cell reuse renders only the visible rows.
//  Columns can be resized and reordered; Cmd+C copies the selected rows as TSV.
//

import AppKit
import SwiftUI

struct ResultGridView: NSViewRepresentable {
  let result: CellResult
  var sortColumn: String? = nil
  var ascending = true

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

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    context.coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tableView = scrollView.documentView as? NSTableView else { return }
    context.coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending)
  }
}

/// Table view that answers the copy: action with the coordinator's TSV
final class ResultGridTableView: NSTableView {
  weak var coordinator: ResultGridCoordinator?

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
