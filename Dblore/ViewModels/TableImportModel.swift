import AppKit
import Foundation
import Observation

nonisolated enum TableImportFormat: Sendable, Equatable {
  case csv
  case tsv
  case json

  static func from(_ url: URL) -> Self {
    switch url.pathExtension.lowercased() {
    case "tsv": .tsv
    case "json", "jsonl", "ndjson": .json
    default: .csv
    }
  }
}

nonisolated enum TableImportDestination: Sendable, Hashable {
  case new(schema: String?, table: String)
  case existing(schema: String?, table: String)

  var schema: String? {
    switch self {
    case .new(let schema, _), .existing(let schema, _): schema
    }
  }

  var table: String {
    switch self {
    case .new(_, let table), .existing(_, let table): table
    }
  }

  var createsTable: Bool {
    if case .new = self { return true }
    return false
  }
}

nonisolated struct TableImportColumnMapping: Sendable, Equatable {
  var sourceName: String
  var targetName: String
  var kind: ImportTypeInference.Kind
  var included = true
}

/// A column set the import can match file rows on in an existing table: its primary key or a
/// non-partial unique index whose keys are all plain columns
nonisolated struct TableImportMatchKey: Sendable, Hashable {
  /// Key columns in key order
  var columns: [String]
  /// `Primary key (id)`, or the index name with its columns
  var displayName: String
  var isPrimaryKey: Bool
}

/// What a keyed import does with the file's rows, from the match reads (before Safe Mode)
nonisolated struct TableImportMatchSummary: Sendable, Equatable {
  /// A file row that is not written (1-based, as in the batch's row ranges)
  struct Refusal: Sendable, Equatable {
    var row: Int
    var reason: String
  }

  /// At most this many refusals are listed; `refusedCount` counts them all
  static let listedRefusalLimit = 200

  var mode: ImportMode
  var inserts = 0
  var updates = 0
  var skips = 0
  var refusedCount = 0
  /// Rows whose key is not in the table (inserted, or skipped in Update)
  var newRows = 0
  /// Rows whose key names one table row (updated, or skipped in Insert skipping existing)
  var existingRows = 0
  /// The first refusals in file order, with their reasons (never file values)
  var refused: [Refusal] = []

  var counts: ImportSQLBuilder.MatchCounts {
    .init(inserts: inserts, updates: updates, skips: skips, refused: refusedCount)
  }
}

nonisolated enum TableImportError: Error, LocalizedError, Sendable {
  case noFile
  case noColumns
  case noTable
  case columnsChanged
  case previewLimit
  case fileTooLarge
  /// A key is chosen, but the keys were not loaded for this destination
  case matchKeysNotLoaded
  case nothingToUpdate
  case matchReadFailed(String)
  /// Every row is skipped or refused
  case nothingToWrite(skipped: Int, refused: Int)

  var errorDescription: String? {
    switch self {
    case .noFile: "Choose a file to import"
    case .noColumns: "Select at least one column"
    case .noTable: "Enter a table name"
    case .columnsChanged:
      "The file has columns not shown in the preview. Review the file before importing."
    case .previewLimit:
      "Preview exceeds 8 MB before 100 rows. Shorten large records to preview this file."
    case .fileTooLarge:
      "Import exceeds the 256 MB safety limit. Split the file into smaller parts."
    case .matchKeysNotLoaded:
      "The keys of this table are not loaded. Choose the table again to match rows."
    case .nothingToUpdate:
      "Import at least one column besides the key to update rows."
    case .matchReadFailed(let detail):
      "Could not check which rows already exist, so nothing was written: \(detail)"
    case .nothingToWrite(let skipped, let refused):
      "No rows to write: \(skipped) skipped, \(refused) refused."
    }
  }
}

/// A keyed import's choices and the structure its key was loaded from
private nonisolated struct MatchRequest: Sendable {
  var key: TableImportMatchKey
  var mode: ImportMode
  var structure: TableStructure
  var readMatches: @Sendable (BoundStatement) async throws -> [[CellValue]]
}

private nonisolated struct PreparedImport: Sendable {
  var batch: PendingStagedBatch
  var summary: TableImportMatchSummary?
}

private nonisolated struct ParsedImportFile: Sendable {
  var columns: [String]
  var rows: [[String?]]
  /// Delimited text only: the full import decodes with the preview's encoding
  var encoding: String.Encoding?
}

