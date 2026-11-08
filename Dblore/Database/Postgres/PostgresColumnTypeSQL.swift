// PostgresColumnTypeSQL.swift
// Classifies column types on the server (`PostgresColumnType`) for `allColumns` and
// `structureColumns`. Their column read selects only `a.atttypid`; one more statement then reads
// the type data of the distinct non-built-in oids, bound as one `oid[]` text literal, and is not
// sent when there are none.
//
// The comparison operand is "bare" (written `OPERATOR(<extension schema>.<op>)`) only when the
// base type, through at most 8 domains, is owned (pg_depend deptype 'e') by the extension that
// ships it under that name: citext; PostGIS geometry and geography; hstore; ltree, lquery and
// ltxtquery; cube; the isn types. A user type with one of those names in another schema, an
// array of them (`anyarray` equality compares elements with their default btree opclass) and
// every other type are "qualified". The domain chain is unrolled (`d1` … `d8`, each joined only
// while the previous one is a domain), so the read has no recursion.

import Foundation

nonisolated enum PostgresColumnTypeSQL {
  /// The cells of a type row: oid, operand, cast name, compare cast, operator schema
  static let width = 5

  /// PostgreSQL's FirstNormalObjectId: every type initdb creates (every built-in) has a lower oid.
  /// Built-in types are never extension-owned, so they are not read: their nil type data compares
  /// with the qualified `pg_catalog` operator, as their read would.
  static let firstNormalObjectID: UInt32 = 16_384

  /// The type data of the oids in `$1` (an `oid[]` text literal), one row per oid. `ext`: the
  /// allowlisted extension-owned base types; `el`, `eln`: an array's element type (a domain over
  /// an array stays the domain).
  static let query = """
    SELECT t.oid::pg_catalog.int8,
      CASE WHEN ext.oid IS NULL THEN 'qualified' ELSE 'bare' END,
      CASE WHEN tn.nspname OPERATOR(pg_catalog.=) 'pg_catalog' THEN NULL
        WHEN el.oid IS NOT NULL
          THEN pg_catalog.quote_ident(eln.nspname) OPERATOR(pg_catalog.||) '.'
            OPERATOR(pg_catalog.||) pg_catalog.quote_ident(el.typname) OPERATOR(pg_catalog.||) '[]'
        ELSE pg_catalog.quote_ident(tn.nspname) OPERATOR(pg_catalog.||) '.'
          OPERATOR(pg_catalog.||) pg_catalog.quote_ident(t.typname) END,
      CASE WHEN t.typtype OPERATOR(pg_catalog.=) 'd' THEN ext.base_name END,
      ext.operator_schema
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace tn ON tn.oid OPERATOR(pg_catalog.=) t.typnamespace
    LEFT JOIN pg_catalog.pg_type el ON el.oid OPERATOR(pg_catalog.=) t.typelem
      AND t.typtype OPERATOR(pg_catalog.=) 'b' AND t.typcategory OPERATOR(pg_catalog.=) 'A'
    LEFT JOIN pg_catalog.pg_namespace eln ON eln.oid OPERATOR(pg_catalog.=) el.typnamespace
    LEFT JOIN pg_catalog.pg_type d1 ON d1.oid OPERATOR(pg_catalog.=) t.typbasetype
      AND t.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d2 ON d2.oid OPERATOR(pg_catalog.=) d1.typbasetype
      AND d1.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d3 ON d3.oid OPERATOR(pg_catalog.=) d2.typbasetype
      AND d2.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d4 ON d4.oid OPERATOR(pg_catalog.=) d3.typbasetype
      AND d3.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d5 ON d5.oid OPERATOR(pg_catalog.=) d4.typbasetype
      AND d4.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d6 ON d6.oid OPERATOR(pg_catalog.=) d5.typbasetype
      AND d5.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d7 ON d7.oid OPERATOR(pg_catalog.=) d6.typbasetype
      AND d6.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN pg_catalog.pg_type d8 ON d8.oid OPERATOR(pg_catalog.=) d7.typbasetype
      AND d7.typtype OPERATOR(pg_catalog.=) 'd'
    LEFT JOIN (
      SELECT bt.oid, pg_catalog.quote_ident(en.nspname) AS operator_schema,
        pg_catalog.quote_ident(bn.nspname) OPERATOR(pg_catalog.||) '.'
          OPERATOR(pg_catalog.||) pg_catalog.quote_ident(bt.typname) AS base_name
      FROM pg_catalog.pg_depend dep
      JOIN pg_catalog.pg_type bt ON bt.oid OPERATOR(pg_catalog.=) dep.objid
      JOIN pg_catalog.pg_namespace bn ON bn.oid OPERATOR(pg_catalog.=) bt.typnamespace
      JOIN pg_catalog.pg_extension e ON e.oid OPERATOR(pg_catalog.=) dep.refobjid
      JOIN pg_catalog.pg_namespace en ON en.oid OPERATOR(pg_catalog.=) e.extnamespace
      JOIN (VALUES ('citext'::pg_catalog.name, 'citext'::pg_catalog.name),
          ('postgis', 'geometry'), ('postgis', 'geography'), ('hstore', 'hstore'),
          ('ltree', 'ltree'), ('ltree', 'lquery'), ('ltree', 'ltxtquery'), ('cube', 'cube'),
          ('isn', 'ean13'), ('isn', 'isbn'), ('isn', 'isbn13'), ('isn', 'ismn'),
          ('isn', 'ismn13'), ('isn', 'issn'), ('isn', 'issn13'), ('isn', 'upc'))
        AS listed(extname, typname)
        ON listed.extname OPERATOR(pg_catalog.=) e.extname
        AND listed.typname OPERATOR(pg_catalog.=) bt.typname
      WHERE dep.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_type'::pg_catalog.regclass
        AND dep.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass
        AND dep.deptype OPERATOR(pg_catalog.=) 'e'
        AND bt.typtype OPERATOR(pg_catalog.<>) 'd'
    ) ext ON ext.oid OPERATOR(pg_catalog.=)
        COALESCE(d8.oid, d7.oid, d6.oid, d5.oid, d4.oid, d3.oid, d2.oid, d1.oid, t.oid)
      AND t.typcategory OPERATOR(pg_catalog.<>) 'A'
    WHERE t.oid OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.oid[])
    """

  /// The type data in a row of `query`; nil without an oid
  static func parse(_ row: [CellValue]) -> PostgresColumnType? {
    guard row.count >= width, let oid = CatalogValue.oid(row[0]) else { return nil }
    return PostgresColumnType(
      oid: oid,
      operand: CatalogValue.string(row[1]) == "bare" ? .bare : .qualified,
      castName: CatalogValue.string(row[2]),
      compareCast: CatalogValue.string(row[3]),
      operatorSchema: CatalogValue.string(row[4]))
  }
}

nonisolated extension PostgresSchemaIntrospector {
  /// The type data of `oids` by oid, in one read (none without a non-built-in oid). A built-in
  /// oid, or one the server does not answer for, has no entry.
  func columnTypes(
    _ oids: Set<UInt32>, in session: any DatabaseSession
  ) async throws -> [UInt32: PostgresColumnType] {
    let oids = oids.filter { $0 >= PostgresColumnTypeSQL.firstNormalObjectID }
    guard !oids.isEmpty else { return [:] }
    let literal = "{" + oids.sorted().map(String.init).joined(separator: ",") + "}"
    var types: [UInt32: PostgresColumnType] = [:]
    for row in try await rows(
      in: session, sql: PostgresColumnTypeSQL.query, binds: [.text(literal)])
    {
      if let type = PostgresColumnTypeSQL.parse(row) { types[type.oid] = type }
    }
    return types
  }
}
