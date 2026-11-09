//
//  RowDetailField.swift
//  Dblore
//
//  One column of the Row Details sidebar: the row's value and its draft. Drafts stay local
//  until Apply; Cancel reverts them.
//

import Foundation

struct RowDetailField: Identifiable, Equatable, Sendable {
  /// Draft value, input kind and validation
  var field: NewRowField
  /// Value of the row when the panel was opened
  let original: CellValue
  let isReadOnly: Bool
  /// Full byte length of a value a lazy data-viewer page cut: shown as "<N bytes, not loaded>"
  /// and read-only, so its prefix is never edited or applied. Nil for a whole value.
  let unloadedLength: Int?
  /// A value the capped read cut (`CellResult.cutCells`): read-only for good, never loaded
  let isCut: Bool

  var id: String { field.name }
  var name: String { field.name }

  var text: String {
    get { field.text }
    set { field.text = newValue }
  }

  var isNull: Bool {
    get { field.isNull }
    set { field.isNull = newValue }
  }

  init(
    field: NewRowField, original: CellValue, isReadOnly: Bool, unloadedLength: Int? = nil,
    isCut: Bool = false
  ) {
    self.field = field
    self.original = original
    self.isReadOnly = isReadOnly || unloadedLength != nil || isCut
    self.unloadedLength = unloadedLength
    self.isCut = isCut
    revert()
  }

  /// Draft back to the original value. A NULL original leaves the text empty.
  mutating func revert() {
    field.isNull = original == .null
    field.text = field.isNull ? "" : originalText
  }

  /// NULL-ness or text differs from the original
  var isDirty: Bool {
    let originalIsNull = original == .null
    if isNull != originalIsNull { return true }
    return !isNull && text != originalText
  }

  /// Text of the original as typed in the field: a DATE column's `.date` value as `yyyy-MM-dd`
  /// (midnight UTC), another date as the grid shows it in its column (`NewRowField.wallClock`),
  /// anything else as its full string (a decoded DATE is already that text)
  private var originalText: String {
    // A cut value shows the start of its kept text, as the grid does
    if isCut {
      let kept =
        switch original {
        case .string(let text), .json(let text), .decimal(let text): text
        case let value: value.displayString
        }
      return String(kept.prefix(ResultGridModel.maxDisplayLength)) + "…"
    }
    if let unloadedLength { return ResultGridModel.notLoadedText(length: unloadedLength) }
    if case .date(let date) = original {
      if field.kind == .date { return Self.plainDateFormatter.string(from: date) }
      return original.displayString(wallClock: field.wallClock)
    }
    return original.fullString
  }

  private static let plainDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  /// Why the draft cannot be applied, or nil
  var validationError: String? {
    guard !isReadOnly, isDirty else { return nil }
    if !isNull && text.isEmpty && field.kind != .text { return "Enter a value or set NULL" }
    return field.validationError
  }

  /// Value to bind on Apply: nil for NULL
  var bindText: String? { isNull ? nil : text }
}

/// Primary key column of the Row Details header
struct RowDetailKey: Equatable, Sendable {
  let name: String
  let value: CellValue
}

/// Row shown in the Row Details sidebar
struct RowDetailState: Equatable {
  let tableName: String?
  /// 1-based row number (`originalRow + 1`)
  let rowNumber: Int
  let keyPairs: [RowDetailKey]
  /// Every column value of the row, keyed by column name
  let rowData: [String: CellValue]
  let primaryKeyColumns: [String]
  /// Index of the row in the result's `rows` (or past them for a staged insert)
  let originalRow: Int
  /// Data viewer: `tempID` of the staged insert (its position in the change set moves when an
  /// earlier insert is reverted), nil for a loaded row
  let stagedInsertID: UUID?
  /// Edit target of the result the row was read from: Apply sends to it, never to the shared
  /// `cellDetailEditTarget` (a grid edit of another result replaces that one)
  let editTarget: EditTarget?
  var fields: [RowDetailField]
}
