// SQLDumpCatalog.swift
// Catalog reads that fill the `SQLDumpDDL` inputs, run through the dump's snapshot reader (reads
// only). Table structures come from the engine's schema introspector; the rest is read here.
//
// PostgreSQL dumps the plain and partitioned tables of every schema except `information_schema`
// and the `pg_` schemas, without temporary tables and extension members, then the views of
// those schemas. Sequences, enums and domains are kept only when a dumped column uses them.
// Index, foreign key, exclusion constraint and NOT VALID check text comes from
// `pg_get_indexdef` and `pg_get_constraintdef`. Needs PostgreSQL 11+ (`pg_constraint.conparentid`).
// MySQL dumps the base tables and views of the connected database (`SHOW CREATE TABLE`,
// `SHOW CREATE VIEW`). View dependencies come from `information_schema.VIEW_TABLE_USAGE` where
// the server has it (MySQL 8.0.13+), else views fall back to name order. MariaDB has no
// VIEW_TABLE_USAGE: the views each `information_schema.VIEWS.VIEW_DEFINITION` names are its
// dependencies.
// SQLite dumps the `main` database: `sqlite_master` in rowid order, shadow tables from
// `pragma_table_list` (SQLite 3.37+, else the name prefix rule) and `sqlite_sequence`.
// DuckDB dumps the connected database (`current_database()`), without internal and temporary
// objects: non-internal schemas, ENUM types, sequences, then tables, indexes and views in
// creation (oid) order, each with the `sql` text of its `duckdb_*()` table function.

import Foundation

