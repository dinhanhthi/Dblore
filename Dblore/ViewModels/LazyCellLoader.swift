// LazyCellLoader.swift
// Full values of the large binary and text cells a lazy data-viewer page cut to
// `DataViewerState.lazyPrefixBytes` bytes or `lazyPrefixCharacters` characters (lengths in
// bytes, UTF-8 for text). The page's result carries which ones
// (`CellResult.truncation`: full lengths by row key and column, the relation, the key columns
// and the connection it was read on), so every copy of it knows its cut cells, whatever page
// the tab shows now. A cut cell is read alone by its row's primary key:
// `SELECT <quoted column> FROM <page relation> WHERE <k1> = :k1 [AND <k2> = :k2 ...]`, keys bound
// as an edit's WHERE binds them (`RewindCaptureSQL.keyCondition`); a keyless table's row by the
// locator its page read for it (`RowLocatorKind.terms`, the edit's own WHERE), checked by
// `ReadOnlyQueryGuard` and sent through the tab's gated read path with named parameters (the one
// a page read takes), pinned to the page's connection, so the value comes back as the same
// `CellValue` a plain read gives. No row (or more than one) is an error, never the cut
// value; so is a value that is not the page's full length or does not start with the page's
// prefix (a reused SQLite rowid, a VACUUM, another writer: the key now names other bytes). A
// loaded value replaces the cell and its truncation entry (`replacingCells`), in the
// shown page when it is still the page read in the same generation (`reset()` on every read).
// The Cell Value viewer loads one cell at a time (a request for another cell cancels the older
// one); copies, exports and Duplicate Row load every cut cell they need first, with progress
// and Cancel, up to `bulkLimitBytes` in all, and copy, export or stage nothing when a load
// fails, is cancelled, is over that limit or a cut cell cannot be read. Edits only ever bind
// the user's whole new value: SET lists the edited columns, WHERE the primary key (or locator).
// Cells an editor or notebook read cut at the app's cell limit (`CellResult.cutCells`) count
// as unloaded too, but are never loaded: a copy, export, pin or Duplicate Row that includes one
// is refused (`cutCellsMessage`).

import Foundation
import Observation

/// One cut cell of a data-viewer page: its row's primary key values (in
/// `Truncation.keyColumns` order), or a keyless row's locator key, and its column name
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
  /// The value read is not the page's full length or does not start with the page's prefix
  case rowChanged

  var errorDescription: String? {
    switch self {
    case .noKey: "The row has no primary key value to read the full value by."
    case .rowMissing: "The row is no longer in the table."
    case .notUnique: "More than one row has the row's primary key."
    case .busy: "Values are still loading for another copy or export."
    case .noConnection: "The page's connection is unknown. Reload the table."
    case .rowChanged: "The row changed since it was read, reload the data."
    }
  }
}

/// What the page read of a cut value: its full byte length (UTF-8 for text) and its first
/// bytes or characters. A full value read later must match both, or it is another row's (or a
/// changed) value.
nonisolated struct LazyCellExpectation: Sendable {
  /// The cut value the page read
  enum Prefix: Sendable {
    case bytes(Data)
    case text(String)
  }

  let length: Int
  let prefix: Prefix

  /// The expectation of a cut cell whose page value is `cut`, nil when that is not bytes or text
  init?(length: Int, cut: CellValue) {
    switch cut {
    case .data(let prefix): self.prefix = .bytes(prefix)
    case .string(let prefix): self.prefix = .text(prefix)
    default: return nil
    }
    self.length = length
  }

  /// True when `value` is the full value: bytes of `length` bytes, or text (a JSON value by its
  /// text) of `length` UTF-8 bytes, starting with the prefix. Text compares Unicode scalars,
  /// never characters: a prefix may end inside a grapheme, and a canonically equivalent text
  /// is another value.
  func matches(_ value: CellValue) -> Bool {
    switch (prefix, value) {
    case (.bytes(let prefix), .data(let full)):
      full.count == length && full.starts(with: prefix)
    case (.text(let prefix), .string(let full)), (.text(let prefix), .json(let full)):
      full.utf8.count == length && full.unicodeScalars.starts(with: prefix.unicodeScalars)
    default: false
    }
  }
}