/// Owns the import sheet's preview and mapping. Full file parsing happens only at submit.
@Observable
@MainActor
final class TableImportModel {
  var fileURL: URL?
  var format: TableImportFormat = .csv
  var hasHeader = true
  var destination: TableImportDestination = .new(schema: nil, table: "")
  var mappings: [TableImportColumnMapping] = []
  var tables: [DatabaseTable] = []
  var previewRows: [[String?]] = []
  var progress = 0.0
  var isLoading = false
  var isImporting = false
  var isExecutingBatch = false
  var errorMessage: String?
  /// Keys of an existing destination, primary key first. Empty until loaded and for a new table.
  var matchKeys: [TableImportMatchKey] = []
  /// Why only Insert is available for the loaded existing table. Nil when keys are offered.
  var matchModesUnavailableReason: String?
  var isLoadingMatchKeys = false
  /// What rows whose key exists do. Without `matchKey`, only `.insert` applies (plain INSERT).
  var mode: ImportMode = .insert
  /// The key file rows are matched on (one of `matchKeys`); nil inserts every row as is
  var matchKey: TableImportMatchKey?
  /// Counts of the last keyed batch prepared, set before Safe Mode; nil for a plain INSERT
  var matchSummary: TableImportMatchSummary?
  /// The match reads of a keyed import are running
  var isMatchingRows = false
  /// A keyed import's summary is shown: the batch waits for `confirmImport` or `endMatchReview`
  private(set) var isReviewingMatches = false
  /// A plain notice for the summary (not an error): every row is skipped or refused
  private(set) var notice: String?

  @ObservationIgnored private let chooseFile: @MainActor () async -> URL?
  @ObservationIgnored private var parseTask: Task<ParsedImportFile, Error>?
  @ObservationIgnored private var batchTask: Task<PreparedImport, Error>?
  /// The batch `prepareImport` built, run once by `confirmImport`
  @ObservationIgnored private var preparedBatch: PendingStagedBatch?
  /// The structure `matchKeys` came from, with the destination it was read for
  @ObservationIgnored private var matchStructure:
    (destination: TableImportDestination, structure: TableStructure)?
  @ObservationIgnored private var operationID = UUID()
  @ObservationIgnored private var previewEncoding: String.Encoding?
  @ObservationIgnored private var matchKeysRequest = UUID()

  init(chooseFile: @escaping @MainActor () async -> URL? = TableImportModel.showOpenPanel) {
    self.chooseFile = chooseFile
  }

  func pickFile() async {
    guard let url = await chooseFile() else { return }
    await loadFile(url)
  }

  func loadFile(_ url: URL) async {
    await loadFile(url, detectFormat: true)
  }

  private func loadFile(_ url: URL, detectFormat: Bool) async {
    cancel()
    let operationID = self.operationID
    fileURL = url
    if detectFormat { format = .from(url) }
    errorMessage = nil
    previewRows = []
    mappings = []
    previewEncoding = nil
    progress = 0.1
    isLoading = true
    let hasHeader = self.hasHeader
    let format = self.format
    let task = Task.detached(priority: .userInitiated) {
      try Self.parsePreview(
        url: url, format: format, hasHeader: hasHeader,
        rowLimit: 100)
    }
    parseTask = task
    defer {
      if self.operationID == operationID {
        isLoading = false
        parseTask = nil
      }
    }
    do {
      let parsed = try await task.value
      guard self.operationID == operationID else { throw CancellationError() }
      previewRows = parsed.rows
      previewEncoding = parsed.encoding
      let kinds = ImportTypeInference.infer(rows: parsed.rows, columnCount: parsed.columns.count)
      mappings = parsed.columns.enumerated().map { index, name in
        TableImportColumnMapping(sourceName: name, targetName: name, kind: kinds[index])
      }
      progress = 1
    } catch is CancellationError {
      if self.operationID == operationID { progress = 0 }
    } catch {
      if self.operationID == operationID {
        errorMessage = error.localizedDescription
        progress = 0
      }
    }
  }

  func reloadPreview() async {
    guard let fileURL else { return }
    await loadFile(fileURL, detectFormat: false)
  }

  func cancel() {
    operationID = UUID()
    parseTask?.cancel()
    batchTask?.cancel()
    isLoading = false
    isImporting = false
    isMatchingRows = false
    endMatchReview()
  }

