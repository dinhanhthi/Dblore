// SQLiteSchemaIntrospector.swift
// SQLite catalog reads for one open session. Row estimates come from sqlite_stat1 when that
// table exists. Schema load never counts live rows and never loads an extension.
// Users, roles, functions, and procedures stay empty.

import Foundation

/// `sqlite_schema` and `pragma_*` reads through `DatabaseSession.query`.
nonisolated struct SQLiteSchemaIntrospector: SchemaIntrospector {
  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    var tables: [DatabaseTable] = []
    for schema in try await schemas(in: session) {
      let estimates = try await rowEstimates(schema: schema, in: session)
      for name in try await relations(schema: schema, type: "table", in: session) {
        tables.append(DatabaseTable(schema: schema, name: name, rowCount: estimates[name]))
      }
    }
    return tables
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    var views: [DatabaseView] = []
    for schema in try await schemas(in: session) {
      let quoted = try quote(schema)
      let sql = """
        SELECT name, sql FROM \(quoted).sqlite_schema
        WHERE type = 'view' AND \(Self.userRelationFilter)
        ORDER BY name
        """
      for row in try await rows(in: session, sql: sql) {
        guard let name = SQLiteCatalogValue.string(row, 0) else { continue }
        views.append(
          DatabaseView(schema: schema, name: name, definition: SQLiteCatalogValue.string(row, 1)))
      }
    }
    return views
  }

  func functions(in _: any DatabaseSession) async throws -> [DatabaseFunction] { [] }

  func procedures(in _: any DatabaseSession) async throws -> [DatabaseProcedure] { [] }

  func users(in _: any DatabaseSession) async throws -> [DatabaseUser] { [] }

  func roles(in _: any DatabaseSession) async throws -> [DatabaseRole] { [] }

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
    var foreignKeys: [ForeignKey] = []
    for schema in try await schemas(in: session) {
      for table in try await relations(schema: schema, type: "table", in: session) {
        foreignKeys.append(
          contentsOf: try await keys(of: table, schema: schema, in: session))
      }
    }
    return foreignKeys
  }

  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    var columns: [String: [DatabaseColumn]] = [:]
    for schema in try await schemas(in: session) {
      let names =
        try await relations(schema: schema, type: "table", in: session)
        + (try await relations(schema: schema, type: "view", in: session))
      for name in names {
        columns["\(schema).\(name)"] = try await describe(
          schema: schema, table: name, in: session
        ).columns
      }
    }
    return columns
  }

  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable? {
    let known = try await schemas(in: session)
    guard let relation = split(name, schemas: known),
      relation.schema == "main" || relation.schema == "temp",
      !relation.table.hasPrefix("sqlite_")
    else { return nil }
    let quoted = try quote(relation.schema)
    let found = try await rows(
      in: session,
      sql: """
        SELECT rootpage FROM \(quoted).sqlite_schema
        WHERE type = 'table' AND name = ?
        """,
      binds: [.text(relation.table)])
    guard let rootpage = found.first.flatMap({ SQLiteCatalogValue.int($0, 0) }),
      let oid = UInt32(exactly: rootpage), oid != 0
    else { return nil }
    let described = try await describe(schema: relation.schema, table: relation.table, in: session)
    guard !described.primaryKey.isEmpty else { return nil }
    return EditTable(
      oid: oid,
      attributeNames: described.attributeNames,
      primaryKeyColumns: described.primaryKey,
      qualifiedName: "\(quoted).\(try quote(relation.table))",
      updateOnly: false,
      tableRef: .sqlite(schema: relation.schema, table: relation.table),
      schema: relation.schema,
      name: relation.table,
      generatedColumns: Set(described.columns.filter(\.isGenerated).map(\.name)))
  }

  func rowCount(schema: String, table: String, in session: any DatabaseSession) async throws -> Int
  {
    let sql = "SELECT COUNT(*) FROM \(try quote(schema)).\(try quote(table))"
    let listed = try await rows(in: session, sql: sql)
    return listed.first.flatMap { SQLiteCatalogValue.int($0, 0) } ?? 0
  }

  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws -> [String] {
    try await editTable(named: tableName, in: session)?.primaryKeyColumns ?? []
  }

  /// Declared types already arrive on the result. SQLite has no separate precision catalog.
  func enrichColumnTypes(
    _ columns: [ColumnInfo], query _: String, in _: any DatabaseSession
  ) async -> [ColumnInfo] {
    columns
  }

  // MARK: - Relations

  private func schemas(in session: any DatabaseSession) async throws -> [String] {
    let listed = try await rows(
      in: session, sql: "SELECT name FROM pragma_database_list ORDER BY seq")
    return listed.compactMap { SQLiteCatalogValue.string($0, 0) }
  }

  private func relations(
    schema: String, type: String, in session: any DatabaseSession
  ) async throws -> [String] {
    let quoted = try quote(schema)
    let listed = try await rows(
      in: session,
      sql: """
        SELECT name FROM \(quoted).sqlite_schema
        WHERE type = ? AND \(Self.userRelationFilter)
        ORDER BY name
        """,
      binds: [.text(type)])
    return listed.compactMap { SQLiteCatalogValue.string($0, 0) }
  }

  /// First integer of `sqlite_stat1.stat`. Missing table or missing row means no estimate.
  private func rowEstimates(
    schema: String, in session: any DatabaseSession
  ) async throws -> [String: Int] {
    let quoted = try quote(schema)
    let exists = try await rows(
      in: session,
      sql: """
        SELECT 1 FROM \(quoted).sqlite_schema
        WHERE type = 'table' AND name = 'sqlite_stat1'
        """)
    guard !exists.isEmpty else { return [:] }
    var estimates: [String: Int] = [:]
    let stats = try await rows(
      in: session, sql: "SELECT tbl, CAST(stat AS INTEGER) FROM \(quoted).sqlite_stat1")
    for row in stats {
      guard let table = SQLiteCatalogValue.string(row, 0),
        let estimate = SQLiteCatalogValue.int(row, 1)
      else { continue }
      estimates[table] = max(estimates[table] ?? estimate, estimate)
    }
    return estimates
  }

  private func describe(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableDescription {
    let info = try await xinfo(schema: schema, table: table, in: session)
    let unique = try await uniqueColumnNames(schema: schema, table: table, in: session)
    var attributeNames: [Int16: String] = [:]
    var columns: [DatabaseColumn] = []
    for column in info {
      if let ordinal = Int16(exactly: column.cid) {
        attributeNames[ordinal] = column.name
      }
      columns.append(
        DatabaseColumn(
          name: column.name,
          type: column.type,
          isNullable: !column.notNull,
          isPrimaryKey: column.pk > 0,
          isUnique: unique.contains(column.name) && column.pk == 0,
          isHidden: column.hidden == 1,
          isGenerated: column.hidden == 2 || column.hidden == 3))
    }
    return TableDescription(
      columns: columns, attributeNames: attributeNames, primaryKey: primaryKey(in: info))
  }

  private func xinfo(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> [XColumn] {
    let listed = try await rows(
      in: session,
      sql: """
        SELECT cid, name, type, "notnull", pk, hidden
        FROM pragma_table_xinfo(?, ?)
        ORDER BY cid
        """,
      binds: [.text(table), .text(schema)])
    var columns: [XColumn] = []
    for row in listed {
      guard let cid = SQLiteCatalogValue.int(row, 0),
        let name = SQLiteCatalogValue.string(row, 1)
      else { continue }
      columns.append(
        XColumn(
          cid: cid,
          name: name,
          type: SQLiteCatalogValue.string(row, 2) ?? "",
          notNull: (SQLiteCatalogValue.int(row, 3) ?? 0) != 0,
          pk: SQLiteCatalogValue.int(row, 4) ?? 0,
          hidden: SQLiteCatalogValue.int(row, 5) ?? 0))
    }
    return columns
  }

  /// Single-column unique indexes that are not the primary key.
  private func uniqueColumnNames(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> Set<String> {
    let indexes = try await rows(
      in: session,
      sql: """
        SELECT name, "unique", origin, partial FROM pragma_index_list(?, ?)
        """,
      binds: [.text(table), .text(schema)])
    var names: Set<String> = []
    for index in indexes {
      guard let indexName = SQLiteCatalogValue.string(index, 0),
        SQLiteCatalogValue.int(index, 1) == 1,
        SQLiteCatalogValue.string(index, 2) != "pk",
        (SQLiteCatalogValue.int(index, 3) ?? 0) == 0
      else { continue }
      let columns = try await rows(
        in: session,
        sql: "SELECT cid, name FROM pragma_index_info(?, ?)",
        binds: [.text(indexName), .text(schema)])
      guard columns.count == 1,
        let cid = SQLiteCatalogValue.int(columns[0], 0), cid >= 0,
        let name = SQLiteCatalogValue.string(columns[0], 1)
      else { continue }
      names.insert(name)
    }
    return names
  }

  private func keys(
    of table: String, schema: String, in session: any DatabaseSession
  ) async throws -> [ForeignKey] {
    let listed = try await rows(
      in: session,
      sql: """
        SELECT id, seq, "table", "from", "to", on_update, on_delete
        FROM pragma_foreign_key_list(?, ?)
        ORDER BY id, seq
        """,
      binds: [.text(table), .text(schema)])
    var groups: [Int: [FKPiece]] = [:]
    var order: [Int] = []
    for row in listed {
      guard let id = SQLiteCatalogValue.int(row, 0),
        let seq = SQLiteCatalogValue.int(row, 1),
        let targetTable = SQLiteCatalogValue.string(row, 2),
        let sourceColumn = SQLiteCatalogValue.string(row, 3)
      else { continue }
      if groups[id] == nil { order.append(id) }
      groups[id, default: []].append(
        FKPiece(
          seq: seq,
          targetTable: targetTable,
          sourceColumn: sourceColumn,
          targetColumn: SQLiteCatalogValue.string(row, 4),
          onUpdate: SQLiteCatalogValue.string(row, 5) ?? "NO ACTION",
          onDelete: SQLiteCatalogValue.string(row, 6) ?? "NO ACTION"))
    }
    var keys: [ForeignKey] = []
    for id in order {
      guard var pieces = groups[id], !pieces.isEmpty else { continue }
      pieces.sort { $0.seq < $1.seq }
      if pieces.contains(where: { $0.targetColumn == nil }) {
        let targetKey = try await primaryKeyNames(
          schema: schema, table: pieces[0].targetTable, in: session)
        for index in pieces.indices
        where pieces[index].targetColumn == nil && index < targetKey.count {
          pieces[index].targetColumn = targetKey[index]
        }
      }
      let sourceColumns = pieces.map(\.sourceColumn)
      let targetColumns = pieces.compactMap(\.targetColumn)
      guard targetColumns.count == sourceColumns.count, !sourceColumns.isEmpty else { continue }
      keys.append(
        ForeignKey(
          constraintName: String(id),
          sourceSchema: schema,
          sourceTable: table,
          sourceColumns: sourceColumns,
          targetSchema: schema,
          targetTable: pieces[0].targetTable,
          targetColumns: targetColumns,
          onUpdate: foreignKeyAction(pieces[0].onUpdate),
          onDelete: foreignKeyAction(pieces[0].onDelete)))
    }
    return keys
  }

  private func primaryKeyNames(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> [String] {
    primaryKey(in: try await xinfo(schema: schema, table: table, in: session))
  }

  /// `pk` is the 1-based key ordinal. Column order in the table is `cid`, not key order.
  private func primaryKey(in info: [XColumn]) -> [String] {
    info.filter { $0.pk > 0 }.sorted { $0.pk < $1.pk }.map(\.name)
  }

  private func foreignKeyAction(_ text: String) -> ForeignKeyAction {
    switch text.uppercased() {
    case "CASCADE": .cascade
    case "RESTRICT": .restrict
    case "SET NULL": .setNull
    case "SET DEFAULT": .setDefault
    default: .noAction
    }
  }

  /// `sqlite_*` is SQLite's own catalog (`sqlite_sequence`, `sqlite_stat1`, …).
  private static let userRelationFilter = "name NOT GLOB 'sqlite_*'"

  private func quote(_ identifier: String) throws -> String {
    try SQLDialect.sqlite.quoteIdentifier(identifier)
  }

  /// `table` is `main.table`. `schema.table` uses a schema from `pragma_database_list`.
  private func split(
    _ name: String, schemas: [String]
  ) -> (schema: String, table: String)? {
    guard !name.isEmpty else { return nil }
    if let dot = name.firstIndex(of: "."), !name.hasPrefix("\"") {
      let schemaPart = String(name[..<dot])
      let table = String(name[name.index(after: dot)...])
      if !table.isEmpty,
        let schema = schemas.first(where: { $0.caseInsensitiveCompare(schemaPart) == .orderedSame })
      {
        return (schema, table)
      }
    }
    return ("main", name)
  }

  private func rows(
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

nonisolated extension SQLiteSchemaIntrospector {
  fileprivate struct TableDescription: Sendable {
    var columns: [DatabaseColumn]
    var attributeNames: [Int16: String]
    var primaryKey: [String]
  }

  fileprivate struct XColumn: Sendable {
    var cid: Int
    var name: String
    var type: String
    var notNull: Bool
    var pk: Int
    var hidden: Int
  }

  fileprivate struct FKPiece: Sendable {
    var seq: Int
    var targetTable: String
    var sourceColumn: String
    var targetColumn: String?
    var onUpdate: String
    var onDelete: String
  }
}

private nonisolated enum SQLiteCatalogValue {
  static func string(_ row: [CellValue], _ index: Int) -> String? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .string(let text), .json(let text):
      return text
    default:
      return nil
    }
  }

  static func int(_ row: [CellValue], _ index: Int) -> Int? {
    guard index < row.count else { return nil }
    if case .int(let number) = row[index] { return number }
    return nil
  }
}
