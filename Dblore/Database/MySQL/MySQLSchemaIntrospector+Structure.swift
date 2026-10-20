// MySQLSchemaIntrospector+Structure.swift
// Structure of one MySQL / MariaDB table from information_schema (COLUMNS, STATISTICS,
// TABLE_CONSTRAINTS, KEY_COLUMN_USAGE, REFERENTIAL_CONSTRAINTS, CHECK_CONSTRAINTS). Database and
// table are always binds. A view or a missing table throws. An empty table comment reads as nil.
//
// Defaults are raw SQL text on both engines (see `MySQLCatalog.defaultExpression`). Generated
// expressions, check clauses and functional index keys stay as the server prints them (MySQL
// wraps the first two in parentheses, MariaDB does not), except that MySQL's escaped quotes in
// them and in expression defaults are undone (`MySQLCatalog.unescapedExpression`). A check has
// no columns: neither engine lists the columns it references.
// Functional index keys (EXPRESSION) are read on MySQL 8.0.13+; MariaDB has none. A prefix key
// (`name(5)`) reads as the whole column. Checks come from CHECK_CONSTRAINTS on MySQL 8.0.16+
// (matched to the table through TABLE_CONSTRAINTS) and MariaDB 10.2+ (its own TABLE_NAME column:
// a column-level check is named after the column, so the name alone is not unique); older
// servers give none.

import Foundation

