//
//  ResultGridModel.swift
//  Dblore
//
//  Pure model behind the result grid: the displayed (sorted) rows, cell display text and
//  TSV of a selection. It holds only the displayed rows, so every row index it takes is a
//  table (displayed) row and can never be confused with an index into `CellResult.rows`;
//  only `displayedRow(forOriginalRow:)` takes, and `originalRow(forDisplayedRow:)` returns,
//  an index into `CellResult.rows`. `apply(changeSet:)` lays a staged overlay on those rows.
//

import Foundation

/// How a displayed row relates to the staged change set.
enum ResultGridRowState: Equatable {
  case normal
  case inserted
  case deleted
  case edited
}

/// Stable identity of one displayed row. `generation` changes only when that row's overlay does.
struct ResultGridRowIdentity: Equatable {
  /// Index into `CellResult.rows`. Nil for a staged insert.
  var originalRow: Int?
  /// Temporary id of a staged insert. Nil for a loaded row.
  var insertID: UUID?
  /// Bumps when this displayed row's staged values or state change.
  var generation: Int
}

struct ResultGridModel {
  let columns: [ColumnInfo]
  /// Loaded rows in display order, before staged inserts. Edits replace values on read.
  private let loadedRows: [[CellValue]]
  /// Index into `CellResult.rows` of each loaded displayed row
  private let originalRows: [Int]
  /// Displayed row of each index into `CellResult.rows`
  private let displayedRowByOriginalRow: [Int]
  private let columnIndexByName: [String: Int]
  /// Lazily filled display text of loaded cells. Staged edits and inserts skip it, so a copy
  /// that does not share the overlay still reads the loaded text. A new model (empty cache) is
  /// built whenever the result or sort changes.
  private let textCache: DisplayTextCache
  /// Rows whose overlay changed on the last `apply`. Empty when that apply changed nothing.
  private(set) var changedRows = IndexSet()
  private var appliedChangeSet: RowChangeSet?
  private var staging = Staging()
  private var generations: [Int] = []
  private var cachedKeyColumns: [String]?
  private var cachedKeyRows: [RowChangeSet.RowKey: [Int]] = [:]

  init(
    result: CellResult, sortColumn: String?, ascending: Bool,
    valueFilter: ColumnValueFilter = ColumnValueFilter()
  ) {
    columns = result.columns
    var indexByName: [String: Int] = [:]
    for (index, column) in result.columns.enumerated() where indexByName[column.name] == nil {
      indexByName[column.name] = index
    }
    columnIndexByName = indexByName
    let sorted = result.sortedRowIndices(byColumn: sortColumn, ascending: ascending)
    // A category filter drops rows from the grid only. `result.rows` (the LIMIT window) stays.
    let originalRows =
      valueFilter.isEmpty
      ? sorted
      : sorted.filter { valueFilter.includes(row: result.rows[$0], columns: result.columns) }
    loadedRows = originalRows.map { result.rows[$0] }
    self.originalRows = originalRows
    // Sized to the loaded result, so a filtered-out original row has no displayed row (-1)
    var displayedRowByOriginalRow = Array(repeating: -1, count: result.rows.count)
    for (displayedRow, originalRow) in originalRows.enumerated() {
      displayedRowByOriginalRow[originalRow] = displayedRow
    }
    self.displayedRowByOriginalRow = displayedRowByOriginalRow
    textCache = DisplayTextCache(rowCount: originalRows.count)
  }

  var rowCount: Int { loadedRows.count + staging.inserts.count }

  /// The displayed row at table row `row`, with staged edits and inserts applied
  func row(at row: Int) -> [CellValue] {
    values(at: row)
  }

  /// Table (displayed) row of `originalRow`, an index into `CellResult.rows` such as a search
  /// match's row; nil when out of range
  func displayedRow(forOriginalRow originalRow: Int) -> Int? {
    guard displayedRowByOriginalRow.indices.contains(originalRow) else { return nil }
    let displayed = displayedRowByOriginalRow[originalRow]
    return displayed >= 0 ? displayed : nil
  }

