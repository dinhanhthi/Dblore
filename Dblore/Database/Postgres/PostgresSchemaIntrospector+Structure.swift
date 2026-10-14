// PostgresSchemaIntrospector+Structure.swift
// Structure of one PostgreSQL table from pg_catalog. Schema and table are bound and resolved to
// the table oid (plain or partitioned table; a view or a missing name throws); every other read
// binds that oid.
//
// Defaults and generated expressions are pg_get_expr text (`'x'::character varying`,
// `nextval('s_seq'::regclass)`, `(s * 2)`). A generated column has no default. Index keys are the
// key columns in order (INCLUDE columns are left out); an expression key is
// pg_get_indexdef(index, n, true). A check is pg_get_expr(conbin) and its columns are the ones
// it references (conkey). Constraints other than p/u/f/c (exclusion, NOT NULL on PG 18) are left
// out. Column lists travel as JSON text so names with quotes decode as they are.

import Foundation

nonisolated extension PostgresSchemaIntrospector {
  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure {
    let found = try await rows(
      in: session,
      sql: """
        SELECT c.oid::int8 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p')
        """,
      binds: [.text(schema), .text(table)])
    guard let oid = found.first?.first.flatMap(CatalogValue.oid) else {
      throw DatabaseError.queryFailed("Table \(schema).\(table) was not found", 0)
    }
    let bind: [SQLBindValue] = [.text(String(oid))]
    return TableStructure(
      tableID: .postgresql(oid: oid), schema: schema, name: table,
      columns: try await structureColumns(bind, in: session),
      indexes: try await structureIndexes(bind, in: session),
      constraints: try await structureConstraints(bind, in: session))
  }

  /// attgenerated is PostgreSQL 12+; read through to_jsonb so older servers see no key.
  private func structureColumns(
    _ bind: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Column] {
    let query = """
      SELECT a.attnum::int4, a.attname::text, format_type(a.atttypid, a.atttypmod),
        a.attnotnull, pg_get_expr(d.adbin, d.adrelid), a.attidentity::text,
        COALESCE(to_jsonb(a) ->> 'attgenerated', ''), col_description(a.attrelid, a.attnum)
      FROM pg_attribute a
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY a.attnum
      """
    var columns: [TableStructure.Column] = []
    for row in try await rows(in: session, sql: query, binds: bind) {
      guard row.count >= 8, let ordinal = CatalogValue.int(row[0]),
        let name = CatalogValue.string(row[1])
      else { continue }
      let expression = CatalogValue.string(row[4])
      let generated = CatalogValue.string(row[6]) ?? ""
      var identity: TableStructure.Identity?
      switch CatalogValue.string(row[5]) {
      case "a": identity = .always
      case "d": identity = .byDefault
      default: identity = nil
      }
      columns.append(
        TableStructure.Column(
          ordinal: ordinal, name: name, dataType: CatalogValue.string(row[2]) ?? "",
          isNullable: !(CatalogValue.bool(row[3]) ?? false),
          defaultExpression: generated.isEmpty ? expression : nil,
          identity: identity,
          generated: generated.isEmpty
            ? nil : TableStructure.Generated(expression: expression, isStored: generated == "s"),
          comment: CatalogValue.string(row[7])))
    }
    return columns
  }

  /// One row per key part, in index name then key order.
  private func structureIndexes(
    _ bind: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Index] {
    let query = """
      SELECT ic.relname::text, i.indisunique, i.indisprimary, am.amname::text,
        pg_get_expr(i.indpred, i.indrelid), a.attname::text,
        pg_get_indexdef(i.indexrelid, k.ord::int, true)
      FROM pg_index i
      JOIN pg_class ic ON ic.oid = i.indexrelid
      JOIN pg_am am ON am.oid = ic.relam
      CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
      LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        AND k.attnum <> 0
      WHERE i.indrelid = $1::oid AND k.ord <= i.indnkeyatts
      ORDER BY ic.relname, k.ord
      """
    var indexes: [TableStructure.Index] = []
    for row in try await rows(in: session, sql: query, binds: bind) {
      guard row.count >= 7, let name = CatalogValue.string(row[0]) else { continue }
      let key: TableStructure.Index.Key =
        CatalogValue.string(row[5]).map { .column($0) }
        ?? .expression(CatalogValue.string(row[6]))
      if indexes.last?.name == name {
        indexes[indexes.count - 1].keys.append(key)
        continue
      }
      let predicate = CatalogValue.string(row[4])
      indexes.append(
        TableStructure.Index(
          name: name, keys: [key], isUnique: CatalogValue.bool(row[1]) ?? false,
          isPrimary: CatalogValue.bool(row[2]) ?? false, method: CatalogValue.string(row[3]),
          isPartial: predicate != nil, predicate: predicate))
    }
    return indexes
  }

  /// conparentid = 0 drops the per-partition copies of an inherited constraint.
  private func structureConstraints(
    _ bind: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Constraint] {
    let query = """
      SELECT c.conname::text, c.contype::text,
        (SELECT COALESCE(json_agg(a.attname::text ORDER BY x.n), '[]')::text
          FROM unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum),
        fn.nspname::text, fc.relname::text,
        (SELECT COALESCE(json_agg(a.attname::text ORDER BY x.n), '[]')::text
          FROM unnest(c.confkey) WITH ORDINALITY AS x(attnum, n)
          JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = x.attnum),
        c.confupdtype::text, c.confdeltype::text, pg_get_expr(c.conbin, c.conrelid)
      FROM pg_constraint c
      LEFT JOIN pg_class fc ON fc.oid = c.confrelid
      LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
      WHERE c.conrelid = $1::oid AND c.contype IN ('p', 'u', 'f', 'c') AND c.conparentid = 0
      ORDER BY c.conname
      """
    var constraints: [TableStructure.Constraint] = []
    for row in try await rows(in: session, sql: query, binds: bind) {
      guard row.count >= 9, let name = CatalogValue.string(row[0]) else { continue }
      let kind: TableStructure.Constraint.Kind
      switch CatalogValue.string(row[1]) {
      case "p": kind = .primaryKey
      case "u": kind = .unique
      case "f":
        guard let schema = CatalogValue.string(row[3]), let table = CatalogValue.string(row[4])
        else { continue }
        kind = .foreignKey(
          TableStructure.ForeignKeyReference(
            schema: schema, table: table, columns: CatalogValue.stringList(row[5]),
            onUpdate: ForeignKeyAction(pgCode: CatalogValue.string(row[6]) ?? "a"),
            onDelete: ForeignKeyAction(pgCode: CatalogValue.string(row[7]) ?? "a")))
      default:
        kind = .check(CatalogValue.string(row[8]) ?? "")
      }
      constraints.append(
        TableStructure.Constraint(
          name: name, kind: kind, columns: CatalogValue.stringList(row[2])))
    }
    return constraints
  }
}
