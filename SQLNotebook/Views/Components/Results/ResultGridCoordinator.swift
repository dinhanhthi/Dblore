//
//  ResultGridCoordinator.swift
//  SQLNotebook
//
//  Data source and delegate of the result grid NSTableView. Rows, NULL text and TSV come
//  from ResultGridModel; cells are reused through makeView(withIdentifier:owner:).
//  Inline edit (double-click or Return) is allowed only when `isEditable`, and a commit
//  delivers the displayed row's values, never a row index.
//

import AppKit
import SwiftUI

@MainActor
final class ResultGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSTextFieldDelegate
{
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

  /// Set by the caller from `NotebookViewModel.canEdit(_:)`: without it no cell can be edited
  var isEditable = false
  /// Called with the displayed row values, the edited result column index and the new text
  var onCommitEdit: ((_ row: [CellValue], _ column: Int, _ newValue: String) -> Void)?
  /// Row values and column of the cell being edited, captured when editing starts so a reload
  /// during the edit can't shift the committed row
  private var editing: (row: [CellValue], column: Int)?

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

  // MARK: - Inline edit

  /// Starts editing the cell at a table row and model column with its full value.
  /// Returns false when the grid is not editable.
  @discardableResult
  func beginEditing(_ tableView: NSTableView, row: Int, column: Int) -> Bool {
    guard isEditable, let model, row >= 0, row < model.rowCount,
      let tableColumn = tableView.tableColumns.firstIndex(where: {
        $0.identifier.rawValue == String(column)
      }),
      let textField =
        (tableView.view(atColumn: tableColumn, row: row, makeIfNecessary: true)
        as? NSTableCellView)?.textField
    else { return false }
    editing = (model.row(at: row), column)
    textField.isEditable = true
    textField.stringValue = model.value(row: row, column: column).fullString
    textField.textColor = Self.textColor
    return tableView.window?.makeFirstResponder(textField) ?? false
  }

  /// Delivers an edit of a displayed row to `onCommitEdit`; nothing when not editable or when
  /// the text is the unchanged full value.
  func commitEdit(row: Int, column: Int, newValue: String) {
    guard let model, row >= 0, row < model.rowCount, column < model.columns.count else { return }
    commit(rowValues: model.row(at: row), column: column, newValue: newValue)
  }

  private func commit(rowValues: [CellValue], column: Int, newValue: String) {
    let original = column < rowValues.count ? rowValues[column] : .null
    guard isEditable, newValue != original.fullString else { return }
    onCommitEdit?(rowValues, column, newValue)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let textField = notification.object as? NSTextField,
      let tableView = textField.enclosingScrollView?.documentView as? NSTableView
    else { return }
    textField.isEditable = false
    textField.isSelectable = false
    let row = tableView.row(for: textField)
    let tableColumn = tableView.column(for: textField)
    if let editing {
      self.editing = nil
      commit(rowValues: editing.row, column: editing.column, newValue: textField.stringValue)
    }
    guard row >= 0, tableColumn >= 0 else { return }
    // Show the stored value again; a successful edit re-runs the cell and reloads the grid
    tableView.reloadData(forRowIndexes: [row], columnIndexes: [tableColumn])
  }

  /// Escape cancels the edit without committing
  func control(
    _ control: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
      let textField = control as? NSTextField,
      let tableView = textField.enclosingScrollView?.documentView as? NSTableView
    else { return false }
    let row = tableView.row(for: textField)
    let tableColumn = tableView.column(for: textField)
    editing = nil
    textField.abortEditing()
    textField.isEditable = false
    textField.isSelectable = false
    if row >= 0, tableColumn >= 0 {
      tableView.reloadData(forRowIndexes: [row], columnIndexes: [tableColumn])
    }
    return true
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
    cell.textField?.isEditable = false
    cell.textField?.isSelectable = false
    cell.textField?.delegate = self
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