/// Where the cut cells of a page are read
nonisolated struct LazyCellSource: Sendable {
  /// The quoted relation of the page (`DataViewerState.relation`)
  let relation: String
  /// Primary key columns in row-key order (`Truncation.keyColumns`), empty for a keyless page
  let keyColumns: [String]
  let dialect: SQLDialect
  /// A keyless page's locator kind (`Truncation.rowLocator`): rows are read by their locator
  var rowLocator: RowLocatorKind? = nil
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

  /// The read of `cell`'s full value, refused before sending when the key cannot be bound. A
  /// locator source names the row as an edit does (`RowLocatorKind.terms`: PostgreSQL
  /// `tableoid`, `ctid` and `xmin` with their casts, SQLite the rowid and its `IS` terms), never
  /// by the hidden `dblore_*` aliases.
  nonisolated static func statement(
    _ cell: LazyCell, source: LazyCellSource
  ) throws -> (sql: String, parameters: [String: SQLBindValue]) {
    let condition: (sql: String, values: [String?])
    if let kind = source.rowLocator {
      condition = try locatorCondition(cell.row, kind: kind, dialect: source.dialect)
    } else {
      // `= NULL` matches nothing
      guard !cell.row.values.contains(where: \.isNull) else { throw LazyCellLoadError.noKey }
      do {
        condition = try RewindCaptureSQL.keyCondition(
          keys: source.keyColumns, keyValues: cell.row.values, dialect: source.dialect,
          placeholder: { ":k\($0)" })
      } catch RewindCaptureError.noPrimaryKey {
        throw LazyCellLoadError.noKey
      }
    }
    var parameters: [String: SQLBindValue] = [:]
    for (index, value) in condition.values.enumerated() {
      parameters["k\(index + 1)"] = SQLBindValue(optionalText: value)
    }
    let column = try source.dialect.quoteIdentifier(cell.column)
    return ("SELECT \(column) FROM \(source.relation) WHERE \(condition.sql)", parameters)
  }

  /// The WHERE naming the row `row` locates (`:k1`, `:k2`, ... in term order), each term bound
  /// as `CellUpdateStatement.make` binds it; `noKey` when the key carries no locator of `kind`
  private nonisolated static func locatorCondition(
    _ row: RowChangeSet.RowKey, kind: RowLocatorKind, dialect: SQLDialect
  ) throws -> (sql: String, values: [String?]) {
    guard let locator = row.locator, let terms = kind.terms(locator, dialect: dialect) else {
      throw LazyCellLoadError.noKey
    }
    var conditions: [String] = []
    var values: [String?] = []
    for (index, term) in terms.enumerated() {
      let placeholder = CellUpdateStatement.bindPlaceholder(
        ":k\(index + 1)", term.value, dialect: dialect)
      conditions.append(term.lead + placeholder + term.trail)
      values.append(CellUpdateStatement.inputText(term.value, dialect: dialect))
    }
    return (conditions.joined(separator: " AND "), values)
  }

  /// `cell`'s full value as the read returns it. With `expected` (the page's full length and
  /// prefix of the cut value), a value of another length or prefix throws `rowChanged`: the key
  /// or locator now names other bytes. `@concurrent` leaves the main actor.
  @concurrent nonisolated static func load(
    _ cell: LazyCell, source: LazyCellSource, expected: LazyCellExpectation? = nil
  ) async throws -> CellValue {
    let read = try statement(cell, source: source)
    _ = try ReadOnlyQueryGuard.check(read.sql, dialect: source.dialect)
    let result = try await source.read(read.sql, read.parameters)
    guard let row = result.rows.first else { throw LazyCellLoadError.rowMissing }
    guard result.rows.count == 1, row.count == 1 else { throw LazyCellLoadError.notUnique }
    if let expected, !expected.matches(row[0]) { throw LazyCellLoadError.rowChanged }
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
  /// cell joins it. `expected` checks the value read (`load`). The caller writes the value into
  /// the page.
  func value(
    for cell: LazyCell, source: LazyCellSource, expected: LazyCellExpectation? = nil
  ) async throws -> CellValue {
    let task: Task<CellValue, Error>
    if let current = viewer, current.cell == cell, !current.task.isCancelled {
      task = current.task
    } else {
      viewer?.task.cancel()
      task = Task { try await Self.load(cell, source: source, expected: expected) }
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
  /// Refused while another copy or export loads (`LazyCellLoadError.busy`). Each value read is
  /// checked against its cell's `expected` (`load`). The caller writes the values into the
  /// page; none is kept here.
  func values(
    for cells: [LazyCell], source: LazyCellSource,
    expected: [LazyCell: LazyCellExpectation] = [:]
  ) async throws -> [LazyCell: CellValue] {
    let missing = Array(Set(cells))
    guard !missing.isEmpty else { return [:] }
    guard bulk == nil else { throw LazyCellLoadError.busy }
    let generation = generation
    progress = Progress(done: 0, total: missing.count)
    let task = Task { [weak self] in
      var values: [LazyCell: CellValue] = [:]
      for cell in missing {
        try Task.checkCancellation()
        values[cell] = try await Self.load(cell, source: source, expected: expected[cell])
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
  /// Row key of `rows[row]` in `truncation`: a keyless page's locator of that page row
  /// (`Truncation.locators`, never matched by values), else the row's values of
  /// `truncation.keyColumns` in that order; nil when a key column or the row is missing
  nonisolated func rowKey(
    at row: Int, in truncation: DataViewerState.Truncation
  ) -> RowChangeSet.RowKey? {
    if let kind = truncation.rowLocator { return truncation.locatorKey(row: row, kind: kind) }
    guard rows.indices.contains(row) else { return nil }
    var values: [CellValue] = []
    for key in truncation.keyColumns {
      guard let index = columns.firstIndex(where: { $0.name == key }), index < rows[row].count
      else { return nil }
      values.append(rows[row][index])
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
      let key = truncation.flatMap { rowKey(at: row, in: $0) }
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
    replaced.typesPending = typesPending
    replaced.cutCells = cutCells
    replaced.stoppedAtByteBudget = stoppedAtByteBudget
    return replaced
  }
}

// MARK: - The tab's lazy cells

extension NotebookViewModel {
  /// Where the cut cells of `truncation` are read: its relation and key, through the tab's
  /// gated read path, pinned to the connection the page was read on (a reconnect may reach
  /// another database with the same table and keys). A keyless page's rows are read by their
  /// locator (`Truncation.rowLocator`). Throws without a connection, relation, or key columns
  /// or locator (`noKey`), or without the page's connection (`noConnection`).
  func lazyCellSource(for truncation: DataViewerState.Truncation) throws -> LazyCellSource {
    guard let connectionManager, !truncation.relation.isEmpty,
      !truncation.keyColumns.isEmpty || truncation.rowLocator != nil
    else { throw LazyCellLoadError.noKey }
    guard let epoch = truncation.connectionEpoch else { throw LazyCellLoadError.noConnection }
    let policy = protectionPolicy
    let caller = id
    return LazyCellSource(
      relation: truncation.relation, keyColumns: truncation.keyColumns,
      dialect: truncation.dialect, rowLocator: truncation.rowLocator
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

  /// The unloaded cells of `result` by row index (into `rows`) and column index, with their
  /// full byte length (a cell the capped read cut, `cutCells(in:)`: its kept length); empty for
  /// a result with no cut value
  func unloadedCells(in result: CellResult) -> [Int: [Int: Int]] {
    var cells = cutCells(in: result)
    guard let truncation = truncation(of: result) else { return cells }
    let columnIndex = Dictionary(
      result.columns.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
    for index in result.rows.indices {
      guard let key = result.rowKey(at: index, in: truncation),
        let lengths = truncation.lengths[key]
      else { continue }
      for (name, length) in lengths {
        if let column = columnIndex[name] { cells[index, default: [:]][column] = length }
      }
    }
    return cells
  }

  /// The cells of `result` the capped read cut (`CellResult.cutCells`) by row index and column
  /// index, with the byte length they kept (UTF-8 for text); empty for an error. They are never
  /// loaded: the read kept only their prefix.
  func cutCells(in result: CellResult) -> [Int: [Int: Int]] {
    guard result.error == nil else { return [:] }
    var cells: [Int: [Int: Int]] = [:]
    for position in result.cutCells
    where result.rows.indices.contains(position.row)
      && result.columns.indices.contains(position.column)
      && result.rows[position.row].indices.contains(position.column)
    {
      let kept =
        switch result.rows[position.row][position.column] {
        case .string(let text), .json(let text), .decimal(let text): text.utf8.count
        case .data(let data): data.count
        case let value: value.fullString.utf8.count
        }
      cells[position.row, default: [:]][position.column] = kept
    }
    return cells
  }

  /// True when `result` holds cut values (of a lazy page or the capped read)
  func hasUnloadedCells(in result: CellResult) -> Bool {
    truncation(of: result) != nil || !cutCells(in: result).isEmpty
  }

  /// Why a copy, export, pin or write of cells including `count` cells the capped read cut is
  /// refused
  nonisolated static func cutCellsMessage(count: Int) -> String {
    let limit = "\(CappedReadLimits.app.maxCellCharacters / 1_048_576) MiB"
    return count == 1
      ? "1 value in this selection was cut at \(limit), so it cannot be copied whole."
      : "\(count) values in this selection were cut at \(limit), so they cannot be copied whole."
  }

  /// Full values of the cells at `cells` (row index into `result.rows`, column index) that are
  /// cut, by row and column index: loaded first (progress and Cancel), then written into the
  /// shown page when it is the same page. Nil, after a message naming `action`, when a cell
  /// the capped read cut is among them (it cannot be loaded), a load fails, is cancelled, would
  /// load more than `LazyCellLoader.bulkLimitBytes` or reads a value that is not the page's
  /// (`LazyCellLoadError.rowChanged`): the caller copies, exports or stages nothing, and
  /// nothing is stored.
  func loadUnloadedCells(
    _ cells: [(row: Int, column: Int)], of result: CellResult, action: String
  ) async -> [Int: [Int: CellValue]]? {
    let cut = cutCells(in: result)
    let cutCount = Set(
      cells.lazy.filter { cut[$0.row]?[$0.column] != nil }
        .map { CellPosition(row: $0.row, column: $0.column) }
    ).count
    guard cutCount == 0 else {
      showToast("\(action) refused: \(Self.cutCellsMessage(count: cutCount))", type: .error)
      return nil
    }
    guard let truncation = truncation(of: result) else { return [:] }
    let unloaded = unloadedCells(in: result)
    var wanted: [(row: Int, column: Int, cell: LazyCell)] = []
    var expected: [LazyCell: LazyCellExpectation] = [:]
    var bytes = 0
    for (row, column) in cells
    where result.rows.indices.contains(row) && result.columns.indices.contains(column) {
      guard let length = unloaded[row]?[column], let key = result.rowKey(at: row, in: truncation)
      else { continue }
      bytes += length
      let cell = LazyCell(row: key, column: result.columns[column].name)
      // A cut value that is not bytes or text cannot be checked: never loaded as whole
      guard let expectation = LazyCellExpectation(length: length, cut: result.rows[row][column])
      else {
        showToast("\(action) refused: \(Self.keylessRowChangedMessage).", type: .error)
        return nil
      }
      expected[cell] = expectation
      wanted.append((row, column, cell))
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
      values = try await lazyCells.values(
        for: wanted.map(\.cell), source: source, expected: expected)
    } catch is CancellationError {
      showToast(
        "\(action) cancelled before the full values loaded.", type: .info)
      return nil
    } catch LazyCellLoadError.rowChanged {
      showToast("\(action) refused: \(Self.keylessRowChangedMessage).", type: .error)
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
  /// same page (same relation, key or locator kind, connection and loader generation) and still
  /// has them cut; the sidebar cell and row are re-read from the page
  private func storeLoadedValues(
    _ values: [LazyCell: CellValue], of truncation: DataViewerState.Truncation,
    generation: Int
  ) {
    guard generation == lazyCells.generation, !values.isEmpty, let result = editorResult,
      let shown = self.truncation(of: result), shown.relation == truncation.relation,
      shown.keyColumns == truncation.keyColumns, shown.rowLocator == truncation.rowLocator,
      shown.connectionEpoch == truncation.connectionEpoch
    else { return }
    var replaced: [Int: [Int: CellValue]] = [:]
    for index in result.rows.indices {
      guard let key = result.rowKey(at: index, in: shown),
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
      let key = sidebarKey(of: rowData, in: truncation),
      let length = truncation.lengths[key]?[column]
    {
      return (LazyCell(row: key, column: column), length)
    }
    if let viewer = lazyCells.viewerCell, viewer.cell.column == column,
      sidebarKey(of: rowData, in: viewer.truncation) == viewer.cell.row
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
  /// page). Returns the failure message, nil when loaded or cancelled by a newer request. The
  /// value read must be `length` bytes starting with the sidebar's cut prefix, else nothing is
  /// stored (`LazyCellLoadError.rowChanged`).
  func loadSidebarCell(_ cell: LazyCell, length: Int) async -> String? {
    guard let truncation = sidebarTruncation(for: cell) else {
      return LazyCellLoadError.noKey.localizedDescription
    }
    guard case .cellInfo(let column, _, let cut, _, _?, _, .none) = rightSidebarContent,
      column == cell.column, let expected = LazyCellExpectation(length: length, cut: cut)
    else { return LazyCellLoadError.rowChanged.localizedDescription }
    lazyCells.noteViewerCell(cell, length: length, truncation: truncation)
    let generation = lazyCells.generation
    do {
      let source = try lazyCellSource(for: truncation)
      let value = try await lazyCells.value(for: cell, source: source, expected: expected)
      storeLoadedValues([cell: value], of: truncation, generation: generation)
      // A row that left the page keeps its sidebar value: replace it there
      if case .cellInfo(
        let column, let type, _, let table, var rowData?, let keys, .none) = rightSidebarContent,
        column == cell.column, sidebarKey(of: rowData, in: truncation) == cell.row
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

  // MARK: - Row Details

  /// Loads the cut text values of the Row Details row (shown "Loading full value…", read-only)
  /// one by one through the viewer's read (a newer request cancels it), each checked against
  /// the page's prefix, and writes them into the shown page, which re-reads the panel
  /// (`syncRowDetail`): its fields then hold the full values and can be edited; drafts typed
  /// meanwhile stay. A cut binary value stays not loaded. Returns the failure message (the
  /// fields stay read-only), nil when loaded, cancelled or nothing is cut.
  func loadRowDetailCells() async -> String? {
    guard case .rowDetail(nil) = rightSidebarContent, let state = rowDetail,
      state.stagedInsertID == nil, let result = editorResult,
      let truncation = truncation(of: result), result.rows.indices.contains(state.originalRow),
      let key = result.rowKey(at: state.originalRow, in: truncation),
      sidebarKey(of: state.rowData, in: truncation) == key
    else { return nil }
    let row = result.rows[state.originalRow]
    var cells: [(cell: LazyCell, expected: LazyCellExpectation)] = []
    for field in state.fields where field.unloadedLength != nil {
      guard case .string = field.original, let length = truncation.lengths[key]?[field.name],
        let column = result.columns.firstIndex(where: { $0.name == field.name }),
        column < row.count, row[column] == field.original,
        let expected = LazyCellExpectation(length: length, cut: row[column])
      else { continue }
      cells.append((LazyCell(row: key, column: field.name), expected))
    }
    guard !cells.isEmpty else { return nil }
    let generation = lazyCells.generation
    var values: [LazyCell: CellValue] = [:]
    do {
      let source = try lazyCellSource(for: truncation)
      for (cell, expected) in cells {
        values[cell] = try await lazyCells.value(for: cell, source: source, expected: expected)
      }
    } catch is CancellationError {
      return nil
    } catch {
      return error.localizedDescription
    }
    let drafts = rowDetail?.fields.filter { !$0.isReadOnly && $0.isDirty } ?? []
    storeLoadedValues(values, of: truncation, generation: generation)
    // The re-read dropped the drafts: those of the same row and originals come back
    guard var shown = rowDetail, shown.stagedInsertID == nil,
      shown.originalRow == state.originalRow
    else { return nil }
    for draft in drafts {
      guard let index = shown.fields.firstIndex(where: { $0.name == draft.name }),
        !shown.fields[index].isReadOnly, shown.fields[index].original == draft.original
      else { continue }
      shown.fields[index].field = draft.field
    }
    rowDetail = shown
    return nil
  }

  /// Row key of the sidebar's row in `truncation` (the shown page's or the viewer's). A keyless
  /// page names it by the locator of the sidebar's page row (`cellDetailRow`): the shown page's
  /// while that row is on it (the sidebar follows a re-read by position), else `truncation`'s
  /// (the sidebar kept a row the re-read no longer has). Else `rowData`'s key values.
  private func sidebarKey(
    of rowData: [String: CellValue], in truncation: DataViewerState.Truncation
  ) -> RowChangeSet.RowKey? {
    guard let kind = truncation.rowLocator else {
      return Self.key(of: rowData, keyColumns: truncation.keyColumns)
    }
    guard let row = cellDetailRow else { return nil }
    if let shown = editorResult, shown.rows.indices.contains(row) {
      return shown.truncation?.locatorKey(row: row, kind: kind)
    }
    return truncation.locatorKey(row: row, kind: kind)
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
