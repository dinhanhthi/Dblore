//
//  ResultGridCoordinator.swift
//  SQLNotebook
//
//  Data source and delegate of the result grid NSTableView. Rows, NULL text and TSV come
//  from ResultGridModel; cells are reused through makeView(withIdentifier:owner:).
//

import AppKit
import SwiftUI

@MainActor
final class ResultGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  static let textColor = NSColor(Color.foreground)
  static let nullTextColor = NSColor(Color.foregroundSubtle)
  /// Same size as `Font.mono` (body, monospaced)
  static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

  private static let cellIdentifier = NSUserInterfaceItemIdentifier("ResultGridCell")

  /// What decides a reload: the result's identity and the sort, not every SwiftUI update
  private struct Key: Equatable {
    let timestamp: Date
    let columnNames: [String]
    let rowCount: Int
    let sortColumn: String?
    let ascending: Bool
  }

  private(set) var model: ResultGridModel?
  private var key: Key?

  /// Rebuilds the columns and reloads the table when the result or the sort changed.
  /// Returns whether the table was reloaded.
  @discardableResult
  func update(
    _ tableView: NSTableView, result: CellResult, sortColumn: String?, ascending: Bool
  )
    -> Bool
  {
    let newKey = Key(
      timestamp: result.timestamp, columnNames: result.columns.map(\.name),
      rowCount: result.rows.count, sortColumn: sortColumn, ascending: ascending)
    guard newKey != key else { return false }
    if newKey.columnNames != key?.columnNames {
      rebuildColumns(tableView, columns: result.columns)
    }
    key = newKey
    model = ResultGridModel(result: result, sortColumn: sortColumn, ascending: ascending)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.reloadData()
    return true
  }

  /// TSV of the selected rows, all columns in result order
  func selectionTSV(_ tableView: NSTableView) -> String {
    guard let model else { return "" }
    return model.tsv(
      rows: tableView.selectedRowIndexes, columns: IndexSet(0..<model.columns.count))
  }

  func copySelection(_ tableView: NSTableView) {
    guard !tableView.selectedRowIndexes.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(selectionTSV(tableView), forType: .string)
  }

  // MARK: - NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int {
    model?.rowCount ?? 0
  }

  // MARK: - NSTableViewDelegate

  func tableView(
    _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
  )
    -> NSView?
  {
    guard let model, let tableColumn, let column = Int(tableColumn.identifier.rawValue) else {
      return nil
    }
    let cell =
      tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? NSTableCellView
      ?? makeCell()
    let isNull = model.value(row: row, column: column) == .null
    cell.textField?.stringValue = model.displayText(row: row, column: column)
    cell.textField?.textColor = isNull ? Self.nullTextColor : Self.textColor
    return cell
  }

  // MARK: - Private

  /// Column identifiers are the model column index, so a reordered column still maps back
  private func rebuildColumns(_ tableView: NSTableView, columns: [ColumnInfo]) {
    tableView.tableColumns.forEach(tableView.removeTableColumn)
    for (index, info) in columns.enumerated() {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
      column.title = info.name
      column.minWidth = 40
      column.width = 150
      tableView.addTableColumn(column)
    }
  }

  private func makeCell() -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = Self.cellIdentifier
    let textField = NSTextField(labelWithString: "")
    textField.font = Self.font
    textField.lineBreakMode = .byTruncatingTail
    textField.cell?.usesSingleLineMode = true
    textField.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(textField)
    cell.textField = textField
    NSLayoutConstraint.activate([
      textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Spacing.xsm),
      textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.xsm),
      textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}