nonisolated extension MySQLSchemaIntrospector {
  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure {
    let binds: [SQLBindValue] = [.text(schema), .text(table)]
    let found = try await rows(
      in: session,
      sql: """
        SELECT TABLE_COMMENT FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND TABLE_TYPE IN \(Self.tableTypes)
        """,
      binds: binds)
    guard !found.isEmpty else {
      throw DatabaseError.queryFailed("Table \(schema).\(table) was not found", 0)
    }
    let server = try await serverInfo(of: session)
    return TableStructure(
      tableID: .mysql(database: schema, table: table), schema: schema, name: table,
      columns: try await structureColumns(binds, server: server, in: session),
      indexes: try await structureIndexes(binds, server: server, in: session),
      constraints: try await structureKeys(binds, in: session)
        + structureChecks(binds, server: server, in: session),
      comment: found.first.flatMap { MySQLCatalog.nonEmpty(MySQLCatalogValue.string($0, 0)) })
  }

  /// The session's parsed version, or `SELECT VERSION()` for another session type.
  private func serverInfo(of session: any DatabaseSession) async throws -> MySQLServerInfo? {
    if let info = (session as? MySQLSession)?.serverInfo { return info }
    let found = try await rows(in: session, sql: "SELECT VERSION()")
    return found.first.flatMap { MySQLCatalogValue.string($0, 0) }.flatMap(
      MySQLServerInfo.init(version:))
  }

  private func structureColumns(
    _ binds: [SQLBindValue], server: MySQLServerInfo?, in session: any DatabaseSession
  ) async throws -> [TableStructure.Column] {
    let sql = """
      SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT,
        EXTRA, GENERATION_EXPRESSION, COLUMN_COMMENT, CHARACTER_SET_NAME, COLLATION_NAME
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
      ORDER BY ORDINAL_POSITION
      """
    var columns: [TableStructure.Column] = []
    for row in try await rows(in: session, sql: sql, binds: binds) {
      guard let ordinal = MySQLCatalogValue.int(row, 0),
        let name = MySQLCatalogValue.string(row, 1)
      else { continue }
      let dataType = MySQLCatalogValue.string(row, 2) ?? ""
      let extra = MySQLCatalog.nonEmpty(MySQLCatalogValue.string(row, 6))
      let isGenerated = extra.map(MySQLCatalog.isGenerated(extra:)) ?? false
      let upperExtra = extra?.uppercased() ?? ""
      columns.append(
        TableStructure.Column(
          ordinal: ordinal, name: name, dataType: dataType,
          isNullable: MySQLCatalogValue.string(row, 4) == "YES",
          defaultExpression: isGenerated
            ? nil
            : MySQLCatalog.defaultExpression(
              MySQLCatalogValue.string(row, 5), dataType: dataType, extra: extra ?? "",
              isMariaDB: server?.flavor == .mariadb),
          identity: upperExtra.contains("AUTO_INCREMENT") ? .autoIncrement : nil,
          generated: isGenerated
            ? TableStructure.Generated(
              expression: MySQLCatalog.nonEmpty(MySQLCatalogValue.string(row, 7)).map {
                server?.flavor == .mariadb ? $0 : MySQLCatalog.unescapedExpression($0)
              },
              isStored: upperExtra.contains("STORED") || upperExtra.contains("PERSISTENT"))
            : nil,
          comment: MySQLCatalog.nonEmpty(MySQLCatalogValue.string(row, 8)),
          columnType: MySQLCatalogValue.string(row, 3),
          extra: extra,
          characterSet: MySQLCatalogValue.string(row, 9),
          collation: MySQLCatalogValue.string(row, 10)))
    }
    return columns
  }

  /// One row per key part, grouped by index in name then key order.
  private func structureIndexes(
    _ binds: [SQLBindValue], server: MySQLServerInfo?, in session: any DatabaseSession
  ) async throws -> [TableStructure.Index] {
    let hasExpressions =
      server.map { $0.flavor == .mysql && ($0.major, $0.minor, $0.patch) >= (8, 0, 13) } ?? false
    let sql = """
      SELECT INDEX_NAME, COLUMN_NAME, \(hasExpressions ? "EXPRESSION" : "NULL"), NON_UNIQUE,
        INDEX_TYPE
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
      ORDER BY INDEX_NAME, SEQ_IN_INDEX
      """
    var indexes: [TableStructure.Index] = []
    for row in try await rows(in: session, sql: sql, binds: binds) {
      guard let name = MySQLCatalogValue.string(row, 0) else { continue }
      let key: TableStructure.Index.Key =
        MySQLCatalogValue.string(row, 1).map { .column($0) }
        ?? .expression(MySQLCatalogValue.string(row, 2).map(MySQLCatalog.unescapedExpression))
      if indexes.last?.name == name {
        indexes[indexes.count - 1].keys.append(key)
        continue
      }
      indexes.append(
        TableStructure.Index(
          name: name, keys: [key], isUnique: MySQLCatalogValue.int(row, 3) == 0,
          isPrimary: name == "PRIMARY", method: MySQLCatalogValue.string(row, 4)?.lowercased(),
          isPartial: false, predicate: nil))
    }
    return indexes
  }

  /// Primary key, unique and foreign key constraints, columns in key order. A UNIQUE key and a
  /// foreign key of one table may share a name, so a key column row is matched to its
  /// constraint by whether it references a table, and rows are grouped by name and type.
  private func structureKeys(
    _ binds: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Constraint] {
    let sql = """
      SELECT tc.CONSTRAINT_NAME, tc.CONSTRAINT_TYPE, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA,
        k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
      FROM information_schema.TABLE_CONSTRAINTS tc
      JOIN information_schema.KEY_COLUMN_USAGE k
        ON k.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
        AND k.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
        AND k.TABLE_SCHEMA = tc.TABLE_SCHEMA
        AND k.TABLE_NAME = tc.TABLE_NAME
        AND (k.REFERENCED_TABLE_NAME IS NULL) = (tc.CONSTRAINT_TYPE <> 'FOREIGN KEY')
      LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS r
        ON r.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
        AND r.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
        AND r.TABLE_NAME = tc.TABLE_NAME
      WHERE tc.TABLE_SCHEMA = ? AND tc.TABLE_NAME = ?
        AND tc.CONSTRAINT_TYPE IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
      ORDER BY tc.CONSTRAINT_NAME, tc.CONSTRAINT_TYPE, k.ORDINAL_POSITION
      """
    var constraints: [TableStructure.Constraint] = []
    var lastType: String?
    for row in try await rows(in: session, sql: sql, binds: binds) {
      guard let name = MySQLCatalogValue.string(row, 0),
        let type = MySQLCatalogValue.string(row, 1),
        let column = MySQLCatalogValue.string(row, 2)
      else { continue }
      let target = MySQLCatalogValue.string(row, 5)
      if let last = constraints.last, last.name == name, lastType == type {
        constraints[constraints.count - 1].columns.append(column)
        if case .foreignKey(var reference) = last.kind, let target {
          reference.columns.append(target)
          constraints[constraints.count - 1].kind = .foreignKey(reference)
        }
        continue
      }
      let kind: TableStructure.Constraint.Kind
      switch type {
      case "PRIMARY KEY": kind = .primaryKey
      case "UNIQUE": kind = .unique
      default:
        guard let schema = MySQLCatalogValue.string(row, 3),
          let table = MySQLCatalogValue.string(row, 4), let target
        else { continue }
        kind = .foreignKey(
          TableStructure.ForeignKeyReference(
            schema: schema, table: table, columns: [target],
            onUpdate: ForeignKeyAction(mysqlRule: MySQLCatalogValue.string(row, 6) ?? ""),
            onDelete: ForeignKeyAction(mysqlRule: MySQLCatalogValue.string(row, 7) ?? "")))
      }
      constraints.append(TableStructure.Constraint(name: name, kind: kind, columns: [column]))
      lastType = type
    }
    return constraints
  }

  private func structureChecks(
    _ binds: [SQLBindValue], server: MySQLServerInfo?, in session: any DatabaseSession
  ) async throws -> [TableStructure.Constraint] {
    guard let server else { return [] }
    let sql: String
    switch server.flavor {
    case .mysql:
      guard (server.major, server.minor, server.patch) >= (8, 0, 16) else { return [] }
      sql = """
        SELECT tc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
        FROM information_schema.TABLE_CONSTRAINTS tc
        JOIN information_schema.CHECK_CONSTRAINTS cc
          ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
          AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
        WHERE tc.TABLE_SCHEMA = ? AND tc.TABLE_NAME = ? AND tc.CONSTRAINT_TYPE = 'CHECK'
        ORDER BY tc.CONSTRAINT_NAME
        """
    case .mariadb:
      guard (server.major, server.minor) >= (10, 2) else { return [] }
      sql = """
        SELECT CONSTRAINT_NAME, CHECK_CLAUSE
        FROM information_schema.CHECK_CONSTRAINTS
        WHERE CONSTRAINT_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY CONSTRAINT_NAME
        """
    }
    return try await rows(in: session, sql: sql, binds: binds).compactMap { row in
      guard let name = MySQLCatalogValue.string(row, 0),
        let clause = MySQLCatalogValue.string(row, 1)
      else { return nil }
      return TableStructure.Constraint(
        name: name,
        kind: .check(server.flavor == .mariadb ? clause : MySQLCatalog.unescapedExpression(clause)),
        columns: [])
    }
  }
}

