// LazyCellLoader.swift
// Full values of the large binary cells a lazy data-viewer page cut to
// `DataViewerState.lazyPrefixBytes`. The page's result carries which ones
// (`CellResult.truncation`: full lengths by row key and column, the relation, the key columns
// and the connection it was read on), so every copy of it knows its cut cells, whatever page
// the tab shows now. A cut cell is read alone by its row's primary key:
// `SELECT <quoted column> FROM <page relation> WHERE <k1> = :k1 [AND <k2> = :k2 ...]`, keys bound
// as an edit's WHERE binds them (`RewindCaptureSQL.keyCondition`), checked by
// `ReadOnlyQueryGuard` and sent through the tab's gated read path with named parameters (the one
// a page read takes), pinned to the page's connection, so the value comes back as the same
// binary `CellValue` a page read gives. No row (or more than one) is an error, never the cut
// value. A loaded value replaces the cell and its truncation entry (`replacingCells`), in the
// shown page when it is still the page read in the same generation (`reset()` on every read).
// The Cell Value viewer loads one cell at a time (a request for another cell cancels the older
// one); copies, exports and Duplicate Row load every cut cell they need first, with progress
// and Cancel, up to `bulkLimitBytes` in all, and copy, export or stage nothing when a load
// fails, is cancelled, is over that limit or a cut cell cannot be read. Edits only ever bind
// the user's whole new value: SET lists the edited columns, WHERE the primary key.

import Foundation
import Observation

/// One cut cell of a data-viewer page: its row's primary key values (in
/// `Truncation.keyColumns` order) and its column name
nonisolated struct LazyCell: Hashable, Sendable {
  let row: RowChangeSet.RowKey
  let column: String
}

/// Why a cut cell's full value was not loaded
nonisolated enum LazyCellLoadError: Error, Equatable, LocalizedError {
  /// The row has no usable key (no key columns, a NULL key value), or the tab no connection
  case noKey
  /// No row has the key any more
  case rowMissing
  /// More than one row has the key
  case notUnique
  /// Another copy or export is loading values
  case busy
  /// The page's connection is unknown: the value could come from another database
  case noConnection

  var errorDescription: String? {
    switch self {
    case .noKey: "The row has no primary key value to read the full value by."
    case .rowMissing: "The row is no longer in the table."
    case .notUnique: "More than one row has the row's primary key."
    case .busy: "Values are still loading for another copy or export."
    case .noConnection: "The page's connection is unknown. Reload the table."
    }
  }
}

/// Where the cut cells of a page are read
nonisolated struct LazyCellSource: Sendable {
  /// The quoted relation of the page (`DataViewerState.relation`)
  let relation: String
  /// Primary key columns in row-key order (`Truncation.keyColumns`)
  let keyColumns: [String]
  let dialect: SQLDialect
  /// Runs one guarded read with named parameters on the tab's typed read path
  let read:
    @Sendable (_ sql: String, _ parameters: [String: SQLBindValue]) async throws -> QueryResult
}

@MainActor
@Observable
final class LazyCellLoader {
  /// Cells a copy or export is loading
  struct Progress: Equatable {
    var done: Int
    let total: Int
  }

  /// The cut cell the Cell Value viewer shows, its full length and the truncation it is cut in
  struct ViewerCell {
    let cell: LazyCell
    let length: Int
    let truncation: DataViewerState.Truncation
  }

  /// Most bytes a copy, export or Duplicate Row loads at once (sum of the full lengths)
  static let bulkLimitBytes = 256 * 1024 * 1024

  /// The copy or export loading cells, nil when none is
  private(set) var progress: Progress?
  /// Bumped by `reset()`: a load started before is never written back. Observed: the Cell
  /// Value viewer loads its cut cell again for a new page.
  private(set) var generation = 0
  /// The cut cell the Cell Value viewer shows until loaded: the viewer keeps a value after its
  /// row left the page, and that value is still the cut one
  @ObservationIgnored private(set) var viewerCell: ViewerCell?
  @ObservationIgnored private var viewer: (cell: LazyCell, task: Task<CellValue, Error>)?
  @ObservationIgnored private var bulk: Task<[LazyCell: CellValue], Error>?

  /// A new page was read: forget the viewer's cut cell and stop the copy or export loading
  /// (the viewer load goes on, its cell is read by key). The caller notes the viewer's cell
  /// again when it still shows it cut.
  func reset() {
    generation += 1
    viewerCell = nil
    bulk?.cancel()
    bulk = nil
    progress = nil
  }

