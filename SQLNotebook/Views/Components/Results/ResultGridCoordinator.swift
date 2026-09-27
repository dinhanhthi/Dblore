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
  /// Background of the current search match (the one Enter moved to), as in the result table
  static let currentMatchColor = NSColor(SearchHighlighter.currentMatchColor)
  /// Same size as `Font.mono` (body, monospaced)
  static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

  private static let cellIdentifier = NSUserInterfaceItemIdentifier("ResultGridCell")

  /// What decides a reload: the result's identity, the sort and the search, not every SwiftUI
  /// update
  private struct Key: Equatable {
    let timestamp: Date
    let columnNames: [String]
    let rowCount: Int
    let sortColumn: String?
    let ascending: Bool
    let searchQuery: String
    let caseSensitive: Bool
    let currentMatchId: UUID?
  }

  private(set) var model: ResultGridModel?
  private var key: Key?
  /// Table (displayed) row and result column of the current search match
  private var currentMatchCell: (row: Int, column: Int)?

  /// Set by the caller from `NotebookViewModel.canEdit(_:)`: without it no cell can be edited
  var isEditable = false
  /// Called with the displayed row values, the edited result column index and the new text
  var onCommitEdit: ((_ row: [CellValue], _ column: Int, _ newValue: String) -> Void)?
  /// Row values and column of the cell being edited, captured when editing starts so a reload
  /// during the edit can't shift the committed row
  private var editing: (row: [CellValue], column: Int)?
  /// Called with the column and direction chosen by a header click (nil column: no sort)
  var onSortChange: ((_ column: String?, _ ascending: Bool) -> Void)?
  /// Called with the displayed row values, its index into `CellResult.rows` and the result
  /// column index of a clicked cell
  var onCellClick: ((_ row: [CellValue], _ originalRow: Int, _ column: Int) -> Void)?
  /// True while `update` shows the input sort in the header, so it isn't reported back
  private var isShowingInputSort = false

  /// Sort after a header click on `clicked`: the same column goes ascending, descending, then
  /// no sort (nil column); another column starts ascending
  static func nextSort(
    current: (column: String?, ascending: Bool), clicked: String
  ) -> (column: String?, ascending: Bool) {
    guard current.column == clicked else { return (clicked, true) }
    return current.ascending ? (clicked, false) : (nil, true)
  }

  /// Numbers are right-aligned, other values left-aligned, as in the result table
  static func alignment(for value: CellValue) -> NSTextAlignment {
    switch value {
    case .int, .double: .right
    default: .left
    }
  }

  /// Rebuilds the columns and reloads the table when the result, the sort or the search
  /// changed, and scrolls to the row of `currentMatch` (a match in this result's data).
  /// Returns whether the table was reloaded.
  @discardableResult
  func update(
    _ tableView: NSTableView, result: CellResult, sortColumn: String?, ascending: Bool,
    searchQuery: String = "", caseSensitive: Bool = false, currentMatch: SearchMatch? = nil
  )
    -> Bool
  {
    let newKey = Key(
      timestamp: result.timestamp, columnNames: result.columns.map(\.name),
      rowCount: result.rows.count, sortColumn: sortColumn, ascending: ascending,
      searchQuery: searchQuery, caseSensitive: caseSensitive, currentMatchId: currentMatch?.id)
    guard newKey != key else { return false }
    if newKey.columnNames != key?.columnNames {
      rebuildColumns(tableView, columns: result.columns)
    }
    key = newKey
    let model = ResultGridModel(result: result, sortColumn: sortColumn, ascending: ascending)
    self.model = model
    currentMatchCell = nil
    if case .tableData(let originalRow, let columnName) = currentMatch?.matchType,
      let row = model.displayedRow(forOriginalRow: originalRow),
      let column = model.columns.firstIndex(where: { $0.name == columnName })
    {
      currentMatchCell = (row, column)
    }
    tableView.dataSource = self
    tableView.delegate = self
    let sortDescriptors = sortColumn.map { [NSSortDescriptor(key: $0, ascending: ascending)] } ?? []
    if tableView.sortDescriptors != sortDescriptors {
      isShowingInputSort = true
      tableView.sortDescriptors = sortDescriptors
      isShowingInputSort = false
    }
    tableView.reloadData()
    if let currentMatchCell {
      tableView.scrollRowToVisible(currentMatchCell.row)
    }
    return true
  }

  /// Reports a click on a displayed row (not the header) to `onCellClick`
  func cellClicked(row: Int, column: Int) {
    guard let model, let originalRow = model.originalRow(forDisplayedRow: row),
      column < model.columns.count
    else { return }
    onCellClick?(model.row(at: row), originalRow, column)
  }

  /// TSV of the selected rows, all columns in on-screen order (after a column move)
  func selectionTSV(_ tableView: NSTableView) -> String {
    guard let model else { return "" }
    return model.tsv(
      rows: tableView.selectedRowIndexes,
      columns: tableView.tableColumns.compactMap { Int($0.identifier.rawValue) })
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

  func tableView(
    _ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]
  ) {
    guard !isShowingInputSort else { return }
    // The table flips the direction itself; only the clicked column is taken from it
    guard let clicked = tableView.sortDescriptors.first?.key else {
      onSortChange?(nil, true)
      return
    }
    let next = Self.nextSort(
      current: (key?.sortColumn, key?.ascending ?? true), clicked: clicked)
    if next.column == nil {
      isShowingInputSort = true
      tableView.sortDescriptors = []
      isShowingInputSort = false
    }
    onSortChange?(next.column, next.ascending)
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
    let value = model.value(row: row, column: column)
    let isNull = value == .null
    let text = model.displayText(row: row, column: column)
    cell.textField?.textColor = isNull ? Self.nullTextColor : Self.textColor
    if let key, !key.searchQuery.isEmpty {
      cell.textField?.attributedStringValue = highlighted(
        text, query: key.searchQuery, caseSensitive: key.caseSensitive,
        textColor: isNull ? Self.nullTextColor : Self.textColor,
        isCurrentMatch: currentMatchCell?.row == row && currentMatchCell?.column == column)
    } else {
      cell.textField?.stringValue = text
    }
    cell.textField?.alignment = Self.alignment(for: value)
    cell.textField?.isEditable = false
    cell.textField?.isSelectable = false
    cell.textField?.delegate = self
    return cell
  }

  // MARK: - Private

  /// `text` with every match of `query` on the search highlight color, like SearchHighlighter;
  /// in the current match cell the first match is on the current-match color
  private func highlighted(
    _ text: String, query: String, caseSensitive: Bool, textColor: NSColor, isCurrentMatch: Bool
  ) -> NSAttributedString {
    let string = NSMutableAttributedString(
      string: text, attributes: [.font: Self.font, .foregroundColor: textColor])
    let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
    var start = text.startIndex
    while let range = text.range(of: query, options: options, range: start..<text.endIndex) {
      let isCurrent = isCurrentMatch && start == text.startIndex
      string.addAttributes(
        [
          .backgroundColor: isCurrent
            ? Self.currentMatchColor : NSColor(SearchHighlighter.highlightColor),
          .foregroundColor: NSColor.black,
        ], range: NSRange(range, in: text))
      start = range.upperBound
    }
    return string
  }

  /// Column identifiers are the model column index, so a reordered column still maps back
  private func rebuildColumns(_ tableView: NSTableView, columns: [ColumnInfo]) {
    tableView.tableColumns.forEach(tableView.removeTableColumn)
    for (index, info) in columns.enumerated() {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
      column.title = info.name
      column.minWidth = 40
      column.width = 150
      column.sortDescriptorPrototype = NSSortDescriptor(key: info.name, ascending: true)
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
