//
//  DatabaseConnectionManager+CellUpdate.swift
//  SQLNotebook
//
//  Inline grid edit: primary-key-only UPDATE with bind parameters. Sent through
//  `executeGatedUpdate(_:policy:connectionEpoch:)` in +Gate.
//

import Foundation
import Logging
import NIOCore
import PostgresNIO

/// `UPDATE [ONLY] <table> SET <column> = $1 WHERE <pk1> = $2 [AND ...]` for one grid cell.
/// Identifiers are quoted; values never appear in the SQL text.
nonisolated struct CellUpdateStatement: Sendable, Equatable {
  let sql: String
  /// `$1` is the new value, `$2...` the primary-key values in key order; nil binds NULL
  let values: [String?]

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
  /// (server-reported source table OID equal to the table's OID and an attribute number whose
  /// name is the column name), and every primary key column must be in the result. So joins,
  /// comma joins, computed or aliased columns and scalar subqueries make the result read-only,
  /// and a PK value can never come from another table or expression (duplicate names included).
  static func editablePrimaryKey(columns: [ColumnInfo], table: EditTable?) -> [String] {
    guard let table, table.oid != 0, !table.primaryKeyColumns.isEmpty, !columns.isEmpty else {
      return []
    }
    for column in columns {
      guard column.tableOID == table.oid, let attnum = column.attributeNumber,
        table.attributeNames[attnum] == column.name
      else { return [] }
    }
    let names = Set(columns.map(\.name))
    return table.primaryKeyColumns.allSatisfy(names.contains) ? table.primaryKeyColumns : []
  }

  /// `"name"` with embedded double quotes doubled
  static func quoteIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// Bind parameters: untyped text (the server infers each parameter's type from the column,
  /// like libpq's `PQexecParams` without `paramTypes`), NULL for nil.
  var bindings: PostgresBindings {
    var bindings = PostgresBindings(capacity: values.count)
    for value in values {
      if let value {
        bindings.append(UntypedText(value))
      } else {
        bindings.appendNull()
      }
    }
    return bindings
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
/// table OID and primary key columns in key order. Session-only (never persisted); each live
/// execution creates a new `generation`, so an edit can be checked against the result it was
/// opened from, and carries the `connectionEpoch` it was resolved on, so the actor refuses it
/// after a reconnect or connection switch.
nonisolated struct EditTarget: Sendable, Equatable {
  let qualifiedName: String
  let oid: UInt32
  let primaryKeyColumns: [String]
  let connectionEpoch: UInt64
  /// Emit `UPDATE ONLY` (plain table)
  let updateOnly: Bool
  let generation: UUID

  init(
    qualifiedName: String, oid: UInt32, primaryKeyColumns: [String], connectionEpoch: UInt64 = 0,
    updateOnly: Bool = false, generation: UUID = UUID()
  ) {
    self.qualifiedName = qualifiedName
    self.oid = oid
    self.primaryKeyColumns = primaryKeyColumns
    self.connectionEpoch = connectionEpoch
    self.updateOnly = updateOnly
    self.generation = generation
  }
}

extension ColumnInfo {
  /// Column metadata with its source table OID / attribute number from the RowDescription
  nonisolated init(name: String, type: String, origin: PostgresColumn?) {
    self.init(
      name: name, type: type, tableOID: origin.map { UInt32(bitPattern: $0.tableOID) },
      attributeNumber: origin?.columnAttributeNumber)
  }
}

extension DatabaseConnectionManager {
  /// Resolve `tableName` (`table` or `schema.table`, bound and resolved with `to_regclass` like
  /// the query did via search_path) to its OID, server-qualified name, columns and primary key.
  /// nil if not editable: not a plain (`r`) or partitioned (`p`) table, a plain table with
  /// inheritance children (`relhassubclass`: a SELECT of the parent also returns child rows and
  /// the primary key is not unique across them), or the connection changed during the lookup.
  func fetchEditTable(tableName: String) async throws -> EditTable? {
    guard let connection = _connection else { throw DatabaseError.notConnected }
    let epoch = connectionEpoch
    var binds = PostgresBindings(capacity: 1)
    binds.append(tableName)
    let query = PostgresQuery(
      unsafeSQL: """
        SELECT c.oid::int8, a.attnum::int4, a.attname::text,
               COALESCE((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(att, ord)
                         WHERE k.att = a.attnum), 0)::int4,
               format('%I.%I', n.nspname, c.relname), c.relkind::text, c.relhassubclass
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
        WHERE c.oid = to_regclass($1)
        """, binds: binds)
    var oid: UInt32 = 0
    var qualifiedName = ""
    var names: [Int16: String] = [:]
    var keyPositions: [(position: Int32, name: String)] = []
    var relationKind = ""
    var hasSubclass = true
    let rows = try await connection.query(query, logger: Logger(label: "sqlnotebook.edit"))
    for try await (tableOID, attnum, name, keyPosition, qualified, kind, subclass) in rows.decode(
      (Int64, Int32, String, Int32, String, String, Bool).self)
    {
      guard let number = Int16(exactly: attnum), let tableID = UInt32(exactly: tableOID) else {
        continue
      }
      oid = tableID
      qualifiedName = qualified
      relationKind = kind
      hasSubclass = subclass
      names[number] = name
      if keyPosition > 0 { keyPositions.append((keyPosition, name)) }
    }
    guard oid != 0, epoch == connectionEpoch,
      relationKind == "p" || (relationKind == "r" && !hasSubclass)
    else { return nil }
    let primaryKey = keyPositions.sorted { $0.position < $1.position }.map(\.name)
    return EditTable(
      oid: oid, attributeNames: names, primaryKeyColumns: primaryKey, qualifiedName: qualifiedName,
      connectionEpoch: epoch, updateOnly: relationKind == "r")
  }
}

/// A text-format parameter with an unspecified type (OID 0): PostgreSQL resolves the type from
/// the statement (`SET col = $1`, `pk = $2`), so no type name is ever spliced into the SQL.
private nonisolated struct UntypedText: PostgresDynamicTypeEncodable {
  let text: String
  init(_ text: String) { self.text = text }

  var psqlType: PostgresDataType { .null }  // OID 0 = unspecified
  var psqlFormat: PostgresFormat { .text }

  func encode<JSONEncoder: PostgresJSONEncoder>(
    into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
  ) {
    byteBuffer.writeString(text)
  }
}
