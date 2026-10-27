import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

extension TableImportFormat {
  /// File extensions a multi-file or folder import lists (lowercased); other files are skipped
  nonisolated static let importableExtensions: Set<String> = [
    "csv", "tsv", "json", "jsonl", "ndjson",
  ]
}

nonisolated enum MultiFileImportError: Error, LocalizedError, Sendable, Equatable {
  /// No file is included
  case noFiles
  /// Several tables match the file's name except for case, and none was chosen
  case tableNotChosen(file: String)
  /// A file could not be prepared; `reason` is the one-file import's error
  case fileFailed(file: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .noFiles: "Include at least one file to import"
    case .tableNotChosen(let file): "\(file): Choose the table this file goes into."
    case .fileFailed(let file, let reason): "\(file): \(reason)"
    }
  }
}

/// One file of a multi-file import. Its `model` owns the destination, mappings, mode and
/// match key, so Edit opens the one-file sheet on it.
@Observable
@MainActor
final class MultiFileImportEntry: Identifiable {
  let id = UUID()
  let url: URL
  let model: TableImportModel
  var isIncluded = true
  /// Set while several tables match the file's name except for case: no table is picked
  /// until `setDestination` is called
  private(set) var destinationChoiceReason: String?

  /// The file name without format characters (bidi overrides and the like), which could make
  /// it read as another name
  var displayName: String {
    String(
      String.UnicodeScalarView(
        url.lastPathComponent.unicodeScalars.filter { $0.properties.generalCategory != .format }))
  }
  var destination: TableImportDestination { model.destination }

  init(url: URL, model: TableImportModel, destinationChoiceReason: String? = nil) {
    self.url = url
    self.model = model
    self.destinationChoiceReason = destinationChoiceReason
  }

  /// The user's choice of table (existing or new). Match keys load again for it.
  func setDestination(_ destination: TableImportDestination) {
    model.destination = destination
    destinationChoiceReason = nil
  }
}

/// One included file's part of a run, shown before its one Safe Mode decision. Counts and
/// reasons only, never file values.
struct MultiFileImportFileSummary: Sendable, Equatable {
  var file: String
  var destination: TableImportDestination
  /// What the file's statements do (a plain INSERT file inserts every row)
  var counts: ImportSQLBuilder.MatchCounts
  /// A keyed file's new and existing rows and its refused rows with their reasons
  var match: TableImportMatchSummary?
  /// A keyed file with nothing to write: it adds no statement, the other files still run
  var notice: String?
}

/// Every included file of a run, with the totals
struct MultiFileImportSummary: Sendable, Equatable {
  var files: [MultiFileImportFileSummary]

  var totals: ImportSQLBuilder.MatchCounts {
    files.reduce(.init(inserts: 0, updates: 0, skips: 0, refused: 0)) { sum, file in
      .init(
        inserts: sum.inserts + file.counts.inserts, updates: sum.updates + file.counts.updates,
        skips: sum.skips + file.counts.skips, refused: sum.refused + file.counts.refused)
    }
  }
}

/// Where a run is
enum MultiFileImportProgress: Sendable, Equatable {
  /// Parsing and matching file `file` (1-based) of `count`; nothing is written yet
  case preparing(file: Int, of: Int)
  /// The batch is with the tab: its Safe Mode decision, then one transaction
  case running
}

/// The statements of every included file in one batch, file after file
struct MultiFileImportBatch: Sendable {
  /// `statementFiles` names each statement's file, so a failure names it
  var batch: PendingStagedBatch
  /// Names of the files in the batch, in order
  var files: [String]
  var summary: MultiFileImportSummary
}

/// Files from a multi-select or a folder, each into the current schema's table named like the
/// file (case-insensitive) or a new table of that name
@Observable
@MainActor
final class MultiFileImportModel {
  /// The current schema: files match its tables and new tables are created in it
  let schema: String?
  /// Loaded tables (any schema); only those of `schema` match a file
  let tables: [DatabaseTable]
  private(set) var entries: [MultiFileImportEntry] = []
  private(set) var isLoading = false
  var errorMessage: String?
  /// Set while a run prepares its files or runs its batch
  private(set) var progress: MultiFileImportProgress?
  /// The prepared run is shown: its batch waits for `confirmImport` or `endReview`
  private(set) var isReviewing = false
  /// The last run prepared, kept after `confirmImport`
  private(set) var summary: MultiFileImportSummary?
  /// A plain notice for the summary (not an error): no file has a row to write
  private(set) var notice: String?
  /// A MySQL or MariaDB run creating a table: it can't roll back everything (shown before
  /// Safe Mode)
  private(set) var implicitCommitWarning: String?