  /// Cancel of the progress bar: the copy or export loading stops and copies nothing
  func cancelLoading() {
    bulk?.cancel()
  }

  // MARK: - Read

  /// The read of `cell`'s full value, refused before sending when the key cannot be bound
  nonisolated static func statement(
    _ cell: LazyCell, source: LazyCellSource
  ) throws -> (sql: String, parameters: [String: SQLBindValue]) {
    // `= NULL` matches nothing
    guard !cell.row.values.contains(where: \.isNull) else { throw LazyCellLoadError.noKey }
    let condition: (sql: String, values: [String?])
    do {
      condition = try RewindCaptureSQL.keyCondition(
        keys: source.keyColumns, keyValues: cell.row.values, dialect: source.dialect,
        placeholder: { ":k\($0)" })
    } catch RewindCaptureError.noPrimaryKey {
      throw LazyCellLoadError.noKey
    }
    var parameters: [String: SQLBindValue] = [:]
    for (index, value) in condition.values.enumerated() {
      parameters["k\(index + 1)"] = SQLBindValue(optionalText: value)
    }
    let column = try source.dialect.quoteIdentifier(cell.column)
    return ("SELECT \(column) FROM \(source.relation) WHERE \(condition.sql)", parameters)
  }

  /// `cell`'s full value as the read returns it. `@concurrent` leaves the main actor.
  @concurrent nonisolated static func load(
    _ cell: LazyCell, source: LazyCellSource
  ) async throws -> CellValue {
    let read = try statement(cell, source: source)
    _ = try ReadOnlyQueryGuard.check(read.sql, dialect: source.dialect)
    let result = try await source.read(read.sql, read.parameters)
    guard let row = result.rows.first else { throw LazyCellLoadError.rowMissing }
    guard result.rows.count == 1, row.count == 1 else { throw LazyCellLoadError.notUnique }
    return row[0]
  }

  // MARK: - Cell Value viewer

  /// Records that the viewer shows `cell` cut, `length` bytes in full, in `truncation`. The
  /// viewer shows one cell, so only the latest is kept.
  func noteViewerCell(
    _ cell: LazyCell, length: Int, truncation: DataViewerState.Truncation
  ) {
    viewerCell = ViewerCell(cell: cell, length: length, truncation: truncation)
  }

  /// The Cell Value viewer's load of `cell`. A request for another cell cancels this one (it
  /// throws `CancellationError`, even when its read already returned); a request for the same
  /// cell joins it. The caller writes the value into the page.
  func value(for cell: LazyCell, source: LazyCellSource) async throws -> CellValue {
    let task: Task<CellValue, Error>
    if let current = viewer, current.cell == cell, !current.task.isCancelled {
      task = current.task
    } else {
      viewer?.task.cancel()
      task = Task { try await Self.load(cell, source: source) }
      viewer = (cell, task)
    }
    let value: CellValue
    do {
      value = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch {
      // A failed read is not joined again: the next request reads anew
      if viewer?.task == task { viewer = nil }
      throw error
    }
    if viewer?.task == task { viewer = nil }
    guard !task.isCancelled else { throw CancellationError() }
    if viewerCell?.cell == cell { viewerCell = nil }
    return value
  }

  // MARK: - Copy and export

  /// Full values of `cells` for a copy or export, read one by one with `progress`. Cancel
  /// (`cancelLoading`), a page read meanwhile or a failed read throws: nothing is returned.
  /// Refused while another copy or export loads (`LazyCellLoadError.busy`). The caller writes
  /// the values into the page; none is kept here.
  func values(for cells: [LazyCell], source: LazyCellSource) async throws -> [LazyCell: CellValue] {
    let missing = Array(Set(cells))
    guard !missing.isEmpty else { return [:] }
    guard bulk == nil else { throw LazyCellLoadError.busy }
    let generation = generation
    progress = Progress(done: 0, total: missing.count)
    let task = Task { [weak self] in
      var values: [LazyCell: CellValue] = [:]
      for cell in missing {
        try Task.checkCancellation()
        values[cell] = try await Self.load(cell, source: source)
        self?.progress?.done += 1
      }
      return values
    }
    bulk = task
    defer {
      // `reset()` may have cleared it, and another load started since
      if bulk == task {
        bulk = nil
        progress = nil
      }
    }
    let values = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    guard !task.isCancelled, generation == self.generation else { throw CancellationError() }
    return values
  }
}

// MARK: - Result rows

extension CellResult {
  /// Row key of `row` (values of `columns`) in `keyColumns` order; nil when a key column is
  /// missing
  nonisolated func rowKey(_ row: [CellValue], keyColumns: [String]) -> RowChangeSet.RowKey? {
    var values: [CellValue] = []
    for key in keyColumns {
      guard let index = columns.firstIndex(where: { $0.name == key }), index < row.count else {
        return nil
      }
      values.append(row[index])
    }
    return values.isEmpty ? nil : RowChangeSet.RowKey(values: values)
  }

