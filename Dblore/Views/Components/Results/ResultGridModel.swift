//
//  ResultGridModel.swift
//  Dblore
//
//  Pure model behind the result grid: the displayed (sorted) rows, cell display text and
//  TSV of a selection. It holds only the displayed rows, so every row index it takes is a
//  table (displayed) row and can never be confused with an index into `CellResult.rows`;
//  only `displayedRow(forOriginalRow:)` takes, and `originalRow(forDisplayedRow:)` returns,
//  an index into `CellResult.rows`. `apply(changeSet:)` lays a staged overlay on those rows.
//  A binary column's "Display As" format decides its text: hex and UUID inline, MessagePack and
//  Protobuf decoded off the main actor (the cell shows its size until the text lands).
//  A cell a lazy data-viewer page cut (`unloadedCells`) shows "<N bytes, not loaded>" and is
//  never decoded from its prefix; copies fill it with its full value first (`fillLoaded`).
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
  private var loadedRows: [[CellValue]]
  /// Index into `CellResult.rows` of each loaded displayed row
  private let originalRows: [Int]
  /// Displayed row of each index into `CellResult.rows`
  private let displayedRowByOriginalRow: [Int]
  private let columnIndexByName: [String: Int]
  /// Display text shows invisible characters as marks (`InvisibleCharacters`)
  private let marksInvisibleCharacters: Bool
  /// Lazily filled display text of loaded cells. Staged edits and inserts skip it, so a copy
  /// that does not share the overlay still reads the loaded text. A new model (empty cache) is
  /// built whenever the result or sort changes.
  private var textCache: DisplayTextCache
  /// "Display As" of binary result columns by index; a column left out shows its size
  private var binaryFormats: [Int: BinaryDisplayFormat] = [:]
  /// Off-main decodes of MessagePack and Protobuf cells, landing in `textCache`
  private let binaryDecodes = BinaryDecodeQueue()
  /// Rows whose overlay changed on the last `apply`. Empty when that apply changed nothing.
  private(set) var changedRows = IndexSet()
  private var appliedChangeSet: RowChangeSet?
  private var staging = Staging()
  private var generations: [Int] = []
  private var cachedKeyColumns: [String]?
  private var cachedKeyRows: [RowChangeSet.RowKey: [Int]] = [:]
  /// Full byte length of each cut cell by index into `CellResult.rows`, then result column
  private var unloaded: [Int: [Int: Int]]

  /// A cell of the loaded result: index into `CellResult.rows` and result column
  struct CellRef: Hashable {
    let row: Int
    let column: Int
  }

  init(
    result: CellResult, sortColumn: String?, ascending: Bool,
    valueFilter: ColumnValueFilter = ColumnValueFilter(), marksInvisibleCharacters: Bool = true,
    binaryFormats: [String: BinaryDisplayFormat] = [:], unloadedCells: [Int: [Int: Int]] = [:]
  ) {
    columns = result.columns
    unloaded = unloadedCells
    self.marksInvisibleCharacters = marksInvisibleCharacters
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
    self.binaryFormats = Self.formatsByIndex(binaryFormats, columns: result.columns)
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

  // MARK: - Binary Display As

  /// "Display As" of result column `column`; `.size` when none is set
  func binaryFormat(column: Int) -> BinaryDisplayFormat {
    binaryFormats[column] ?? .size
  }

  /// Whether result column `column` holds binary values: its type is a binary type, or a loaded
  /// value is binary (SQLite columns have no fixed type)
  func isBinaryColumn(_ column: Int) -> Bool {
    guard columns.indices.contains(column) else { return false }
    let type = columns[column].type.lowercased()
    if type == "bytea" || type.contains("blob") || type.contains("binary") { return true }
    return loadedRows.contains { row in
      guard column < row.count, case .data = row[column] else { return false }
      return true
    }
  }

  /// Sets the "Display As" formats by column name. Returns the result columns whose format
  /// changed: their cached text is dropped and their pending decodes cancelled.
  @discardableResult
  mutating func setBinaryFormats(_ formats: [String: BinaryDisplayFormat]) -> IndexSet {
    let next = Self.formatsByIndex(formats, columns: columns)
    var changed = IndexSet()
    for column in Set(next.keys).union(binaryFormats.keys)
    where next[column] != binaryFormats[column] {
      changed.insert(column)
      textCache.clear(column: column)
      binaryDecodes.cancel(column: column)
    }
    binaryFormats = next
    return changed
  }

  /// Called on the main actor when an off-main decode stored the text of a displayed row and
  /// result column: the grid reloads that cell. Shared by every copy of this model.
  var onBinaryTextReady: ((_ row: Int, _ column: Int) -> Void)? {
    get { binaryDecodes.onReady }
    nonmutating set { binaryDecodes.onReady = newValue }
  }

  /// Drops the pending decodes of displayed row `row` (scrolled out of the grid)
  func cancelBinaryDecodes(row: Int) {
    binaryDecodes.cancel(row: row)
  }

  /// Drops every pending decode (the grid moved to a new model or went away)
  func cancelBinaryDecodes() {
    binaryDecodes.cancelAll()
  }

  /// The text a cell shows, for "Copy as Displayed". A MessagePack or Protobuf cell whose text
  /// has not landed yet is decoded off the main actor, so the copy is never the size placeholder.
  func displayTextForCopy(row: Int, column: Int) async -> String {
    if let length = unloadedLength(row: row, column: column) {
      return Self.notLoadedText(length: length)
    }
    if row < loadedRows.count, !isCellEdited(row: row, column: column),
      let cached = textCache.display(row: row, column: column)
    {
      return cached.text
    }
    if let decode = offMainDecode(row: row, column: column) {
      let text = await BinaryDecodeQueue.decode(
        decode.data, format: decode.format, limit: Self.maxDisplayLength)
      let flat = Self.flattened(text ?? CellValue.data(decode.data).displayString)
      return Self.cellDisplay(flat, marks: marksInvisibleCharacters).text
    }
    return computeDisplay(row: row, column: column).text
  }

  // MARK: - Unloaded cells

  /// "<N bytes, not loaded>": a cut cell's text, whatever its column's "Display As"
  static func notLoadedText(length: Int) -> String {
    "<\(length) bytes, not loaded>"
  }

  /// Full byte length of the cut value at displayed row `row` and result column `column`; nil
  /// for a whole value, a staged insert or a staged edit (it replaced the whole value)
  func unloadedLength(row: Int, column: Int) -> Int? {
    guard row < loadedRows.count, !unloaded.isEmpty, !isCellEdited(row: row, column: column)
    else { return nil }
    return unloaded[originalRows[row]]?[column]
  }

  /// Cut cells of the displayed `rows` in `columns`, as shown (a staged edit replaced its cell)
  func unloadedCells(rows: IndexSet, columns: [Int]) -> [CellRef] {
    guard !unloaded.isEmpty else { return [] }
    return rows.flatMap { row in
      columns.compactMap { column in
        unloadedLength(row: row, column: column) == nil
          ? nil : CellRef(row: originalRows[row], column: column)
      }
    }
  }

  /// Cut cells of `originalRows` (indexes into `CellResult.rows`) in `columns`, staged edits
  /// ignored (for copies of the loaded result itself)
  func unloadedCells(originalRows: [Int], columns: [Int]) -> [CellRef] {
    guard !unloaded.isEmpty else { return [] }
    return originalRows.flatMap { row in
      columns.compactMap { unloaded[row]?[$0] == nil ? nil : CellRef(row: row, column: $0) }
    }
  }

  /// Puts full values (by index into `CellResult.rows`, then result column) into the cut cells,
  /// staged rows included where the column is not edited. Display text starts over, in a cache
  /// of this copy only.
  mutating func fillLoaded(_ values: [Int: [Int: CellValue]]) {
    guard !values.isEmpty else { return }
    for (originalRow, cells) in values {
      guard let row = displayedRow(forOriginalRow: originalRow) else { continue }
      for (column, value) in cells where column < loadedRows[row].count {
        loadedRows[row][column] = value
        if staging.values.indices.contains(row), var staged = staging.values[row],
          !isCellEdited(row: row, column: column), column < staged.count
        {
          staged[column] = value
          staging.values[row] = staged
        }
        unloaded[originalRow]?[column] = nil
      }
      if unloaded[originalRow]?.isEmpty == true { unloaded[originalRow] = nil }
    }
    textCache = DisplayTextCache(rowCount: loadedRows.count)
  }

  private static func formatsByIndex(
    _ formats: [String: BinaryDisplayFormat], columns: [ColumnInfo]
  ) -> [Int: BinaryDisplayFormat] {
    var byIndex: [Int: BinaryDisplayFormat] = [:]
    for (index, column) in columns.enumerated() {
      if let format = formats[column.name], format != .size { byIndex[index] = format }
    }
    return byIndex
  }

  /// MessagePack and Protobuf decode the whole value, so the grid never runs them on the main
  /// actor; size, hex and UUID read at most the bytes shown
  private static func decodesOffMain(_ format: BinaryDisplayFormat) -> Bool {
    format == .messagePack || format == .protobuf
  }

  /// Bytes and format of a cell whose text needs an off-main decode, else nil
  private func offMainDecode(
    row: Int, column: Int
  ) -> (data: Data, format: BinaryDisplayFormat)? {
    guard let format = binaryFormats[column], Self.decodesOffMain(format),
      case .data(let data) = value(row: row, column: column)
    else { return nil }
    return (data, format)
  }

  /// Text shown in a cell, the same as the result table (NULL shows as "NULL"), on one line
  /// (line breaks become spaces) and at most `maxDisplayLength` characters: the single-line
  /// text field still lays out every line of a long multi-line value, which made scrolling lag.
  /// With `marksInvisibleCharacters`, other invisible characters show as marks.
  /// A MessagePack or Protobuf cell shows its size until its text lands; only with
  /// `requestsDecode` (a cell on screen) does the call start that decode.
  func displayText(row: Int, column: Int, requestsDecode: Bool = false) -> String {
    display(row: row, column: column, requestsDecode: requestsDecode).text
  }

  /// Code point and name of each invisible character marked in the cell's display text, one
  /// per line in first-seen order. Nil when there is none or marks are off.
  func invisibleCharacterTooltip(row: Int, column: Int) -> String? {
    display(row: row, column: column).tooltip
  }

  private func display(row: Int, column: Int, requestsDecode: Bool = false) -> CellDisplay {
    // Never decoded from its prefix
    if let length = unloadedLength(row: row, column: column) {
      return CellDisplay(text: Self.notLoadedText(length: length), tooltip: nil)
    }
    // Staged text must not land in the shared cache: a copy of this model keeps the loaded rows.
    // A staged MessagePack or Protobuf value shows its size (it has no cache to decode into).
    if row >= loadedRows.count || isCellEdited(row: row, column: column) {
      return computeDisplay(row: row, column: column)
    }
    if let cached = textCache.display(row: row, column: column) { return cached }
    if let decode = offMainDecode(row: row, column: column) {
      // The size placeholder is not cached: the decoded text replaces it when it lands
      if requestsDecode {
        requestDecode(row: row, column: column, data: decode.data, format: decode.format)
      }
      return computeDisplay(row: row, column: column)
    }
    let display = computeDisplay(row: row, column: column)
    textCache.store(display, row: row, column: column, columnCount: columns.count)
    return display
  }

  /// Decodes the cell off the main actor and stores its text (the size when the bytes do not
  /// decode) unless the cell's format changed or the decode was cancelled meanwhile
  private func requestDecode(row: Int, column: Int, data: Data, format: BinaryDisplayFormat) {
    let marks = marksInvisibleCharacters
    let columnCount = columns.count
    let fallback = CellValue.data(data).displayString
    let cache = textCache
    binaryDecodes.request(
      row: row, column: column, data: data, format: format, limit: Self.maxDisplayLength
    ) { [weak cache] text in
      cache?.store(
        Self.cellDisplay(Self.flattened(text ?? fallback), marks: marks), row: row,
        column: column, columnCount: columnCount)
    }
  }

  /// A MessagePack or Protobuf value shows its size: it is never decoded here
  private func computeDisplay(row: Int, column: Int) -> CellDisplay {
    Self.cellDisplay(flatText(row: row, column: column), marks: marksInvisibleCharacters)
  }

  private static func cellDisplay(_ flat: String, marks: Bool) -> CellDisplay {
    guard marks else { return CellDisplay(text: flat, tooltip: nil) }
    let text = InvisibleCharacters.marked(flat)
    // `marked` returns its argument when nothing is marked
    return CellDisplay(
      text: text, tooltip: text == flat ? nil : InvisibleCharacters.tooltip(for: flat))
  }

  private func flatText(row: Int, column: Int) -> String {
    let value = value(row: row, column: column)
    if case .data(let data) = value, let format = binaryFormats[column],
      !Self.decodesOffMain(format),
      let text = format.text(for: data, limit: Self.maxDisplayLength)
    {
      return Self.flattened(text)
    }
    return Self.flattened(value.displayString)
  }

  /// `text` on one line, at most `maxDisplayLength` characters plus "…"
  private static func flattened(_ text: String) -> String {
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
  /// newline or quote is quoted with quotes doubled, as in CSV. `neutralizesFormulas`
  /// prefixes formula-like text cells as in CSV; other cell types stay raw.
  func tsv(rows: IndexSet, columns: [Int], neutralizesFormulas: Bool) -> String {
    rows.map { row in
      columns.map {
        DataExporter.tsvField(
          value(row: row, column: $0), neutralizesFormulas: neutralizesFormulas)
      }
      .joined(separator: "\t")
    }
    .joined(separator: "\n")
  }

  /// Selected cells in the "Copy rows as" `format`, `columns` (model column indices) in the
  /// given order. TSV is `tsv(rows:columns:neutralizesFormulas:)`; the other formats come from
  /// `DataExporter.copyText`, headers being the column names.
  func copyText(
    rows: IndexSet, columns: [Int], format: CopyRowsFormat, neutralizesFormulas: Bool
  ) -> String {
    if format == .tsv {
      return tsv(rows: rows, columns: columns, neutralizesFormulas: neutralizesFormulas)
    }
    let selected = CellResult(
      columns: columns.map { self.columns[$0] },
      rows: rows.map { row in columns.map { value(row: row, column: $0) } },
      rowCount: rows.count)
    return DataExporter.copyText(
      result: selected, format: format, neutralizesFormulas: neutralizesFormulas)
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

/// Marks for characters a cell would otherwise show as nothing or as a plain space, or that
/// silently reorder the text around them. Line breaks are not marked (the grid shows them as
/// spaces).
/// - A C0 control (U+0000-U+001F, tab included) shows as its Unicode Control Picture
///   (U+2400 + code), DEL as U+2421 SYMBOL FOR DELETE.
/// - A zero-width or format character (U+00AD, U+200B-U+200D, U+2060-U+2064, U+FEFF, a tag
///   U+E0000-U+E007F) shows as U+2422 BLANK SYMBOL.
/// - A special space (U+00A0, U+2000-U+200A, U+202F, U+205F, U+3000, U+3164, U+FFA0) shows as
///   U+2423 OPEN BOX.
/// - A direction control (U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069) shows as U+21C4
///   RIGHTWARDS ARROW OVER LEFTWARDS ARROW; as a mark it no longer reorders the cell text.
/// A joiner (U+200C, U+200D) between two non-ASCII letters, combining marks or emoji belongs to
/// the text (an emoji sequence, a Persian or Indic word) and stays, as do the tags of a
/// well-formed subdivision flag (U+1F3F4 WAVING BLACK FLAG, 2 to 7 tag digits or lowercase
/// letters, U+E007F CANCEL TAG); every other tag is marked. Every mark is one UTF-16 unit
/// (`isMark`).
enum InvisibleCharacters {
  /// Whether `value` is a mark glyph (U+2400-U+2423 or U+21C4)
  static func isMark(_ value: UInt32) -> Bool {
    (0x2400...0x2423).contains(value) || value == 0x21C4
  }

  /// `text` with each invisible character replaced by its mark. Returns `text` itself, with no
  /// allocation, when there is none (a plain ASCII value scans its bytes only).
  static func marked(_ text: String) -> String {
    guard mayContainInvisible(text), text.unicodeScalars.contains(where: isCandidate) else {
      return text
    }
    var result = String.UnicodeScalarView()
    var changed = false
    forEachScalar(in: text) { scalar, marks in
      changed = changed || marks
      result.append(marks ? mark(for: scalar) : scalar)
    }
    return changed ? String(result) : text
  }

  /// "U+200B ZERO WIDTH SPACE" lines for the characters `marked` replaces in `text`, first-seen
  /// order, no repeats. Nil when there is none.
  static func tooltip(for text: String) -> String? {
    guard mayContainInvisible(text), text.unicodeScalars.contains(where: isCandidate) else {
      return nil
    }
    var seen = Set<UInt32>()
    var lines: [String] = []
    forEachScalar(in: text) { scalar, marks in
      guard marks, seen.insert(scalar.value).inserted else { return }
      lines.append("U+\(String(format: "%04X", scalar.value)) \(name(of: scalar))")
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// False only when every byte is printable ASCII
  private static func mayContainInvisible(_ text: String) -> Bool {
    text.utf8.contains { $0 < 0x20 || $0 >= 0x7F }
  }

  /// A character that may be marked; `forEachScalar` keeps a joiner or a tag by its neighbours
  private static func isCandidate(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F, 0xA0, 0xAD, 0x061C, 0x2000...0x200F, 0x202A...0x202F, 0x205F,
      0x2060...0x2064, 0x2066...0x2069, 0x3000, 0x3164, 0xFEFF, 0xFFA0, 0xE0000...0xE007F:
      return true
    default:
      return false
    }
  }

  private static let tags: ClosedRange<UInt32> = 0xE0000...0xE007F

  /// Calls `body` with each scalar of `text` and whether it shows as a mark
  private static func forEachScalar(in text: String, _ body: (Unicode.Scalar, Bool) -> Void) {
    let scalars = Array(text.unicodeScalars)
    // Index of the U+E007F CANCEL TAG that ends the last subdivision flag
    var flagEnd = -1
    for (index, scalar) in scalars.enumerated() {
      var marks = isCandidate(scalar)
      if scalar.value == 0x200C || scalar.value == 0x200D {
        marks =
          !(index > 0 && index + 1 < scalars.count && joins(scalars[index - 1])
          && joins(scalars[index + 1]))
      } else if tags.contains(scalar.value) {
        marks = index > flagEnd
      } else if scalar.value == 0x1F3F4, let end = subdivisionFlagEnd(scalars, flag: index) {
        flagEnd = end
      }
      body(scalar, marks)
    }
  }

  /// Index of the cancel tag when the U+1F3F4 at `flag` starts a subdivision flag: 2 to 7 tag
  /// digits or lowercase letters (U+E0030-U+E0039, U+E0061-U+E007A), then U+E007F CANCEL TAG
  private static func subdivisionFlagEnd(_ scalars: [Unicode.Scalar], flag: Int) -> Int? {
    var end = flag + 1
    while end < scalars.count, end - flag <= 7,
      (0xE0030...0xE0039).contains(scalars[end].value)
        || (0xE0061...0xE007A).contains(scalars[end].value)
    {
      end += 1
    }
    let count = end - flag - 1
    guard (2...7).contains(count), end < scalars.count, scalars[end].value == 0xE007F else {
      return nil
    }
    return end
  }

  /// A non-ASCII letter, combining mark (a virama, a variation selector) or emoji, which a
  /// joiner next to it may belong to
  private static func joins(_ scalar: Unicode.Scalar) -> Bool {
    guard !scalar.isASCII else { return false }
    let properties = scalar.properties
    switch properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
      return true
    default:
      // Skin tone modifiers are emoji too
      return properties.isAlphabetic || properties.isEmoji
    }
  }

  private static func mark(for scalar: Unicode.Scalar) -> Unicode.Scalar {
    let value: UInt32
    switch scalar.value {
    case 0x00...0x1F: value = 0x2400 + scalar.value
    case 0x7F: value = 0x2421
    case 0xAD, 0x200B...0x200D, 0x2060...0x2064, 0xFEFF, 0xE0000...0xE007F: value = 0x2422
    case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: value = 0x21C4
    default: value = 0x2423
    }
    return Unicode.Scalar(value) ?? scalar
  }

  /// Unicode has no name for a control character, so its control picture's name stands in
  /// ("SYMBOL FOR START OF HEADING" gives "START OF HEADING")
  private static func name(of scalar: Unicode.Scalar) -> String {
    if let name = scalar.properties.name { return name }
    let pictureName = mark(for: scalar).properties.name ?? ""
    return pictureName.hasPrefix("SYMBOL FOR ")
      ? String(pictureName.dropFirst("SYMBOL FOR ".count)) : pictureName
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

/// Display text of a cell and the tooltip naming its invisible-character marks
private struct CellDisplay {
  let text: String
  let tooltip: String?
}

/// Per-cell display text of one `ResultGridModel`, filled on first request. A row's array is
/// allocated on first store, so memory stays proportional to the cells actually shown. Main
/// actor only, like the model (the project's default isolation), so no locking is needed.
private final class DisplayTextCache {
  private var rows: [[CellDisplay?]?]

  init(rowCount: Int) {
    rows = Array(repeating: nil, count: rowCount)
  }

  /// Drops the cached text of result column `column` in every row
  func clear(column: Int) {
    for row in rows.indices where rows[row].map({ column < $0.count }) == true {
      rows[row]?[column] = nil
    }
  }

  func display(row: Int, column: Int) -> CellDisplay? {
    guard let cells = rows[row], column < cells.count else { return nil }
    return cells[column]
  }

  func store(_ display: CellDisplay, row: Int, column: Int, columnCount: Int) {
    // A column past the model's columns (a short row shows NULL) is not cached
    guard column < columnCount else { return }
    if rows[row] == nil { rows[row] = Array(repeating: nil, count: columnCount) }
    rows[row]?[column] = display
  }
}

/// Pending off-main decodes of one `ResultGridModel`, at most one per cell. A result lands only
/// while its request is still the cell's pending one: cancelling a row (scrolled away), a
/// column (format changed) or all (new model) removes the request, so a late result is dropped.
/// Main actor only; the decode itself runs on the concurrent pool.
private final class BinaryDecodeQueue {
  private struct Cell: Hashable {
    let row: Int
    let column: Int
  }

  private struct Pending {
    let id: Int
    let format: BinaryDisplayFormat
    let task: Task<Void, Never>
  }

  private var pending: [Cell: Pending] = [:]
  private var nextID = 0
  /// Called with the displayed row and result column once a decoded text is stored
  var onReady: ((_ row: Int, _ column: Int) -> Void)?

  /// Starts decoding a cell unless the same format is already pending for it; `store` receives
  /// the text (nil when the bytes do not decode) on the main actor
  func request(
    row: Int, column: Int, data: Data, format: BinaryDisplayFormat, limit: Int,
    store: @escaping (String?) -> Void
  ) {
    let cell = Cell(row: row, column: column)
    if pending[cell]?.format == format { return }
    pending[cell]?.task.cancel()
    nextID += 1
    let id = nextID
    let task = Task { [weak self] in
      let text = await Self.decode(data, format: format, limit: limit)
      guard let self, self.pending[cell]?.id == id else { return }
      self.pending[cell] = nil
      store(text)
      self.onReady?(row, column)
    }
    pending[cell] = Pending(id: id, format: format, task: task)
  }

  func cancel(row: Int) {
    cancel { $0.row == row }
  }

  func cancel(column: Int) {
    cancel { $0.column == column }
  }

  func cancelAll() {
    cancel { _ in true }
  }

  private func cancel(where matches: (Cell) -> Bool) {
    for cell in pending.keys where matches(cell) {
      pending.removeValue(forKey: cell)?.task.cancel()
    }
  }

  /// A request cancelled before it starts skips the decode
  @concurrent nonisolated static func decode(
    _ data: Data, format: BinaryDisplayFormat, limit: Int
  ) async -> String? {
    guard !Task.isCancelled else { return nil }
    return format.text(for: data, limit: limit)
  }
}
