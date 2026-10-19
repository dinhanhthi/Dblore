// MongoExportWriter.swift
// Writes exported MongoDB documents page by page to a temporary file in the container, then puts
// it at the destination in one step (`SQLDumpWriter.replaceItem`; an existing file is replaced).
// Cancel or a failure deletes the temporary file. The sandbox grants the save panel's file only,
// so the temporary file never sits next to the destination.
//
// Formats:
//   Extended JSON (relaxed or canonical), NDJSON: one compact document per line.
//   Extended JSON, array: "[\n", compact documents joined by ",\n", then "\n]" ("[]" when empty).
//   CSV: a header of the picked dot paths, then one row per document (`csvCell`), quoted as
//   needed (RFC 4180, `DataExporter.escapeCSV`).

import Foundation

actor MongoExportWriter {
  nonisolated enum JSONMode: Sendable, Equatable {
    case relaxed
    case canonical
  }

  nonisolated enum JSONLayout: Sendable, Equatable {
    case ndjson
    case array
  }

  nonisolated enum Format: Sendable, Equatable {
    case extendedJSON(mode: JSONMode, layout: JSONLayout)
    /// Dot paths into nested documents (`address.city`)
    case csv(fields: [String])
  }

  let destination: URL
  let format: Format
  private(set) var documentsWritten = 0
  private let temporary: URL
  /// Nil once finished or cancelled
  private var output: FileHandle?

  /// Creates the temporary file (mode 0600) in `temporaryDirectory`; CSV writes its header now.
  init(
    destination: URL, format: Format,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws {
    let temporary = temporaryDirectory.appendingPathComponent(
      "Dblore-export-\(UUID().uuidString).partial")
    let handle = FileHandle(
      fileDescriptor: try SQLDumpWriter.createPrivateFile(at: temporary), closeOnDealloc: true)
    if case .csv(let fields) = format {
      do {
        try handle.write(contentsOf: Data(Self.csvLine(fields).utf8))
      } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
        throw error
      }
    }
    self.destination = destination
    self.format = format
    self.temporary = temporary
    output = handle
  }

  /// Appends one page. Throws `CancellationError` after `cancel()` or `finish()`.
  func write(_ documents: [MongoValue]) throws {
    guard output != nil else { throw CancellationError() }
    var text = ""
    for document in documents {
      switch format {
      case .extendedJSON(let mode, let layout):
        if layout == .array { text += documentsWritten == 0 ? "[\n" : ",\n" }
        text += MongoRelaxedJSON.render(
          document, as: mode == .canonical ? .canonicalExtendedJSON : .relaxedExtendedJSON)
        if layout == .ndjson { text += "\n" }
      case .csv(let fields):
        text += Self.csvLine(fields.map { Self.csvCell(document, path: $0) })
      }
      documentsWritten += 1
    }
    try emit(text)
  }

  /// Closes the file and puts it at the destination. On failure nothing is left behind.
  func finish() throws {
    guard output != nil else { throw CancellationError() }
    do {
      if case .extendedJSON(_, .array) = format { try emit(documentsWritten == 0 ? "[]" : "\n]") }
      let handle = output
      output = nil
      try handle?.close()
      try SQLDumpWriter.replaceItem(at: destination, withItemAt: temporary)
    } catch {
      discard()
      throw error
    }
  }

  /// Closes and deletes the temporary file. No-op once finished or cancelled.
  func cancel() {
    guard output != nil else { return }
    discard()
  }

  private func discard() {
    try? output?.close()
    output = nil
    try? FileManager.default.removeItem(at: temporary)
  }

  private func emit(_ text: String) throws {
    guard let output else { throw CancellationError() }
    guard !text.isEmpty else { return }
    try output.write(contentsOf: Data(text.utf8))
  }

  private nonisolated static func csvLine(_ cells: [String]) -> String {
    cells.map { DataExporter.escapeCSV($0, quote: .ifNeeded) }.joined(separator: ",") + "\n"
  }

  /// The value at `path` ("a.b" walks nested documents; the first field with a key wins) as CSV
  /// text: strings raw, every other value compact relaxed Extended JSON (an ObjectId is
  /// `{"$oid": "…"}`, a date `{"$date": "…"}`), missing or null an empty cell.
  private nonisolated static func csvCell(_ document: MongoValue, path: String) -> String {
    var value = document
    for key in path.split(separator: ".", omittingEmptySubsequences: false) {
      guard case .document(let fields) = value, let field = fields.first(where: { $0.key == key })
      else { return "" }
      value = field.value
    }
    switch value {
    case .null: return ""
    case .string(let text): return text
    default: return MongoRelaxedJSON.render(value, as: .relaxedExtendedJSON)
    }
  }
}