  @ObservationIgnored private let chooseFiles: @MainActor () async -> [URL]
  @ObservationIgnored private var operationID = UUID()
  /// The batch `prepareImport` built, run once by `confirmImport`
  @ObservationIgnored private var preparedBatch: PendingStagedBatch?

  static let implicitCommitWarningText =
    "MySQL and MariaDB save the import so far each time they create a table. If a later file "
    + "fails, the new tables and the rows written before the last one stay."

  init(
    schema: String?, tables: [DatabaseTable],
    chooseFiles: @escaping @MainActor () async -> [URL] = MultiFileImportModel.showOpenPanel
  ) {
    self.schema = schema
    self.tables = tables
    self.chooseFiles = chooseFiles
  }

  var includedEntries: [MultiFileImportEntry] { entries.filter(\.isIncluded) }

  func pickFiles() async {
    let urls = await chooseFiles()
    guard !urls.isEmpty else { return }
    await load(urls)
  }

  /// Picked files and folders: a folder adds its importable files (not its subfolders)
  func load(_ urls: [URL]) async {
    cancel()
    let operationID = self.operationID
    entries = []
    errorMessage = nil
    isLoading = true
    defer { if self.operationID == operationID { isLoading = false } }
    let files: [URL]
    do {
      files = try await Task.detached(priority: .userInitiated) {
        try Self.importableFiles(in: urls)
      }.value
    } catch {
      if self.operationID == operationID { errorMessage = error.localizedDescription }
      return
    }
    guard self.operationID == operationID else { return }
    guard !files.isEmpty else {
      errorMessage = "No CSV, TSV or JSON files to import"
      return
    }
    entries = files.map(makeEntry)
    // One preview at a time, each read off the main actor by its model
    for entry in entries {
      guard self.operationID == operationID else { return }
      await entry.model.loadFile(entry.url)
    }
  }

  /// Stops the previews, match reads and parses of every file; a running prepare stops at
  /// the next file and a prepared run is dropped. A batch already with the tab is not stopped.
  func cancel() {
    operationID = UUID()
    for entry in entries { entry.model.cancel() }
    isLoading = false
    if case .preparing = progress { progress = nil }
    endReview()
  }

  /// Back from the summary: the prepared batch is dropped, nothing was written
  func endReview() {
    preparedBatch = nil
    isReviewing = false
    summary = nil
    notice = nil
    implicitCommitWarning = nil
  }

