// RowChangeSQLBuilder.swift
// DELETE, UPDATE, and INSERT statements for one staged row change set.
// Bound statements keep values out of the SQL. Preview text inlines literals for display.
// MySQL: backticks, `?`, no ONLY, `() VALUES ()`, bytes through `UNHEX(?)`; an UPDATE skips
// columns whose bind text equals the loaded value and carries a row check (0 affected rows
// is either a same-value write or a missing row: CLIENT_FOUND_ROWS is off).

import Foundation

/// One statement and its untyped text binds. Nil is SQL NULL.
nonisolated struct BoundStatement: Equatable, Sendable {
  var sql: String
  var values: [String?]
  var expectedRows: Int? = 1
  /// MySQL UPDATE: run when it affects 0 rows; a row found counts as the 1 expected
  var rowCheck: RowExistenceCheck? = nil
  /// The statement as its caller already classified it (a restore plan), so the batch does not
  /// tokenize `sql` again; nil classifies `sql` with the connection's dialect
  var classified: ClassifiedStatement? = nil

  /// Neutral binds for `values`. Nil text is `.null`; any other string is `.text`.
  var binds: [SQLBindValue] {
    values.map(SQLBindValue.init(optionalText:))
  }
}

/// Builds bound DML, then a display-only preview, for a `RowChangeSet`.
/// Statement order is every DELETE, then every UPDATE, then every INSERT.
/// Throws `RowChangeError.noRowKey` when the set has an UPDATE or DELETE and the target no key.
nonisolated enum RowChangeSQLBuilder {
  static func statements(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) throws -> [BoundStatement] {
    try drafts(for: set, target: target, columns: columns, dialect: dialect).map {
      var statement = $0.bound(dialect: dialect)
      statement.rowCheck = $0.rowCheck
      return statement
    }
  }

  /// The Data Rewind step of each statement `statements(for:...)` returns, in the same order.
  /// An INSERT is read back only when its values hold every key column (D4).
  static func rewindSteps(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) throws -> [RewindPlan.Step] {
    try drafts(for: set, target: target, columns: columns, dialect: dialect)
      .compactMap(\.rewindStep)
  }

  static func previewText(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) throws -> String {
    try drafts(for: set, target: target, columns: columns, dialect: dialect)
      .map { $0.preview(dialect: dialect) }
      .joined(separator: "\n")
  }

  private static func drafts(
    for set: RowChangeSet, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) throws -> [StatementDraft] {
    // Without a key a WHERE would match every row: no UPDATE or DELETE (no ctid-style edits).
    if target.primaryKeyColumns.isEmpty, !set.deletes.isEmpty || !set.edits.isEmpty {
      throw RowChangeError.noRowKey(table: target.qualifiedName)
    }
    let relation = relationName(target)
    let only = target.updateOnly && dialect.supportsUpdateOnly
    var result: [StatementDraft] = []
    result.reserveCapacity(set.deletes.count + set.edits.count + set.inserts.count)
    for row in set.deletes {
      var draft = delete(row, relation: relation, only: only, target: target, dialect: dialect)
      draft.rewindStep = RewindPlan.Step(operation: .delete, keyBefore: row.values, keyAfter: nil)
      result.append(draft)
    }
    for (row, changes) in set.edits {
      if var update = update(
        row, changes: changes, originals: set.originals[row] ?? [:], relation: relation,
        only: only, target: target, columns: columns, dialect: dialect)
      {
        update.rewindStep = RewindPlan.Step(
          operation: .update, keyBefore: row.values, keyAfter: row.values)
        result.append(update)
      }
    }
    for insert in set.inserts {
      var draft = insertStatement(
        insert.values, relation: relation, columns: columns,
        generated: target.generatedColumns, dialect: dialect)
      draft.rewindStep = RewindPlan.Step(
        operation: .insert, keyBefore: nil,
        keyAfter: insertedKey(insert.values, target: target, columns: columns))
      result.append(draft)
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
    _ row: RowChangeSet.RowKey, changes: [String: CellValue], originals: [String: CellValue],
    relation: String, only: Bool, target: EditTarget, columns: [ColumnInfo], dialect: SQLDialect
  ) -> StatementDraft? {
    let keys = Set(target.primaryKeyColumns)
    let edited = columns.filter { column in
      guard let value = changes[column.name], !keys.contains(column.name),
        !target.generatedColumns.contains(column.name)
      else { return false }
      return !(dialect == .mysql && sameBindText(value, originals[column.name], dialect: dialect))
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
    if dialect == .mysql {
      var check = StatementDraft()
      check.text("SELECT 1 FROM \(relation)")
      appendWhere(row.values, columns: target.primaryKeyColumns, to: &check, dialect: dialect)
      check.text(" FOR UPDATE")
      let bound = check.bound(dialect: dialect)
      draft.rowCheck = RowExistenceCheck(sql: bound.sql, values: bound.values)
    }
    return draft
  }

  /// The key an INSERT of `values` writes, or nil when a key column is left to the database:
  /// missing, NULL, generated, or not a column the INSERT sends.
  private static func insertedKey(
    _ values: [String: CellValue], target: EditTarget, columns: [ColumnInfo]
  ) -> [CellValue]? {
    let sent = Set(columns.map(\.name))
    var key: [CellValue] = []
    for column in target.primaryKeyColumns {
      guard let value = values[column], sent.contains(column),
        !target.generatedColumns.contains(column)
      else { return nil }
      if case .null = value { return nil }
      key.append(value)
    }
    return key.isEmpty ? nil : key
  }

  /// True when `original` is loaded and binds the same text as `value` (the server would
  /// store the same value).
  private static func sameBindText(
    _ value: CellValue, _ original: CellValue?, dialect: SQLDialect
  ) -> Bool {
    guard let original else { return false }
    return CellUpdateStatement.inputText(value, dialect: dialect)
      == CellUpdateStatement.inputText(original, dialect: dialect)
  }

  private static func insertStatement(
    _ values: [String: CellValue], relation: String, columns: [ColumnInfo],
    generated: Set<String>, dialect: SQLDialect
  ) -> StatementDraft {
    let included = columns.filter { values[$0.name] != nil && !generated.contains($0.name) }
    var draft = StatementDraft()
    draft.text("INSERT INTO \(relation)")
    guard !included.isEmpty else {
      draft.text(dialect == .mysql ? " () VALUES ()" : " DEFAULT VALUES")
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

  /// `dialect.quoteIdentifier`, or the dialect's quote doubled when the name contains a NUL.
  private static func quote(_ name: String, dialect: SQLDialect) -> String {
    CellUpdateStatement.quoteIdentifier(name, dialect: dialect)
  }
}

/// SQL text split into literal pieces and cell values, so binds and preview stay separate.
private nonisolated struct StatementDraft {
  private enum Segment {
    case text(String)
    case value(CellValue)
  }

  private var segments: [Segment] = []
  /// The row check of a MySQL UPDATE (`BoundStatement.rowCheck`)
  var rowCheck: RowExistenceCheck? = nil
  /// What Data Rewind reads around this statement (`RowChangeSQLBuilder.rewindSteps`)
  var rewindStep: RewindPlan.Step? = nil

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
        sql += CellUpdateStatement.bindPlaceholder(
          dialect.placeholder(index), value, dialect: dialect)
        index += 1
        values.append(CellUpdateStatement.inputText(value, dialect: dialect))
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
}
