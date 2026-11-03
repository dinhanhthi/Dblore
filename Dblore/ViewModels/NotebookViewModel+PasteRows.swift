//
//  NotebookViewModel+PasteRows.swift
//  Dblore
//
//  Paste Rows: plain text from the clipboard staged as inserts into the data viewer's table,
//  in one undo step. The pasted text is data only: each value becomes a bound value of the
//  staged batch, never SQL text.
//

import AppKit
import Foundation

/// Why a paste stages nothing. `message` is shown to the user.
nonisolated struct PasteRowsRefusal: Error, Equatable, Sendable {
  var message: String
}

/// Clipboard text read as rows for a table's columns. Pure, so tests pass the text directly,
/// and nonisolated, so a large paste is read off the main actor.
nonisolated enum PastedRows {
  static let maxRows = 10_000
  static let tooManyRows = "Paste at most 10,000 rows at a time"
  static let nothingToPaste = "The clipboard has no rows to paste"

  struct Field: Sendable, Equatable {
    var text: String
    /// The field was quoted, so a quoted "NULL" stays text
    var quoted: Bool
  }

  struct Parsed: Sendable, Equatable {
    /// Index in the table's columns of each pasted field position
    var columnIndexes: [Int]
    var rows: [[Field]]
  }

  /// A table column, as the paste reads it
  struct Column: Sendable {
    var name: String
    var type: String
    /// `ColumnInfo.wallClock`: a naive timestamp reads its text as the stored wall clock
    var wallClock = false
  }

  /// Tab-separated when the text has a tab, else comma-separated. A first row whose every
  /// cell names a distinct column (case-insensitive) is a header and maps fields by name;
  /// otherwise fields map by position through `columnOrder` (indexes in `columnNames`, the
  /// grid's on-screen order, as Copy Rows writes them). Rows of different widths, more fields
  /// than `columnOrder` or more than `maxRows` rows are refused.
  static func parse(
    _ text: String, columnNames: [String], columnOrder: [Int]
  ) throws(PasteRowsRefusal) -> Parsed {
    let table: DelimitedTextReader.Table
    do {
      table = try DelimitedTextReader.read(
        Data(text.utf8),
        options: .init(
          delimiter: text.contains("\t") ? "\t" : ",", hasHeader: false,
          maxRows: maxRows + 1, reportsQuotedFields: true))
    } catch DelimitedTextError.rowLimitExceeded {
      throw PasteRowsRefusal(message: tooManyRows)
    } catch DelimitedTextError.unclosedQuote {
      throw PasteRowsRefusal(message: "A quoted field in the pasted text is not closed")
    } catch {
      throw PasteRowsRefusal(message: "The pasted text is too large to paste as rows")
    }
    guard let first = table.rows.first else { throw PasteRowsRefusal(message: nothingToPaste) }
    // `rows` are padded to the widest record, so the width check reads `quoted`, which keeps
    // each record's own length
    let width = first.count
    guard table.quoted.allSatisfy({ $0.count == width }) else {
      throw PasteRowsRefusal(message: "The pasted rows do not all have the same number of values")
    }
    let named = first.compactMap { columnIndex(named: $0, in: columnNames) }
    let hasHeader = named.count == width && Set(named).count == width
    if !hasHeader, width > columnOrder.count {
      throw PasteRowsRefusal(
        message: "The pasted rows have \(width) values, the table has \(columnOrder.count) columns")
    }
    let skipped = hasHeader ? 1 : 0
    guard table.rows.count > skipped else { throw PasteRowsRefusal(message: nothingToPaste) }
    guard table.rows.count - skipped <= maxRows else {
      throw PasteRowsRefusal(message: tooManyRows)
    }
    let rows = zip(table.rows.dropFirst(skipped), table.quoted.dropFirst(skipped)).map {
      zip($0, $1).map { Field(text: $0, quoted: $1) }
    }
    return Parsed(columnIndexes: hasHeader ? named : Array(columnOrder.prefix(width)), rows: rows)
  }

  /// One insert per pasted row (`parse`), each value checked and typed (`cellValue`, on the
  /// connection's `dialect`). Generated columns are left out. A refused value names its row and
  /// column.
  static func inserts(
    _ text: String, columns: [Column], columnOrder: [Int], generatedColumns: Set<String>,
    dialect: SQLDialect
  ) throws(PasteRowsRefusal) -> [[String: CellValue]] {
    let parsed = try parse(text, columnNames: columns.map(\.name), columnOrder: columnOrder)
    var inserts: [[String: CellValue]] = []
    inserts.reserveCapacity(parsed.rows.count)
    for (rowIndex, row) in parsed.rows.enumerated() {
      var values: [String: CellValue] = [:]
      for (field, columnIndex) in zip(row, parsed.columnIndexes) {
        let column = columns[columnIndex]
        if generatedColumns.contains(column.name) { continue }
        do {
          values[column.name] = try cellValue(
            field, columnType: column.type, wallClock: column.wallClock, dialect: dialect)
        } catch {
          throw PasteRowsRefusal(
            message: "Row \(rowIndex + 1), column \"\(column.name)\": \(error.message)")
        }
      }
      inserts.append(values)
    }
    return inserts
  }

  /// The paste rule, the reverse of what Copy Rows writes (`DataExporter.tsvField` and
  /// `csvField`, where NULL is the bare text NULL): a bare NULL is SQL NULL, a quoted "NULL" is
  /// text; an empty field is the empty string on a text column (CHAR, CLOB or TEXT in its type)
  /// and NULL on any other. Other text is checked against the column type, then typed as an
  /// edited cell. Known limits: Copy Rows does not quote a text cell holding NULL, so that cell
  /// pastes back as SQL NULL; and with Settings' formula neutralizing on (the default), Copy Rows
  /// writes a text cell starting with = + - or @ with a leading ', which pastes back as part of
  /// the value. A date is read as a new value on `dialect` (`NotebookViewModel.editedNewDate`).
  static func cellValue(
    _ field: Field, columnType: String, wallClock: Bool = false, dialect: SQLDialect
  ) throws(PasteRowsRefusal) -> CellValue {
    if !field.quoted, field.text == "NULL" { return .null }
    if field.text.isEmpty {
      return TableImportModel.hasTextAffinity(columnType) ? .string("") : .null
    }
    let placeholder = CellValue.placeholder(forColumnType: columnType)
    if case .invalid(let message) = CellValueValidator.validate(
      field.text, for: placeholder, columnType: columnType, wallClock: wallClock)
    {
      throw PasteRowsRefusal(message: message)
    }
    if case .date = placeholder {
      return NotebookViewModel.editedNewDate(
        field.text, columnType: columnType, wallClock: wallClock, dialect: dialect)
    }
    return NotebookViewModel.editedCellValue(
      field.text, original: placeholder, columnType: columnType)
  }

  /// The exact name first, then the first case-insensitive match
  private static func columnIndex(named name: String, in columnNames: [String]) -> Int? {
    columnNames.firstIndex(of: name)
      ?? columnNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
  }
}

