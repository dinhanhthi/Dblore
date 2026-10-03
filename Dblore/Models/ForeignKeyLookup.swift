// ForeignKeyLookup.swift
// Which foreign key owns a source column, the bound lookup, and the jump filter.
// Nothing here is sent to a database.

import Foundation

/// Pure foreign-key lookup for one source cell.
/// Names match exactly, with no case-folding. A composite key is a reference only when
/// every source column is in the row. A NULL component is not a lookup and not a filter.
nonisolated enum ForeignKeyLookup: Sendable {

  /// First key on `schema.table` that includes `column` and whose source columns are all
  /// in `rowColumns`. Catalog order wins when more than one key matches.
  static func reference(
    for column: String,
    schema: String,
    table: String,
    foreignKeys: [ForeignKey],
    rowColumns: [String]
  ) -> ForeignKey? {
    let present = Set(rowColumns)
    for key in foreignKeys {
      guard key.sourceSchema == schema, key.sourceTable == table else { continue }
      guard key.sourceColumns.contains(column) else { continue }
      guard key.sourceColumns.allSatisfy(present.contains) else { continue }
      return key
    }
    return nil
  }

  /// `SELECT * FROM <quoted target> WHERE <target column> = :fk1 AND … LIMIT 2`.
  /// Keys are `fk1`, `fk2`, … (no colon), one per source column, in source-column order.
  /// Nil when a component is missing or NULL, or the two column lists differ.
  static func lookupSQL(
    for foreignKey: ForeignKey,
    values: [String: CellValue],
    dialect: SQLDialect
  ) -> (sql: String, parameters: [String: SQLBindValue])? {
    guard let pairs = components(of: foreignKey, values: values) else { return nil }
    var parameters: [String: SQLBindValue] = [:]
    var terms: [String] = []
    for (offset, pair) in pairs.enumerated() {
      let name = "fk\(offset + 1)"
      parameters[name] = .text(pair.text)
      let column = quotedIdentifier(pair.column, dialect: dialect)
      terms.append("\(column) = :\(name)")
    }
    let relation = quotedRelation(
      schema: foreignKey.targetSchema, table: foreignKey.targetTable, dialect: dialect)
    let sql = "SELECT * FROM \(relation) WHERE \(terms.joined(separator: " AND ")) LIMIT 2"
    return (sql, parameters)
  }

  /// Equals conditions on the target columns, in source-column order.
  /// Nil when a component is missing or NULL, or the two column lists differ.
  static func jumpFilter(
    for foreignKey: ForeignKey, values: [String: CellValue]
  ) -> TableFilter? {
    guard let pairs = components(of: foreignKey, values: values) else { return nil }
    let conditions = pairs.map { pair in
      FilterCondition(
        column: pair.column, op: .equals, value: pair.text, connector: .and,
        emptyStringIsValue: pair.text.isEmpty)
    }
    return TableFilter(conditions: conditions)
  }

  /// Target column plus untyped bind text, in source-column order.
  /// Nil if any source value is missing or NULL. Does not emit `= NULL`.
  private static func components(
    of foreignKey: ForeignKey, values: [String: CellValue]
  ) -> [(column: String, text: String)]? {
    guard !foreignKey.sourceColumns.isEmpty,
      foreignKey.sourceColumns.count == foreignKey.targetColumns.count
    else { return nil }
    var pairs: [(column: String, text: String)] = []
    for (index, source) in foreignKey.sourceColumns.enumerated() {
      guard let value = values[source], let text = inputText(value) else { return nil }
      pairs.append((foreignKey.targetColumns[index], text))
    }
    return pairs
  }

  /// Untyped input text. Nil is SQL NULL.
  private static func inputText(_ value: CellValue) -> String? {
    switch value {
    case .null:
      nil
    case .int(let number):
      String(number)
    case .double(let number):
      String(number)
    case .bool(let flag):
      flag ? "true" : "false"
    case .string(let text), .json(let text):
      text
    case .date(let date):
      ISO8601DateFormatter().string(from: date)
    case .data(let data):
      "\\x" + data.map { String(format: "%02x", $0) }.joined()
    }
  }

  /// `"schema"."name"` when schema is non-empty, including the default schema.
  /// An empty schema is `"name"` alone, matching `DataViewerState`.
  private static func quotedRelation(
    schema: String, table: String, dialect: SQLDialect
  ) -> String {
    let quotedTable = quotedIdentifier(table, dialect: dialect)
    guard !schema.isEmpty else { return quotedTable }
    return quotedIdentifier(schema, dialect: dialect) + "." + quotedTable
  }

  /// Dialect quoting, or the historical non-throwing quote when the name contains NUL.
  private static func quotedIdentifier(_ name: String, dialect: SQLDialect) -> String {
    do {
      return try dialect.quoteIdentifier(name)
    } catch {
      return CellUpdateStatement.quoteIdentifier(name)
    }
  }
}
