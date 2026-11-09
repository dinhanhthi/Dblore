// StreamedResultWriter.swift
// Writes an export a batch of rows at a time to a file, through a buffer, with the bytes the
// whole-result export writes for the same rows.

import Foundation

/// A result export written as its rows arrive, for a read too large to hold. Every piece (the
/// header line, one row's line or object, the JSON brackets and separators, an INSERT statement
/// of `DataExporter.insertBatchSize` rows) comes from the `DataExporter` function the
/// whole-result export calls, so the file has its exact bytes. One task writes, then calls
/// `finish`; the caller owns `fileHandle` and closes it.
nonisolated final class StreamedResultWriter {
  /// A streamed file format
  enum Format: Sendable {
    /// CSV, JSON or SQL INSERT (`options.format`) as `DataExporter.download` writes it: the
    /// options applied to each row (`DataExporter.applying`, masked columns redacted), then the
    /// line ending and encoding (`DataExporter.fileData`)
    case download(ExportOptions)
    /// TSV as `DataExporter.toTSV` writes it: the header line always, UTF-8, LF
    case tsv(neutralizesFormulas: Bool)
  }

  /// Bytes kept before they are written to the file
  static let defaultBufferSize = 1 << 20

  private enum Kind {
    case csv(ExportOptions)
    case tsv(neutralizesFormulas: Bool)
    case json(ExportOptions, keys: [String])
    case sqlInsert(ExportOptions)
  }

  private let format: Format
  private let kind: Kind
  /// The columns as given: `applying` finds the masked ones there
  private let columns: [ColumnInfo]
  /// The columns as the options write them (formula-prefixed names)
  private let writtenColumns: [ColumnInfo]
  private let dialect: SQLDialect
  private let schema: String?
  private let name: String?
  private let fileHandle: FileHandle
  private let bufferSize: Int
  private var buffer = Data()
  /// Byte order mark of the encoding, written once at the start of the file
  private let markLength: Int
  private var wroteRow = false
  private var wroteStatement = false
  /// Rows of the next INSERT statement
  private var pendingInserts: [[CellValue]] = []

  /// `schema` and `name`: the unquoted table of an INSERT, as in `DataExporter.sqlInsert`.
  /// Writes the header (and the byte order mark) into the buffer.
  init(
    format: Format, columns: [ColumnInfo], dialect: SQLDialect = .postgresql,
    schema: String? = nil, name: String? = nil, fileHandle: FileHandle,
    bufferSize: Int = defaultBufferSize
  ) {
    self.format = format
    self.columns = columns
    let writtenColumns = Self.prepared([], columns: columns, format: format).columns
    self.writtenColumns = writtenColumns
    self.dialect = dialect
    self.schema = schema
    self.name = name
    self.fileHandle = fileHandle
    self.bufferSize = bufferSize
    switch format {
    case .tsv(let neutralizesFormulas):
      kind = .tsv(neutralizesFormulas: neutralizesFormulas)
      markLength = 0
    case .download(let options):
      switch options.format {
      case .csv: kind = .csv(options)
      case .json: kind = .json(options, keys: DataExporter.jsonObjectKeys(writtenColumns))
      case .sqlInsert: kind = .sqlInsert(options)
      default: preconditionFailure("\(options.format) is not a streamed export format")
      }
      buffer = DataExporter.fileData(text: "", options: options)
      markLength = buffer.count
    }
    switch kind {
    case .csv(let options) where options.includeHeader:
      append(DataExporter.csvHeader(writtenColumns, quote: options.quote))
    case .tsv(let neutralizesFormulas):
      append(DataExporter.tsvHeader(writtenColumns, neutralizesFormulas: neutralizesFormulas))
    default:
      break
    }
  }

  /// Writes `rows` (already masked by the connection's rules), flushing the buffer each time
  /// it passes `bufferSize`.
  func write(rows: [[CellValue]]) throws {
    for row in Self.prepared(rows, columns: columns, format: format).rows {
      switch kind {
      case .csv(let options):
        append(DataExporter.csvLine(row, columns: writtenColumns, quote: options.quote))
      case .tsv(let neutralizesFormulas):
        append(
          DataExporter.tsvLine(
            row, columns: writtenColumns, neutralizesFormulas: neutralizesFormulas))
      case .json(let options, let keys):
        let pretty = options.jsonPretty
        let object = DataExporter.jsonObject(
          row, keys: keys, columns: writtenColumns, pretty: pretty,
          includeNull: options.jsonIncludeNull, valuesAsString: options.jsonValuesAsString)
        append(
          wroteRow
            ? DataExporter.jsonSeparator(pretty: pretty)
            : DataExporter.jsonOpen("[", pretty: pretty))
        append(DataExporter.jsonItem(object, pretty: pretty))
      case .sqlInsert(let options):
        pendingInserts.append(row)
        if pendingInserts.count == DataExporter.insertBatchSize {
          appendInsert(options)
        }
      }
      wroteRow = true
      if buffer.count >= bufferSize { try flush() }
    }
  }

  /// Writes the footer (JSON close, last INSERT statement) and the rest of the buffer. Does
  /// not close `fileHandle`.
  func finish() throws {
    switch kind {
    case .json(let options, _):
      // An empty array is `[]`, as `toJSON` writes it
      append(wroteRow ? DataExporter.jsonClose("]", pretty: options.jsonPretty) : "[]")
    case .sqlInsert(let options) where !pendingInserts.isEmpty:
      appendInsert(options)
    default:
      break
    }
    try flush()
  }

  /// The pending rows as one INSERT statement, after a line break unless it is the first
  private func appendInsert(_ options: ExportOptions) {
    let statement = SQLInsertRenderer.insertScript(
      result: QueryResult(
        columns: writtenColumns, rows: pendingInserts, rowCount: pendingInserts.count,
        executionTime: 0),
      schema: schema, name: name, dialect: dialect, batchSize: DataExporter.insertBatchSize,
      includeColumns: options.includeHeader)
    pendingInserts.removeAll(keepingCapacity: true)
    guard !statement.isEmpty else { return }
    append(wroteStatement ? "\n" + statement : statement)
    wroteStatement = true
  }

  /// `text` encoded as the whole file is. Every piece ends at a row or statement boundary, never
  /// on a CR, so the line ending applied piece by piece equals the ending applied to the whole.
  private func append(_ text: String) {
    guard !text.isEmpty else { return }
    switch format {
    case .tsv:
      buffer.append(contentsOf: text.utf8)
    case .download(let options):
      buffer.append(DataExporter.fileData(text: text, options: options).dropFirst(markLength))
    }
  }

  private func flush() throws {
    guard !buffer.isEmpty else { return }
    try fileHandle.write(contentsOf: buffer)
    buffer.removeAll(keepingCapacity: true)
  }

  /// `rows` with the download options applied, as `DataExporter.download` applies them; TSV
  /// rows as they are
  private static func prepared(
    _ rows: [[CellValue]], columns: [ColumnInfo], format: Format
  ) -> CellResult {
    let result = CellResult(columns: columns, rows: rows, rowCount: rows.count)
    guard case .download(let options) = format else { return result }
    return DataExporter.applying(options, to: result)
  }
}
