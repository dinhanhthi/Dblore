// SQLiteValueMapping.swift
// SQLite storage classes become CellValue. Table identity `sqlite:<schema>.<table>` is built only here.

import Foundation

extension TableRef {
  /// SQLite table identity. The `sqlite:<schema>.<table>` string is built only here.
  nonisolated static func sqlite(schema: String, table: String) -> TableRef {
    TableRef("sqlite:\(schema).\(table)")
  }

  /// Schema and table from `sqlite(schema:table:)`. Nil for any other identity.
  /// The first dot separates them; schema names used here do not contain a dot.
  nonisolated var sqliteComponents: (schema: String, table: String)? {
    let prefix = "sqlite:"
    guard identity.hasPrefix(prefix) else { return nil }
    let rest = identity.dropFirst(prefix.count)
    guard let dot = rest.firstIndex(of: ".") else { return nil }
    let schema = String(rest[..<dot])
    let table = String(rest[rest.index(after: dot)...])
    guard !schema.isEmpty, !table.isEmpty, !table.contains(".") else { return nil }
    return (schema, table)
  }
}

/// Maps one SQLite result cell onto `CellValue`. Declared JSON stays text unless the value is
/// valid JSON. Callers pass the storage class from `sqlite3_column_type`, not a converted value.
nonisolated enum SQLiteValueMapping {
  nonisolated enum Storage: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
  }

  nonisolated static func cell(storage: Storage, declaredType: String?) -> CellValue {
    switch storage {
    case .integer(let number):
      if let value = Int(exactly: number) { return .int(value) }
      return .string(String(number))
    case .real(let number):
      return .double(number)
    case .text(let text):
      if isJSONDeclaration(declaredType), isValidJSON(text) { return .json(text) }
      return .string(text)
    case .blob(let data):
      return .data(data)
    case .null:
      return .null
    }
  }

  /// True when the column's declared type is JSON. SQLite type names are case-insensitive.
  nonisolated static func isJSONDeclaration(_ declaredType: String?) -> Bool {
    guard let declaredType else { return false }
    return declaredType.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
      "JSON") == .orderedSame
  }

  /// True for any JSON text, including a single value (`1`, `"a"`, `true`, `null`).
  nonisolated static func isValidJSON(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
  }
}