  /// Back from the summary: the prepared batch is dropped, nothing was written
  func endMatchReview() {
    preparedBatch = nil
    isReviewingMatches = false
    notice = nil
    matchSummary = nil
  }

  /// `matchKeys` whose columns are all imported, compared exactly as the planner binds them
  var offeredMatchKeys: [TableImportMatchKey] {
    let imported = Set(mappings.filter(\.included).map(\.targetName))
    return matchKeys.filter { $0.columns.allSatisfy(imported.contains) }
  }

  /// Why only Insert is available: the load's reason, or no key with all its columns imported
  var keyedModesUnavailableReason: String? {
    if let matchModesUnavailableReason { return matchModesUnavailableReason }
    guard let key = matchKeys.first, offeredMatchKeys.isEmpty else { return nil }
    return "Import every column of a key, such as \(key.columns.joined(separator: ", ")), to "
      + "match rows. Until then only Insert is available."
  }

  /// Insert drops the key (every row inserted as is); another mode needs an offered key and
  /// takes the first (the primary key) when none is chosen
  func selectMode(_ mode: ImportMode) {
    guard mode == .insert || !offeredMatchKeys.isEmpty else { return }
    self.mode = mode
    if mode == .insert {
      matchKey = nil
    } else {
      syncMatchChoice()
    }
  }

  /// Keeps the key one of `offeredMatchKeys` after the keys or the mapping change: another
  /// offered key replaces it outside Insert, and with none offered the mode goes back to Insert
  func syncMatchChoice() {
    let offered = offeredMatchKeys
    if let key = matchKey, !offered.contains(key) { matchKey = nil }
    if offered.isEmpty {
      mode = .insert
    } else if mode != .insert, matchKey == nil {
      matchKey = offered.first
    }
  }

