// EditTypes.swift
// Inline grid edit types: the primary-key UPDATE statement, the server-resolved table,
// and the live edit target. Neutral binds live on the statement; PostgresNIO bindings
// stay in DatabaseConnectionManager+CellUpdate.

import Foundation

/// `UPDATE [ONLY] <table> SET <column> = $1 WHERE <pk1> = $2 [AND ...]` for one grid cell.
/// Identifiers are quoted; values never appear in the SQL text.
nonisolated struct CellUpdateStatement: Sendable, Equatable {
  let sql: String
  /// `$1` is the new value, `$2...` the primary-key values in key order; nil binds NULL
  let values: [String?]

  /// Neutral binds for `values`. Nil text is `.null`; any other string is `.text`.
  var binds: [SQLBindValue] {
    values.map(SQLBindValue.init(optionalText:))
  }

  /// Builds the UPDATE for one cell of `rowData`, keyed by `primaryKeyColumns` only.
  /// - Parameters:
  ///   - qualifiedName: the server's `format('%I.%I', schema, table)` of the edit target,
  ///     inserted verbatim (never user text; see `isServerQualifiedName`)
  ///   - newValue: the new value as PostgreSQL input text; nil sets NULL
  ///   - updateOnly: emit `UPDATE ONLY` (plain tables: never touch inheritance children)
  /// - Throws: `DatabaseError.notEditable` when the row cannot be targeted by its primary key
  static func make(
    qualifiedName: String, columnName: String, newValue: String?, primaryKeyColumns: [String],
    rowData: [String: CellValue], updateOnly: Bool = false
  ) throws -> CellUpdateStatement {
    guard isServerQualifiedName(qualifiedName) else {
      throw DatabaseError.notEditable("unsupported table name \"\(qualifiedName)\"")
    }
    guard !primaryKeyColumns.isEmpty else {
      throw DatabaseError.notEditable("the table has no primary key")
    }
    var keyValues: [String] = []
    for column in primaryKeyColumns {
      guard let value = rowData[column] else {
        throw DatabaseError.notEditable("primary key column \"\(column)\" is not in the result")
      }
      guard let text = inputText(value) else {
        throw DatabaseError.notEditable("primary key column \"\(column)\" is NULL")
      }
      keyValues.append(text)
    }
    let conditions = primaryKeyColumns.enumerated().map { index, column in
      "\(quoteIdentifier(column)) = $\(index + 2)"
    }
    let sql =
      "UPDATE \(updateOnly ? "ONLY " : "")\(qualifiedName) SET \(quoteIdentifier(columnName)) = $1"
      + " WHERE \(conditions.joined(separator: " AND "))"
    return CellUpdateStatement(sql: sql, values: [newValue] + keyValues)
  }

  /// True if `name` has the shape of `format('%I.%I', ...)` output: exactly two identifiers
  /// joined by `.`, each either `[a-z_][a-z0-9_]*` or a non-empty `"..."` with `""` escapes.
  static func isServerQualifiedName(_ name: String) -> Bool {
    let scalars = Array(name.unicodeScalars)
    guard let dot = identifierEnd(scalars, from: 0), dot < scalars.count, scalars[dot] == ".",
      let end = identifierEnd(scalars, from: dot + 1)
    else { return false }
    return end == scalars.count
  }

  /// End offset of the `%I` identifier starting at `start`, or nil if there is none.
  private static func identifierEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
    guard start < s.count else { return nil }
    guard s[start] == "\"" else {
      guard s[start] == "_" || ("a"..."z").contains(s[start]) else { return nil }
      var i = start + 1
      while i < s.count, s[i] == "_" || ("a"..."z").contains(s[i]) || ("0"..."9").contains(s[i]) {
        i += 1
      }
      return i
    }
    var i = start + 1
    while i < s.count {
      if s[i] == "\"" {
        guard i + 1 < s.count, s[i + 1] == "\"" else { return i > start + 1 ? i + 1 : nil }
        i += 2
      } else {
        i += 1
      }
    }
    return nil
  }

  /// Words that make a SELECT non-editable wherever they appear: subquery, CTE, set operation,
  /// join, SELECT INTO.
  private static let nonEditableWords: Set<String> = [
    "SELECT", "WITH", "UNION", "INTERSECT", "EXCEPT", "JOIN", "LATERAL", "INTO",
  ]
  /// Clauses that may follow the relation of an editable SELECT
  private static let trailingClauses: Set<String> = ["WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH"]

  /// The relation of `SELECT ... FROM <relation> [[AS] alias] [WHERE|ORDER|LIMIT|OFFSET|FETCH ...]`
  /// as text for `to_regclass` (`name` or `schema.name`, quoted parts re-quoted), or nil for
  /// anything else (fail closed): a comma or `(` after the relation, JOIN, subquery, CTE, set
  /// operation, other clauses, several statements or an ambiguous backslash string.
  static func singleRelation(in sql: String) -> String? {
    var tokens = SQLTokenizer.tokens(sql)
    if tokens.last?.isSymbol(";") == true { tokens.removeLast() }
    guard let first = tokens.first, first.isWord("SELECT") else { return nil }
    let forbidden = tokens.dropFirst().contains { token in
      token.kind == .backslashString || token.isSymbol(";")
        || token.keyword.map(nonEditableWords.contains) == true
    }
    let froms = tokens.indices.filter { tokens[$0].depth == 0 && tokens[$0].isWord("FROM") }
    guard !forbidden, froms.count == 1, let from = froms.first else { return nil }

    func name(at index: Int) -> String? {
      guard index < tokens.count else { return nil }
      switch tokens[index].kind {
      case .word: return tokens[index].text
      case .quotedIdentifier: return quoteIdentifier(tokens[index].text)
      default: return nil
      }
    }
    func isClause(_ index: Int) -> Bool {
      index < tokens.count && tokens[index].keyword.map(trailingClauses.contains) == true
    }
    guard var relation = name(at: from + 1) else { return nil }
    var i = from + 2
    if i < tokens.count, tokens[i].isSymbol(".") {
      guard let table = name(at: i + 1) else { return nil }
      relation += "." + table
      i += 2
    }
    if i < tokens.count, tokens[i].isWord("AS") {
      guard name(at: i + 1) != nil else { return nil }
      i += 2
    } else if name(at: i) != nil, !isClause(i) {
      i += 1
    }
    return i == tokens.count || isClause(i) ? relation : nil
  }

  /// Primary key columns an inline edit of a result with `columns` may use, or empty when the
  /// result is not editable. Fail closed: EVERY column must be a plain column of `table`
  /// (source table identity equal to the table, and an attribute number whose
  /// name is the column name), and every primary key column must be in the result. So joins,
  /// comma joins, computed or aliased columns and scalar subqueries make the result read-only,
  /// and a PK value can never come from another table or expression (duplicate names included).
  static func editablePrimaryKey(columns: [ColumnInfo], table: EditTable?) -> [String] {
    guard let table, table.oid != 0, !table.primaryKeyColumns.isEmpty, !columns.isEmpty else {
      return []
    }
    let tableID = TableRef.postgresql(oid: table.oid)
    for column in columns {
      guard let origin = column.origin, origin.tableID == tableID,
        let attnum = Int16(exactly: origin.columnOrdinal),
        table.attributeNames[attnum] == column.name
      else { return [] }
    }
    let names = Set(columns.map(\.name))
    return table.primaryKeyColumns.allSatisfy(names.contains) ? table.primaryKeyColumns : []
  }

  /// `"name"` with embedded double quotes doubled. A NUL cannot be quoted by the dialect,
  /// so it keeps the historical quote-and-double-quotes text.
  static func quoteIdentifier(_ name: String) -> String {
    do {
      return try SQLDialect.postgresql.quoteIdentifier(name)
    } catch {
      return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
  }

  /// PostgreSQL input text for a result value (nil for NULL)
  private static func inputText(_ value: CellValue) -> String? {
    switch value {
    case .null: nil
    case .int(let number): String(number)
    case .double(let number): String(number)
    case .bool(let flag): flag ? "true" : "false"
    case .string(let text), .json(let text): text
    case .date(let date): ISO8601DateFormatter().string(from: date)
    case .data(let data): "\\x" + data.map { String(format: "%02x", $0) }.joined()
    }
  }
}