nonisolated enum SQLDumpCatalog {
  // MARK: - PostgreSQL

  /// User relations: not in a system schema, not temporary, not owned by an extension
  private static let postgresUserRelation = """
    n.nspname <> 'information_schema' AND left(n.nspname, 3) <> 'pg_'
      AND c.relpersistence <> 't'
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend e
        WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid AND e.deptype = 'e')
    """

  private static let postgresTableFilter = "c.relkind IN ('r', 'p') AND \(postgresUserRelation)"

  static func postgresInput(_ reader: any DatabaseSession) async throws -> SQLDumpDDL.PostgresInput
  {
    let introspector = PostgresSchemaIntrospector()
    let listed = try await rows(
      reader,
      """
      SELECT c.oid::int8, n.nspname::text, c.relname::text, pg_get_partkeydef(c.oid),
        pn.nspname::text, pc.relname::text, pg_get_expr(c.relpartbound, c.oid)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_inherits i ON c.relispartition AND i.inhrelid = c.oid
      LEFT JOIN pg_class pc ON pc.oid = i.inhparent
      LEFT JOIN pg_namespace pn ON pn.oid = pc.relnamespace
      WHERE \(postgresTableFilter)
      ORDER BY n.nspname, c.relname
      """)
    let indexes = try await postgresIndexes(reader)
    let constraints = try await postgresConstraints(reader)
    var tables: [SQLDumpDDL.PostgresTable] = []
    for row in listed {
      guard row.count >= 7, let oid = CatalogValue.int(row[0]),
        let schema = CatalogValue.string(row[1]), let name = CatalogValue.string(row[2])
      else { continue }
      var table = SQLDumpDDL.PostgresTable(
        structure: try await introspector.tableStructure(schema: schema, table: name, in: reader),
        partitionKey: CatalogValue.string(row[3]))
      if let parentSchema = CatalogValue.string(row[4]), let parent = CatalogValue.string(row[5]),
        let bound = CatalogValue.string(row[6])
      {
        table.partitionOf = SQLDumpDDL.Partition(
          parent: SQLDumpDDL.ObjectName(schema: parentSchema, name: parent), bound: bound)
        table.inheritedConstraintNames = constraints[oid]?.inherited ?? []
      }
      for index in indexes[oid] ?? [] {
        table.indexDefinitions[index.name] = index.definition
        if index.isInherited { table.inheritedIndexNames.insert(index.name) }
      }
      table.foreignKeyDefinitions = constraints[oid]?.foreignKeys ?? [:]
      table.exclusionConstraints = constraints[oid]?.exclusions ?? [:]
      table.notValidCheckDefinitions = constraints[oid]?.notValidChecks ?? [:]
      tables.append(table)
    }
    let dumped = Set(
      tables.map { SQLDumpDDL.ObjectName(schema: $0.structure.schema, name: $0.structure.name) })
    let types = try await postgresTypes(reader)
    return SQLDumpDDL.PostgresInput(
      tables: tables, sequences: try await postgresSequences(reader, dumped: dumped),
      enums: types.enums, domains: types.domains, views: try await postgresViews(reader))
  }

  private struct PostgresIndex {
    var name: String
    var definition: String
    var isInherited: Bool
  }

  /// `pg_get_indexdef` of every index of a dumped table, by table oid
  private static func postgresIndexes(
    _ reader: any DatabaseSession
  ) async throws -> [Int: [PostgresIndex]] {
    var indexes: [Int: [PostgresIndex]] = [:]
    for row in try await rows(
      reader,
      """
      SELECT x.indrelid::int8, ic.relname::text, pg_get_indexdef(x.indexrelid),
        EXISTS (SELECT 1 FROM pg_inherits h WHERE h.inhrelid = x.indexrelid)
      FROM pg_index x
      JOIN pg_class ic ON ic.oid = x.indexrelid
      JOIN pg_class c ON c.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE \(postgresTableFilter)
      """)
    {
      guard row.count >= 4, let table = CatalogValue.int(row[0]),
        let name = CatalogValue.string(row[1]), let definition = CatalogValue.string(row[2])
      else { continue }
      indexes[table, default: []].append(
        PostgresIndex(
          name: name, definition: definition, isInherited: CatalogValue.bool(row[3]) ?? false))
    }
    return indexes
  }

  private struct PostgresConstraints {
    var foreignKeys: [String: String] = [:]
    var exclusions: [String: String] = [:]
    /// CHECK constraints that are not validated (`NOT convalidated`)
    var notValidChecks: [String: String] = [:]
    /// Check constraints inherited from a parent (`coninhcount > 0` and not local)
    var inherited: Set<String> = []
  }

  /// Foreign keys, exclusion constraints and NOT VALID checks (`pg_get_constraintdef`) and
  /// inherited constraint names, by table oid. Copies a partition gets from its parent
  /// (`conparentid` set) are left out: the parent's constraint creates them.
  private static func postgresConstraints(
    _ reader: any DatabaseSession
  ) async throws -> [Int: PostgresConstraints] {
    var constraints: [Int: PostgresConstraints] = [:]
    for row in try await rows(
      reader,
      """
      SELECT con.conrelid::int8, con.conname::text, con.contype::text,
        pg_get_constraintdef(con.oid), con.coninhcount > 0 AND NOT con.conislocal,
        NOT con.convalidated
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE \(postgresTableFilter) AND con.conparentid = 0
        AND (con.contype IN ('f', 'x') OR (con.contype = 'c' AND NOT con.convalidated)
          OR (con.coninhcount > 0 AND NOT con.conislocal))
      """)
    {
      guard row.count >= 6, let table = CatalogValue.int(row[0]),
        let name = CatalogValue.string(row[1]), let definition = CatalogValue.string(row[3])
      else { continue }
      if CatalogValue.bool(row[4]) == true {
        constraints[table, default: .init()].inherited.insert(name)
      }
      switch CatalogValue.string(row[2]) {
      case "f": constraints[table, default: .init()].foreignKeys[name] = definition
      case "x": constraints[table, default: .init()].exclusions[name] = definition
      case "c" where CatalogValue.bool(row[5]) == true:
        constraints[table, default: .init()].notValidChecks[name] = definition
      default: break
      }
    }
    return constraints
  }

  /// Sequences owned by a dumped column (serial, identity, `OWNED BY`) or used by a dumped
  /// column's default (`nextval`)
  private static func postgresSequences(
    _ reader: any DatabaseSession, dumped: Set<SQLDumpDDL.ObjectName>
  ) async throws -> [SQLDumpDDL.PostgresSequence] {
    var sequences: [SQLDumpDDL.PostgresSequence] = []
    for row in try await rows(
      reader,
      """
      SELECT n.nspname::text, c.relname::text, format_type(s.seqtypid, NULL), s.seqstart::text,
        s.seqincrement::text, s.seqmin::text, s.seqmax::text, s.seqcycle, tn.nspname::text,
        tc.relname::text, a.attname::text, d.deptype::text, ps.last_value::text,
        (SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_array(un.nspname, uc.relname)), '[]')::text
          FROM pg_depend ud
          JOIN pg_attrdef ad ON ad.oid = ud.objid
          JOIN pg_class uc ON uc.oid = ad.adrelid
          JOIN pg_namespace un ON un.oid = uc.relnamespace
          WHERE ud.classid = 'pg_attrdef'::regclass AND ud.refclassid = 'pg_class'::regclass
            AND ud.refobjid = s.seqrelid)
      FROM pg_sequence s
      JOIN pg_class c ON c.oid = s.seqrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = s.seqrelid
        AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
      LEFT JOIN pg_class tc ON tc.oid = d.refobjid
      LEFT JOIN pg_namespace tn ON tn.oid = tc.relnamespace
      LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
      LEFT JOIN pg_sequences ps ON ps.schemaname = n.nspname AND ps.sequencename = c.relname
      WHERE n.nspname <> 'information_schema' AND left(n.nspname, 3) <> 'pg_'
      ORDER BY n.nspname, c.relname
      """)
    {
      guard row.count >= 14, let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]), let dataType = CatalogValue.string(row[2]),
        let start = int64(row[3]), let increment = int64(row[4]), let minValue = int64(row[5]),
        let maxValue = int64(row[6])
      else { continue }
      var owner: SQLDumpDDL.ColumnRef?
      if let ownerSchema = CatalogValue.string(row[8]), let table = CatalogValue.string(row[9]),
        let column = CatalogValue.string(row[10])
      {
        owner = SQLDumpDDL.ColumnRef(
          table: SQLDumpDDL.ObjectName(schema: ownerSchema, name: table), column: column)
      }
      let users = pairs(row[13]).map { SQLDumpDDL.ObjectName(schema: $0.0, name: $0.1) }
      guard
        owner.map({ dumped.contains($0.table) }) == true || users.contains(where: dumped.contains)
      else { continue }
      sequences.append(
        SQLDumpDDL.PostgresSequence(
          schema: schema, name: name, dataType: dataType, start: start, increment: increment,
          minValue: minValue, maxValue: maxValue, cycle: CatalogValue.bool(row[7]) ?? false,
          ownedBy: owner.flatMap { dumped.contains($0.table) ? $0 : nil },
          lastValue: int64(row[12]), isIdentity: CatalogValue.string(row[11]) == "i"))
    }
    return sequences
  }

  /// Enums and domains that dumped columns use, directly, as array elements or as a domain's
  /// base type. Domains in creation (oid) order.
  private static func postgresTypes(
    _ reader: any DatabaseSession
  ) async throws -> (enums: [SQLDumpDDL.PostgresEnum], domains: [SQLDumpDDL.PostgresDomain]) {
    var enums: [SQLDumpDDL.PostgresEnum] = []
    var domains: [SQLDumpDDL.PostgresDomain] = []
    for row in try await rows(
      reader,
      """
      WITH RECURSIVE used(oid) AS (
        SELECT a.atttypid FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE \(postgresTableFilter) AND a.attnum > 0 AND NOT a.attisdropped
        UNION
        SELECT CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.typelem END
        FROM used u JOIN pg_type t ON t.oid = u.oid
        WHERE t.typtype = 'd' OR (t.typcategory = 'A' AND t.typelem <> 0)
      )
      SELECT n.nspname::text, t.typname::text, t.typtype::text,
        (SELECT COALESCE(json_agg(e.enumlabel::text ORDER BY e.enumsortorder), '[]')::text
          FROM pg_enum e WHERE e.enumtypid = t.oid),
        format_type(t.typbasetype, t.typtypmod), pg_get_expr(t.typdefaultbin, 0), t.typnotnull,
        (SELECT COALESCE(json_agg(json_build_array(dc.conname::text, pg_get_constraintdef(dc.oid))
            ORDER BY dc.conname), '[]')::text
          FROM pg_constraint dc WHERE dc.contypid = t.oid AND dc.contype = 'c'),
        (SELECT COALESCE(json_agg(dc.conname::text), '[]')::text
          FROM pg_constraint dc
          WHERE dc.contypid = t.oid AND dc.contype = 'c' AND NOT dc.convalidated)
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE t.oid IN (SELECT oid FROM used) AND t.typtype IN ('e', 'd')
        AND n.nspname <> 'information_schema' AND left(n.nspname, 3) <> 'pg_'
      ORDER BY t.oid
      """)
    {
      guard row.count >= 9, let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1])
      else { continue }
      if CatalogValue.string(row[2]) == "e" {
        enums.append(
          SQLDumpDDL.PostgresEnum(
            schema: schema, name: name, labels: CatalogValue.stringList(row[3])))
        continue
      }
      let notValid = Set(CatalogValue.stringList(row[8]))
      domains.append(
        SQLDumpDDL.PostgresDomain(
          schema: schema, name: name, baseType: CatalogValue.string(row[4]) ?? "",
          defaultExpression: CatalogValue.string(row[5]),
          notNull: CatalogValue.bool(row[6]) ?? false,
          constraints: pairs(row[7]).map {
            SQLDumpDDL.DomainConstraint(
              name: $0.0, definition: $0.1, notValid: notValid.contains($0.0))
          }))
    }
    return (enums, domains)
  }

  /// Views of the dumped schemas (`pg_get_viewdef`) with the relations their rules read
  private static func postgresViews(
    _ reader: any DatabaseSession
  ) async throws -> [SQLDumpDDL.View] {
    try await rows(
      reader,
      """
      SELECT n.nspname::text, c.relname::text, pg_get_viewdef(c.oid),
        (SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_array(dn.nspname, dc.relname)), '[]')::text
          FROM pg_rewrite r
          JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
          JOIN pg_class dc ON dc.oid = d.refobjid
          JOIN pg_namespace dn ON dn.oid = dc.relnamespace
          WHERE r.ev_class = c.oid AND d.refclassid = 'pg_class'::regclass
            AND d.refobjid <> c.oid)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'v' AND \(postgresUserRelation)
      ORDER BY n.nspname, c.relname
      """
    ).compactMap { row in
      guard row.count >= 4, let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]), let sql = CatalogValue.string(row[2])
      else { return nil }
      return SQLDumpDDL.View(
        schema: schema, name: name, sql: sql,
        dependsOn: pairs(row[3]).map { SQLDumpDDL.ObjectName(schema: $0.0, name: $0.1) })
    }
  }

  // MARK: - MySQL

  static func mysqlInput(_ reader: any DatabaseSession) async throws -> SQLDumpDDL.MySQLInput {
    guard let database = try await rows(reader, "SELECT DATABASE()").first.flatMap({ text($0, 0) })
    else { throw SQLDumpError.noDatabaseSelected }
    let dialect = SQLDialect.mysql
    let introspector = MySQLSchemaIntrospector(database: database)
    var tables: [SQLDumpDDL.MySQLTable] = []
    for row in try await rows(
      reader,
      """
      SELECT TABLE_NAME FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = ? AND TABLE_TYPE IN \(MySQLSchemaIntrospector.tableTypes)
      ORDER BY TABLE_NAME
      """, binds: [.text(database)])
    {
      guard let name = text(row, 0) else { continue }
      let create = try await rows(reader, "SHOW CREATE TABLE \(try dialect.quoteIdentifier(name))")
      guard let statement = create.first.flatMap({ text($0, 1) }) else { continue }
      tables.append(
        SQLDumpDDL.MySQLTable(
          structure: try await introspector.tableStructure(
            schema: database, table: name, in: reader),
          createStatement: statement))
    }
    let isMariaDB =
      try await rows(reader, "SELECT VERSION()").first.flatMap({ text($0, 0) }).flatMap(
        MySQLServerInfo.init(version:))?.flavor == .mariadb
    var dependencies: [String: [SQLDumpDDL.ObjectName]] = [:]
    // Not on MySQL before 8.0.13: an error inside the transaction leaves it open, and the views
    // keep name order
    if !isMariaDB,
      let usage = try? await rows(
        reader,
        """
        SELECT VIEW_NAME, TABLE_SCHEMA, TABLE_NAME FROM information_schema.VIEW_TABLE_USAGE
        WHERE VIEW_SCHEMA = ?
        """, binds: [.text(database)])
    {
      for row in usage {
        guard let view = text(row, 0), let schema = text(row, 1), let table = text(row, 2)
        else { continue }
        dependencies[view, default: []].append(SQLDumpDDL.ObjectName(schema: schema, name: table))
      }
    }
    let listed = try await rows(
      reader,
      "SELECT TABLE_NAME\(isMariaDB ? ", VIEW_DEFINITION" : "") FROM information_schema.VIEWS"
        + " WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME",
      binds: [.text(database)])
    if isMariaDB {
      let names = Set(listed.compactMap { text($0, 0) })
      for row in listed {
        guard let name = text(row, 0), let definition = text(row, 1) else { continue }
        dependencies[name] = mariadbViewDependencies(
          definition, schema: database, viewNames: names)
      }
    }
    var views: [SQLDumpDDL.View] = []
    for row in listed {
      guard let name = text(row, 0) else { continue }
      let create = try await rows(reader, "SHOW CREATE VIEW \(try dialect.quoteIdentifier(name))")
      guard let statement = create.first.flatMap({ text($0, 1) }) else { continue }
      views.append(
        SQLDumpDDL.View(
          schema: database, name: name, sql: statement, dependsOn: dependencies[name] ?? []))
    }
    return SQLDumpDDL.MySQLInput(tables: tables, views: views)
  }

  /// Views of `schema` among `viewNames` that a MariaDB `VIEW_DEFINITION` names: backtick-quoted
  /// names exactly, bare ones without ASCII case. A name after `.` counts only when `schema` is
  /// before the dot (`schema`.`view`, not another schema's view or `view`.`column`). String
  /// literals and comments are skipped.
  static func mariadbViewDependencies(
    _ definition: String, schema: String, viewNames: Set<String>
  ) -> [SQLDumpDDL.ObjectName] {
    let bareNames = Dictionary(grouping: viewNames, by: SQLTokenizer.asciiUppercased)
    func names(_ token: SQLToken) -> [String] {
      switch token.kind {
      case .quotedIdentifier: viewNames.contains(token.text) ? [token.text] : []
      case .word: bareNames[token.text] ?? []
      default: []
      }
    }
    func isSchema(_ token: SQLToken) -> Bool {
      switch token.kind {
      case .quotedIdentifier: token.text == schema
      case .word: token.text == SQLTokenizer.asciiUppercased(schema)
      default: false
      }
    }
    let tokens = SQLTokenizer(dialect: .mysql).tokens(definition)
    var found: [SQLDumpDDL.ObjectName] = []
    for (position, token) in tokens.enumerated() {
      if position >= 2, tokens[position - 1].isSymbol("."), !isSchema(tokens[position - 2]) {
        continue
      }
      for name in names(token).sorted() {
        let object = SQLDumpDDL.ObjectName(schema: schema, name: name)
        if !found.contains(object) { found.append(object) }
      }
    }
    return found
  }

  // MARK: - SQLite

  static func sqliteInput(_ reader: any DatabaseSession) async throws -> SQLDumpDDL.SQLiteInput {
    let masterRows = try await rows(
      reader, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY rowid"
    ).compactMap { row -> SQLDumpDDL.SQLiteMasterRow? in
      guard let type = text(row, 0), let name = text(row, 1), let table = text(row, 2) else {
        return nil
      }
      return SQLDumpDDL.SQLiteMasterRow(type: type, name: name, tableName: table, sql: text(row, 3))
    }
    // SQLite 3.37+; older libraries fall back to the name prefix rule
    let shadows = try? await rows(
      reader, "SELECT name FROM pragma_table_list WHERE schema = 'main' AND type = 'shadow'"
    ).compactMap { text($0, 0) }
    var sequences: [SQLDumpDDL.SQLiteSequence] = []
    if masterRows.contains(where: { $0.type == "table" && $0.name == "sqlite_sequence" }) {
      for row in try await rows(reader, "SELECT name, seq FROM sqlite_sequence") {
        guard let name = text(row, 0), case .int(let seq) = row.count > 1 ? row[1] : .null
        else { continue }
        sequences.append(SQLDumpDDL.SQLiteSequence(name: name, seq: Int64(seq)))
      }
    }
    let shadowNames = shadows.map(Set.init)
    let introspector = SQLiteSchemaIntrospector()
    var structures: [TableStructure] = []
    for name in SQLDumpDDL.sqliteDumpedTableNames(masterRows, shadowTableNames: shadowNames) {
      structures.append(
        try await introspector.tableStructure(schema: "main", table: name, in: reader))
    }
    return SQLDumpDDL.SQLiteInput(
      masterRows: masterRows, structures: structures, shadowTableNames: shadowNames,
      sequences: sequences)
  }

  // MARK: - DuckDB

  /// Objects of the connected database, not of `temp`, `system` or an attached one
  private static let duckdbCurrent = "database_name = current_database()"

  static func duckdbInput(_ reader: any DatabaseSession) async throws -> SQLDumpDDL.DuckDBInput {
    let schemas = try await rows(
      reader,
      """
      SELECT schema_name FROM duckdb_schemas()
      WHERE \(duckdbCurrent) AND NOT internal ORDER BY schema_name
      """
    ).compactMap { text($0, 0) }
    let enums = try await rows(
      reader,
      """
      SELECT schema_name, type_name, to_json(labels)::VARCHAR FROM duckdb_types()
      WHERE \(duckdbCurrent) AND NOT internal AND logical_type = 'ENUM' ORDER BY type_oid
      """
    ).compactMap { row -> SQLDumpDDL.DuckDBEnum? in
      guard row.count >= 3, let schema = text(row, 0), let name = text(row, 1) else { return nil }
      return SQLDumpDDL.DuckDBEnum(
        schema: schema, name: name, labels: CatalogValue.stringList(row[2]))
    }
    let sequences = try await rows(
      reader,
      """
      SELECT schema_name, sequence_name, start_value::VARCHAR, increment_by::VARCHAR,
        min_value::VARCHAR, max_value::VARCHAR, cycle, last_value::VARCHAR
      FROM duckdb_sequences()
      WHERE \(duckdbCurrent) AND NOT temporary ORDER BY schema_name, sequence_name
      """
    ).compactMap { row -> SQLDumpDDL.DuckDBSequence? in
      guard row.count >= 8, let schema = text(row, 0), let name = text(row, 1),
        let start = int64(row[2]), let increment = int64(row[3]), let minValue = int64(row[4]),
        let maxValue = int64(row[5])
      else { return nil }
      return SQLDumpDDL.DuckDBSequence(
        schema: schema, name: name, start: start, increment: increment, minValue: minValue,
        maxValue: maxValue, cycle: CatalogValue.bool(row[6]) ?? false, lastValue: int64(row[7]))
    }
    let introspector = DuckDBSchemaIntrospector()
    var tables: [SQLDumpDDL.DuckDBTable] = []
    for row in try await rows(
      reader,
      """
      SELECT schema_name, table_name, sql FROM duckdb_tables()
      WHERE \(duckdbCurrent) AND NOT internal AND NOT temporary ORDER BY table_oid
      """)
    {
      guard let schema = text(row, 0), let name = text(row, 1), let sql = text(row, 2) else {
        continue
      }
      tables.append(
        SQLDumpDDL.DuckDBTable(
          structure: try await introspector.tableStructure(schema: schema, table: name, in: reader),
          sql: sql))
    }
    let indexes = try await rows(
      reader,
      """
      SELECT schema_name, table_name, index_name, sql FROM duckdb_indexes()
      WHERE \(duckdbCurrent) ORDER BY index_oid
      """
    ).compactMap { row -> SQLDumpDDL.DuckDBIndex? in
      guard let schema = text(row, 0), let table = text(row, 1), let name = text(row, 2),
        let sql = text(row, 3)
      else { return nil }
      return SQLDumpDDL.DuckDBIndex(schema: schema, table: table, name: name, sql: sql)
    }
    let views = try await rows(
      reader,
      """
      SELECT schema_name, view_name, sql FROM duckdb_views()
      WHERE \(duckdbCurrent) AND NOT internal AND NOT temporary ORDER BY view_oid
      """
    ).compactMap { row -> SQLDumpDDL.View? in
      guard let schema = text(row, 0), let name = text(row, 1), let sql = text(row, 2) else {
        return nil
      }
      return SQLDumpDDL.View(schema: schema, name: name, sql: sql, dependsOn: [])
    }
    return SQLDumpDDL.DuckDBInput(
      schemas: schemas, enums: enums, sequences: sequences, tables: tables, indexes: indexes,
      views: views)
  }

  // MARK: - Shared

  private static func rows(
    _ reader: any DatabaseSession, _ sql: String, binds: [SQLBindValue] = []
  ) async throws -> [[CellValue]] {
    let source = try await reader.query(sql, binds: binds)
    var collected: [[CellValue]] = []
    for try await row in source.rows { collected.append(row) }
    return collected
  }

  private static func text(_ row: [CellValue], _ index: Int) -> String? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .string(let value), .json(let value): return value
    case .data(let data): return String(data: data, encoding: .utf8)
    default: return nil
    }
  }

  private static func int64(_ value: CellValue) -> Int64? {
    switch value {
    case .int(let number): Int64(number)
    case .string(let text): Int64(text)
    default: nil
    }
  }

  /// `[["a", "b"], ...]` JSON text as pairs
  private static func pairs(_ value: CellValue) -> [(String, String)] {
    guard let text = CatalogValue.string(value), let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([[String]].self, from: data)
    else { return [] }
    return decoded.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
  }
}