  /// Index into `CellResult.rows` of table (displayed) row `displayedRow`; nil when out of
  /// range
  func originalRow(forDisplayedRow displayedRow: Int) -> Int? {
    originalRows.indices.contains(displayedRow) ? originalRows[displayedRow] : nil
  }

  /// The search match the grid should treat as current. A table-data match on a row this
  /// model hides is not current: the later matches are walked (wrapping once) until one
  /// that is still on screen, or that is not a row of this cell. Nil when every candidate
  /// is a hidden row, so the hidden match does not stay current.
  func shownSearchMatch(_ current: SearchMatch, matches: [SearchMatch]) -> SearchMatch? {
    guard let start = matches.firstIndex(where: { $0.id == current.id }) else {
      return isSearchMatchShown(current, anchorCell: current.cellId) ? current : nil
    }
    for step in 0..<matches.count {
      let candidate = matches[(start + step) % matches.count]
      if isSearchMatchShown(candidate, anchorCell: current.cellId) { return candidate }
    }
    return nil
  }

  /// A table-data match of `anchorCell` is shown only when this model still displays that
  /// original row. Matches in another cell, and matches that are not rows, are not hidden here.
  private func isSearchMatchShown(_ match: SearchMatch, anchorCell: UUID) -> Bool {
    switch match.matchType {
    case .tableData(let row, _):
      if match.cellId != anchorCell { return true }
      return displayedRow(forOriginalRow: row) != nil
    case .columnName, .sqlContent, .errorMessage:
      return true
    }
  }

  /// Value at a table row and column; NULL when the row is shorter than the columns.
  /// A staged edit replaces the loaded value. A staged insert reads its own values.
  func value(row: Int, column: Int) -> CellValue {
    let values = values(at: row)
    return column < values.count ? values[column] : .null
  }

  /// Loaded rows, then staged inserts. Deleted rows stay. Re-applying the same set reports
  /// no changed rows and leaves each row's `rowIdentity` generation alone.
  @discardableResult
  mutating func apply(changeSet: RowChangeSet?) -> IndexSet {
    let next = Self.stored(changeSet)
    if next == appliedChangeSet {
      changedRows = []
      return []
    }
    let nextStaging = overlay(for: next)
    let dirty = dirtyRows(from: staging, to: nextStaging)
    staging = nextStaging
    bumpGenerations(dirty, rowCount: loadedRows.count + nextStaging.inserts.count)
    appliedChangeSet = next
    changedRows = dirty
    return dirty
  }

  /// `normal` when `row` is outside the displayed rows
  func rowState(at row: Int) -> ResultGridRowState {
    if row >= loadedRows.count {
      return row < rowCount ? .inserted : .normal
    }
    guard staging.states.indices.contains(row) else { return .normal }
    return staging.states[row]
  }

  /// Result columns with a staged edit on an existing row. Inserts are not cell edits.
  func editedColumns(at row: Int) -> IndexSet {
    guard staging.editedColumns.indices.contains(row) else { return [] }
    return staging.editedColumns[row]
  }

  func isCellEdited(row: Int, column: Int) -> Bool {
    editedColumns(at: row).contains(column)
  }

  /// Identity of displayed row `displayedRow`. Out of range traps, like `row(at:)`.
  func rowIdentity(at displayedRow: Int) -> ResultGridRowIdentity {
    let generation = generations.indices.contains(displayedRow) ? generations[displayedRow] : 0
    if displayedRow < loadedRows.count {
      return ResultGridRowIdentity(
        originalRow: originalRows[displayedRow], insertID: nil, generation: generation)
    }
    let insert = staging.inserts[displayedRow - loadedRows.count]
    return ResultGridRowIdentity(originalRow: nil, insertID: insert.id, generation: generation)
  }

  /// Longest text shown in a cell; longer text ends with "…"
  static let maxDisplayLength = 1000