/// The table an inline edit targets, as resolved by the server: OID, column names by attribute
/// number, and primary key columns in key order.
nonisolated struct EditTable: Sendable, Equatable {
  let oid: UInt32
  let attributeNames: [Int16: String]
  let primaryKeyColumns: [String]
  /// Server-resolved `format('%I.%I', schema, table)`
  var qualifiedName: String = ""
  /// Connection epoch the table was resolved on (`DatabaseConnectionManager.connectionEpoch`)
  var connectionEpoch: UInt64 = 0
  /// Plain table (`relkind = 'r'`): updated with `UPDATE ONLY`; false for a partitioned table
  var updateOnly: Bool = false
}

/// The validated target of inline edits for one live result: server-resolved qualified name,
/// table identity and primary key columns in key order. Session-only (never persisted); each live
/// execution creates a new `generation`, so an edit can be checked against the result it was
/// opened from, and carries the `connectionEpoch` it was resolved on, so the actor refuses it
/// after a reconnect or connection switch. Callers compare `tableID`; they do not read a catalog OID.
nonisolated struct EditTarget: Sendable, Equatable {
  let qualifiedName: String
  let tableID: TableRef
  let primaryKeyColumns: [String]
  let connectionEpoch: UInt64
  /// Emit `UPDATE ONLY` (plain table)
  let updateOnly: Bool
  let generation: UUID

  init(
    qualifiedName: String, tableID: TableRef, primaryKeyColumns: [String],
    connectionEpoch: UInt64 = 0, updateOnly: Bool = false, generation: UUID = UUID()
  ) {
    self.qualifiedName = qualifiedName
    self.tableID = tableID
    self.primaryKeyColumns = primaryKeyColumns
    self.connectionEpoch = connectionEpoch
    self.updateOnly = updateOnly
    self.generation = generation
  }
}
