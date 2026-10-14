// DuckDBSchemaIntrospector+Structure.swift
// Structure of one DuckDB table of `current_database()` from duckdb_tables(), duckdb_columns(),
// duckdb_indexes() and duckdb_constraints(), for viewing. Schema and table are binds and match
// exactly. A view or a missing table throws.
//
// Limits of the catalog: a generated column reads as a default (`CAST((n * 2) AS INTEGER)`),
// with `generated` nil. Indexes are CREATE INDEX ones only: the ones behind PRIMARY KEY and
// UNIQUE are not listed. An index key is the text duckdb_indexes() keeps (`pa`, `"name"`,
// `((n + 1))`): a column when, without its double quotes, it names a column of the table,
// otherwise an expression. Indexes have no method or predicate. A foreign key targets the
// table's own schema with NO ACTION both ways (DuckDB refuses other schemas and actions). A
// check's columns are the ones it references; NOT NULL constraints are left out (see
// `Column.isNullable`).

import Foundation

nonisolated extension DuckDBSchemaIntrospector {
  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure {
    let binds: [SQLBindValue] = [.text(schema), .text(table)]
    let filter = """
      WHERE database_name = current_database() AND schema_name = $1 AND table_name = $2
      """
    let found = try await rows(
      in: session, sql: "SELECT 1 FROM duckdb_tables() \(filter)", binds: binds)
    guard !found.isEmpty else {
      throw DatabaseError.queryFailed("Table \(schema).\(table) was not found", 0)
    }
    let columns = try await rows(
      in: session,
      sql: """
        SELECT column_index, column_name, data_type, is_nullable, column_default, comment
        FROM duckdb_columns() \(filter)
        ORDER BY column_index
        """,
      binds: binds
    ).compactMap { row -> TableStructure.Column? in
      guard let ordinal = DuckDBCatalogValue.int(row, 0),
        let name = DuckDBCatalogValue.string(row, 1)
      else { return nil }
      return TableStructure.Column(
        ordinal: ordinal, name: name, dataType: DuckDBCatalogValue.string(row, 2) ?? "",
        isNullable: DuckDBCatalogValue.bool(row, 3) ?? true,
        defaultExpression: DuckDBCatalogValue.string(row, 4),
        comment: DuckDBCatalogValue.string(row, 5))
    }
    return TableStructure(
      tableID: .duckdb(schema: schema, table: table), schema: schema, name: table,
      columns: columns,
      indexes: try await structureIndexes(
        filter, binds, columns: Set(columns.map(\.name)), in: session),
      constraints: try await structureConstraints(filter, binds, schema: schema, in: session))
  }

  /// One row per key, in index name then key order. `expressions` is list text (`['((n + 1))',
  /// '"name"']`); the cast to VARCHAR[] splits it with quotes and commas handled. `filter` is
  /// the constant WHERE clause above.
  private func structureIndexes(
    _ filter: String, _ binds: [SQLBindValue], columns: Set<String>,
    in session: any DatabaseSession
  ) async throws -> [TableStructure.Index] {
    let sql = """
      SELECT index_name, is_unique, unnest(keys) AS key, generate_subscripts(keys, 1) AS key_position
      FROM (
        SELECT index_name, is_unique, CAST(expressions AS VARCHAR[]) AS keys
        FROM duckdb_indexes() \(filter)
      )
      ORDER BY index_name, key_position
      """
    var indexes: [TableStructure.Index] = []
    for row in try await rows(in: session, sql: sql, binds: binds) {
      guard let name = DuckDBCatalogValue.string(row, 0),
        let text = DuckDBCatalogValue.string(row, 2)
      else { continue }
      var unquoted = text
      if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
        unquoted = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
      }
      let key: TableStructure.Index.Key =
        columns.contains(unquoted) ? .column(unquoted) : .expression(text)
      if indexes.last?.name == name {
        indexes[indexes.count - 1].keys.append(key)
        continue
      }
      indexes.append(
        TableStructure.Index(
          name: name, keys: [key], isUnique: DuckDBCatalogValue.bool(row, 1) ?? false,
          isPrimary: false, method: nil, isPartial: false, predicate: nil))
    }
    return indexes
  }

  /// Constraints in catalog order, then their columns (key order) in a second read so a check
  /// without columns is kept.
  private func structureConstraints(
    _ filter: String, _ binds: [SQLBindValue], schema: String, in session: any DatabaseSession
  ) async throws -> [TableStructure.Constraint] {
    let kinds = "AND constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY', 'CHECK')"
    let listed = try await rows(
      in: session,
      sql: """
        SELECT constraint_index, constraint_type, constraint_name, expression, referenced_table
        FROM duckdb_constraints() \(filter) \(kinds)
        ORDER BY constraint_index
        """,
      binds: binds)
    let parts = try await rows(
      in: session,
      sql: """
        SELECT constraint_index, unnest(constraint_column_names) AS key_column,
          generate_subscripts(constraint_column_names, 1) AS key_position,
          referenced_column_names[key_position] AS referenced_column
        FROM duckdb_constraints() \(filter) \(kinds)
        ORDER BY constraint_index, key_position
        """,
      binds: binds)
    var columns: [Int: [String]] = [:]
    var targets: [Int: [String]] = [:]
    for row in parts {
      guard let index = DuckDBCatalogValue.int(row, 0) else { continue }
      if let column = DuckDBCatalogValue.string(row, 1) {
        columns[index, default: []].append(column)
      }
      if let target = DuckDBCatalogValue.string(row, 3) {
        targets[index, default: []].append(target)
      }
    }
    return listed.compactMap { row in
      guard let index = DuckDBCatalogValue.int(row, 0) else { return nil }
      let kind: TableStructure.Constraint.Kind
      switch DuckDBCatalogValue.string(row, 1) {
      case "PRIMARY KEY": kind = .primaryKey
      case "UNIQUE": kind = .unique
      case "FOREIGN KEY":
        guard let table = DuckDBCatalogValue.string(row, 4) else { return nil }
        kind = .foreignKey(
          TableStructure.ForeignKeyReference(
            schema: schema, table: table, columns: targets[index] ?? [], onUpdate: .noAction,
            onDelete: .noAction))
      default: kind = .check(DuckDBCatalogValue.string(row, 3) ?? "")
      }
      return TableStructure.Constraint(
        name: DuckDBCatalogValue.string(row, 2), kind: kind, columns: columns[index] ?? [])
    }
  }
}

extension TableRef {
  /// DuckDB table identity: `duckdb:` then the double-quoted schema and table, built only here.
  /// Quotes are doubled, so names with dots or quotes never give the same string.
  nonisolated static func duckdb(schema: String, table: String) -> TableRef {
    func quoted(_ name: String) -> String {
      "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return TableRef("duckdb:\(quoted(schema)).\(quoted(table))")
  }
}