  /// Reads the existing destination's structure through `fetchStructure` (schema, table; the
  /// manager's catalog read, off the main actor) before any transaction and keeps its match
  /// keys. A schema left empty is the one of the matching loaded table. A result for a
  /// destination changed meanwhile, or for a newer load, is dropped. `delay` debounces typing:
  /// the keys show as loading at once, and a load cancelled while it waits reads nothing.
  func loadMatchKeys(
    after delay: Duration = .zero,
    fetchStructure: @Sendable (String, String) async throws -> TableStructure
  ) async {
    let request = UUID()
    matchKeysRequest = request
    let destination = self.destination
    matchKeys = []
    matchStructure = nil
    matchModesUnavailableReason = nil
    // The newest load owns the flag: an older one still reading no longer resets it
    isLoadingMatchKeys = false
    // A new table, or no name yet: nothing to read and no reason to show
    guard !destination.createsTable,
      !destination.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      syncMatchChoice()
      return
    }
    isLoadingMatchKeys = true
    defer { if matchKeysRequest == request { isLoadingMatchKeys = false } }
    if delay > .zero {
      do { try await Task.sleep(for: delay) } catch { return }
      guard matchKeysRequest == request else { return }
    }
    guard
      let schema = destination.schema
        ?? Self.existingTable(destination: destination, tables: tables)?.schema
    else {
      matchModesUnavailableReason = "The table was not found, so only Insert is available."
      syncMatchChoice()
      return
    }
    let result: Result<TableStructure, Error>
    do {
      result = .success(try await fetchStructure(schema, destination.table))
    } catch {
      result = .failure(error)
    }
    guard matchKeysRequest == request, self.destination == destination else { return }
    switch result {
    case .success(let structure):
      matchKeys = Self.keys(in: structure)
      matchStructure = (destination, structure)
      if matchKeys.isEmpty {
        matchModesUnavailableReason =
          "This table has no primary key or unique index on plain columns, so only Insert is "
          + "available."
      }
    case .failure(let error):
      matchModesUnavailableReason =
        "Could not read the keys of this table, so only Insert is available: "
        + error.localizedDescription
    }
    syncMatchChoice()
  }

  /// Primary key first (from the constraint: a SQLite rowid key and DuckDB keys have no index
  /// row), then unique non-partial indexes of plain columns in catalog order, then unique
  /// constraints without an index of their name (DuckDB). A constraint whose index is listed
  /// is decided by that index, since a constraint lists only the plain columns of a key with an
  /// expression part. A column list already offered is not repeated.
  private nonisolated static func keys(in structure: TableStructure) -> [TableImportMatchKey] {
    var offered: [TableImportMatchKey] = []
    func offer(_ columns: [String], _ name: String, isPrimaryKey: Bool = false) {
      guard !columns.isEmpty, !offered.contains(where: { $0.columns == columns }) else { return }
      offered.append(
        TableImportMatchKey(
          columns: columns, displayName: "\(name) (\(columns.joined(separator: ", ")))",
          isPrimaryKey: isPrimaryKey))
    }
    if let primary = structure.constraints.first(where: { $0.kind == .primaryKey }) {
      offer(primary.columns, "Primary key", isPrimaryKey: true)
    }
    for index in structure.indexes where index.isUnique && !index.isPrimary && !index.isPartial {
      let columns = index.keys.compactMap { key -> String? in
        if case .column(let name) = key { name } else { nil }
      }
      if columns.count == index.keys.count { offer(columns, index.name) }
    }
    let indexNames = Set(structure.indexes.map(\.name))
    for constraint in structure.constraints where constraint.kind == .unique {
      guard constraint.name.map({ !indexNames.contains($0) }) ?? true else { continue }
      offer(constraint.columns, constraint.name ?? "Unique")
    }
    return offered
  }

  /// Reparse off the main actor so the preview does not keep the whole file in memory.
  /// `maxChunkBytes` caps each INSERT's bind bytes (MySQL `max_allowed_packet`).
  /// With a `matchKey` (existing table), every row is first matched through `readMatches`
  /// (the tab manager's `readImportMatches`), off the main actor, then routed by `mode` into
  /// INSERT chunks and one UPDATE per row, refused or skipped; `matchSummary` keeps the
  /// counts. A failed read throws before any statement is built.
  func prepareBatch(
    dialect: SQLDialect, connectionEpoch: UInt64, maxChunkBytes: Int? = nil,
    readMatches: (@Sendable (BoundStatement) async throws -> [[CellValue]])? = nil
  ) async throws -> PendingStagedBatch {
    guard let fileURL else { throw TableImportError.noFile }
    guard !destination.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TableImportError.noTable
    }
    guard mappings.contains(where: \.included) else { throw TableImportError.noColumns }
    matchSummary = nil
    let match = try matchRequest(readMatches: readMatches)
    let operationID = UUID()
    self.operationID = operationID
    defer {
      if self.operationID == operationID {
        parseTask = nil
        batchTask = nil
      }
    }
    progress = 0.1
    let format = self.format
    let hasHeader = self.hasHeader
    let encoding = previewEncoding
    let parse = Task.detached(priority: .userInitiated) {
      try Self.parse(
        url: fileURL, format: format, hasHeader: hasHeader, rowLimit: nil, encoding: encoding)
    }
    parseTask = parse
    let parsed = try await parse.value
    guard self.operationID == operationID else { throw CancellationError() }
    guard parsed.columns == mappings.map(\.sourceName) else {
      throw TableImportError.columnsChanged
    }
    parseTask = nil
    progress = 0.6
    let mappings = self.mappings
    let destination = self.destination
    let tables = self.tables
    let build = Task.detached(priority: .userInitiated) {
      let columns = Self.importColumns(
        mappings: mappings, destination: destination, tables: tables, dialect: dialect)
      let rows = try Self.selectedRows(parsed: parsed, mappings: mappings)
      guard let match else {
        return PreparedImport(
          batch: try Self.buildBatch(
            columns: columns, rows: rows, destination: destination, dialect: dialect,
            connectionEpoch: connectionEpoch, maxChunkBytes: maxChunkBytes))
      }
      return try await Self.buildMatchedBatch(
        columns: columns, rows: rows, destination: destination, match: match, dialect: dialect,
        connectionEpoch: connectionEpoch, maxChunkBytes: maxChunkBytes)
    }
    batchTask = build
    isMatchingRows = match != nil
    defer { if self.operationID == operationID { isMatchingRows = false } }
    let prepared = try await build.value
    guard self.operationID == operationID else { throw CancellationError() }
    batchTask = nil
    matchSummary = prepared.summary
    progress = 1
    return prepared.batch
  }

  /// What a keyed import needs from the model, read on the main actor: nil for a plain INSERT
  /// (a new table, or Insert without a key)
  private func matchRequest(
    readMatches: (@Sendable (BoundStatement) async throws -> [[CellValue]])?
  ) throws -> MatchRequest? {
    guard !destination.createsTable, matchKey != nil || mode != .insert else { return nil }
    guard let key = matchKey else { throw ImportMatchPlanner.Error.noKey }
    guard let loaded = matchStructure, loaded.destination == destination,
      matchKeys.contains(key), let readMatches
    else { throw TableImportError.matchKeysNotLoaded }
    return MatchRequest(
      key: key, mode: mode, structure: loaded.structure, readMatches: readMatches)
  }

  /// The active tab owns the transaction, Safe Mode prompt, history, and viewer reload.
  /// `prepareImport`, then `confirmImport` at once: the sheet shows a keyed import's summary
  /// between the two.
  @discardableResult
  func submit(to viewModel: NotebookViewModel) async -> Bool {
    guard await prepareImport(for: viewModel) else { return false }
    return await confirmImport(to: viewModel)
  }

  /// First step: parses the file and, for a keyed import, runs the match reads through the
  /// tab's manager, then keeps the batch for `confirmImport`. Writes nothing and asks nothing.
  /// False with `errorMessage` set, or with `notice` when every row is skipped or refused.
  func prepareImport(for viewModel: NotebookViewModel) async -> Bool {
    endMatchReview()
    if let reason = viewModel.importUnsupportedReason {
      errorMessage = reason
      return false
    }
    guard let manager = viewModel.connectionManager else {
      errorMessage = "No database connection available"
      return false
    }
    let epoch = await manager.connectionEpoch
    let dialect = viewModel.sqlDialect
    let maxChunkBytes =
      dialect == .mysql
      ? ImportSQLBuilder.mysqlChunkByteCap(
        maxAllowedPacket: await manager.mysqlServerInfo?.maxAllowedPacket) : nil
    return await prepareImport(
      dialect: dialect, connectionEpoch: epoch, maxChunkBytes: maxChunkBytes,
      readMatches: { try await manager.readImportMatches($0) })
  }

  /// `prepareImport(for:)` with the tab's values. A keyed batch starts the summary review.
  func prepareImport(
    dialect: SQLDialect, connectionEpoch: UInt64, maxChunkBytes: Int? = nil,
    readMatches: (@Sendable (BoundStatement) async throws -> [[CellValue]])?
  ) async -> Bool {
    endMatchReview()
    guard !Task.isCancelled else {
      errorMessage = "Import cancelled"
      return false
    }
    isImporting = true
    defer { isImporting = false }
    do {
      let batch = try await prepareBatch(
        dialect: dialect, connectionEpoch: connectionEpoch, maxChunkBytes: maxChunkBytes,
        readMatches: readMatches)
      try Task.checkCancellation()
      errorMessage = nil
      if let summary = matchSummary {
        isReviewingMatches = true
        // Every row skipped or refused: no transaction is opened for nothing
        if batch.statements.isEmpty {
          notice =
            TableImportError.nothingToWrite(skipped: summary.skips, refused: summary.refusedCount)
            .localizedDescription
          return false
        }
      }
      preparedBatch = batch
      return true
    } catch is CancellationError {
      errorMessage = "Import cancelled"
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Second step: the one Safe Mode decision and the prepared batch in the tab's transaction.
  /// False when nothing is prepared (Back, or a changed file) or the tab refuses the batch.
  func confirmImport(to viewModel: NotebookViewModel) async -> Bool {
    guard let batch = preparedBatch else { return false }
    preparedBatch = nil
    isReviewingMatches = false
    guard !Task.isCancelled else {
      errorMessage = "Import cancelled"
      return false
    }
    isImporting = true
    isExecutingBatch = true
    defer {
      isImporting = false
      isExecutingBatch = false
    }
    if let reason = await viewModel.beginImportBatch(batch) {
      errorMessage = reason
      return false
    }
    errorMessage = nil
    return true
  }

  private nonisolated static func parse(
    url: URL, format: TableImportFormat, hasHeader: Bool, rowLimit: Int?,
    encoding: String.Encoding?
  ) throws -> ParsedImportFile {
    try Task.checkCancellation()
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let maxBytes = DelimitedTextReader.maxImportFileBytes
    guard try handle.seekToEnd() <= maxBytes else { throw TableImportError.fileTooLarge }
    try handle.seek(toOffset: 0)
    var data = Data()
    while true {
      try Task.checkCancellation()
      let chunk =
        try handle.read(upToCount: min(1_024 * 1_024, maxBytes + 1 - data.count))
        ?? Data()
      if chunk.isEmpty { break }
      data.append(chunk)
      guard data.count <= maxBytes else { throw TableImportError.fileTooLarge }
    }
    return try parse(
      data: data, format: format, hasHeader: hasHeader, rowLimit: rowLimit, encoding: encoding)
  }

  /// Read only enough bytes for the preview. Full import still reparses the entire file.
  private nonisolated static func parsePreview(
    url: URL, format: TableImportFormat, hasHeader: Bool, rowLimit: Int
  ) throws -> ParsedImportFile {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let maxBytes = 8 * 1_024 * 1_024
    var data = Data()
    while data.count < maxBytes {
      try Task.checkCancellation()
      let chunk = try handle.read(upToCount: min(64 * 1_024, maxBytes - data.count)) ?? Data()
      if chunk.isEmpty {
        return try parse(data: data, format: format, hasHeader: hasHeader, rowLimit: rowLimit)
      }
      data.append(chunk)
      // Without a new line end the delimited candidate is unchanged, so its parse would be too
      if format != .json, !chunk.contains(where: { $0 == 10 || $0 == 13 }) { continue }
      // A JSON record (array element or NDJSON line) can only complete at `}`, `]` or a new line
      if format == .json,
        !chunk.contains(where: { $0 == 0x7D || $0 == 0x5D || $0 == 10 || $0 == 13 })
      {
        continue
      }
      let candidate: Data
      if format == .json {
        // A read may stop inside a UTF-8 codepoint. Parse a valid prefix so the reader
        // does not mistake the entire preview for Latin-1.
        if String(data: data, encoding: .utf8) != nil {
          candidate = data
        } else if let valid = (1...3).first(where: {
          data.count >= $0 && String(data: data.dropLast($0), encoding: .utf8) != nil
        }) {
          candidate = Data(data.dropLast(valid))
        } else {
          candidate = data
        }
      } else if let end = data.lastIndex(where: { $0 == 10 || $0 == 13 }) {
        candidate = Data(data[...end])
      } else {
        continue
      }
      if let preview = try? parse(
        data: candidate, format: format, hasHeader: hasHeader, rowLimit: rowLimit),
        preview.rows.count >= rowLimit
      {
        return preview
      }
    }
    throw TableImportError.previewLimit
  }

  private nonisolated static func parse(
    data: Data, format: TableImportFormat, hasHeader: Bool, rowLimit: Int?,
    encoding: String.Encoding? = nil
  ) throws -> ParsedImportFile {
    try Task.checkCancellation()
    switch format {
    case .json:
      let table = try JSONRowsReader.read(data, options: .init(rowLimit: rowLimit))
      return ParsedImportFile(columns: table.columns, rows: table.rows)
    case .csv, .tsv:
      let delimiter: Character? = format == .tsv ? "\t" : nil
      let table = try DelimitedTextReader.read(
        data,
        options: .init(
          delimiter: delimiter, hasHeader: hasHeader, rowLimit: rowLimit, encoding: encoding))
      return ParsedImportFile(
        columns: table.columns, rows: table.rows.map { $0.map(Optional.some) },
        encoding: table.encoding)
    }
  }

  /// SQLite TEXT affinity: the declared type contains CHAR, CLOB or TEXT
  nonisolated static func hasTextAffinity(_ declaredType: String) -> Bool {
    let type = declaredType.uppercased()
    return type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT")
  }

  /// MySQL DATE, DATETIME(n) and TIMESTAMP(n) (COLUMN_TYPE text)
  nonisolated static func isMySQLDateTimeType(_ declaredType: String) -> Bool {
    let type = declaredType.uppercased()
    return type.hasPrefix("DATE") || type.hasPrefix("TIMESTAMP")
  }

  /// The loaded table an existing destination names. Nil for a new table or when not loaded.
  private nonisolated static func existingTable(
    destination: TableImportDestination, tables: [DatabaseTable]
  ) -> DatabaseTable? {
    guard !destination.createsTable else { return nil }
    let name = destination.table.lowercased()
    return tables.first { table in
      table.name.lowercased() == name && (destination.schema.map { $0 == table.schema } ?? true)
    }
  }

  /// Lowercased column name to declared type for an existing destination. Empty when unknown.
  private nonisolated static func declaredTypes(
    destination: TableImportDestination, tables: [DatabaseTable]
  ) -> [String: String] {
    let table = existingTable(destination: destination, tables: tables)
    return Dictionary(
      (table?.columns ?? []).map { ($0.name.lowercased(), $0.type) },
      uniquingKeysWith: { first, _ in first })
  }

  /// The INSERT / UPDATE columns of the included mappings. SQLite and MySQL booleans become
  /// 1/0 unless an existing column has TEXT affinity, which gets the file value unchanged.
  /// MySQL timestamps become UTC DATETIME text only for a new table, an unlisted column, or a
  /// DATE / DATETIME / TIMESTAMP column (JSON, ENUM, SET, binary and text columns keep the
  /// file text).
  private nonisolated static func importColumns(
    mappings: [TableImportColumnMapping], destination: TableImportDestination,
    tables: [DatabaseTable], dialect: SQLDialect
  ) -> [ImportSQLBuilder.Column] {
    let types: [String: String]
    switch dialect {
    case .sqlite, .mysql: types = declaredTypes(destination: destination, tables: tables)
    default: types = [:]
    }
    return mappings.filter(\.included).map {
      let type = types[$0.targetName.lowercased()]
      let keepsText: Bool
      switch $0.kind {
      case .timestamp where dialect == .mysql:
        keepsText = type.map { !isMySQLDateTimeType($0) } == true
      case .boolean, .timestamp:
        keepsText = type.map(hasTextAffinity) == true
      default:
        keepsText = false
      }
      return ImportSQLBuilder.Column(name: $0.targetName, kind: keepsText ? .text : $0.kind)
    }
  }

  /// The included columns of every parsed row (a short row reads NULL)
  private nonisolated static func selectedRows(
    parsed: ParsedImportFile, mappings: [TableImportColumnMapping]
  ) throws -> [[String?]] {
    try Task.checkCancellation()
    let selected = mappings.indices.filter { mappings[$0].included }
    guard !selected.isEmpty else { throw TableImportError.noColumns }
    var rows: [[String?]] = []
    rows.reserveCapacity(parsed.rows.count)
    for (rowIndex, row) in parsed.rows.enumerated() {
      if rowIndex.isMultiple(of: 1_024) { try Task.checkCancellation() }
      rows.append(selected.map { row.indices.contains($0) ? row[$0] : nil })
    }
    return rows
  }

  private nonisolated static func buildBatch(
    columns: [ImportSQLBuilder.Column], rows: [[String?]], destination: TableImportDestination,
    dialect: SQLDialect, connectionEpoch: UInt64, maxChunkBytes: Int?
  ) throws -> PendingStagedBatch {
    let create =
      destination.createsTable
      ? try ImportSQLBuilder.createTable(
        schema: destination.schema, table: destination.table, columns: columns, dialect: dialect)
      : nil
    let inserts = try ImportSQLBuilder.insertStatements(
      schema: destination.schema, table: destination.table, columns: columns, rows: rows,
      dialect: dialect, maxChunkBytes: maxChunkBytes)
    let summary = try ImportSQLBuilder.summaryText(
      createTable: create, schema: destination.schema, table: destination.table,
      columns: columns.map(\.name), rowCount: rows.count, dialect: dialect)
    var ranges: [ClosedRange<Int>?] = create == nil ? [] : [nil]
    var row = 1
    for insert in inserts {
      let count = insert.expectedRows ?? 0
      ranges.append(row...(row + count - 1))
      row += count
    }
    try Task.checkCancellation()
    return PendingStagedBatch(
      statements: (create.map { [$0] } ?? []) + inserts, preview: summary,
      connectionEpoch: connectionEpoch, historySource: .dataImport, rowRanges: ranges)
  }

  /// A keyed import: the match reads, then each row's outcome in `match.mode`, then INSERT
  /// chunks of the inserted rows (their range spans the chunk's first to last file row, so it
  /// can include rows another statement writes) and one UPDATE per updated row. A row whose
  /// key text repeats an earlier row's is refused (two inserts would fail the batch, two
  /// updates would let the last win); keys equal only under the column's collation are left
  /// to the database. In Update a row with a NULL key part is refused, never silently skipped.
  private nonisolated static func buildMatchedBatch(
    columns: [ImportSQLBuilder.Column], rows: [[String?]], destination: TableImportDestination,
    match: MatchRequest, dialect: SQLDialect, connectionEpoch: UInt64, maxChunkBytes: Int?
  ) async throws -> PreparedImport {
    let names = columns.map(\.name)
    if match.mode == .update || match.mode == .insertOrUpdate,
      names.allSatisfy { match.key.columns.contains($0) }
    {
      throw TableImportError.nothingToUpdate
    }
    let bound = try ImportSQLBuilder.bindRows(rows, columns: columns, dialect: dialect)
    let plan = try ImportMatchPlanner.plan(
      schema: destination.schema, table: destination.table, keyColumns: match.key.columns,
      columns: names, rows: bound, structure: match.structure, dialect: dialect)
    var counts: [Int: Int] = [:]
    for read in plan.reads {
      try Task.checkCancellation()
      let result: [[CellValue]]
      do {
        result = try await match.readMatches(read)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw TableImportError.matchReadFailed(error.localizedDescription)
      }
      counts.merge(ImportMatchPlanner.counts(result), uniquingKeysWith: +)
    }
    try Task.checkCancellation()
    let keys = try match.key.columns.map { name in
      guard let column = match.structure.columns.first(where: { $0.name == name }) else {
        throw ImportMatchPlanner.Error.unknownColumn(name)
      }
      return try ImportMatchPlanner.KeyColumn(column, dialect: dialect)
    }
    var summary = TableImportMatchSummary(mode: match.mode)
    var insertRows: [Int] = []
    var updateRows: [Int] = []
    var seenKeys: Set<[String]> = []
    func refuse(_ row: Int, _ reason: String) {
      summary.refusedCount += 1
      if summary.refused.count < TableImportMatchSummary.listedRefusalLimit {
        summary.refused.append(.init(row: row + 1, reason: reason))
      }
    }
    let outcomes = ImportMatchPlanner.outcomes(plan, counts: counts, mode: match.mode)
    for (row, outcome) in outcomes.enumerated() {
      if row.isMultiple(of: 1_024) { try Task.checkCancellation() }
      if case .refused(let reason) = outcome {
        refuse(row, reason)
        continue
      }
      guard let key = ImportSQLBuilder.keyText(bound[row], columns: columns, keys: keys) else {
        if match.mode == .update {
          refuse(row, "The key is empty, so the row can't be matched.")
          continue
        }
        // Never matches: inserted as is (a NULL key part is the database's to accept)
        insertRows.append(row)
        summary.newRows += 1
        continue
      }
      guard seenKeys.insert(key).inserted else {
        refuse(row, "This key appears earlier in the file.")
        continue
      }
      switch outcome {
      case .insert:
        insertRows.append(row)
        summary.newRows += 1
      case .update:
        updateRows.append(row)
        summary.existingRows += 1
      case .skip:
        summary.skips += 1
        if match.mode == .update { summary.newRows += 1 } else { summary.existingRows += 1 }
      case .refused:
        break
      }
    }
    summary.inserts = insertRows.count
    summary.updates = updateRows.count

    let inserts =
      insertRows.isEmpty
      ? []
      : try ImportSQLBuilder.insertStatements(
        schema: destination.schema, table: destination.table, columns: columns,
        rows: insertRows.map { rows[$0] }, dialect: dialect, maxChunkBytes: maxChunkBytes)
    var ranges: [ClosedRange<Int>?] = []
    var offset = 0
    for insert in inserts {
      let count = insert.expectedRows ?? 0
      ranges.append((insertRows[offset] + 1)...(insertRows[offset + count - 1] + 1))
      offset += count
    }
    var updates: [BoundStatement] = []
    updates.reserveCapacity(updateRows.count)
    for row in updateRows {
      if updates.count.isMultiple(of: 1_024) { try Task.checkCancellation() }
      updates.append(
        try ImportSQLBuilder.updateStatement(
          schema: destination.schema, table: destination.table, columns: columns, row: rows[row],
          keys: keys, dialect: dialect))
      ranges.append((row + 1)...(row + 1))
    }
    let preview = try ImportSQLBuilder.matchSummaryText(
      schema: destination.schema, table: destination.table, columns: names,
      update: updates.first, counts: summary.counts, dialect: dialect)
    try Task.checkCancellation()
    return PreparedImport(
      batch: PendingStagedBatch(
        statements: inserts + updates, preview: preview, connectionEpoch: connectionEpoch,
        historySource: .dataImport, rowRanges: ranges),
      summary: summary)
  }

  private static func showOpenPanel() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
