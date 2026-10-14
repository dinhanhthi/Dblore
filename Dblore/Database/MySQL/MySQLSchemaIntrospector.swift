// MySQLSchemaIntrospector.swift
// MySQL / MariaDB catalog reads for one open session, from information_schema only.
//
// Scope: the connected database (`ConnectionConfig.database`), always bound as a parameter. It
// is the schema of every object, so `allColumns` keys read `"<database>.<relation>"`.
// Tables are TABLE_TYPE 'BASE TABLE' (and MariaDB 'SYSTEM VERSIONED'); MariaDB sequences
// ('SEQUENCE') and system views are not listed. Keys come from STATISTICS: COLUMN_KEY shows
// PRI for a NOT NULL UNIQUE key of a table without a primary key.
// Routines and triggers are in `MySQLSchemaIntrospector+Routines.swift`. MySQL users and roles
// stay empty (`supportsRolesAndUsers` is false).

import Foundation

/// `information_schema` reads through `DatabaseSession.query`.
nonisolated struct MySQLSchemaIntrospector: SchemaIntrospector {
  /// The connected database. Every catalog read binds it.
  let database: String

  /// TABLE_TYPE values listed as tables.
  static let tableTypes = "('BASE TABLE', 'SYSTEM VERSIONED')"

  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    let sql = """
      SELECT TABLE_NAME, TABLE_ROWS
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = ? AND TABLE_TYPE IN \(Self.tableTypes)
      ORDER BY TABLE_NAME
      """
    var tables: [DatabaseTable] = []
    for row in try await rows(in: session, sql: sql, binds: [.text(database)]) {
      guard let name = MySQLCatalogValue.string(row, 0) else { continue }
      tables.append(
        DatabaseTable(schema: database, name: name, rowCount: MySQLCatalogValue.int(row, 1)))
    }
    return tables
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    let sql = """
      SELECT TABLE_NAME
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'VIEW'
      ORDER BY TABLE_NAME
      """
    var views: [DatabaseView] = []
    for row in try await rows(in: session, sql: sql, binds: [.text(database)]) {
      guard let name = MySQLCatalogValue.string(row, 0) else { continue }
      views.append(DatabaseView(schema: database, name: name, definition: nil))
    }
    return views
  }

  func users(in _: any DatabaseSession) async throws -> [DatabaseUser] { [] }

  func roles(in _: any DatabaseSession) async throws -> [DatabaseRole] { [] }

  /// Columns of every listed table and view, in ORDINAL_POSITION order.
  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    let sql = """
      SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.EXTRA
      FROM information_schema.COLUMNS c
      JOIN information_schema.TABLES t
        ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
      WHERE c.TABLE_SCHEMA = ?
        AND (t.TABLE_TYPE IN \(Self.tableTypes) OR t.TABLE_TYPE = 'VIEW')
      ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
      """
    var columns: [MySQLCatalog.ColumnRow] = []
    for row in try await rows(in: session, sql: sql, binds: [.text(database)]) {
      guard let table = MySQLCatalogValue.string(row, 0),
        let name = MySQLCatalogValue.string(row, 1),
        let type = MySQLCatalogValue.string(row, 2)
      else { continue }
      columns.append(
        MySQLCatalog.ColumnRow(
          table: table, name: name, type: type,
          isNullable: MySQLCatalogValue.string(row, 3) != "NO",
          extra: MySQLCatalogValue.string(row, 4) ?? ""))
    }
    return MySQLCatalog.columnsByRelation(
      columns, keys: try await uniqueKeyParts(in: session), database: database)
  }

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
    let sql = """
      SELECT k.CONSTRAINT_NAME, k.TABLE_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA,
        k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
      FROM information_schema.KEY_COLUMN_USAGE k
      JOIN information_schema.REFERENTIAL_CONSTRAINTS r
        ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
        AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
        AND r.TABLE_NAME = k.TABLE_NAME
      WHERE k.TABLE_SCHEMA = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL
      ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
      """
    var parts: [MySQLCatalog.ForeignKeyPart] = []
    for row in try await rows(in: session, sql: sql, binds: [.text(database)]) {
      guard let constraint = MySQLCatalogValue.string(row, 0),
        let table = MySQLCatalogValue.string(row, 1),
        let column = MySQLCatalogValue.string(row, 2),
        let targetSchema = MySQLCatalogValue.string(row, 3),
        let targetTable = MySQLCatalogValue.string(row, 4),
        let targetColumn = MySQLCatalogValue.string(row, 5)
      else { continue }
      parts.append(
        MySQLCatalog.ForeignKeyPart(
          constraint: constraint, table: table, column: column, targetSchema: targetSchema,
          targetTable: targetTable, targetColumn: targetColumn,
          updateRule: MySQLCatalogValue.string(row, 6) ?? "",
          deleteRule: MySQLCatalogValue.string(row, 7) ?? ""))
    }
    return MySQLCatalog.foreignKeys(parts, database: database)
  }

  /// `name` is `table`, or `<database>.<table>` for the connected database. A table name may
  /// contain a dot, so the whole text is tried as a table first. Tables of other databases,
  /// views and tables without a primary key are not editable (nil).
  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable? {
    var candidates = [name]
    let prefix = database + "."
    if name.hasPrefix(prefix), name.count > prefix.count {
      candidates.append(String(name.dropFirst(prefix.count)))
    }
    for table in candidates {
      if let editTable = try await editTable(table: table, in: session) { return editTable }
    }
    return nil
  }

  /// Rows of `table` (exact name, as the catalog spells it) in the connected database.
  private func editTable(
    table: String, in session: any DatabaseSession
  ) async throws
    -> EditTable?
  {
    let sql = """
      SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.EXTRA
      FROM information_schema.COLUMNS c
      JOIN information_schema.TABLES t
        ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
      WHERE c.TABLE_SCHEMA = ? AND c.TABLE_NAME = ? AND t.TABLE_TYPE IN \(Self.tableTypes)
      ORDER BY c.ORDINAL_POSITION
      """
    var names: [Int16: String] = [:]
    var generated: Set<String> = []
    // The catalog collation may compare names without case; only the exact table counts.
    for row in try await rows(in: session, sql: sql, binds: [.text(database), .text(table)])
    where MySQLCatalogValue.string(row, 0) == table {
      guard let position = MySQLCatalogValue.int(row, 1).flatMap({ Int16(exactly: $0) }),
        let column = MySQLCatalogValue.string(row, 2)
      else { return nil }
      names[position] = column
      if MySQLCatalog.isGenerated(extra: MySQLCatalogValue.string(row, 3) ?? "") {
        generated.insert(column)
      }
    }
    guard !names.isEmpty else { return nil }
    let keys = try await uniqueKeyParts(
      in: session, filter: "AND TABLE_NAME = ? AND INDEX_NAME = 'PRIMARY'",
      binds: [.text(table)])
    let primaryKey = MySQLCatalog.primaryKey(keys, table: table)
    guard !primaryKey.isEmpty else { return nil }
    let dialect = SQLDialect.mysql
    return EditTable(
      oid: MySQLCatalog.editTableOID,
      attributeNames: names,
      primaryKeyColumns: primaryKey,
      qualifiedName: try dialect.quoteIdentifier(database) + "."
        + (try dialect.quoteIdentifier(table)),
      updateOnly: false,
      tableRef: .mysql(database: database, table: table),
      schema: database,
      name: table,
      generatedColumns: generated)
  }

  /// ORDINAL_POSITION by exact column name of `schema`.`table` (exact names, as the column
  /// definitions spell them; the same ordinals as `EditTable.attributeNames`). Empty when the
  /// table is not in the catalog (a temporary table).
  func columnOrdinals(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> [String: Int] {
    let sql = """
      SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
      """
    var ordinals: [String: Int] = [:]
    // The catalog collation may compare names without case; only the exact table counts.
    for row in try await rows(in: session, sql: sql, binds: [.text(schema), .text(table)])
    where MySQLCatalogValue.string(row, 0) == schema && MySQLCatalogValue.string(row, 1) == table {
      guard let column = MySQLCatalogValue.string(row, 2),
        let position = MySQLCatalogValue.int(row, 3)
      else { continue }
      ordinals[column] = position
    }
    return ordinals
  }

  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws -> [String] {
    try await editTable(named: tableName, in: session)?.primaryKeyColumns ?? []
  }

  /// Exact count. An empty `schema` is the connected database.
  func rowCount(schema: String, table: String, in session: any DatabaseSession) async throws -> Int
  {
    let dialect = SQLDialect.mysql
    let relation =
      try dialect.quoteIdentifier(schema.isEmpty ? database : schema) + "."
      + (try dialect.quoteIdentifier(table))
    let counted = try await rows(in: session, sql: "SELECT COUNT(*) FROM \(relation)")
    return counted.first.flatMap { MySQLCatalogValue.int($0, 0) } ?? 0
  }

  /// Result types already come from the column definitions.
  func enrichColumnTypes(
    _ columns: [ColumnInfo], query _: String, in _: any DatabaseSession
  ) async -> [ColumnInfo] {
    columns
  }

  // MARK: - Reads

  /// Columns of every UNIQUE index (the primary key included), in index order. `filter` is a
  /// constant SQL fragment from this file; names always travel in `binds`.
  private func uniqueKeyParts(
    in session: any DatabaseSession, filter: String = "", binds: [SQLBindValue] = []
  ) async throws -> [MySQLCatalog.KeyPart] {
    let sql = """
      SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME, SUB_PART
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = ? AND NON_UNIQUE = 0 \(filter)
      ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
      """
    var parts: [MySQLCatalog.KeyPart] = []
    for row in try await rows(in: session, sql: sql, binds: [.text(database)] + binds) {
      guard let table = MySQLCatalogValue.string(row, 0),
        let index = MySQLCatalogValue.string(row, 1)
      else { continue }
      parts.append(
        MySQLCatalog.KeyPart(
          table: table, index: index, column: MySQLCatalogValue.string(row, 2),
          isPrefix: MySQLCatalogValue.int(row, 3) != nil))
    }
    return parts
  }

  func rows(
    in session: any DatabaseSession, sql: String, binds: [SQLBindValue] = []
  ) async throws -> [[CellValue]] {
    let source = try await session.query(sql, binds: binds)
    var collected: [[CellValue]] = []
    for try await row in source.rows {
      collected.append(row)
    }
    return collected
  }
}