nonisolated extension MySQLCatalog {
  /// COLUMN_DEFAULT as raw SQL text, the same on both engines (`'it''s'`, `'a\\b'`, `0`,
  /// `b'1'`, `CURRENT_TIMESTAMP`, an expression in parentheses); nil for no default or
  /// DEFAULT NULL.
  /// MariaDB already prints it that way, except DEFAULT NULL, which reads as the text `NULL`.
  /// MySQL prints a literal unquoted: an expression (EXTRA DEFAULT_GENERATED, or
  /// CURRENT_TIMESTAMP on a temporal column of a server that does not flag it), a number, a
  /// bit or a year stays as it is; anything else is quoted with `'` and `\` doubled.
  static func defaultExpression(
    _ value: String?, dataType: String, extra: String, isMariaDB: Bool
  ) -> String? {
    guard let value else { return nil }
    if isMariaDB { return value == "NULL" ? nil : value }
    let type = dataType.lowercased()
    let isExpression =
      extra.uppercased().contains("DEFAULT_GENERATED")
      || (["timestamp", "datetime"].contains(type)
        && value.uppercased().hasPrefix("CURRENT_TIMESTAMP"))
    let unquoted: Set<String> = [
      "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric",
      "float", "double", "real", "bit", "year",
    ]
    if isExpression { return unescapedExpression(value) }
    if unquoted.contains(type) { return value }
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "''")
    return "'\(escaped)'"
  }

  /// MySQL prints an expression default, a generated expression, a check clause or a functional
  /// index key with every `\` and `'` escaped (`concat(_utf8mb4\'it\\\'s\')`); this undoes that,
  /// so the text is SQL again (`concat(_utf8mb4'it\'s')`). Text with a bare `'` is not in that
  /// form and is kept.
  static func unescapedExpression(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case "'":
        return text
      case "\\":
        guard let next = scalars.next() else { return text }
        guard next == "'" || next == "\\" else {
          result.append(scalar)
          result.append(next)
          continue
        }
        result.append(next)
      default:
        result.append(scalar)
      }
    }
    return String(result)
  }

  /// Nil for NULL and for the empty text MySQL prints where MariaDB has NULL.
  static func nonEmpty(_ value: String?) -> String? {
    value.flatMap { $0.isEmpty ? nil : $0 }
  }
}