  /// Text shown in a cell, the same as the result table (NULL shows as "NULL"), on one line
  /// (line breaks become spaces) and at most `maxDisplayLength` characters: the single-line
  /// text field still lays out every line of a long multi-line value, which made scrolling lag
  func displayText(row: Int, column: Int) -> String {
    // Staged text must not land in the shared cache: a copy of this model keeps the loaded rows.
    if row >= loadedRows.count || isCellEdited(row: row, column: column) {
      return computeDisplayText(row: row, column: column)
    }
    if let cached = textCache.text(row: row, column: column) { return cached }
    let text = computeDisplayText(row: row, column: column)
    textCache.store(text, row: row, column: column, columnCount: columns.count)
    return text
  }

  private func computeDisplayText(row: Int, column: Int) -> String {
    let text = value(row: row, column: column).displayString
    let prefix = text.prefix(Self.maxDisplayLength)
    let flat = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .joined(separator: " ")
    return prefix.endIndex < text.endIndex ? flat + "…" : flat
  }

  /// Indexes into `CellResult.rows` for the selected displayed rows, in ascending
  /// displayed-row order.
  func selectedRowIndices(rows: IndexSet) -> [Int] {
    rows.compactMap { originalRow(forDisplayedRow: $0) }
  }

  /// Values of the one column in `columns` for `rows`, in displayed-row order.
  /// Empty when `columns` spans more than one column.
  func selectedColumnValues(rows: IndexSet, columns: [Int]) -> [CellValue] {
    guard columns.count == 1, let column = columns.first else { return [] }
    return rows.map { value(row: $0, column: column) }
  }

  /// Tab-separated selected cells (no header, no trailing newline), full values like the
  /// TSV copy, `columns` (model column indices) in the given order. A value with a tab,
  /// newline or quote is quoted with quotes doubled, as in CSV.
  func tsv(rows: IndexSet, columns: [Int]) -> String {
    rows.map { row in
      columns.map { DataExporter.escapeTSV(value(row: row, column: $0).fullString) }
        .joined(separator: "\t")
    }
    .joined(separator: "\n")
  }

  private func values(at row: Int) -> [CellValue] {
    if row < loadedRows.count {
      if staging.values.indices.contains(row), let staged = staging.values[row] {
        return staged
      }
      return loadedRows[row]
    }
    return staging.inserts[row - loadedRows.count].values
  }

  /// Empty and nil sets both mean "no overlay".
  private static func stored(_ changeSet: RowChangeSet?) -> RowChangeSet? {
    guard let changeSet, !changeSet.isEmpty else { return nil }
    return changeSet
  }

  private mutating func overlay(for set: RowChangeSet?) -> Staging {
    guard let set else { return Staging() }
    let matches = rowsByKey(primaryKeyColumns: set.primaryKeyColumns)
    var next = Staging()
    next.states = Array(repeating: .normal, count: loadedRows.count)
    next.editedColumns = Array(repeating: IndexSet(), count: loadedRows.count)
    next.values = Array(repeating: nil, count: loadedRows.count)
    for (key, edits) in set.edits {
      for row in matches[key] ?? [] {
        var edited = IndexSet()
        var values = loadedRows[row]
        for (name, value) in edits {
          guard let index = columnIndexByName[name] else { continue }
          if index >= values.count {
            values.append(contentsOf: Array(repeating: .null, count: index + 1 - values.count))
          }
          values[index] = value
          edited.insert(index)
        }
        guard !edited.isEmpty else { continue }
        next.states[row] = .edited
        next.editedColumns[row] = edited
        next.values[row] = values
      }
    }
    for key in set.deletes {
      for row in matches[key] ?? [] {
        next.states[row] = .deleted
        next.editedColumns[row] = []
        next.values[row] = nil
      }
    }
    next.inserts = set.inserts.map { insert in
      Staging.StagedInsert(
        id: insert.tempID, values: columns.map { insert.values[$0.name] ?? .null })
    }
    return next
  }