  /// This result with the cells of `values` (row index into `rows`, then column index)
  /// replaced by their full values, every other field kept (session-only ones too); each
  /// replaced cell leaves the truncation
  func replacingCells(_ values: [Int: [Int: CellValue]]) -> CellResult {
    guard !values.isEmpty else { return self }
    var rows = rows
    var truncation = truncation
    for (row, cells) in values where rows.indices.contains(row) {
      let key = truncation.flatMap { rowKey(rows[row], keyColumns: $0.keyColumns) }
      for (column, value) in cells where rows[row].indices.contains(column) {
        rows[row][column] = value
        if let key, columns.indices.contains(column) {
          truncation?.lengths[key]?[columns[column].name] = nil
          if truncation?.lengths[key]?.isEmpty == true { truncation?.lengths[key] = nil }
        }
      }
    }
    var replaced = CellResult(
      columns: columns, rows: rows, executionTime: executionTime, rowCount: rowCount,
      timestamp: timestamp, error: error, wasLimited: wasLimited, sourceQuery: sourceQuery,
      tableName: tableName, primaryKeyColumns: primaryKeyColumns, affectedRows: affectedRows,
      editTarget: editTarget, lookupRelation: lookupRelation, aiSessionKey: aiSessionKey)
    replaced.sessionReset = sessionReset
    replaced.skippedStatements = skippedStatements
    replaced.skippedQueuedCells = skippedQueuedCells
    replaced.dataRevision = dataRevision
    replaced.truncation = truncation
    return replaced
  }
}

// MARK: - The tab's lazy cells

extension NotebookViewModel {
  /// Where the cut cells of `truncation` are read: its relation and key, through the tab's
  /// gated read path, pinned to the connection the page was read on (a reconnect may reach
  /// another database with the same table and keys). Throws without a connection, relation or
  /// key columns (`noKey`), or without the page's connection (`noConnection`).
  func lazyCellSource(for truncation: DataViewerState.Truncation) throws -> LazyCellSource {
    guard let connectionManager, !truncation.keyColumns.isEmpty, !truncation.relation.isEmpty
    else { throw LazyCellLoadError.noKey }
    guard let epoch = truncation.connectionEpoch else { throw LazyCellLoadError.noConnection }
    let policy = protectionPolicy
    let caller = id
    return LazyCellSource(
      relation: truncation.relation, keyColumns: truncation.keyColumns,
      dialect: truncation.dialect
    ) { sql, parameters in
      try await connectionManager.execute(
        userSQL: sql, parameters: parameters, policy: policy, maxRows: 2, caller: caller,
        expectedEpoch: epoch)
    }
  }

  /// The truncation `result` carries, nil for an error or a result with no cut value
  private func truncation(of result: CellResult) -> DataViewerState.Truncation? {
    guard result.error == nil, let truncation = result.truncation, !truncation.lengths.isEmpty
    else { return nil }
    return truncation
  }

  /// Resets the loader for a page read, before the new page is shown, keeping the Cell Value
  /// viewer's cut cell (its value stays cut even once its row left the page)
  func resetLazyCells() {
    let sidebar = unloadedSidebarCell
    let truncation = sidebar.flatMap { sidebarTruncation(for: $0.cell) }
    lazyCells.reset()
    if let sidebar, let truncation {
      lazyCells.noteViewerCell(sidebar.cell, length: sidebar.length, truncation: truncation)
    }
  }

  /// The cut cell of `row` (values of `result`'s columns) at `column` with its full byte
  /// length, or nil when that value is whole (or already loaded). An unloaded value must never
  /// be copied, exported or written.
  func unloadedCell(
    row: [CellValue], column: String, in result: CellResult
  ) -> (cell: LazyCell, length: Int)? {
    guard let truncation = truncation(of: result),
      let key = result.rowKey(row, keyColumns: truncation.keyColumns),
      let length = truncation.lengths[key]?[column]
    else { return nil }
    return (LazyCell(row: key, column: column), length)
  }