  /// First step of a run: prepares every included file with the tab's values (see
  /// `prepareBatch`) and keeps the batch for `confirmImport`. Writes nothing and asks nothing.
  /// False with `errorMessage` set, or with `notice` when no file has a row to write.
  func prepareImport(for viewModel: NotebookViewModel) async -> Bool {
    endReview()
    if let reason = viewModel.importUnsupportedReason {
      errorMessage = reason
      return false
    }
    guard let manager = viewModel.connectionManager else {
      errorMessage = "No database connection available"
      return false
    }
    if let refusal = await Self.lockRefusal(manager) {
      errorMessage = refusal
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

  /// `prepareImport(for:)` with the tab's values. Every prepared run starts the review.
  func prepareImport(
    dialect: SQLDialect, connectionEpoch: UInt64, maxChunkBytes: Int? = nil,
    readMatches: (@Sendable (BoundStatement) async throws -> [[CellValue]])?
  ) async -> Bool {
    endReview()
    guard !Task.isCancelled else {
      errorMessage = "Import cancelled"
      return false
    }
    do {
      let prepared = try await prepareBatch(
        dialect: dialect, connectionEpoch: connectionEpoch, maxChunkBytes: maxChunkBytes,
        readMatches: readMatches)
      try Task.checkCancellation()
      errorMessage = nil
      summary = prepared.summary
      isReviewing = true
      // Every row skipped or refused: no transaction is opened for nothing
      guard !prepared.batch.statements.isEmpty else {
        let totals = prepared.summary.totals
        notice =
          TableImportError.nothingToWrite(skipped: totals.skips, refused: totals.refused)
          .localizedDescription
        return false
      }
      if dialect == .mysql, prepared.summary.files.contains(where: \.destination.createsTable) {
        implicitCommitWarning = Self.implicitCommitWarningText
      }
      preparedBatch = prepared.batch
      return true
    } catch is CancellationError {
      errorMessage = "Import cancelled"
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Second step: the run's one Safe Mode decision, then every file in the tab's one
  /// transaction. False when nothing is prepared (Back, Cancel) or the tab refuses the batch;
  /// a failing statement's `errorMessage` names its file and rows.
  func confirmImport(to viewModel: NotebookViewModel) async -> Bool {
    guard preparedBatch != nil else { return false }
    // Relocked since the summary: the prepared run stays for Continue once unlocked
    if let manager = viewModel.connectionManager, let refusal = await Self.lockRefusal(manager) {
      errorMessage = refusal
      return false
    }
    // Back or Cancel during the check drops the run
    guard let batch = preparedBatch else { return false }
    preparedBatch = nil
    isReviewing = false
    guard !Task.isCancelled else {
      errorMessage = "Import cancelled"
      return false
    }
    progress = .running
    defer { progress = nil }
    if let reason = await viewModel.beginImportBatch(batch) {
      errorMessage = reason
      return false
    }
    errorMessage = nil
    return true
  }

  /// Prepares every included file in order (each parse and match read off the main actor) and
  /// joins their statements into one batch. The first failing file stops it, named in the error;
  /// `cancel` stops it before the next file.
  func prepareBatch(
    dialect: SQLDialect, connectionEpoch: UInt64, maxChunkBytes: Int? = nil,
    readMatches: (@Sendable (BoundStatement) async throws -> [[CellValue]])? = nil
  ) async throws -> MultiFileImportBatch {
    let included = includedEntries
    guard !included.isEmpty else { throw MultiFileImportError.noFiles }
    let operationID = self.operationID
    defer { if self.operationID == operationID { progress = nil } }
    var statements: [BoundStatement] = []
    var rowRanges: [ClosedRange<Int>?] = []
    var previews: [String] = []
    var statementFiles: [String] = []
    var summaries: [MultiFileImportFileSummary] = []
    for (index, entry) in included.enumerated() {
      try Task.checkCancellation()
      guard self.operationID == operationID else { throw CancellationError() }
      progress = .preparing(file: index + 1, of: included.count)
      guard entry.destinationChoiceReason == nil else {
        throw MultiFileImportError.tableNotChosen(file: entry.displayName)
      }
      let batch: PendingStagedBatch
      do {
        batch = try await entry.model.prepareBatch(
          dialect: dialect, connectionEpoch: connectionEpoch, maxChunkBytes: maxChunkBytes,
          readMatches: readMatches)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A file whose preview failed has no columns: its preview error says why
        let previewError = entry.model.mappings.isEmpty ? entry.model.errorMessage : nil
        throw MultiFileImportError.fileFailed(
          file: entry.displayName, reason: previewError ?? error.localizedDescription)
      }
      statements += batch.statements
      rowRanges += batch.rowRanges
      statementFiles += Array(repeating: entry.displayName, count: batch.statements.count)
      // A chunk's last line can be a comment: its `;` goes on a line of its own, so Safe Mode
      // and History read each file's statements apart from the next file's
      previews.append(
        "-- File: \(SQLDialect.lineCommentSafe(entry.displayName))\n" + batch.preview + "\n;")
      summaries.append(Self.fileSummary(entry, batch: batch))
    }
    guard self.operationID == operationID else { throw CancellationError() }
    let summary = MultiFileImportSummary(files: summaries)
    let totals = summary.totals
    let header =
      "-- \(included.count) file\(included.count == 1 ? "" : "s"): \(totals.inserts) to insert, "
      + "\(totals.updates) to update, \(totals.skips) skipped, \(totals.refused) refused"
    var batch = PendingStagedBatch(
      statements: statements, preview: ([header] + previews).joined(separator: "\n\n"),
      connectionEpoch: connectionEpoch, historySource: .dataImport, rowRanges: rowRanges)
    batch.statementFiles = statementFiles
    return MultiFileImportBatch(
      batch: batch, files: included.map(\.displayName), summary: summary)
  }

  /// The counts of one prepared file: its match summary when keyed, else every row inserted
  private static func fileSummary(
    _ entry: MultiFileImportEntry, batch: PendingStagedBatch
  ) -> MultiFileImportFileSummary {
    guard let match = entry.model.matchSummary else {
      let rows = batch.statements.compactMap(\.expectedRows).reduce(0, +)
      return MultiFileImportFileSummary(
        file: entry.displayName, destination: entry.destination,
        counts: .init(inserts: rows, updates: 0, skips: 0, refused: 0))
    }
    let notice =
      batch.statements.isEmpty
      ? TableImportError.nothingToWrite(skipped: match.skips, refused: match.refusedCount)
        .localizedDescription : nil
    return MultiFileImportFileSummary(
      file: entry.displayName, destination: entry.destination, counts: match.counts,
      match: match, notice: notice)
  }

  /// Loads the match keys of every file going into a chosen existing table, one at a time
  /// (see `TableImportModel.loadMatchKeys`)
  func loadMatchKeys(
    fetchStructure: @Sendable (String, String) async throws -> TableStructure
  ) async {
    for entry in entries
    where !entry.destination.createsTable && entry.destinationChoiceReason == nil {
      await entry.model.loadMatchKeys(fetchStructure: fetchStructure)
    }
  }

  /// The file's table: the one of `schema` whose name equals the file's basename ignoring
  /// case, else a new table of that name. Several such tables (names differing only in case)
  /// pick none: the user chooses.
  private func makeEntry(_ url: URL) -> MultiFileImportEntry {
    let model = TableImportModel()
    model.tables = tables
    let name = url.deletingPathExtension().lastPathComponent
    let matches = tables.filter { table in
      table.name.lowercased() == name.lowercased() && (schema.map { $0 == table.schema } ?? true)
    }
    switch matches.count {
    case 0:
      model.destination = .new(schema: schema, table: name)
    case 1:
      model.destination = .existing(schema: matches[0].schema, table: matches[0].name)
    default:
      model.destination = .existing(schema: schema, table: "")
      let names = matches.map(\.name)
      let list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
      return MultiFileImportEntry(
        url: url, model: model,
        destinationChoiceReason: "Tables \(list) match this file's name. Choose its table.")
    }
    return MultiFileImportEntry(url: url, model: model)
  }

  /// The importable files of `urls`: a file as is, a folder's own regular files (no hidden
  /// files, subfolders or symlinks), each once, sorted by name
  private nonisolated static func importableFiles(in urls: [URL]) throws -> [URL] {
    var files: [URL] = []
    for url in urls {
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        files.append(url)
        continue
      }
      let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
      let children = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
      files += children.filter {
        let values = try? $0.resourceValues(forKeys: keys)
        return values?.isRegularFile == true && values?.isSymbolicLink == false
      }
    }
    var seen: Set<String> = []
    return
      files
      .filter {
        TableImportFormat.importableExtensions.contains($0.pathExtension.lowercased())
          && seen.insert($0.standardizedFileURL.path).inserted
      }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  /// The refusal of a relocked connection, before a summary is built or a batch is sent
  private static func lockRefusal(_ manager: DatabaseConnectionManager) async -> String? {
    guard let config = await manager.config else { return nil }
    return manager.lockSource.refusal(for: config)?.localizedDescription
  }

  private static func showOpenPanel() async -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    // .folder keeps folders choosable: the content types filter folders too
    panel.allowedContentTypes =
      TableImportFormat.importableExtensions.compactMap { UTType(filenameExtension: $0) }
      + [.folder]
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.urls : [])
      }
    }
  }
}
