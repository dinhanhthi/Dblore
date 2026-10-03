// RowChangeSQLBuilder.swift
// DELETE, UPDATE, and INSERT statements for one staged row change set.
// Bound statements keep values out of the SQL. Preview text inlines literals for display.

import Foundation

/// One statement and its untyped text binds. Nil is SQL NULL.
nonisolated struct BoundStatement: Equatable, Sendable {
  var sql: String
  var values: [String?]
  var expectedRows: Int? = 1

  /// Neutral binds for `values`. Nil text is `.null`; any other string is `.text`.
  var binds: [SQLBindValue] {
    values.map(SQLBindValue.init(optionalText:))
  }
}

/// Builds bound DML, then a display-only preview, for a `RowChangeSet`.
/// Statement order is every DELETE, then every UPDATE, then every INSERT.
nonisolated enum RowChangeSQLBuilder {
  static func statements(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) -> [BoundStatement] {
    drafts(for: set, target: target, columns: columns, dialect: dialect).map {
      $0.bound(dialect: dialect)
    }
  }

  static func previewText(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) -> String {
    drafts(for: set, target: target, columns: columns, dialect: dialect)
      .map { $0.preview(dialect: dialect) }
      .joined(separator: "\n")
  }

  private static func drafts(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) -> [StatementDraft] {
    let relation = relationName(target)
    let only = target.updateOnly && dialect.supportsUpdateOnly
    var result: [StatementDraft] = []
    result.reserveCapacity(set.deletes.count + set.edits.count + set.inserts.count)
    for row in set.deletes {
      result.append(delete(row, relation: relation, only: only, target: target, dialect: dialect))
    }
    for (row, changes) in set.edits {
      if let update = update(
        row, changes: changes, relation: relation, only: only, target: target, columns: columns,
        dialect: dialect)
      {
        result.append(update)
      }
    }
    for insert in set.inserts {
      result.append(
        insertStatement(insert.values, relation: relation, columns: columns, dialect: dialect))
    }
    return result
  }

  private static func delete(
    _ row: RowChangeSet.RowKey, relation: String, only: Bool, target: EditTarget,
    dialect: SQLDialect
  ) -> StatementDraft {
    var draft = StatementDraft()
    draft.text("DELETE FROM")
    if only {
      draft.text(" ONLY")
    }
    draft.text(" \(relation)")
    appendWhere(row.values, columns: target.primaryKeyColumns, to: &draft, dialect: dialect)
    return draft
  }

  private static func update(
    _ row: RowChangeSet.RowKey, changes: [String: CellValue], relation: String, only: Bool,
    target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) -> StatementDraft? {
    let keys = Set(target.primaryKeyColumns)
    let edited = columns.filter { column in
      changes[column.name] != nil && !keys.contains(column.name)
    }
    guard !edited.isEmpty else { return nil }

    var draft = StatementDraft()
    draft.text("UPDATE ")
    if only {
      draft.text("ONLY ")
    }
    draft.text("\(relation) SET ")
    for (index, column) in edited.enumerated() {
      if index > 0 {
        draft.text(", ")
      }
      draft.text("\(quote(column.name, dialect: dialect)) = ")
      draft.value(changes[column.name] ?? .null)
    }
    appendWhere(row.values, columns: target.primaryKeyColumns, to: &draft, dialect: dialect)
    return draft
  }

  private static func insertStatement(
    _ values: [String: CellValue], relation: String, columns: [ColumnInfo], dialect: SQLDialect
  ) -> StatementDraft {
    let included = columns.filter { values[$0.name] != nil }
    var draft = StatementDraft()
    draft.text("INSERT INTO \(relation)")
    guard !included.isEmpty else {
      draft.text(" DEFAULT VALUES")
      return draft
    }
    let names = included.map { quote($0.name, dialect: dialect) }.joined(separator: ", ")
    draft.text(" (\(names)) VALUES (")
    for (index, column) in included.enumerated() {
      if index > 0 {
        draft.text(", ")
      }
      draft.value(values[column.name] ?? .null)
    }
    draft.text(")")
    return draft
  }

  private static func appendWhere(
    _ values: [CellValue], columns: [String], to draft: inout StatementDraft, dialect: SQLDialect
  ) {
    guard !columns.isEmpty else { return }
    draft.text(" WHERE ")
    for (index, column) in columns.enumerated() {
      if index > 0 {
        draft.text(" AND ")
      }
      draft.text("\(quote(column, dialect: dialect)) = ")
      let value = index < values.count ? values[index] : .null
      draft.value(value)
    }
  }

  /// Non-empty `qualifiedName` is server `format('%I.%I')` text. Do not quote it again.
  /// An empty name has no schema or table piece on `EditTarget` to quote.
  private static func relationName(_ target: EditTarget) -> String {
    target.qualifiedName
  }

  /// `dialect.quoteIdentifier`, or doubled quotes when the name contains a NUL.
  private static func quote(_ name: String, dialect: SQLDialect) -> String {
    do {
      return try dialect.quoteIdentifier(name)
    } catch {
      return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
  }
}

/// SQL text split into literal pieces and cell values, so binds and preview stay separate.
private nonisolated struct StatementDraft {
  private enum Segment {
    case text(String)
    case value(CellValue)
  }

  private var segments: [Segment] = []

  mutating func text(_ text: String) {
    segments.append(.text(text))
  }

  mutating func value(_ value: CellValue) {
    segments.append(.value(value))
  }

  func bound(dialect: SQLDialect) -> BoundStatement {
    var sql = ""
    var values: [String?] = []
    var index = 1
    for segment in segments {
      switch segment {
      case .text(let text):
        sql += text
      case .value(let value):
        sql += dialect.placeholder(index)
        index += 1
        values.append(bindText(value))
      }
    }
    return BoundStatement(sql: sql, values: values)
  }

  func preview(dialect: SQLDialect) -> String {
    var sql = ""
    for segment in segments {
      switch segment {
      case .text(let text):
        sql += text
      case .value(let value):
        sql += dialect.literal(value)
      }
    }
    return sql + ";"
  }

  /// PostgreSQL input text. Nil is SQL NULL. Matches `CellUpdateStatement` cell input.
  private func bindText(_ value: CellValue) -> String? {
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
}
