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

nonisolated enum TableImportDestination: Sendable, Equatable {
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

nonisolated enum TableImportError: Error, LocalizedError, Sendable {
  case noFile
  case noColumns
  case noTable
  case columnsChanged
  case previewLimit
  case fileTooLarge

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
    }
  }
}

private nonisolated struct ParsedImportFile: Sendable {
  var columns: [String]
  var rows: [[String?]]
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
  var previewRows: [[String?]] = []
  var progress = 0.0
  var isLoading = false
  var isImporting = false
  var isExecutingBatch = false
  var errorMessage: String?

  @ObservationIgnored private let chooseFile: @MainActor () async -> URL?
  @ObservationIgnored private var parseTask: Task<ParsedImportFile, Error>?
  @ObservationIgnored private var batchTask: Task<PendingStagedBatch, Error>?
  @ObservationIgnored private var operationID = UUID()

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
  }

  /// Reparse off the main actor so the preview does not keep the whole file in memory.
  func prepareBatch(dialect: SQLDialect, connectionEpoch: UInt64) async throws -> PendingStagedBatch
  {
    guard let fileURL else { throw TableImportError.noFile }
    guard !destination.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TableImportError.noTable
    }
    guard mappings.contains(where: \.included) else { throw TableImportError.noColumns }
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
    let parse = Task.detached(priority: .userInitiated) {
      try Self.parse(url: fileURL, format: format, hasHeader: hasHeader, rowLimit: nil)
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
    let build = Task.detached(priority: .userInitiated) {
      try Self.buildBatch(
        parsed: parsed, mappings: mappings, destination: destination,
        dialect: dialect, connectionEpoch: connectionEpoch)
    }
    batchTask = build
    let batch = try await build.value
    guard self.operationID == operationID else { throw CancellationError() }
    batchTask = nil
    progress = 1
    return batch
  }

  /// The active tab owns the transaction, Safe Mode prompt, history, and viewer reload.
  @discardableResult
  func submit(to viewModel: NotebookViewModel) async -> Bool {
    guard !Task.isCancelled else {
      errorMessage = "Import cancelled"
      return false
    }
    guard let manager = viewModel.connectionManager else {
      errorMessage = "No database connection available"
      return false
    }
    isImporting = true
    defer { isImporting = false }
    do {
      let epoch = await manager.connectionEpoch
      let batch = try await prepareBatch(
        dialect: viewModel.notebook.connectionConfig?.databaseType.dialect ?? .postgresql,
        connectionEpoch: epoch)
      try Task.checkCancellation()
      isExecutingBatch = true
      defer { isExecutingBatch = false }
      if let reason = await viewModel.beginImportBatch(batch) {
        errorMessage = reason
        return false
      }
      errorMessage = nil
      return true
    } catch is CancellationError {
      errorMessage = "Import cancelled"
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private nonisolated static func parse(
    url: URL, format: TableImportFormat, hasHeader: Bool, rowLimit: Int?
  ) throws -> ParsedImportFile {
    try Task.checkCancellation()
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let maxBytes = 256 * 1_024 * 1_024
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
    return try parse(data: data, format: format, hasHeader: hasHeader, rowLimit: rowLimit)
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
    data: Data, format: TableImportFormat, hasHeader: Bool, rowLimit: Int?
  ) throws -> ParsedImportFile {
    try Task.checkCancellation()
    switch format {
    case .json:
      let table = try JSONRowsReader.read(data, options: .init(rowLimit: rowLimit))
      return ParsedImportFile(columns: table.columns, rows: table.rows)
    case .csv, .tsv:
      let delimiter: Character? = format == .tsv ? "\t" : nil
      let table = try DelimitedTextReader.read(
        data, options: .init(delimiter: delimiter, hasHeader: hasHeader, rowLimit: rowLimit))
      return ParsedImportFile(
        columns: table.columns, rows: table.rows.map { $0.map(Optional.some) })
    }
  }

  private nonisolated static func buildBatch(
    parsed: ParsedImportFile, mappings: [TableImportColumnMapping],
    destination: TableImportDestination, dialect: SQLDialect, connectionEpoch: UInt64
  ) throws -> PendingStagedBatch {
    try Task.checkCancellation()
    let selected = mappings.enumerated().filter { $0.element.included }
    guard !selected.isEmpty else { throw TableImportError.noColumns }
    let columns = selected.map {
      ImportSQLBuilder.Column(name: $0.element.targetName, kind: $0.element.kind)
    }
    var rows: [[String?]] = []
    rows.reserveCapacity(parsed.rows.count)
    for (rowIndex, row) in parsed.rows.enumerated() {
      if rowIndex.isMultiple(of: 1_024) { try Task.checkCancellation() }
      rows.append(selected.map { index, _ in row.indices.contains(index) ? row[index] : nil })
    }
    let create =
      destination.createsTable
      ? try ImportSQLBuilder.createTable(
        schema: destination.schema, table: destination.table, columns: columns, dialect: dialect)
      : nil
    let inserts = try ImportSQLBuilder.insertStatements(
      schema: destination.schema, table: destination.table, columns: columns, rows: rows,
      dialect: dialect)
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