/// Pure mapping of MySQL catalog rows into the schema tree models.
nonisolated enum MySQLCatalog {
  /// MySQL has no table OID. `EditTable.oid` only has to be nonzero; identity is `tableRef`.
  static let editTableOID: UInt32 = 1

  /// One `information_schema.COLUMNS` row.
  struct ColumnRow: Sendable, Equatable {
    let table: String
    let name: String
    /// COLUMN_TYPE (`varchar(10)`, `int unsigned`, `enum('a','b')`)
    let type: String
    let isNullable: Bool
    /// EXTRA (`auto_increment`, `VIRTUAL GENERATED`, `DEFAULT_GENERATED on update ...`)
    let extra: String
  }

  /// One column of one UNIQUE index (STATISTICS with NON_UNIQUE = 0).
  struct KeyPart: Sendable, Equatable {
    let table: String
    let index: String
    /// Nil for a functional key part (MySQL 8).
    let column: String?
    /// The index covers only a prefix of the column (SUB_PART), so the column is not unique.
    let isPrefix: Bool
  }

  /// One column of one foreign key (KEY_COLUMN_USAGE joined with REFERENTIAL_CONSTRAINTS).
  struct ForeignKeyPart: Sendable, Equatable {
    let constraint: String
    let table: String
    let column: String
    let targetSchema: String
    let targetTable: String
    let targetColumn: String
    let updateRule: String
    let deleteRule: String
  }

  /// A generated column (VIRTUAL, STORED, MariaDB PERSISTENT). Not MySQL's DEFAULT_GENERATED,
  /// which marks an expression default.
  static func isGenerated(extra: String) -> Bool {
    let upper = extra.uppercased()
    return ["VIRTUAL GENERATED", "STORED GENERATED", "PERSISTENT GENERATED"].contains {
      upper.contains($0)
    }
  }

  /// Columns keyed by `"<database>.<relation>"`, in input order. The primary key is the index
  /// named PRIMARY. A column is unique only through a single-column, whole-column UNIQUE index
  /// and never when it is part of the primary key. AUTO_INCREMENT is the identity.
  static func columnsByRelation(
    _ rows: [ColumnRow], keys: [KeyPart], database: String
  ) -> [String: [DatabaseColumn]] {
    var primary: Set<ColumnID> = []
    var unique: Set<ColumnID> = []
    let indexes = Dictionary(grouping: keys) { IndexID(table: $0.table, index: $0.index) }
    for (id, parts) in indexes {
      if id.index == "PRIMARY" {
        for part in parts {
          if let column = part.column { primary.insert(ColumnID(table: id.table, column: column)) }
        }
      } else if parts.count == 1, let column = parts[0].column, !parts[0].isPrefix {
        unique.insert(ColumnID(table: id.table, column: column))
      }
    }
    var result: [String: [DatabaseColumn]] = [:]
    for row in rows {
      let id = ColumnID(table: row.table, column: row.name)
      let isPrimaryKey = primary.contains(id)
      result["\(database).\(row.table)", default: []].append(
        DatabaseColumn(
          name: row.name,
          type: displayType(row.type),
          isNullable: row.isNullable,
          isPrimaryKey: isPrimaryKey,
          isIdentity: row.extra.lowercased().contains("auto_increment"),
          isUnique: unique.contains(id) && !isPrimaryKey,
          isGenerated: isGenerated(extra: row.extra)))
    }
    return result
  }

  /// Primary key columns of `table` in key order.
  static func primaryKey(_ keys: [KeyPart], table: String) -> [String] {
    keys.filter { $0.table == table && $0.index == "PRIMARY" }.compactMap(\.column)
  }

  /// One foreign key per run of rows with the same table and constraint, in input order.
  static func foreignKeys(_ parts: [ForeignKeyPart], database: String) -> [ForeignKey] {
    var groups: [[ForeignKeyPart]] = []
    for part in parts {
      if let last = groups.last?.last, last.table == part.table,
        last.constraint == part.constraint
      {
        groups[groups.count - 1].append(part)
      } else {
        groups.append([part])
      }
    }
    return groups.compactMap { group in
      guard let first = group.first else { return nil }
      return ForeignKey(
        constraintName: first.constraint,
        sourceSchema: database,
        sourceTable: first.table,
        sourceColumns: group.map(\.column),
        targetSchema: first.targetSchema,
        targetTable: first.targetTable,
        targetColumns: group.map(\.targetColumn),
        onUpdate: ForeignKeyAction(mysqlRule: first.updateRule),
        onDelete: ForeignKeyAction(mysqlRule: first.deleteRule))
    }
  }

  /// COLUMN_TYPE uppercased like the other engines, except ENUM / SET values (quoted text).
  static func displayType(_ type: String) -> String {
    type.contains("'") ? type : type.uppercased()
  }

  private struct ColumnID: Hashable {
    let table: String
    let column: String
  }

  private struct IndexID: Hashable {
    let table: String
    let index: String
  }
}

/// Cell values from a catalog query. Strings read as UTF-8 even when the server marks them binary.
nonisolated enum MySQLCatalogValue {
  static func string(_ row: [CellValue], _ index: Int) -> String? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .string(let text), .json(let text):
      return text
    case .data(let data):
      return String(data: data, encoding: .utf8)
    default:
      return nil
    }
  }

  /// `.int`, or text holding an integer (BIGINT UNSIGNED beyond `Int` stays nil).
  static func int(_ row: [CellValue], _ index: Int) -> Int? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .int(let number):
      return number
    case .string(let text):
      return Int(text)
    default:
      return nil
    }
  }
}