  /// The unloaded cells of `result` by row index (into `rows`) and column index, with their
  /// full byte length; empty for a result with no cut value
  func unloadedCells(in result: CellResult) -> [Int: [Int: Int]] {
    guard let truncation = truncation(of: result) else { return [:] }
    let columnIndex = Dictionary(
      result.columns.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
    var cells: [Int: [Int: Int]] = [:]
    for (index, row) in result.rows.enumerated() {
      guard let key = result.rowKey(row, keyColumns: truncation.keyColumns),
        let lengths = truncation.lengths[key]
      else { continue }
      for (name, length) in lengths {
        if let column = columnIndex[name] { cells[index, default: [:]][column] = length }
      }
    }
    return cells
  }

  /// True when `result` holds cut values
  func hasUnloadedCells(in result: CellResult) -> Bool {
    truncation(of: result) != nil
  }

  /// Full values of the cells at `cells` (row index into `result.rows`, column index) that are
  /// cut, by row and column index: loaded first (progress and Cancel), then written into the
  /// shown page when it is the same page. Nil, after a message naming `action`, when a load
  /// fails, is cancelled or would load more than `LazyCellLoader.bulkLimitBytes`: the caller
  /// copies, exports or stages nothing.
  func loadUnloadedCells(
    _ cells: [(row: Int, column: Int)], of result: CellResult, action: String
  ) async -> [Int: [Int: CellValue]]? {
    guard let truncation = truncation(of: result) else { return [:] }
    let unloaded = unloadedCells(in: result)
    var wanted: [(row: Int, column: Int, cell: LazyCell)] = []
    var bytes = 0
    for (row, column) in cells
    where result.rows.indices.contains(row) && result.columns.indices.contains(column) {
      guard let length = unloaded[row]?[column],
        let key = result.rowKey(result.rows[row], keyColumns: truncation.keyColumns)
      else { continue }
      bytes += length
      wanted.append((row, column, LazyCell(row: key, column: result.columns[column].name)))
    }
    guard !wanted.isEmpty else { return [:] }
    guard bytes <= LazyCellLoader.bulkLimitBytes else {
      let limit = ByteCountFormatter.string(
        fromByteCount: Int64(LazyCellLoader.bulkLimitBytes), countStyle: .binary)
      let total = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
      showToast(
        "\(action) refused: the full values to load total \(total), over the \(limit) limit."
          + " Select fewer rows.", type: .error)
      return nil
    }
    let generation = lazyCells.generation
    let values: [LazyCell: CellValue]
    do {
      let source = try lazyCellSource(for: truncation)
      values = try await lazyCells.values(for: wanted.map(\.cell), source: source)
    } catch is CancellationError {
      showToast(
        "\(action) cancelled before the full values loaded.", type: .info)
      return nil
    } catch {
      showToast(
        "\(action) refused: a full value could not be loaded (\(error.localizedDescription)).",
        type: .error)
      return nil
    }
    var loaded: [Int: [Int: CellValue]] = [:]
    for (row, column, cell) in wanted {
      guard let value = values[cell] else { return nil }
      loaded[row, default: [:]][column] = value
    }
    storeLoadedValues(values, of: truncation, generation: generation)
    return loaded
  }

  /// `result` with every cut cell loaded (`loadUnloadedCells`), or nil when one could not be
  /// loaded. A result with no cut cell comes back at once.
  func fullyLoadedResult(_ result: CellResult, action: String) async -> CellResult? {
    guard hasUnloadedCells(in: result) else { return result }
    let cells = result.rows.indices.flatMap { row in
      result.columns.indices.map { (row: row, column: $0) }
    }
    guard let values = await loadUnloadedCells(cells, of: result, action: action) else {
      return nil
    }
    let loaded = result.replacingCells(values)
    // A cut cell that could not be matched to its row is never copied as whole
    guard !hasUnloadedCells(in: loaded) else {
      showToast("\(action) refused: a full value could not be loaded.", type: .error)
      return nil
    }
    return loaded
  }

  /// Writes values loaded for cut cells of `truncation` into the shown page when it is the
  /// same page (same relation, key, connection and loader generation) and still has them cut;
  /// the sidebar cell and row are re-read from the page
  private func storeLoadedValues(
    _ values: [LazyCell: CellValue], of truncation: DataViewerState.Truncation,
    generation: Int
  ) {
    guard generation == lazyCells.generation, !values.isEmpty, let result = editorResult,
      let shown = self.truncation(of: result), shown.relation == truncation.relation,
      shown.keyColumns == truncation.keyColumns,
      shown.connectionEpoch == truncation.connectionEpoch
    else { return }
    var replaced: [Int: [Int: CellValue]] = [:]
    for (index, row) in result.rows.enumerated() {
      guard let key = result.rowKey(row, keyColumns: shown.keyColumns),
        let lengths = shown.lengths[key]
      else { continue }
      for name in lengths.keys {
        guard let value = values[LazyCell(row: key, column: name)],
          let column = result.columns.firstIndex(where: { $0.name == name })
        else { continue }
        replaced[index, default: [:]][column] = value
      }
    }
    guard !replaced.isEmpty else { return }
    var updated = result.replacingCells(replaced)
    // Same run, new values: views keyed on the rows of a run rebuild
    updated.dataRevision = result.dataRevision + 1
    editorResult = updated
    syncCellDetail(cellId: nil, result: updated)
    syncRowDetail(cellId: nil, result: updated)
  }

  /// `rows` (of `result`, at most `limit`) with each cut cell replaced by its not-loaded text,
  /// so a reader of the text (the AI's `@results`) never takes a prefix for the whole value
  func rowsMarkingUnloadedCells(of result: CellResult, limit: Int) -> [[CellValue]] {
    var rows = Array(result.rows.prefix(limit))
    for (row, columns) in unloadedCells(in: result) where row < rows.count {
      for (column, length) in columns where column < rows[row].count {
        rows[row][column] = .string(ResultGridModel.notLoadedText(length: length))
      }
    }
    return rows
  }

  // MARK: - Cell Value viewer

  /// The Cell Value sidebar's cell when it is cut, with its full byte length: a cut cell of
  /// the shown page, or the one the viewer showed cut and has not loaded yet (its row may have
  /// left the page). Nil for a whole value.
  var unloadedSidebarCell: (cell: LazyCell, length: Int)? {
    guard case .cellInfo(let column, _, _, _, let rowData?, _, .none) = rightSidebarContent
    else { return nil }
    if let truncation = editorResult.flatMap({ truncation(of: $0) }),
      let key = Self.key(of: rowData, keyColumns: truncation.keyColumns),
      let length = truncation.lengths[key]?[column]
    {
      return (LazyCell(row: key, column: column), length)
    }
    if let viewer = lazyCells.viewerCell, viewer.cell.column == column,
      Self.key(of: rowData, keyColumns: viewer.truncation.keyColumns) == viewer.cell.row
    {
      return (viewer.cell, viewer.length)
    }
    return nil
  }

  /// The truncation `cell` (the sidebar's) is cut in: the shown page's, else the viewer's
  private func sidebarTruncation(for cell: LazyCell) -> DataViewerState.Truncation? {
    if let truncation = editorResult.flatMap({ truncation(of: $0) }),
      truncation.lengths[cell.row]?[cell.column] != nil
    {
      return truncation
    }
    if let viewer = lazyCells.viewerCell, viewer.cell == cell { return viewer.truncation }
    return nil
  }

  /// Loads the sidebar's cut cell off the main actor and shows it in the sidebar (and the
  /// page). Returns the failure message, nil when loaded or cancelled by a newer request.
  func loadSidebarCell(_ cell: LazyCell, length: Int) async -> String? {
    guard let truncation = sidebarTruncation(for: cell) else {
      return LazyCellLoadError.noKey.localizedDescription
    }
    lazyCells.noteViewerCell(cell, length: length, truncation: truncation)
    let generation = lazyCells.generation
    do {
      let source = try lazyCellSource(for: truncation)
      let value = try await lazyCells.value(for: cell, source: source)
      storeLoadedValues([cell: value], of: truncation, generation: generation)
      // A row that left the page keeps its sidebar value: replace it there
      if case .cellInfo(
        let column, let type, _, let table, var rowData?, let keys, .none) = rightSidebarContent,
        column == cell.column,
        Self.key(of: rowData, keyColumns: truncation.keyColumns) == cell.row
      {
        rowData[column] = value
        rightSidebarContent = .cellInfo(
          columnName: column, columnType: type, value: value, tableName: table, rowData: rowData,
          primaryKeyColumns: keys, cellId: nil)
      }
      return nil
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  /// Row key of the sidebar's `rowData` in `keyColumns` order
  private static func key(
    of rowData: [String: CellValue], keyColumns: [String]
  ) -> RowChangeSet.RowKey? {
    guard !keyColumns.isEmpty else { return nil }
    var values: [CellValue] = []
    for key in keyColumns {
      guard let value = rowData[key] else { return nil }
      values.append(value)
    }
    return RowChangeSet.RowKey(values: values)
  }
}
