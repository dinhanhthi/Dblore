// EditTypes.swift
// Inline grid edit types: the primary-key UPDATE statement, the server-resolved table,
// and the live edit target. Neutral binds live on the statement; PostgresNIO bindings
// stay in DatabaseConnectionManager+CellUpdate.

import Foundation

/// `SELECT 1 FROM <table> WHERE <pk> = ? ... FOR UPDATE`: does the row an UPDATE targeted
/// still exist. MySQL reports changed rows, not matched ones (CLIENT_FOUND_ROWS is off), so an
/// UPDATE that writes the stored value affects 0 rows; the locking read (current, not the
/// transaction snapshot) tells that apart from a row deleted elsewhere. Nil text binds NULL.
nonisolated struct RowExistenceCheck: Sendable, Equatable {
  let sql: String
  let values: [String?]

  var binds: [SQLBindValue] {
    values.map(SQLBindValue.init(optionalText:))
  }
}

/// `UPDATE [ONLY] <table> SET <column> = $1 WHERE <pk1> = $2 [AND ...]` for one grid cell.
/// MySQL: backticks and `?`. Identifiers are quoted; values never appear in the SQL text.
nonisolated struct CellUpdateStatement: Sendable, Equatable {
  let sql: String
  /// `$1` is the new value, `$2...` the primary-key values in key order; nil binds NULL
  let values: [String?]
  /// MySQL: checks a 0-affected UPDATE against the row (see `RowExistenceCheck`)
  var rowCheck: RowExistenceCheck? = nil

  /// Neutral binds for `values`. Nil text is `.null`; any other string is `.text`.
  var binds: [SQLBindValue] {
    values.map(SQLBindValue.init(optionalText:))
  }

  /// Builds the UPDATE for one cell of `rowData`, keyed by `primaryKeyColumns` only.
  /// - Parameters:
  ///   - qualifiedName: the server's `format('%I.%I', schema, table)` of the edit target
  ///     (MySQL: two backtick-quoted names), inserted verbatim (never user text; see
  ///     `isServerQualifiedName`)
  ///   - newValue: the new value as input text; nil sets NULL
  ///   - updateOnly: emit `UPDATE ONLY` (plain tables: never touch inheritance children); only
  ///     where `dialect.supportsUpdateOnly`
  /// - Throws: `DatabaseError.notEditable` when the row cannot be targeted by its primary key
  static func make(
    qualifiedName: String, columnName: String, newValue: String?, primaryKeyColumns: [String],
    rowData: [String: CellValue], updateOnly: Bool = false, dialect: SQLDialect = .postgresql
  ) throws -> CellUpdateStatement {
    guard isServerQualifiedName(qualifiedName, dialect: dialect) else {
      throw DatabaseError.notEditable("unsupported table name \"\(qualifiedName)\"")
    }
    guard !primaryKeyColumns.isEmpty else {
      throw DatabaseError.notEditable("the table has no primary key")
    }
    var keyValues: [String] = []
    var conditions: [String] = []
    for (index, column) in primaryKeyColumns.enumerated() {
      guard let value = rowData[column] else {
        throw DatabaseError.notEditable("primary key column \"\(column)\" is not in the result")
      }
      guard let text = inputText(value, dialect: dialect) else {
        throw DatabaseError.notEditable("primary key column \"\(column)\" is NULL")
      }
      keyValues.append(text)
      let placeholder = bindPlaceholder(dialect.placeholder(index + 2), value, dialect: dialect)
      conditions.append("\(quoteIdentifier(column, dialect: dialect)) = \(placeholder)")
    }
    let only = updateOnly && dialect.supportsUpdateOnly ? "ONLY " : ""
    let condition = conditions.joined(separator: " AND ")
    let sql =
      "UPDATE \(only)\(qualifiedName) SET \(quoteIdentifier(columnName, dialect: dialect))"
      + " = \(dialect.placeholder(1)) WHERE \(condition)"
    var statement = CellUpdateStatement(sql: sql, values: [newValue] + keyValues)
    if dialect == .mysql {
      statement.rowCheck = RowExistenceCheck(
        sql: "SELECT 1 FROM \(qualifiedName) WHERE \(condition) FOR UPDATE", values: keyValues)
    }
    return statement
  }

  /// True if `name` has the shape of `format('%I.%I', ...)` output: exactly two identifiers
  /// joined by `.`, each either `[a-z_][a-z0-9_]*` or a non-empty `"..."` with `""` escapes.
  /// MySQL: each a non-empty `` `...` `` with doubled backticks (`MySQLSchemaIntrospector`).
  static func isServerQualifiedName(_ name: String, dialect: SQLDialect = .postgresql) -> Bool {
    let quote: Unicode.Scalar = dialect == .mysql ? "`" : "\""
    let scalars = Array(name.unicodeScalars)
    guard let dot = identifierEnd(scalars, from: 0, quote: quote), dot < scalars.count,
      scalars[dot] == ".",
      let end = identifierEnd(scalars, from: dot + 1, quote: quote)
    else { return false }
    return end == scalars.count
  }

  /// End offset of the `%I` identifier starting at `start`, or nil if there is none. A MySQL
  /// (backtick) identifier is always quoted.
  private static func identifierEnd(
    _ s: [Unicode.Scalar], from start: Int, quote: Unicode.Scalar
  ) -> Int? {
    guard start < s.count else { return nil }
    guard s[start] == quote else {
      guard quote == "\"", s[start] == "_" || ("a"..."z").contains(s[start]) else { return nil }
      var i = start + 1
      while i < s.count, s[i] == "_" || ("a"..."z").contains(s[i]) || ("0"..."9").contains(s[i]) {
        i += 1
      }
      return i
    }
    var i = start + 1
    while i < s.count {
      if s[i] == quote {
        guard i + 1 < s.count, s[i + 1] == quote else { return i > start + 1 ? i + 1 : nil }
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
  /// `dialect` lexes the query and re-quotes quoted parts.
  static func singleRelation(in sql: String, dialect: SQLDialect = .postgresql) -> String? {
    var tokens = SQLTokenizer(dialect: dialect).tokens(sql)
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
      case .quotedIdentifier: return quoteIdentifier(tokens[index].text, dialect: dialect)
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
    let tableID = table.resolvedTableRef
    for column in columns {
      guard let origin = column.origin, origin.tableID == tableID,
        let attnum = Int16(exactly: origin.columnOrdinal),
        table.attributeNames[attnum] == column.name
      else { return [] }
    }
    let names = Set(columns.map(\.name))
    return table.primaryKeyColumns.allSatisfy(names.contains) ? table.primaryKeyColumns : []
  }

  /// Read-only relation of a single-table result for the referenced-row lookup, or nil. Every
  /// column with an origin must come from `table`; a column of another table (a join) gives
  /// nil. A column with no origin (an expression) or an unknown ordinal maps to no base column.
  /// A MySQL column whose ordinal names another column than its source name gives nil.
  /// Never an edit target: editing keeps `editablePrimaryKey`.
  static func lookupRelation(columns: [ColumnInfo], table: EditTable?) -> LookupRelation? {
    guard let table, let schema = table.schema, let name = table.name else { return nil }
    let tableID = table.resolvedTableRef
    var baseColumns: [String?] = []
    for column in columns {
      guard let origin = column.tableOrigin else {
        baseColumns.append(nil)
        continue
      }
      guard origin.tableID == tableID else { return nil }
      let base = Int16(exactly: origin.columnOrdinal).flatMap { table.attributeNames[$0] }
      // MySQL ordinals come from a cache: one that now names another column is stale.
      if let source = column.sourceName, base != source.column { return nil }
      baseColumns.append(base)
    }
    guard baseColumns.contains(where: { $0 != nil }) else { return nil }
    return LookupRelation(
      schema: schema, table: name, baseColumns: baseColumns,
      connectionEpoch: table.connectionEpoch)
  }

  /// `name` quoted by `dialect` (`"name"` with embedded double quotes doubled for PostgreSQL).
  /// A NUL cannot be quoted by the dialect, so it keeps the historical quote-and-double-quotes
  /// text; MySQL keeps backticks (a double-quoted MySQL name is a string literal). The server
  /// then refuses the name.
  static func quoteIdentifier(_ name: String, dialect: SQLDialect = .postgresql) -> String {
    do {
      return try dialect.quoteIdentifier(name)
    } catch {
      let quote = dialect == .mysql ? "`" : "\""
      return quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote
    }
  }

  /// Input text for a result value (nil for NULL). PostgreSQL: `true`/`false`, ISO 8601 dates,
  /// `\x` hex bytes. MySQL: `1`/`0`, `YYYY-MM-DD HH:MM:SS.ffffff` (the session is UTC), and
  /// bare hex bytes for `bindPlaceholder`'s `UNHEX(?)` (every MySQL bind is sent as a string).
  static func inputText(_ value: CellValue, dialect: SQLDialect) -> String? {
    let mysql = dialect == .mysql
    switch value {
    case .null: return nil
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .bool(let flag): return mysql ? (flag ? "1" : "0") : (flag ? "true" : "false")
    case .string(let text), .json(let text): return text
    case .date(let date):
      let text = DateBindText.string(from: date)
      guard mysql else { return text }
      return String(text.dropLast()).replacingOccurrences(of: "T", with: " ")
    case .data(let data):
      let hex = data.map { String(format: "%02x", $0) }.joined()
      return mysql ? hex : "\\x" + hex
    }
  }

  /// `placeholder` for `value`'s bind, or MySQL `UNHEX(placeholder)` for bytes (`inputText`).
  static func bindPlaceholder(
    _ placeholder: String, _ value: CellValue, dialect: SQLDialect
  ) -> String {
    if dialect == .mysql, case .data = value { return "UNHEX(\(placeholder))" }
    return placeholder
  }
}

/// The table an inline edit targets, as resolved by the server: OID, column names by attribute
/// number, primary key columns in key order, and the unquoted catalog schema and table name.
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
  /// Column-origin identity. Nil uses PostgreSQL `pg:<oid>`.
  var tableRef: TableRef? = nil
  /// Unquoted catalog schema (`nspname` or the SQLite schema). Nil when unknown.
  var schema: String? = nil
  /// Unquoted catalog table name (`relname` or the SQLite table). Nil when unknown.
  var name: String? = nil
  /// Generated columns (SQLite `hidden` 2/3, PostgreSQL `attgenerated`): never written
  var generatedColumns: Set<String> = []

  /// Identity compared with result column origins.
  var resolvedTableRef: TableRef {
    tableRef ?? .postgresql(oid: oid)
  }
}

/// Read-only source relation of a single-table result for "Referenced Row...", aliased columns
/// included. Never used to edit. Session-only (never persisted). `connectionEpoch` pins the
/// lookup to the connection the table was resolved on.
nonisolated struct LookupRelation: Sendable, Equatable {
  /// Unquoted catalog schema and table name
  let schema: String
  let table: String
  /// Base column name of each result column, in result order. Nil: an expression or a column
  /// the table does not name.
  let baseColumns: [String?]
  let connectionEpoch: UInt64
}

/// Edit target and lookup relation resolved for one live result
typealias ResultTargets = (editTarget: EditTarget?, lookupRelation: LookupRelation?)

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
  /// Unquoted catalog schema (`nspname` or the SQLite schema). Nil when unknown.
  let schema: String?
  /// Unquoted catalog table name (`relname` or the SQLite table). Nil when unknown.
  let name: String?
  /// Generated columns: read-only in the grid and left out of staged UPDATE and INSERT
  let generatedColumns: Set<String>

  init(
    qualifiedName: String, tableID: TableRef, primaryKeyColumns: [String],
    connectionEpoch: UInt64 = 0, updateOnly: Bool = false, generation: UUID = UUID(),
    schema: String? = nil, name: String? = nil, generatedColumns: Set<String> = []
  ) {
    self.qualifiedName = qualifiedName
    self.tableID = tableID
    self.primaryKeyColumns = primaryKeyColumns
    self.connectionEpoch = connectionEpoch
    self.updateOnly = updateOnly
    self.generation = generation
    self.schema = schema
    self.name = name
    self.generatedColumns = generatedColumns
  }
}
