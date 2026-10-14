//
//  NewRowField.swift
//  Dblore
//
//  One column of the data viewer's Add Row form. An empty field is left out of the INSERT, so
//  the database default (or NULL) applies. NULL is explicit.
//

import Foundation

struct NewRowField: Identifiable, Equatable, Sendable {
  /// Input check and staged value, from the column type name
  enum Kind: Equatable, Sendable {
    case integer, decimal, boolean, date, timestamp, json, uuid, text
  }

  var id: String { name }
  let name: String
  let type: String
  let kind: Kind
  let isPrimaryKey: Bool
  /// False for NOT NULL and primary-key columns. True when the schema is not loaded.
  let isNullable: Bool
  /// Identity column: the database numbers it
  let isIdentity: Bool
  /// Generated column: never written
  let isGenerated: Bool
  var text = ""
  var isNull = false

  init(
    name: String, type: String, isPrimaryKey: Bool = false, isNullable: Bool = true,
    isIdentity: Bool = false, isGenerated: Bool = false
  ) {
    self.name = name
    self.type = type
    self.kind = Self.kind(forColumnType: type)
    self.isPrimaryKey = isPrimaryKey
    self.isNullable = isNullable && !isPrimaryKey
    self.isIdentity = isIdentity
    self.isGenerated = isGenerated
  }

  /// Why the field cannot be staged, or nil
  var validationError: String? {
    if isGenerated { return nil }
    if isNull { return isNullable ? nil : "Column does not accept NULL" }
    if text.isEmpty { return nil }
    switch kind {
    case .integer:
      return CellValueValidator.validate(text, for: .int(0)).errorMessage
    case .decimal:
      return CellValueValidator.validate(text, for: .double(0)).errorMessage
    case .boolean:
      return Bool(text) == nil ? "Invalid boolean value (use true/false)" : nil
    case .date:
      return Self.isPlainDate(text) ? nil : "Invalid date format (use yyyy-MM-dd)"
    case .timestamp:
      if Self.isPlainDate(text) { return nil }
      return CellValueValidator.validate(text, for: .date(Date())).errorMessage
    case .json:
      return CellValueValidator.validate(text, for: .json("")).errorMessage
    case .uuid:
      return UUID(uuidString: text) == nil ? "Invalid UUID format" : nil
    case .text:
      return nil
    }
  }

  /// Value to stage. Nil leaves the column out of the INSERT.
  /// Decimals and dates keep the typed text so the database parses it without rounding.
  var value: CellValue? {
    if isGenerated { return nil }
    if isNull { return .null }
    if text.isEmpty { return nil }
    switch kind {
    case .integer: return Int(text).map(CellValue.int) ?? .string(text)
    case .boolean: return Bool(text).map(CellValue.bool) ?? .string(text)
    case .json: return .json(text)
    case .decimal, .date, .timestamp, .uuid, .text: return .string(text)
    }
  }

  /// Values of every field that has one, keyed by column name
  static func values(_ fields: [NewRowField]) -> [String: CellValue] {
    var values: [String: CellValue] = [:]
    for field in fields {
      if let value = field.value { values[field.name] = value }
    }
    return values
  }

  /// Engine type name (`INTEGER`, `INT`, `character varying(255)`, ...) to an input kind
  static func kind(forColumnType columnType: String) -> Kind {
    let base =
      columnType.uppercased()
      .split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    switch base {
    case "SMALLINT", "INTEGER", "INT", "BIGINT", "TINYINT", "MEDIUMINT", "INT2", "INT4", "INT8",
      "SERIAL", "BIGSERIAL", "SMALLSERIAL", "YEAR":
      return .integer
    case "REAL", "DOUBLE PRECISION", "DOUBLE", "FLOAT", "FLOAT4", "FLOAT8", "NUMERIC", "DECIMAL":
      return .decimal
    case "BOOLEAN", "BOOL":
      return .boolean
    case "DATE":
      return .date
    case "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "TIMESTAMP WITH TIME ZONE",
      "TIMESTAMP WITHOUT TIME ZONE":
      return .timestamp
    case "JSON", "JSONB":
      return .json
    case "UUID":
      return .uuid
    default:
      return .text
    }
  }

  private static let plainDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  /// `yyyy-MM-dd` exactly, a real calendar day
  private static func isPlainDate(_ text: String) -> Bool {
    guard let date = plainDateFormatter.date(from: text) else { return false }
    return plainDateFormatter.string(from: date) == text
  }
}