  /// Primary-key lookup for the loaded page. Reused while the key columns stay the same, so a
  /// one-cell edit does not rebuild it.
  private mutating func rowsByKey(primaryKeyColumns: [String]) -> [RowChangeSet.RowKey: [Int]] {
    if cachedKeyColumns == primaryKeyColumns { return cachedKeyRows }
    var map: [RowChangeSet.RowKey: [Int]] = [:]
    let indexes = primaryKeyColumns.compactMap { columnIndexByName[$0] }
    if indexes.count == primaryKeyColumns.count {
      map.reserveCapacity(loadedRows.count)
      for row in loadedRows.indices {
        let source = loadedRows[row]
        let values = indexes.map { $0 < source.count ? source[$0] : CellValue.null }
        map[RowChangeSet.RowKey(values: values), default: []].append(row)
      }
    }
    cachedKeyColumns = primaryKeyColumns
    cachedKeyRows = map
    return map
  }

  /// Loaded rows whose state or staged values differ, plus insert rows that were added,
  /// removed, or edited. Unchanged loaded rows are left out.
  private func dirtyRows(from old: Staging, to new: Staging) -> IndexSet {
    var dirty = IndexSet()
    for row in loadedRows.indices {
      let oldState = old.states.indices.contains(row) ? old.states[row] : ResultGridRowState.normal
      let newState = new.states.indices.contains(row) ? new.states[row] : .normal
      let oldEdited = old.editedColumns.indices.contains(row) ? old.editedColumns[row] : IndexSet()
      let newEdited = new.editedColumns.indices.contains(row) ? new.editedColumns[row] : IndexSet()
      let oldValues = old.values.indices.contains(row) ? old.values[row] : nil
      let newValues = new.values.indices.contains(row) ? new.values[row] : nil
      if oldState != newState || oldEdited != newEdited || oldValues != newValues {
        dirty.insert(row)
      }
    }
    let insertCount = max(old.inserts.count, new.inserts.count)
    for index in 0..<insertCount {
      let previous = index < old.inserts.count ? old.inserts[index] : nil
      let current = index < new.inserts.count ? new.inserts[index] : nil
      if previous != current { dirty.insert(loadedRows.count + index) }
    }
    return dirty
  }

  private mutating func bumpGenerations(_ dirty: IndexSet, rowCount: Int) {
    if generations.count < rowCount {
      generations.append(contentsOf: repeatElement(0, count: rowCount - generations.count))
    }
    for row in dirty where row < generations.count {
      generations[row] += 1
    }
    if generations.count > rowCount {
      generations.removeLast(generations.count - rowCount)
    }
  }
}

/// Staged overlay currently shown. Empty arrays mean every loaded row is unchanged.
private struct Staging: Equatable {
  struct StagedInsert: Equatable {
    var id: UUID
    var values: [CellValue]
  }

  var states: [ResultGridRowState] = []
  var editedColumns: [IndexSet] = []
  var values: [[CellValue]?] = []
  var inserts: [StagedInsert] = []
}

/// Per-cell display text of one `ResultGridModel`, filled on first request. A row's array is
/// allocated on first store, so memory stays proportional to the cells actually shown. Main
/// actor only, like the model (the project's default isolation), so no locking is needed.
private final class DisplayTextCache {
  private var rows: [[String?]?]

  init(rowCount: Int) {
    rows = Array(repeating: nil, count: rowCount)
  }

  func text(row: Int, column: Int) -> String? {
    guard let cells = rows[row], column < cells.count else { return nil }
    return cells[column]
  }

  func store(_ text: String, row: Int, column: Int, columnCount: Int) {
    // A column past the model's columns (a short row shows NULL) is not cached
    guard column < columnCount else { return }
    if rows[row] == nil { rows[row] = Array(repeating: nil, count: columnCount) }
    rows[row]?[column] = text
  }
}
