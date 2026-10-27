// PostgresSchemaIntrospector.swift
// PostgreSQL catalog reads for one open session. SQL matches the queries the connection
// actor used to send. The actor keeps the metadata pause and the catalog query counter.

import Foundation

/// `pg_catalog` / `information_schema` reads through `DatabaseSession.query`.
nonisolated struct PostgresSchemaIntrospector: SchemaIntrospector {
  /// Relation-level visibility, equivalent to what information_schema applies to tables and views
  private static let relationPrivilegeFilter = """
    (pg_has_role(c.relowner, 'USAGE')
      OR has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
      OR has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
    """

  /// information_schema hides other sessions' temporary tables (unreadable for this session)
  private static let hideOtherTempSchemas = "NOT pg_is_other_temp_schema(n.oid)"

  /// Column-level visibility, as information_schema.columns applies it: a column is listed only
  /// with a privilege on that column (or ownership through a role), not on any other column
  private static let columnPrivilegeFilter = """
    (pg_has_role(c.relowner, 'USAGE')
      OR has_column_privilege(c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES'))
    """

  /// The session's own temp tables (pg_temp_N) are flagged; `pg_my_temp_schema()` is 0 until
  /// the session creates one.
  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    // Never analyzed (reltuples -1 on PG 14+, 0/0 before): fall back to the stats counter,
    // 0 there stays unknown (empty table, track_counts off or stats reset)
    let query = """
      SELECT
        n.nspname::text,
        c.relname::text,
        CASE WHEN c.reltuples < 0 OR (c.reltuples = 0 AND c.relpages = 0)
          THEN NULLIF(pg_stat_get_live_tuples(c.oid), 0)
          ELSE c.reltuples::bigint END AS row_estimate,
        n.oid = pg_my_temp_schema() AS is_temporary
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p')
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND \(Self.hideOtherTempSchemas)
        AND \(Self.relationPrivilegeFilter)
      ORDER BY n.nspname, c.relname
      """
    var tables: [DatabaseTable] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 4,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1])
      else { continue }
      tables.append(
        DatabaseTable(
          schema: schema, name: name, rowCount: CatalogValue.optionalInt(row[2]),
          isTemporary: CatalogValue.bool(row[3]) ?? false))
    }
    return tables
  }

  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    let query = """
      SELECT
        n.nspname::text,
        c.relname::text,
        a.attname::text,
        format_type(a.atttypid, a.atttypmod),
        a.attnotnull,
        (a.attidentity <> '') AS is_identity,
        EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey)
        ) AS is_pk,
        EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.oid AND i.indisunique AND NOT i.indisprimary
            AND array_length(i.indkey, 1) = 1 AND a.attnum = ANY(i.indkey)
        ) AS is_unique
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p', 'v')
        AND a.attnum > 0 AND NOT a.attisdropped
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND \(Self.hideOtherTempSchemas)
        AND \(Self.columnPrivilegeFilter)
      ORDER BY n.nspname, c.relname, a.attnum
      """
    var columnRows: [SchemaCatalog.ColumnRow] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 8,
        let schema = CatalogValue.string(row[0]),
        let relation = CatalogValue.string(row[1]),
        let name = CatalogValue.string(row[2]),
        let formatType = CatalogValue.string(row[3]),
        let notNull = CatalogValue.bool(row[4]),
        let isIdentity = CatalogValue.bool(row[5]),
        let isPK = CatalogValue.bool(row[6]),
        let isUnique = CatalogValue.bool(row[7])
      else { continue }
      columnRows.append(
        SchemaCatalog.ColumnRow(
          schema: schema, relation: relation, name: name, formatType: formatType,
          notNull: notNull, isIdentity: isIdentity, isPK: isPK, isUnique: isUnique))
    }
    return SchemaCatalog.columnsByRelation(columnRows)
  }

  func views(in session: any DatabaseSession) async throws -> [DatabaseView] {
    let query = """
      SELECT n.nspname::text, c.relname::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'v'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND \(Self.hideOtherTempSchemas)
        AND \(Self.relationPrivilegeFilter)
      ORDER BY n.nspname, c.relname
      """
    var views: [DatabaseView] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 2,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1])
      else { continue }
      views.append(DatabaseView(schema: schema, name: name, definition: nil))
    }
    return views
  }

  func functions(in session: any DatabaseSession) async throws -> [DatabaseFunction] {
    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_result(p.oid) AS return_type,
        pg_get_function_arguments(p.oid) AS arguments,
        p.oid::int8
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'f'
        AND \(Self.hideOtherTempSchemas)
      ORDER BY n.nspname, p.proname
      """
    var functions: [DatabaseFunction] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 5,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]),
        let returnType = CatalogValue.string(row[2]),
        let arguments = CatalogValue.string(row[3])
      else { continue }
      functions.append(
        DatabaseFunction(
          schema: schema, name: name, returnType: returnType, arguments: arguments,
          definition: nil, oid: CatalogValue.oid(row[4])))
    }
    return functions
  }

  func procedures(in session: any DatabaseSession) async throws -> [DatabaseProcedure] {
    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_arguments(p.oid) AS arguments,
        p.oid::int8
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'p'
        AND \(Self.hideOtherTempSchemas)
      ORDER BY n.nspname, p.proname
      """
    var procedures: [DatabaseProcedure] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 4,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]),
        let arguments = CatalogValue.string(row[2])
      else { continue }
      procedures.append(
        DatabaseProcedure(
          schema: schema, name: name, arguments: arguments, definition: nil,
          oid: CatalogValue.oid(row[3])))
    }
    return procedures
  }

  /// User triggers (not the internal ones behind foreign keys), in the schemas functions use.
  func triggers(in session: any DatabaseSession) async throws -> [DatabaseTrigger] {
    let query = """
      SELECT
        n.nspname::text,
        c.relname::text,
        t.tgname::text,
        t.tgtype::int4,
        t.tgenabled::text,
        t.oid::int8
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE NOT t.tgisinternal
        AND n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND \(Self.hideOtherTempSchemas)
      ORDER BY n.nspname, c.relname, t.tgname
      """
    var triggers: [DatabaseTrigger] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 6,
        let schema = CatalogValue.string(row[0]),
        let table = CatalogValue.string(row[1]),
        let name = CatalogValue.string(row[2]),
        let type = CatalogValue.int(row[3]),
        let enabled = CatalogValue.string(row[4])
      else { continue }
      triggers.append(
        DatabaseTrigger(
          schema: schema, table: table, name: name, timing: Self.triggerTiming(type),
          events: Self.triggerEvents(type), enabled: enabled != "D",
          oid: CatalogValue.oid(row[5])))
    }
    return triggers
  }

  /// `pg_get_functiondef` for functions and procedures, `pg_get_triggerdef` for triggers.
  /// Aggregates and window functions have no definition, so they get a comment stub. Sequences
  /// and user types are rendered from their loaded catalog rows, without a query.
  func definition(
    of object: SchemaObjectRef, in session: any DatabaseSession
  ) async throws
    -> String?
  {
    switch object {
    case .function(let function):
      guard let oid = function.oid else { return nil }
      return try await routineDefinition(oid: oid, in: session)
    case .procedure(let procedure):
      guard let oid = procedure.oid else { return nil }
      return try await routineDefinition(oid: oid, in: session)
    case .trigger(let trigger):
      guard let oid = trigger.oid else { return nil }
      let found = try await rows(
        in: session, sql: "SELECT pg_get_triggerdef($1::oid, true)", binds: [.text(String(oid))])
      return found.first?.first.flatMap(CatalogValue.string)
    case .sequence(let sequence):
      return try Self.ddl(sequence)
    case .userType(let type):
      return try Self.ddl(type)
    }
  }

  private func routineDefinition(
    oid: UInt32, in session: any DatabaseSession
  ) async throws -> String? {
    // pg_get_functiondef raises on an aggregate, so the CASE keeps it to 'f' and 'p'.
    let query = """
      SELECT
        CASE WHEN p.prokind IN ('f', 'p') THEN pg_get_functiondef(p.oid) END,
        p.prokind::text,
        p.proname::text,
        pg_get_function_arguments(p.oid)
      FROM pg_proc p
      WHERE p.oid = $1::oid
      """
    guard let row = try await rows(in: session, sql: query, binds: [.text(String(oid))]).first,
      row.count >= 4
    else { return nil }
    if let source = CatalogValue.string(row[0]) { return source }
    let kind = CatalogValue.string(row[1]) == "a" ? "aggregate" : "window function"
    let name = CatalogValue.string(row[2]) ?? ""
    let arguments = CatalogValue.string(row[3]) ?? ""
    return "-- Source not available for \(kind) \(name)(\(arguments))"
  }

  // pg_trigger.tgtype bits: ROW 1, BEFORE 2, INSERT 4, DELETE 8, UPDATE 16, TRUNCATE 32,
  // INSTEAD 64.
  private static func triggerTiming(_ type: Int) -> DatabaseTrigger.Timing {
    if type & 64 != 0 { return .insteadOf }
    return type & 2 != 0 ? .before : .after
  }

  private static func triggerEvents(_ type: Int) -> [DatabaseTrigger.Event] {
    let bits: [(Int, DatabaseTrigger.Event)] = [
      (4, .insert), (16, .update), (8, .delete), (32, .truncate),
    ]
    return bits.filter { type & $0.0 != 0 }.map(\.1)
  }

  func users(in session: any DatabaseSession) async throws -> [DatabaseUser] {
    let query = """
      SELECT
        rolname,
        rolcanlogin,
        rolsuper,
        rolcreatedb,
        rolcreaterole,
        rolconnlimit
      FROM pg_roles
      WHERE rolcanlogin = true
      ORDER BY rolname
      """
    var users: [DatabaseUser] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 6,
        let name = CatalogValue.string(row[0]),
        let canLogin = CatalogValue.bool(row[1]),
        let isSuperuser = CatalogValue.bool(row[2]),
        let canCreateDB = CatalogValue.bool(row[3]),
        let canCreateRole = CatalogValue.bool(row[4])
      else { continue }
      users.append(
        DatabaseUser(
          name: name, canLogin: canLogin, isSuperuser: isSuperuser, canCreateDB: canCreateDB,
          canCreateRole: canCreateRole, connectionLimit: CatalogValue.int(row[5])))
    }
    return users
  }

  func roles(in session: any DatabaseSession) async throws -> [DatabaseRole] {
    let query = """
      SELECT
        r.rolname,
        r.rolcanlogin,
        r.rolsuper,
        r.rolcreatedb,
        r.rolcreaterole,
        ARRAY(
          SELECT m.rolname
          FROM pg_auth_members am
          JOIN pg_roles m ON am.member = m.oid
          WHERE am.roleid = r.oid
        ) AS members
      FROM pg_roles r
      WHERE r.rolcanlogin = false
      ORDER BY r.rolname
      """
    var roles: [DatabaseRole] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 6,
        let name = CatalogValue.string(row[0]),
        let canLogin = CatalogValue.bool(row[1]),
        let isSuperuser = CatalogValue.bool(row[2]),
        let canCreateDB = CatalogValue.bool(row[3]),
        let canCreateRole = CatalogValue.bool(row[4])
      else { continue }
      roles.append(
        DatabaseRole(
          name: name, canLogin: canLogin, isSuperuser: isSuperuser, canCreateDB: canCreateDB,
          canCreateRole: canCreateRole, members: CatalogValue.stringList(row[5])))
    }
    return roles
  }

  /// User schemas: not a system schema, not another session's temporary schema
  private static let userSchemaFilter = """
    n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%'
      AND \(hideOtherTempSchemas)
    """

  /// Sequences of the user schemas, not owned by an extension. The owning column comes from the
  /// sequence's auto ('a', serial and `OWNED BY`) or internal ('i', identity) dependency.
  func sequences(in session: any DatabaseSession) async throws -> [DatabaseSequence] {
    let query = """
      SELECT n.nspname::text, c.relname::text, format_type(s.seqtypid, NULL), s.seqstart,
        s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle, tn.nspname::text,
        tc.relname::text, a.attname::text, d.deptype::text, c.oid::int8
      FROM pg_sequence s
      JOIN pg_class c ON c.oid = s.seqrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = s.seqrelid
        AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
      LEFT JOIN pg_class tc ON tc.oid = d.refobjid
      LEFT JOIN pg_namespace tn ON tn.oid = tc.relnamespace
      LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
      WHERE c.relkind = 'S' AND \(Self.userSchemaFilter)
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend e
          WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid AND e.deptype = 'e')
      ORDER BY n.nspname, c.relname
      """
    var sequences: [DatabaseSequence] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 14,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]),
        let dataType = CatalogValue.string(row[2]),
        let start = CatalogValue.int(row[3]),
        let increment = CatalogValue.int(row[4]),
        let minValue = CatalogValue.int(row[5]),
        let maxValue = CatalogValue.int(row[6]),
        let cache = CatalogValue.int(row[7])
      else { continue }
      var owner: DatabaseSequence.Owner?
      if let ownerSchema = CatalogValue.string(row[9]), let table = CatalogValue.string(row[10]),
        let column = CatalogValue.string(row[11])
      {
        owner = DatabaseSequence.Owner(schema: ownerSchema, table: table, column: column)
      }
      sequences.append(
        DatabaseSequence(
          schema: schema, name: name, dataType: dataType, start: start, increment: increment,
          minValue: minValue, maxValue: maxValue, cache: cache,
          cycle: CatalogValue.bool(row[8]) ?? false, ownedBy: owner,
          isIdentity: CatalogValue.string(row[12]) == "i", oid: CatalogValue.oid(row[13])))
    }
    return sequences
  }

  /// Enums (labels by `enumsortorder`), domains (base type, default, NOT NULL, CHECK
  /// constraints) and standalone composite types (`typrelid` of relkind 'c'; a table's row type
  /// is left out) of the user schemas, not owned by an extension. One query: the kind is
  /// `typtype` and each kind's details travel as JSON text.
  func userTypes(in session: any DatabaseSession) async throws -> [DatabaseUserType] {
    let query = """
      SELECT n.nspname::text, t.typname::text, t.typtype::text,
        (SELECT COALESCE(json_agg(e.enumlabel::text ORDER BY e.enumsortorder), '[]')::text
          FROM pg_enum e WHERE e.enumtypid = t.oid),
        CASE WHEN t.typtype = 'd' THEN format_type(t.typbasetype, t.typtypmod) END,
        pg_get_expr(t.typdefaultbin, 0), t.typnotnull,
        (SELECT COALESCE(json_agg(json_build_array(dc.conname::text, pg_get_constraintdef(dc.oid))
            ORDER BY dc.conname), '[]')::text
          FROM pg_constraint dc WHERE dc.contypid = t.oid AND dc.contype = 'c'),
        (SELECT COALESCE(json_agg(json_build_array(a.attname::text,
            format_type(a.atttypid, a.atttypmod)) ORDER BY a.attnum), '[]')::text
          FROM pg_attribute a
          WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped),
        t.oid::int8
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      LEFT JOIN pg_class rc ON rc.oid = t.typrelid
      WHERE (t.typtype IN ('e', 'd') OR (t.typtype = 'c' AND rc.relkind = 'c'))
        AND \(Self.userSchemaFilter)
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend x
          WHERE x.classid = 'pg_type'::regclass AND x.objid = t.oid AND x.deptype = 'e')
      ORDER BY n.nspname, t.typname
      """
    var types: [DatabaseUserType] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 10,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1])
      else { continue }
      let kind: DatabaseUserType.Kind
      switch CatalogValue.string(row[2]) {
      case "e":
        kind = .enum(CatalogValue.stringList(row[3]))
      case "d":
        kind = .domain(
          baseType: CatalogValue.string(row[4]) ?? "",
          notNull: CatalogValue.bool(row[6]) ?? false,
          defaultExpression: CatalogValue.string(row[5]),
          constraints: CatalogValue.stringPairs(row[7]).map {
            DatabaseUserType.Constraint(name: $0.0, definition: $0.1)
          })
      case "c":
        kind = .composite(
          CatalogValue.stringPairs(row[8]).map {
            DatabaseUserType.Attribute(name: $0.0, type: $0.1)
          })
      default:
        continue
      }
      types.append(
        DatabaseUserType(schema: schema, name: name, kind: kind, oid: CatalogValue.oid(row[9])))
    }
    return types
  }

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
    // Column lists are text, not name[]. Binary name[] decodes as bytes, so the names
    // would not match a result column and the referenced-row menu would never appear.
    // conparentid = 0 drops the per-partition copies of a key (PG11+, like prokind above).
    let query = """
      SELECT
        c.conname AS constraint_name,
        ns.nspname AS source_schema,
        cl.relname AS source_table,
        nst.nspname AS target_schema,
        clt.relname AS target_table,
        c.confupdtype AS on_update,
        c.confdeltype AS on_delete,
        (
          SELECT array_agg(a.attname::text ORDER BY x.n)::text
          FROM pg_attribute a
          CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid = c.conrelid AND a.attnum = x.attnum
        ) AS source_columns,
        (
          SELECT array_agg(a.attname::text ORDER BY x.n)::text
          FROM pg_attribute a
          CROSS JOIN LATERAL unnest(c.confkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid = c.confrelid AND a.attnum = x.attnum
        ) AS target_columns
      FROM pg_constraint c
      JOIN pg_class cl ON c.conrelid = cl.oid
      JOIN pg_namespace ns ON cl.relnamespace = ns.oid
      JOIN pg_class clt ON c.confrelid = clt.oid
      JOIN pg_namespace nst ON clt.relnamespace = nst.oid
      WHERE c.contype = 'f'
        AND c.conparentid = 0
        AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      ORDER BY ns.nspname, cl.relname, c.conname
      """
    var foreignKeys: [ForeignKey] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 9,
        let constraintName = CatalogValue.string(row[0]),
        let sourceSchema = CatalogValue.string(row[1]),
        let sourceTable = CatalogValue.string(row[2]),
        let targetSchema = CatalogValue.string(row[3]),
        let targetTable = CatalogValue.string(row[4])
      else { continue }
      let sourceColumns = CatalogValue.stringList(row[7])
      let targetColumns = CatalogValue.stringList(row[8])
      guard !sourceColumns.isEmpty, !targetColumns.isEmpty else { continue }
      foreignKeys.append(
        ForeignKey(
          constraintName: constraintName,
          sourceSchema: sourceSchema,
          sourceTable: sourceTable,
          sourceColumns: sourceColumns,
          targetSchema: targetSchema,
          targetTable: targetTable,
          targetColumns: targetColumns,
          onUpdate: ForeignKeyAction(pgCode: CatalogValue.string(row[5]) ?? "a"),
          onDelete: ForeignKeyAction(pgCode: CatalogValue.string(row[6]) ?? "a")))
    }
    return foreignKeys
  }

  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable? {
    // attgenerated is PostgreSQL 12+. Read it through to_jsonb so older servers see no key.
    let query = """
      SELECT c.oid::int8, a.attnum::int4, a.attname::text,
             COALESCE((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(att, ord)
                       WHERE k.att = a.attnum), 0)::int4,
             format('%I.%I', n.nspname, c.relname), c.relkind::text, c.relhassubclass,
             n.nspname::text, c.relname::text,
             COALESCE(to_jsonb(a) ->> 'attgenerated', '') <> ''
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
      WHERE c.oid = to_regclass($1)
      """
    var oid: UInt32 = 0
    var qualifiedName = ""
    var names: [Int16: String] = [:]
    var keyPositions: [(position: Int, name: String)] = []
    var relationKind = ""
    var hasSubclass = true
    var catalogSchema: String?
    var catalogName: String?
    var generated: Set<String> = []
    for row in try await rows(in: session, sql: query, binds: [.text(name)]) {
      guard row.count >= 10 else { throw CatalogRowError() }
      guard let tableOID = CatalogValue.int(row[0]),
        let attnum = CatalogValue.int(row[1]),
        let columnName = CatalogValue.string(row[2]),
        let keyPosition = CatalogValue.int(row[3]),
        let qualified = CatalogValue.string(row[4]),
        let kind = CatalogValue.string(row[5]),
        let subclass = CatalogValue.bool(row[6]),
        let schemaName = CatalogValue.string(row[7]),
        let relationName = CatalogValue.string(row[8]),
        let isGenerated = CatalogValue.bool(row[9])
      else { throw CatalogRowError() }
      guard let number = Int16(exactly: attnum), let tableID = UInt32(exactly: tableOID) else {
        continue
      }
      oid = tableID
      qualifiedName = qualified
      relationKind = kind
      hasSubclass = subclass
      catalogSchema = schemaName
      catalogName = relationName
      names[number] = columnName
      if isGenerated { generated.insert(columnName) }
      if keyPosition > 0 { keyPositions.append((keyPosition, columnName)) }
    }
    guard oid != 0, relationKind == "p" || (relationKind == "r" && !hasSubclass) else {
      return nil
    }
    let primaryKey = keyPositions.sorted { $0.position < $1.position }.map(\.name)
    return EditTable(
      oid: oid, attributeNames: names, primaryKeyColumns: primaryKey, qualifiedName: qualifiedName,
      updateOnly: relationKind == "r", schema: catalogSchema, name: catalogName,
      generatedColumns: generated)
  }

  func enrichColumnTypes(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async -> [ColumnInfo] {
    do {
      return try await enrichedColumns(columns, query: query, in: session)
    } catch {
      await AppLogger.shared.warning(
        "Failed to enrich column types: \(error)", category: "Database")
      return columns
    }
  }

  /// Column modifiers from `information_schema`, read for each column's own table: the table
  /// OID and attribute number from the row description are bound, never a name. A column with
  /// no table origin keeps its type. Throws when the catalog query fails so the actor can map a
  /// closed session; returns `columns` when the statement is not one table.
  func enrichedColumns(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async throws -> [ColumnInfo] {
    guard !columns.isEmpty, DatabaseConnectionManager.singleTableName(in: query) != nil
    else { return columns }

    var attributeNumbers: [UInt32: Set<Int>] = [:]
    for origin in columns.compactMap(\.tableOrigin) {
      guard let oid = origin.tableID.postgresOID else { continue }
      attributeNumbers[oid, default: []].insert(origin.columnOrdinal)
    }
    var typeMap: [ColumnOrigin: String] = [:]
    for (oid, numbers) in attributeNumbers.sorted(by: { $0.key < $1.key }) {
      let list = numbers.sorted().map(String.init).joined(separator: ",")
      let binds: [SQLBindValue] = [.text(String(oid)), .text("{\(list)}")]
      for row in try await rows(in: session, sql: Self.columnTypeSQL, binds: binds) {
        guard row.count >= 8,
          let ordinal = CatalogValue.int(row[0]),
          let dataType = CatalogValue.string(row[1])
        else { continue }
        let origin = ColumnOrigin(tableID: .postgresql(oid: oid), columnOrdinal: ordinal)
        typeMap[origin] = Self.detailedType(dataType: dataType, row: row)
      }
    }
    return columns.map { column in
      guard let origin = column.tableOrigin, let enrichedType = typeMap[origin] else {
        return column
      }
      return ColumnInfo(name: column.name, type: enrichedType, origin: column.origin)
    }
  }

  /// One table's columns by OID (`$1`) and attribute numbers (`$2`, an int4 array literal).
  /// `ordinal_position` is the attnum; the table's names are joined in the catalog, never sent.
  private static let columnTypeSQL = """
    SELECT c.ordinal_position::int4, c.data_type,
           c.character_maximum_length,
           c.numeric_precision,
           c.numeric_scale,
           c.datetime_precision,
           c.interval_type,
           c.udt_name
    FROM pg_class r
    JOIN pg_namespace n ON n.oid = r.relnamespace
    JOIN information_schema.columns c
      ON c.table_schema = n.nspname AND c.table_name = r.relname
    WHERE r.oid = $1::oid
      AND c.ordinal_position = ANY($2::int4[])
    """

  /// Exact row count. The actor turns a query failure into 0.
  func rowCount(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws
    -> Int
  {
    let query = """
      SELECT COUNT(*) as row_count
      FROM "\(schema)".\"\(table)\"
      """
    for row in try await rows(in: session, sql: query) {
      if let count = row.first.flatMap(CatalogValue.int) { return count }
    }
    return 0
  }

  /// Primary key column names in key order. `tableName` is bound and resolved with `to_regclass`.
  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws
    -> [String]
  {
    let query = """
      SELECT a.attname::text AS column_name
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
      WHERE i.indrelid = to_regclass($1)
        AND i.indisprimary
      ORDER BY array_position(i.indkey, a.attnum)
      """
    var columns: [String] = []
    for row in try await rows(in: session, sql: query, binds: [.text(tableName)]) {
      if let name = row.first.flatMap(CatalogValue.string) { columns.append(name) }
    }
    return columns
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

  /// Same type string the actor built from `information_schema` cells.
  private static func detailedType(dataType: String, row: [CellValue]) -> String {
    var detailedType = dataType.uppercased()
    if detailedType == "USER-DEFINED", let udtName = CatalogValue.string(row[7]) {
      detailedType = udtName.uppercased()
    }
    if let maxLength = CatalogValue.int(row[2]) {
      detailedType += "(\(maxLength))"
    } else if let precision = CatalogValue.int(row[3]) {
      if let scale = CatalogValue.int(row[4]) {
        detailedType += "(\(precision),\(scale))"
      } else {
        detailedType += "(\(precision))"
      }
    } else if let datetimePrecision = CatalogValue.int(row[5]),
      dataType.uppercased().contains("TIMESTAMP")
    {
      if dataType.uppercased().contains("WITH TIME ZONE") {
        detailedType = "TIMESTAMP(\(datetimePrecision)) W TZ"
      } else {
        detailedType = "TIMESTAMP(\(datetimePrecision)) W/O TZ"
      }
    }
    return detailedType
  }
}

/// A catalog row that could not be read as the types the SQL casts promise.
private nonisolated struct CatalogRowError: Error {}

/// Cell values from a catalog query. `name[]` stays on the normal cell decoder.
nonisolated enum CatalogValue {
  static func string(_ value: CellValue) -> String? {
    // `name` values that look like JSON are stored as `.json` by parseCellValue. The text is
    // still the original identifier.
    switch value {
    case .string(let text), .json(let text):
      return text
    default:
      return nil
    }
  }

  static func bool(_ value: CellValue) -> Bool? {
    if case .bool(let flag) = value { return flag }
    return nil
  }

  static func int(_ value: CellValue) -> Int? {
    if case .int(let number) = value { return number }
    return nil
  }

  /// An `oid::int8` cell.
  static func oid(_ value: CellValue) -> UInt32? {
    int(value).flatMap { UInt32(exactly: $0) }
  }

  /// NULL and a failed decode are both "no estimate", matching `decode(Int?.self)`.
  static func optionalInt(_ value: CellValue) -> Int? {
    int(value)
  }

  static func stringList(_ value: CellValue) -> [String] {
    switch value {
    case .json(let text), .string(let text):
      if text.first == "[",
        let data = text.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String].self, from: data)
      {
        return decoded
      }
      return parsePostgresArray(text)
    case .null:
      return []
    default:
      return []
    }
  }

  /// `[["a", "b"], ...]` JSON text (`json_agg(json_build_array(a, b))`) as pairs
  static func stringPairs(_ value: CellValue) -> [(String, String)] {
    guard let text = string(value), let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([[String]].self, from: data)
    else { return [] }
    return decoded.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
  }

  /// Parse PostgreSQL array string format: {val1,val2,val3}
  private static func parsePostgresArray(_ arrayString: String) -> [String] {
    var str = arrayString.trimmingCharacters(in: .whitespaces)
    if str.hasPrefix("{") { str.removeFirst() }
    if str.hasSuffix("}") { str.removeLast() }
    if str.isEmpty { return [] }

    var result: [String] = []
    var current = ""
    var inQuotes = false
    for char in str {
      if char == "\"" {
        inQuotes.toggle()
      } else if char == "," && !inQuotes {
        result.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty {
      result.append(current.trimmingCharacters(in: .whitespaces))
    }
    return result
  }
}
