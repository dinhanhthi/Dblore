// PostgresSchemaIntrospector+Structure.swift
// Structure of one PostgreSQL table from pg_catalog. Schema and table are bound and resolved to
// the table oid and comment (plain or partitioned table; a view or a missing name throws); every
// other read binds that oid.
//
// Defaults and generated expressions are pg_get_expr text (`'x'::character varying`,
// `nextval('s_seq'::regclass)`, `(s * 2)`). A generated column has no default. Index keys are the
// key columns in order (INCLUDE columns are left out); an expression key is
// pg_get_indexdef(index, n, true). Each key's order comes from indoption, unnested with indkey
// so positions line up (see `keyOrder(indoption:)`). A check is pg_get_expr(conbin) and its
// columns are the ones it references (conkey). Constraints other than p/u/f/c (exclusion, NOT
// NULL on PG 18) are left out. Column lists travel as JSON text so names with quotes decode as
// they are. Every catalog object is pg_catalog-qualified (see `PostgresSchemaIntrospector`).
// Comments are joined from pg_description, never read with obj_description / col_description:
// on PostgreSQL 13 and older those are SQL functions whose body is parsed when they run, with
// the caller's search_path and unqualified `=`. An empty comment reads as NULL.

import Foundation

nonisolated extension PostgresSchemaIntrospector {
  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure {
    let found = try await rows(
      in: session,
      sql: """
        SELECT c.oid::pg_catalog.int8,
          CASE WHEN ds.description OPERATOR(pg_catalog.=) '' THEN NULL ELSE ds.description END
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        LEFT JOIN pg_catalog.pg_description ds ON ds.objoid OPERATOR(pg_catalog.=) c.oid
          AND ds.classoid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
          AND ds.objsubid OPERATOR(pg_catalog.=) 0
        WHERE n.nspname OPERATOR(pg_catalog.=) $1 AND c.relname OPERATOR(pg_catalog.=) $2
          AND c.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'p']::pg_catalog."char"[])
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
      constraints: try await structureConstraints(bind, in: session),
      comment: found.first.flatMap { $0.count > 1 ? CatalogValue.string($0[1]) : nil })
  }

  /// attgenerated is PostgreSQL 12+; read through to_jsonb so older servers see no key.
  private func structureColumns(
    _ bind: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Column] {
    let query = """
      SELECT a.attnum::pg_catalog.int4, a.attname::pg_catalog.text,
        pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
        pg_catalog.pg_get_expr(d.adbin, d.adrelid), a.attidentity::pg_catalog.text,
        COALESCE(pg_catalog.to_jsonb(a) OPERATOR(pg_catalog.->>) 'attgenerated', ''),
        CASE WHEN ds.description OPERATOR(pg_catalog.=) '' THEN NULL ELSE ds.description END
      FROM pg_catalog.pg_attribute a
      LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid OPERATOR(pg_catalog.=) a.attrelid
        AND d.adnum OPERATOR(pg_catalog.=) a.attnum
      LEFT JOIN pg_catalog.pg_description ds ON ds.objoid OPERATOR(pg_catalog.=) a.attrelid
        AND ds.classoid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
        AND ds.objsubid OPERATOR(pg_catalog.=) a.attnum
      WHERE a.attrelid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
        AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
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

  /// One row per key part, in index name then key order. The two-array `unnest(a, b)` is grammar
  /// shorthand that exists only unqualified, so it is spelled out as `ROWS FROM`.
  private func structureIndexes(
    _ bind: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Index] {
    let query = """
      SELECT ic.relname::pg_catalog.text, i.indisunique, i.indisprimary,
        am.amname::pg_catalog.text, pg_catalog.pg_get_expr(i.indpred, i.indrelid),
        a.attname::pg_catalog.text,
        pg_catalog.pg_get_indexdef(i.indexrelid, k.ord::pg_catalog.int4, true),
        k.opt::pg_catalog.int4
      FROM pg_catalog.pg_index i
      JOIN pg_catalog.pg_class ic ON ic.oid OPERATOR(pg_catalog.=) i.indexrelid
      JOIN pg_catalog.pg_am am ON am.oid OPERATOR(pg_catalog.=) ic.relam
      CROSS JOIN LATERAL ROWS FROM (pg_catalog.unnest(i.indkey::pg_catalog.int2[]),
          pg_catalog.unnest(i.indoption::pg_catalog.int2[]))
        WITH ORDINALITY AS k(attnum, opt, ord)
      LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) i.indrelid
        AND a.attnum OPERATOR(pg_catalog.=) k.attnum AND k.attnum OPERATOR(pg_catalog.<>) 0
      WHERE i.indrelid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
        AND k.ord OPERATOR(pg_catalog.<=) i.indnkeyatts
      ORDER BY ic.relname, k.ord
      """
    var indexes: [TableStructure.Index] = []
    var orders: [[TableStructure.Index.KeyOrder]] = []
    for row in try await rows(in: session, sql: query, binds: bind) {
      guard row.count >= 8, let name = CatalogValue.string(row[0]) else { continue }
      let key: TableStructure.Index.Key =
        CatalogValue.string(row[5]).map { .column($0) }
        ?? .expression(CatalogValue.string(row[6]))
      let order = Self.keyOrder(indoption: CatalogValue.int(row[7]) ?? 0)
      if indexes.last?.name == name {
        indexes[indexes.count - 1].keys.append(key)
        orders[orders.count - 1].append(order)
        continue
      }
      let predicate = CatalogValue.string(row[4])
      indexes.append(
        TableStructure.Index(
          name: name, keys: [key], isUnique: CatalogValue.bool(row[1]) ?? false,
          isPrimary: CatalogValue.bool(row[2]) ?? false, method: CatalogValue.string(row[3]),
          isPartial: predicate != nil, predicate: predicate))
      orders.append([order])
    }
    for position in indexes.indices {
      indexes[position].sortOrder = TableStructure.Index.storedOrder(orders[position])
    }
    return indexes
  }

  /// One `pg_index.indoption` entry: 0x1 DESC, 0x2 NULLS FIRST. NULLS is kept only when it is
  /// not the default for the direction (LAST for ASC, FIRST for DESC).
  static func keyOrder(indoption: Int) -> TableStructure.Index.KeyOrder {
    let descending = indoption & 0x1 != 0
    let nullsFirst = indoption & 0x2 != 0
    return TableStructure.Index.KeyOrder(
      descending: descending, nullsFirst: nullsFirst == descending ? nil : nullsFirst)
  }

  /// conparentid = 0 drops the per-partition copies of an inherited constraint.
  private func structureConstraints(
    _ bind: [SQLBindValue], in session: any DatabaseSession
  ) async throws -> [TableStructure.Constraint] {
    let query = """
      SELECT c.conname::pg_catalog.text, c.contype::pg_catalog.text,
        (SELECT COALESCE(pg_catalog.json_agg(a.attname::pg_catalog.text ORDER BY x.n), '[]')
            ::pg_catalog.text
          FROM pg_catalog.unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
          JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) c.conrelid
            AND a.attnum OPERATOR(pg_catalog.=) x.attnum),
        fn.nspname::pg_catalog.text, fc.relname::pg_catalog.text,
        (SELECT COALESCE(pg_catalog.json_agg(a.attname::pg_catalog.text ORDER BY x.n), '[]')
            ::pg_catalog.text
          FROM pg_catalog.unnest(c.confkey) WITH ORDINALITY AS x(attnum, n)
          JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) c.confrelid
            AND a.attnum OPERATOR(pg_catalog.=) x.attnum),
        c.confupdtype::pg_catalog.text, c.confdeltype::pg_catalog.text,
        pg_catalog.pg_get_expr(c.conbin, c.conrelid)
      FROM pg_catalog.pg_constraint c
      LEFT JOIN pg_catalog.pg_class fc ON fc.oid OPERATOR(pg_catalog.=) c.confrelid
      LEFT JOIN pg_catalog.pg_namespace fn ON fn.oid OPERATOR(pg_catalog.=) fc.relnamespace
      WHERE c.conrelid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
        AND c.contype OPERATOR(pg_catalog.=) ANY (ARRAY['p', 'u', 'f', 'c']::pg_catalog."char"[])
        AND c.conparentid OPERATOR(pg_catalog.=) 0
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

// MARK: - Sequence and user type DDL

// Read-only DDL of a sequence, enum, domain or composite type, rendered from its loaded catalog
// row (CREATE SEQUENCE, CREATE TYPE and CREATE DOMAIN in the PostgreSQL docs). The SQL dump has
// its own enum, domain and sequence statements; they are not reused because the dump leaves out
// CACHE, NO MINVALUE / NO MAXVALUE and OWNED BY (written after the data), and has no composite
// types. A NOT VALID domain check follows its CREATE DOMAIN as ALTER DOMAIN, as in the dump.
// Identifiers are quoted, enum labels are literals; types, defaults and constraint definitions
// are server text, written as the catalog printed them.
nonisolated extension PostgresSchemaIntrospector {
  static func ddl(_ sequence: DatabaseSequence) throws -> String {
    let dialect = SQLDialect.postgresql
    let (typeMin, typeMax) = sequenceTypeBounds(sequence.dataType)
    let ascending = sequence.increment > 0
    var lines = [
      "CREATE SEQUENCE \(try qualifiedName(sequence.schema, sequence.name))",
      "  AS \(sequence.dataType)",
      "  INCREMENT BY \(sequence.increment)",
      sequence.minValue == (ascending ? 1 : typeMin)
        ? "  NO MINVALUE" : "  MINVALUE \(sequence.minValue)",
      sequence.maxValue == (ascending ? typeMax : -1)
        ? "  NO MAXVALUE" : "  MAXVALUE \(sequence.maxValue)",
      "  START WITH \(sequence.start)",
      "  CACHE \(sequence.cache)",
      sequence.cycle ? "  CYCLE" : "  NO CYCLE",
    ]
    if let owner = sequence.ownedBy {
      let column =
        try qualifiedName(owner.schema, owner.table) + "."
        + dialect.quoteIdentifier(owner.column)
      if sequence.isIdentity {
        let note = SQLDialect.lineCommentSafe(column)
        lines.insert("-- Identity sequence of \(note), created by its column", at: 0)
      } else {
        lines.append("  OWNED BY \(column)")
      }
    }
    return lines.joined(separator: "\n") + ";"
  }

  static func ddl(_ type: DatabaseUserType) throws -> String {
    let dialect = SQLDialect.postgresql
    let name = try qualifiedName(type.schema, type.name)
    switch type.kind {
    case .enum(let labels):
      let items = labels.map { "  " + dialect.literal(.string($0)) }
      return "CREATE TYPE \(name) AS ENUM " + parenthesized(items)
    case .composite(let attributes):
      let items = try attributes.map { "  \(try dialect.quoteIdentifier($0.name)) \($0.type)" }
      return "CREATE TYPE \(name) AS " + parenthesized(items)
    case .domain(let baseType, let notNull, let defaultExpression, let constraints):
      var lines = ["CREATE DOMAIN \(name) AS \(baseType)"]
      if let defaultExpression { lines.append("  DEFAULT \(defaultExpression)") }
      if notNull { lines.append("  NOT NULL") }
      // CREATE DOMAIN cannot hold a check that is not validated: ALTER DOMAIN adds it after
      let notValid = { (constraint: DatabaseUserType.Constraint) in
        constraint.definition.hasSuffix(" NOT VALID")
      }
      for constraint in constraints where !notValid(constraint) {
        lines.append(
          "  CONSTRAINT \(try dialect.quoteIdentifier(constraint.name)) \(constraint.definition)")
      }
      let alters = try constraints.filter(notValid).map {
        "ALTER DOMAIN \(name) ADD CONSTRAINT \(try dialect.quoteIdentifier($0.name))"
          + " \($0.definition);"
      }
      return ([lines.joined(separator: "\n") + ";"] + alters).joined(separator: "\n")
    }
  }

  /// One item per line, `();` when there is none
  private static func parenthesized(_ items: [String]) -> String {
    items.isEmpty ? "();" : "(\n" + items.joined(separator: ",\n") + "\n);"
  }

  private static func qualifiedName(_ schema: String, _ name: String) throws -> String {
    let dialect = SQLDialect.postgresql
    return try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(name)
  }

  /// Range of a sequence's type, which sets its default bounds (bigint for an unknown type)
  private static func sequenceTypeBounds(_ dataType: String) -> (min: Int, max: Int) {
    switch dataType {
    case "smallint": (Int(Int16.min), Int(Int16.max))
    case "integer": (Int(Int32.min), Int(Int32.max))
    default: (Int(Int64.min), Int(Int64.max))
    }
  }
}