extension NotebookViewModel {
  /// Shown when the table or page changed while a paste was read: nothing is staged
  static let tableChangedWhilePasting = "The table changed while the rows were read. Try again."

  /// Paste Rows with the pasteboard's plain text (Cmd+V, Edit > Paste, the grid's menu), read
  /// at once. `columnOrder` is the grid's on-screen column order. The message when nothing was
  /// staged, else nil.
  @discardableResult
  func pasteRows(from pasteboard: NSPasteboard = .general, columnOrder: [Int]) async -> String? {
    await stagePastedRows(pasteboard.string(forType: .string) ?? "", columnOrder: columnOrder)
  }

  /// Stages one insert per pasted row in one change (one undo step). Fields without a header
  /// map by position through `columnOrder` (indexes in the result's columns; nil: query order).
  /// Columns the paste does not map, and generated columns, are left out of the INSERT, so the
  /// server fills them (an identity or auto-increment key; Commit still numbers a key with no
  /// default, as for + Row). The text is parsed and checked off the main actor. Refused, with
  /// nothing staged, on engines without row staging (DuckDB, MongoDB), read-only connections,
  /// a refused paste (`PastedRows.parse`), a value invalid for its column, or a table or page
  /// that changed meanwhile. A page shown before its table definition waits for it.
  @discardableResult
  func stagePastedRows(_ text: String, columnOrder: [Int]? = nil) async -> String? {
    if let reason = unavailableFeatureMessage("Pasting rows", \.supportsRowStaging) {
      return reason
    }
    // Read at once, staged once the table definition of a page shown before it has landed
    if editorResult?.typesPending == true { await awaitResultTargets() }
    if let reason = rowStagingUnavailableReason { return reason }
    guard let target = stagedEditTarget, let result = editorResult else {
      return Self.tableHasNoPrimaryKey
    }
    let columns = result.columns.map {
      PastedRows.Column(name: $0.name, type: $0.type, wallClock: $0.wallClock)
    }
    let order = (columnOrder ?? Array(columns.indices)).filter(columns.indices.contains)
    let generatedColumns = target.generatedColumns
    let dialect = sqlDialect
    let read = await Task.detached(priority: .userInitiated) {
      Result { () throws(PasteRowsRefusal) in
        try PastedRows.inserts(
          text, columns: columns, columnOrder: order, generatedColumns: generatedColumns,
          dialect: dialect)
      }
    }.value
    let inserts: [[String: CellValue]]
    switch read {
    case .success(let rows): inserts = rows
    case .failure(let refusal): return refusal.message
    }
    // The inserts were read for this table and page only
    guard stagedEditTarget == target, editorResult?.timestamp == result.timestamp else {
      return Self.tableChangedWhilePasting
    }
    // Read-only or another policy may have turned on while the rows were read
    if let reason = rowStagingUnavailableReason { return reason }
    return changeSet("Paste Rows") { set in
      for values in inserts { set.stageInsert(values: values) }
    }
  }
}
