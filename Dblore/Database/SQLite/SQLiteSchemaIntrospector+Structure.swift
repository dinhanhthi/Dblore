// SQLiteSchemaIntrospector+Structure.swift
// Structure of one SQLite table from pragma_table_xinfo, pragma_index_list, pragma_index_xinfo
// and pragma_foreign_key_list. Table, index and schema names are bound as pragma arguments.
//
// The pragmas do not expose CHECK constraints (left empty: the structure editor does not edit
// them on SQLite), generated column expressions, expression index text, constraint names, or
// comments. A partial index predicate is read from its CREATE INDEX text only when the word
// WHERE occurs there once and there is no comment; otherwise the index is partial without text.
// AUTOINCREMENT: the single INTEGER PRIMARY KEY column of a table whose CREATE TABLE text has
// the AUTOINCREMENT keyword (SQLite allows it nowhere else). Hidden virtual-table columns
// (hidden = 1) are skipped; hidden 2 is a VIRTUAL and 3 a STORED generated column.

import Foundation

nonisolated extension SQLiteSchemaIntrospector {
  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure {
    // pragma_table_xinfo also answers for views: only a table has a structure to edit
    guard try await createSQL(type: "table", name: table, schema: schema, in: session) != nil else {
      throw DatabaseError.queryFailed("Table \(schema).\(table) was not found", 0)
    }
    let info = try await rows(
      in: session,
      sql: """
        SELECT cid, name, type, "notnull", dflt_value, pk, hidden
        FROM pragma_table_xinfo(?, ?)
        ORDER BY cid
        """,
      binds: [.text(table), .text(schema)])
    guard !info.isEmpty else {
      throw DatabaseError.queryFailed("Table \(schema).\(table) was not found", 0)
    }
    var columns: [TableStructure.Column] = []
    var keyOrdinals: [(name: String, pk: Int)] = []
    for row in info {
      guard let cid = SQLiteCatalogValue.int(row, 0),
        let name = SQLiteCatalogValue.string(row, 1)
      else { continue }
      let hidden = SQLiteCatalogValue.int(row, 6) ?? 0
      guard hidden != 1 else { continue }
      if let pk = SQLiteCatalogValue.int(row, 5), pk > 0 { keyOrdinals.append((name, pk)) }
      columns.append(
        TableStructure.Column(
          ordinal: cid + 1,
          name: name,
          dataType: SQLiteCatalogValue.string(row, 2) ?? "",
          isNullable: (SQLiteCatalogValue.int(row, 3) ?? 0) == 0,
          defaultExpression: SQLiteCatalogValue.string(row, 4),
          generated: hidden == 2 || hidden == 3
            ? TableStructure.Generated(expression: nil, isStored: hidden == 3) : nil))
    }
    let primaryKey = keyOrdinals.sorted { $0.pk < $1.pk }.map(\.name)
    if primaryKey.count == 1,
      let index = columns.firstIndex(where: { $0.name == primaryKey[0] }),
      SQLTokenizer.asciiUppercased(columns[index].dataType) == "INTEGER",
      try await hasAutoincrement(schema: schema, table: table, in: session)
    {
      columns[index].identity = .autoIncrement
    }

    var constraints: [TableStructure.Constraint] = []
    if !primaryKey.isEmpty {
      constraints.append(.init(name: nil, kind: .primaryKey, columns: primaryKey))
    }
    let indexes = try await indexes(schema: schema, table: table, in: session)
    for index in indexes where index.origin == "u" {
      constraints.append(
        .init(
          name: index.index.name, kind: .unique,
          columns: index.index.keys.compactMap {
            if case .column(let name) = $0 { name } else { nil }
          }))
    }
    for key in try await keys(of: table, schema: schema, in: session) {
      constraints.append(
        .init(
          name: nil,
          kind: .foreignKey(
            .init(
              schema: key.targetSchema, table: key.targetTable, columns: key.targetColumns,
              onUpdate: key.onUpdate, onDelete: key.onDelete)),
          columns: key.sourceColumns))
    }
    return TableStructure(
      tableID: .sqlite(schema: schema, table: table), schema: schema, name: table,
      columns: columns, indexes: indexes.map(\.index), constraints: constraints)
  }

  /// Every index with its `pragma_index_list` origin (`c` CREATE INDEX, `u` UNIQUE, `pk`)
  private func indexes(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> [(index: TableStructure.Index, origin: String)] {
    let listed = try await rows(
      in: session,
      sql: """
        SELECT name, "unique", origin, partial FROM pragma_index_list(?, ?)
        ORDER BY name
        """,
      binds: [.text(table), .text(schema)])
    var indexes: [(index: TableStructure.Index, origin: String)] = []
    for row in listed {
      guard let name = SQLiteCatalogValue.string(row, 0) else { continue }
      let origin = SQLiteCatalogValue.string(row, 2) ?? "c"
      let isPartial = SQLiteCatalogValue.int(row, 3) == 1
      // Key columns only; an expression part (cid -2) has no name
      let parts = try await rows(
        in: session,
        sql: "SELECT name FROM pragma_index_xinfo(?, ?) WHERE key = 1 ORDER BY seqno",
        binds: [.text(name), .text(schema)])
      let keys: [TableStructure.Index.Key] = parts.map {
        SQLiteCatalogValue.string($0, 0).map { .column($0) } ?? .expression(nil)
      }
      let predicate =
        isPartial ? try await partialPredicate(index: name, schema: schema, in: session) : nil
      indexes.append(
        (
          TableStructure.Index(
            name: name, keys: keys, isUnique: SQLiteCatalogValue.int(row, 1) == 1,
            isPrimary: origin == "pk", method: nil, isPartial: isPartial, predicate: predicate),
          origin
        ))
    }
    return indexes
  }

  /// Text after WHERE in the CREATE INDEX statement, when that word occurs once and the text
  /// has no comment. Nil otherwise.
  private func partialPredicate(
    index: String, schema: String, in session: any DatabaseSession
  ) async throws -> String? {
    guard let sql = try await createSQL(type: "index", name: index, schema: schema, in: session),
      !sql.contains("--"), !sql.contains("/*")
    else { return nil }
    let parts = SQLTokenizer.asciiUppercased(sql).components(separatedBy: "WHERE")
    guard parts.count == 2 else { return nil }
    let tail = sql.unicodeScalars.suffix(parts[1].unicodeScalars.count)
    let predicate = String(String.UnicodeScalarView(tail))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return predicate.isEmpty ? nil : predicate
  }

  private func hasAutoincrement(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> Bool {
    guard let sql = try await createSQL(type: "table", name: table, schema: schema, in: session)
    else { return false }
    return SQLTokenizer.tokens(sql, dialect: .sqlite).contains { $0.isWord("AUTOINCREMENT") }
  }

  private func createSQL(
    type: String, name: String, schema: String, in session: any DatabaseSession
  ) async throws -> String? {
    let found = try await rows(
      in: session,
      sql: """
        SELECT sql FROM \(try SQLDialect.sqlite.quoteIdentifier(schema)).sqlite_schema
        WHERE type = ? AND name = ?
        """,
      binds: [.text(type), .text(name)])
    return found.first.flatMap { SQLiteCatalogValue.string($0, 0) }
  }
}
