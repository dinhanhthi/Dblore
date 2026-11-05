// PostgresSchemaIntrospector.swift
// PostgreSQL catalog reads for one open session. SQL matches the queries the connection
// actor used to send. The actor keeps the metadata pause and the catalog query counter.

import Foundation

/// `pg_catalog` reads through `DatabaseSession.query`.
///
/// They run on the user's session with the user's `search_path`, where PostgreSQL resolves an
/// unqualified function or operator over every schema on the path (an exact-type match there
/// beats a `pg_catalog` one that needs a cast). So every relation, function, operator, cast type
/// and regclass literal names `pg_catalog`, and the forms that look `=` / `<>` up by name
/// (`NULLIF`, `IN`, `NOT IN`, `LIKE`) are written with `OPERATOR(pg_catalog.…)`. An
/// `OPERATOR(…)` has the precedence of "any other operator" (above comparison, `IS`, `NOT`,
/// `AND`, `OR`), so mixed expressions keep explicit parentheses. `search_path` is never pinned.
nonisolated struct PostgresSchemaIntrospector: SchemaIntrospector {
  /// Relation-level visibility, equivalent to what information_schema applies to tables and views
  private static let relationPrivilegeFilter = """
    (pg_catalog.pg_has_role(c.relowner, 'USAGE')
      OR pg_catalog.has_table_privilege(c.oid,
        'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
      OR pg_catalog.has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
    """

  /// information_schema hides other sessions' temporary tables (unreadable for this session)
  private static let hideOtherTempSchemas = "NOT pg_catalog.pg_is_other_temp_schema(n.oid)"

  /// Column-level visibility, as information_schema.columns applies it: a column is listed only
  /// with a privilege on that column (or ownership through a role), not on any other column
  private static let columnPrivilegeFilter = """
    (pg_catalog.pg_has_role(c.relowner, 'USAGE')
      OR pg_catalog.has_column_privilege(c.oid, a.attnum, 'SELECT, INSERT, UPDATE, REFERENCES'))
    """

  /// `n.nspname NOT IN ('pg_catalog', 'information_schema')`, typed `name` as the literals were
  private static let notSystemSchema = """
    n.nspname OPERATOR(pg_catalog.<>) ALL \
    (ARRAY['pg_catalog', 'information_schema']::pg_catalog.name[])
    """

  /// `notSystemSchema` plus `pg_toast`
  private static func notSystemOrToastSchema(_ alias: String) -> String {
    """
    \(alias).nspname OPERATOR(pg_catalog.<>) ALL \
    (ARRAY['pg_catalog', 'information_schema', 'pg_toast']::pg_catalog.name[])
    """
  }

  /// The session's own temp tables (pg_temp_N) are flagged; `pg_my_temp_schema()` is 0 until
  /// the session creates one. A partition (`relispartition`: its `pg_inherits` parent is a
  /// partitioned table, relkind 'p', which needs no PostgreSQL 10 column) names its parent.
  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    // Never analyzed (reltuples -1 on PG 14+, 0/0 before): fall back to the stats counter,
    // 0 there stays unknown (empty table, track_counts off or stats reset)
    let query = """
      SELECT
        n.nspname::pg_catalog.text,
        c.relname::pg_catalog.text,
        CASE WHEN c.reltuples OPERATOR(pg_catalog.<) 0
            OR (c.reltuples OPERATOR(pg_catalog.=) 0 AND c.relpages OPERATOR(pg_catalog.=) 0)
          THEN CASE WHEN pg_catalog.pg_stat_get_live_tuples(c.oid) OPERATOR(pg_catalog.=) 0
            THEN NULL ELSE pg_catalog.pg_stat_get_live_tuples(c.oid) END
          ELSE c.reltuples::pg_catalog.int8 END AS row_estimate,
        n.oid OPERATOR(pg_catalog.=) pg_catalog.pg_my_temp_schema() AS is_temporary,
        pn.nspname::pg_catalog.text AS parent_schema,
        pc.relname::pg_catalog.text AS parent_name
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
      LEFT JOIN (pg_catalog.pg_inherits i
          JOIN pg_catalog.pg_class pc ON pc.oid OPERATOR(pg_catalog.=) i.inhparent
            AND pc.relkind OPERATOR(pg_catalog.=) 'p'::pg_catalog."char"
          JOIN pg_catalog.pg_namespace pn ON pn.oid OPERATOR(pg_catalog.=) pc.relnamespace)
        ON i.inhrelid OPERATOR(pg_catalog.=) c.oid
      WHERE c.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'p']::pg_catalog."char"[])
        AND \(Self.notSystemOrToastSchema("n"))
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
          isTemporary: CatalogValue.bool(row[3]) ?? false, parent: Self.parent(of: row)))
    }
    return tables
  }

  /// The parent columns (4, 5) of a table listing row, nil when not a partition
  private static func parent(of row: [CellValue]) -> (schema: String, name: String)? {
    guard row.count >= 6, let schema = CatalogValue.string(row[4]),
      let name = CatalogValue.string(row[5])
    else { return nil }
    return (schema, name)
  }

  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    let query = """
      SELECT
        n.nspname::pg_catalog.text,
        c.relname::pg_catalog.text,
        a.attname::pg_catalog.text,
        pg_catalog.format_type(a.atttypid, a.atttypmod),
        a.attnotnull,
        (a.attidentity OPERATOR(pg_catalog.<>) '') AS is_identity,
        EXISTS (
          SELECT 1 FROM pg_catalog.pg_index i
          WHERE i.indrelid OPERATOR(pg_catalog.=) c.oid AND i.indisprimary
            AND a.attnum OPERATOR(pg_catalog.=) ANY (i.indkey)
        ) AS is_pk,
        EXISTS (
          SELECT 1 FROM pg_catalog.pg_index i
          WHERE i.indrelid OPERATOR(pg_catalog.=) c.oid AND i.indisunique AND NOT i.indisprimary
            AND pg_catalog.array_length(i.indkey, 1) OPERATOR(pg_catalog.=) 1
            AND a.attnum OPERATOR(pg_catalog.=) ANY (i.indkey)
        ) AS is_unique
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) a.attrelid
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
      WHERE c.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'p', 'v']::pg_catalog."char"[])
        AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
        AND \(Self.notSystemOrToastSchema("n"))
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
      SELECT n.nspname::pg_catalog.text, c.relname::pg_catalog.text
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
      WHERE c.relkind OPERATOR(pg_catalog.=) 'v'
        AND \(Self.notSystemSchema)
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
        pg_catalog.pg_get_function_result(p.oid) AS return_type,
        pg_catalog.pg_get_function_arguments(p.oid) AS arguments,
        p.oid::pg_catalog.int8
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON p.pronamespace OPERATOR(pg_catalog.=) n.oid
      WHERE \(Self.notSystemSchema)
        AND p.prokind OPERATOR(pg_catalog.=) 'f'
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
        pg_catalog.pg_get_function_arguments(p.oid) AS arguments,
        p.oid::pg_catalog.int8
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON p.pronamespace OPERATOR(pg_catalog.=) n.oid
      WHERE \(Self.notSystemSchema)
        AND p.prokind OPERATOR(pg_catalog.=) 'p'
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
        n.nspname::pg_catalog.text,
        c.relname::pg_catalog.text,
        t.tgname::pg_catalog.text,
        t.tgtype::pg_catalog.int4,
        t.tgenabled::pg_catalog.text,
        t.oid::pg_catalog.int8
      FROM pg_catalog.pg_trigger t
      JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) t.tgrelid
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
      WHERE NOT t.tgisinternal
        AND \(Self.notSystemSchema)
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
        in: session, sql: "SELECT pg_catalog.pg_get_triggerdef($1::pg_catalog.oid, true)",
        binds: [.text(String(oid))])
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
        CASE WHEN p.prokind OPERATOR(pg_catalog.=) ANY (ARRAY['f', 'p']::pg_catalog."char"[])
          THEN pg_catalog.pg_get_functiondef(p.oid) END,
        p.prokind::pg_catalog.text,
        p.proname::pg_catalog.text,
        pg_catalog.pg_get_function_arguments(p.oid)
      FROM pg_catalog.pg_proc p
      WHERE p.oid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
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
      FROM pg_catalog.pg_roles
      WHERE rolcanlogin
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
          FROM pg_catalog.pg_auth_members am
          JOIN pg_catalog.pg_roles m ON am.member OPERATOR(pg_catalog.=) m.oid
          WHERE am.roleid OPERATOR(pg_catalog.=) r.oid
        ) AS members
      FROM pg_catalog.pg_roles r
      WHERE NOT r.rolcanlogin
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
    \(notSystemSchema) AND n.nspname OPERATOR(pg_catalog.!~~) 'pg\\_toast%'
      AND \(hideOtherTempSchemas)
    """

  /// Sequences of the user schemas, not owned by an extension. The owning column comes from the
  /// sequence's auto ('a', serial and `OWNED BY`) or internal ('i', identity) dependency.
  func sequences(in session: any DatabaseSession) async throws -> [DatabaseSequence] {
    let query = """
      SELECT n.nspname::pg_catalog.text, c.relname::pg_catalog.text,
        pg_catalog.format_type(s.seqtypid, NULL), s.seqstart, s.seqincrement, s.seqmin, s.seqmax,
        s.seqcache, s.seqcycle, tn.nspname::pg_catalog.text, tc.relname::pg_catalog.text,
        a.attname::pg_catalog.text, d.deptype::pg_catalog.text, c.oid::pg_catalog.int8
      FROM pg_catalog.pg_sequence s
      JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) s.seqrelid
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
      LEFT JOIN pg_catalog.pg_depend d
        ON d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
        AND d.objid OPERATOR(pg_catalog.=) s.seqrelid
        AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
        AND d.deptype OPERATOR(pg_catalog.=) ANY (ARRAY['a', 'i']::pg_catalog."char"[])
      LEFT JOIN pg_catalog.pg_class tc ON tc.oid OPERATOR(pg_catalog.=) d.refobjid
      LEFT JOIN pg_catalog.pg_namespace tn ON tn.oid OPERATOR(pg_catalog.=) tc.relnamespace
      LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) d.refobjid
        AND a.attnum OPERATOR(pg_catalog.=) d.refobjsubid
      WHERE c.relkind OPERATOR(pg_catalog.=) 'S' AND \(Self.userSchemaFilter)
        AND NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_depend e
          WHERE e.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
            AND e.objid OPERATOR(pg_catalog.=) c.oid AND e.deptype OPERATOR(pg_catalog.=) 'e')
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
      SELECT n.nspname::pg_catalog.text, t.typname::pg_catalog.text, t.typtype::pg_catalog.text,
        (SELECT COALESCE(pg_catalog.json_agg(e.enumlabel::pg_catalog.text
            ORDER BY e.enumsortorder), '[]')::pg_catalog.text
          FROM pg_catalog.pg_enum e WHERE e.enumtypid OPERATOR(pg_catalog.=) t.oid),
        CASE WHEN t.typtype OPERATOR(pg_catalog.=) 'd'
          THEN pg_catalog.format_type(t.typbasetype, t.typtypmod) END,
        pg_catalog.pg_get_expr(t.typdefaultbin, 0), t.typnotnull,
        (SELECT COALESCE(pg_catalog.json_agg(pg_catalog.json_build_array(
            dc.conname::pg_catalog.text, pg_catalog.pg_get_constraintdef(dc.oid))
            ORDER BY dc.conname), '[]')::pg_catalog.text
          FROM pg_catalog.pg_constraint dc
          WHERE dc.contypid OPERATOR(pg_catalog.=) t.oid AND dc.contype OPERATOR(pg_catalog.=) 'c'),
        (SELECT COALESCE(pg_catalog.json_agg(pg_catalog.json_build_array(
            a.attname::pg_catalog.text, pg_catalog.format_type(a.atttypid, a.atttypmod))
            ORDER BY a.attnum), '[]')::pg_catalog.text
          FROM pg_catalog.pg_attribute a
          WHERE a.attrelid OPERATOR(pg_catalog.=) t.typrelid AND a.attnum OPERATOR(pg_catalog.>) 0
            AND NOT a.attisdropped),
        t.oid::pg_catalog.int8
      FROM pg_catalog.pg_type t
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
      LEFT JOIN pg_catalog.pg_class rc ON rc.oid OPERATOR(pg_catalog.=) t.typrelid
      WHERE (t.typtype OPERATOR(pg_catalog.=) ANY (ARRAY['e', 'd']::pg_catalog."char"[])
          OR (t.typtype OPERATOR(pg_catalog.=) 'c' AND rc.relkind OPERATOR(pg_catalog.=) 'c'))
        AND \(Self.userSchemaFilter)
        AND NOT EXISTS (
          SELECT 1 FROM pg_catalog.pg_depend x
          WHERE x.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_type'::pg_catalog.regclass
            AND x.objid OPERATOR(pg_catalog.=) t.oid AND x.deptype OPERATOR(pg_catalog.=) 'e')
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
          SELECT pg_catalog.array_agg(a.attname::pg_catalog.text ORDER BY x.n)::pg_catalog.text
          FROM pg_catalog.pg_attribute a
          CROSS JOIN LATERAL pg_catalog.unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid OPERATOR(pg_catalog.=) c.conrelid
            AND a.attnum OPERATOR(pg_catalog.=) x.attnum
        ) AS source_columns,
        (
          SELECT pg_catalog.array_agg(a.attname::pg_catalog.text ORDER BY x.n)::pg_catalog.text
          FROM pg_catalog.pg_attribute a
          CROSS JOIN LATERAL pg_catalog.unnest(c.confkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid OPERATOR(pg_catalog.=) c.confrelid
            AND a.attnum OPERATOR(pg_catalog.=) x.attnum
        ) AS target_columns
      FROM pg_catalog.pg_constraint c
      JOIN pg_catalog.pg_class cl ON c.conrelid OPERATOR(pg_catalog.=) cl.oid
      JOIN pg_catalog.pg_namespace ns ON cl.relnamespace OPERATOR(pg_catalog.=) ns.oid
      JOIN pg_catalog.pg_class clt ON c.confrelid OPERATOR(pg_catalog.=) clt.oid
      JOIN pg_catalog.pg_namespace nst ON clt.relnamespace OPERATOR(pg_catalog.=) nst.oid
      WHERE c.contype OPERATOR(pg_catalog.=) 'f'
        AND c.conparentid OPERATOR(pg_catalog.=) 0
        AND \(Self.notSystemOrToastSchema("ns"))
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
    // `$1` is the table name from the user's query: `to_regclass` resolves it through the
    // session's search_path on purpose, as the user's own statement resolves it (the carve-out
    // to the pg_catalog rule above).
    let query = """
      SELECT c.oid::pg_catalog.int8, a.attnum::pg_catalog.int4, a.attname::pg_catalog.text,
             COALESCE((SELECT k.ord
                       FROM pg_catalog.unnest(i.indkey::pg_catalog.int2[])
                         WITH ORDINALITY k(att, ord)
                       WHERE k.att OPERATOR(pg_catalog.=) a.attnum), 0)::pg_catalog.int4,
             pg_catalog.format('%I.%I', n.nspname, c.relname), c.relkind::pg_catalog.text,
             c.relhassubclass, n.nspname::pg_catalog.text, c.relname::pg_catalog.text,
             COALESCE(pg_catalog.to_jsonb(a) OPERATOR(pg_catalog.->>) 'attgenerated', '')
               OPERATOR(pg_catalog.<>) ''
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
      JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) c.oid
        AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
      LEFT JOIN pg_catalog.pg_index i ON i.indrelid OPERATOR(pg_catalog.=) c.oid
        AND i.indisprimary
      WHERE c.oid OPERATOR(pg_catalog.=) pg_catalog.to_regclass($1)
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
    // No primary key: rows are named by tableoid + ctid + xmin. A partitioned table is never
    // `UPDATE ONLY` (its rows live in the partitions); tableoid names the partition.
    return EditTable(
      oid: oid, attributeNames: names, primaryKeyColumns: primaryKey, qualifiedName: qualifiedName,
      updateOnly: relationKind == "r", schema: catalogSchema, name: catalogName,
      generatedColumns: generated, rowLocator: primaryKey.isEmpty ? .pgLocator : nil)
  }

  /// One row per column of the view `$1` names (resolved through `to_regclass` like the user's
  /// query, as in `editTable`), with the view-level facts repeated: oid, `%I.%I` name, schema,
  /// name, `pg_relation_is_updatable` bits, no INSTEAD OF trigger, no rule besides `_RETURN`,
  /// the number of relations its `_RETURN` rule reads, and when it is one: its oid, relkind,
  /// `relhassubclass` and primary key attnums; then the column's attnum, name and
  /// `pg_column_is_updatable`; then the `_RETURN` rule's `xmin` (it changes on every `CREATE OR
  /// REPLACE VIEW`) and the base table's generated attnums. Both attnum lists are built by
  /// `array_agg`, so their text is a 1-based `{1,2}` (key order from `indkey`'s ordinality):
  /// `indkey::int2[]` itself keeps int2vector's lower bound 0 and prints as `[0:1]={1,2}`.
  private static let viewEditCandidateSQL = """
    SELECT v.oid::pg_catalog.int8, pg_catalog.format('%I.%I', n.nspname, v.relname),
           n.nspname::pg_catalog.text, v.relname::pg_catalog.text,
           pg_catalog.pg_relation_is_updatable(v.oid, false),
           NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger g
                       WHERE g.tgrelid OPERATOR(pg_catalog.=) v.oid
                         AND (g.tgtype OPERATOR(pg_catalog.&) 64) OPERATOR(pg_catalog.<>) 0),
           NOT EXISTS (SELECT 1 FROM pg_catalog.pg_rewrite w
                       WHERE w.ev_class OPERATOR(pg_catalog.=) v.oid
                         AND w.ev_type OPERATOR(pg_catalog.<>) '1'::pg_catalog."char"),
           b.base_count, b.base_oid::pg_catalog.int8, t.relkind::pg_catalog.text,
           t.relhassubclass,
           (SELECT pg_catalog.array_agg(k.att ORDER BY k.ord)
            FROM pg_catalog.unnest(i.indkey::pg_catalog.int2[]) WITH ORDINALITY AS k(att, ord)
           )::pg_catalog.text,
           a.attnum::pg_catalog.int4, a.attname::pg_catalog.text,
           pg_catalog.pg_column_is_updatable(v.oid, a.attnum, false),
           (SELECT x.xmin::pg_catalog.text FROM pg_catalog.pg_rewrite x
            WHERE x.ev_class OPERATOR(pg_catalog.=) v.oid
              AND x.ev_type OPERATOR(pg_catalog.=) '1'::pg_catalog."char"),
           (SELECT pg_catalog.array_agg(ga.attnum ORDER BY ga.attnum)
            FROM pg_catalog.pg_attribute ga
            WHERE ga.attrelid OPERATOR(pg_catalog.=) t.oid
              AND ga.attnum OPERATOR(pg_catalog.>) 0 AND NOT ga.attisdropped
              AND COALESCE(pg_catalog.to_jsonb(ga) OPERATOR(pg_catalog.->>) 'attgenerated', '')
                OPERATOR(pg_catalog.<>) '')::pg_catalog.text
    FROM pg_catalog.pg_class v
    JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) v.relnamespace
    CROSS JOIN LATERAL (
      SELECT pg_catalog.count(DISTINCT d.refobjid)::pg_catalog.int4 AS base_count,
             pg_catalog.min(d.refobjid) AS base_oid
      FROM pg_catalog.pg_rewrite r
      JOIN pg_catalog.pg_depend d
        ON d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_rewrite'::pg_catalog.regclass
        AND d.objid OPERATOR(pg_catalog.=) r.oid
        AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass
        AND d.refobjid OPERATOR(pg_catalog.<>) v.oid
        AND d.deptype OPERATOR(pg_catalog.=) 'n'
      WHERE r.ev_class OPERATOR(pg_catalog.=) v.oid
        AND r.ev_type OPERATOR(pg_catalog.=) '1'::pg_catalog."char"
    ) b
    LEFT JOIN pg_catalog.pg_class t ON b.base_count OPERATOR(pg_catalog.=) 1
      AND t.oid OPERATOR(pg_catalog.=) b.base_oid
    LEFT JOIN pg_catalog.pg_index i ON i.indrelid OPERATOR(pg_catalog.=) t.oid
      AND i.indisprimary
    JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) v.oid
      AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
    WHERE v.oid OPERATOR(pg_catalog.=) pg_catalog.to_regclass($1)
      AND v.relkind OPERATOR(pg_catalog.=) 'v'
    ORDER BY a.attnum
    """

  /// The view `name` names as an edit candidate (`ViewEditCandidate`), from catalog reads only,
  /// or nil when it is not a view or the v1 rule refuses it (the reason goes to the debug log):
  /// - the UPDATE (4) and DELETE (16) bits of `pg_relation_is_updatable(oid, false)`, the test
  ///   information_schema uses (INSERT is not required);
  /// - no INSTEAD OF trigger and no rule besides `_RETURN`: the bits report a simple view as
  ///   auto-updatable even with either;
  /// - its `_RETURN` rule reads exactly one relation, a partitioned table or a plain table
  ///   without inheritance children (no view on a view, no join);
  /// - that table has a primary key (a view never gets a row locator).
  /// Runs on the user's catalog session, so every catalog object names `pg_catalog`.
  func viewEditCandidate(
    named name: String, in session: any DatabaseSession
  ) async throws -> ViewEditCandidate? {
    var header: [CellValue]?
    var columns: [Int16: String] = [:]
    var updatable: Set<String> = []
    for row in try await rows(in: session, sql: Self.viewEditCandidateSQL, binds: [.text(name)]) {
      guard row.count >= 17, let attnum = CatalogValue.int(row[12]).flatMap(Int16.init(exactly:)),
        let columnName = CatalogValue.string(row[13]), let isUpdatable = CatalogValue.bool(row[14])
      else { throw CatalogRowError() }
      header = header ?? row
      columns[attnum] = columnName
      if isUpdatable { updatable.insert(columnName) }
    }
    guard let header else { return nil }
    guard let viewOID = CatalogValue.oid(header[0]),
      let qualifiedName = CatalogValue.string(header[1]),
      let schema = CatalogValue.string(header[2]),
      let viewName = CatalogValue.string(header[3]),
      let bits = CatalogValue.int(header[4]),
      let noInsteadTrigger = CatalogValue.bool(header[5]),
      let noOtherRule = CatalogValue.bool(header[6]),
      let baseCount = CatalogValue.int(header[7]),
      let definitionVersion = CatalogValue.string(header[15])
    else { throw CatalogRowError() }
    let baseOID = CatalogValue.oid(header[8])
    let baseKind = CatalogValue.string(header[9])
    let basePrimaryKey = CatalogValue.attnumList(header[11])
    let generatedBaseColumns = CatalogValue.attnumList(header[16])
    let baseIsTable =
      baseKind == "p" || (baseKind == "r" && CatalogValue.bool(header[10]) == false)
    let refusal: String?
    if bits & 20 != 20 {
      refusal = "pg_relation_is_updatable is \(bits), not UPDATE and DELETE"
    } else if !noInsteadTrigger {
      refusal = "it has an INSTEAD OF trigger"
    } else if !noOtherRule {
      refusal = "it has a rule besides _RETURN"
    } else if baseCount != 1 || baseOID == nil {
      refusal = "it reads \(baseCount) relations"
    } else if !baseIsTable {
      refusal = "its base relation is not a table without inheritance children"
    } else if basePrimaryKey == nil || generatedBaseColumns == nil {
      refusal = "its base table's key or generated columns are not a 1-based attnum list"
    } else if basePrimaryKey?.isEmpty != false {
      refusal = "its base table has no primary key"
    } else {
      refusal = nil
    }
    if let refusal {
      await AppLogger.shared.debug(
        "View \(viewOID) is not editable: \(refusal)", category: "Database")
      return nil
    }
    guard let baseOID, let basePrimaryKey, let generatedBaseColumns else { return nil }
    return ViewEditCandidate(
      viewOID: viewOID, qualifiedName: qualifiedName, schema: schema, name: viewName,
      columns: columns, updatableColumnNames: updatable, baseOID: baseOID,
      basePrimaryKey: basePrimaryKey, generatedBaseColumns: Set(generatedBaseColumns),
      definitionVersion: definitionVersion)
  }

  /// `pg_get_viewdef` of the view `$1` (its OID), read on the side session that runs the view
  /// body's probe, so names in the body render for that session's `search_path`
  static let viewDefinitionSQL = "SELECT pg_catalog.pg_get_viewdef($1::pg_catalog.oid)"

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

  /// Column modifiers as information_schema reports them, read for each column's own table:
  /// the table OID and attribute number from the row description are bound, never a name. A
  /// column with no table origin keeps its type. Throws when the catalog query fails so the
  /// actor can map a closed session; returns `columns` when the statement is not one table.
  func enrichedColumns(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async throws -> [ColumnInfo] {
    guard !columns.isEmpty, DatabaseConnectionManager.enrichesColumnTypes(query)
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
      return ColumnInfo(
        name: column.name, type: enrichedType, origin: column.origin,
        wallClock: column.wallClock, masked: column.masked)
    }
  }

  /// One table's columns by OID (`$1`) and attribute numbers (`$2`, an int4 array literal),
  /// with the table's names joined in the catalog, never sent. The columns are the ones
  /// information_schema.columns gives (ordinal_position = attnum, data_type,
  /// character_maximum_length, numeric_precision, numeric_scale, datetime_precision,
  /// interval_type, udt_name), so `detailedType` builds the same text as before (`INTEGER(32,0)`,
  /// `CHARACTER VARYING(20)`, `TIMESTAMP(6) W/O TZ`), but read from pg_attribute / pg_type: on
  /// PostgreSQL 13 and older that view calls `_pg_*` SQL functions whose body is parsed with
  /// the caller's search_path and unqualified operators. This is the view's own logic: a
  /// domain reads as its base type and the domain's typmod (`_pg_truetypid`, `_pg_truetypmod`);
  /// data_type is `ARRAY`, the pg_catalog type's `format_type(oid, NULL)` or `USER-DEFINED`;
  /// the typmod is decoded as `_pg_char_max_length`, `_pg_numeric_precision`,
  /// `_pg_numeric_scale` and `_pg_datetime_precision` do (type OIDs 1042/1043 char and varchar,
  /// 1560/1562 bit and varbit, 21/23/20 int2/4/8, 1700 numeric, 700/701 float4/8, 1082 date,
  /// 1083/1114/1184/1266 time and timestamp with and without zone, 1186 interval); and the rows
  /// are the ones the view lists (relkind r/v/f/p, column privilege, no other session's temp
  /// schema). interval_type is NULL: `detailedType` never reads it.
  private static let columnTypeSQL = """
    SELECT a.attnum::pg_catalog.int4,
      CASE WHEN u.typelem OPERATOR(pg_catalog.<>) 0::pg_catalog.oid
          AND u.typlen OPERATOR(pg_catalog.=) '-1'::pg_catalog.int2 THEN 'ARRAY'
        WHEN un.nspname OPERATOR(pg_catalog.=) 'pg_catalog'
          THEN pg_catalog.format_type(u.oid, NULL)
        ELSE 'USER-DEFINED' END,
      CASE WHEN m.typmod OPERATOR(pg_catalog.=) '-1'::pg_catalog.int4 THEN NULL
        WHEN u.oid OPERATOR(pg_catalog.=) ANY (ARRAY[1042, 1043]::pg_catalog.oid[])
          THEN m.typmod OPERATOR(pg_catalog.-) 4
        WHEN u.oid OPERATOR(pg_catalog.=) ANY (ARRAY[1560, 1562]::pg_catalog.oid[])
          THEN m.typmod
        END,
      CASE WHEN u.oid OPERATOR(pg_catalog.=) 21::pg_catalog.oid THEN 16
        WHEN u.oid OPERATOR(pg_catalog.=) 23::pg_catalog.oid THEN 32
        WHEN u.oid OPERATOR(pg_catalog.=) 20::pg_catalog.oid THEN 64
        WHEN u.oid OPERATOR(pg_catalog.=) 1700::pg_catalog.oid THEN
          CASE WHEN m.typmod OPERATOR(pg_catalog.=) '-1'::pg_catalog.int4 THEN NULL
            ELSE ((m.typmod OPERATOR(pg_catalog.-) 4) OPERATOR(pg_catalog.>>) 16)
              OPERATOR(pg_catalog.&) 65535
            END
        WHEN u.oid OPERATOR(pg_catalog.=) 700::pg_catalog.oid THEN 24
        WHEN u.oid OPERATOR(pg_catalog.=) 701::pg_catalog.oid THEN 53
        END,
      CASE WHEN u.oid OPERATOR(pg_catalog.=) ANY (ARRAY[21, 23, 20]::pg_catalog.oid[]) THEN 0
        WHEN u.oid OPERATOR(pg_catalog.=) 1700::pg_catalog.oid THEN
          CASE WHEN m.typmod OPERATOR(pg_catalog.=) '-1'::pg_catalog.int4 THEN NULL
            ELSE (m.typmod OPERATOR(pg_catalog.-) 4) OPERATOR(pg_catalog.&) 65535
            END
        END,
      CASE WHEN u.oid OPERATOR(pg_catalog.=) 1082::pg_catalog.oid THEN 0
        WHEN u.oid OPERATOR(pg_catalog.=) ANY (ARRAY[1083, 1114, 1184, 1266]::pg_catalog.oid[])
          THEN CASE WHEN m.typmod OPERATOR(pg_catalog.<) 0 THEN 6 ELSE m.typmod END
        WHEN u.oid OPERATOR(pg_catalog.=) 1186::pg_catalog.oid THEN
          CASE WHEN m.typmod OPERATOR(pg_catalog.<) 0
              OR (m.typmod OPERATOR(pg_catalog.&) 65535) OPERATOR(pg_catalog.=) 65535
            THEN 6 ELSE m.typmod OPERATOR(pg_catalog.&) 65535
            END
        END,
      NULL::pg_catalog.text,
      u.typname::pg_catalog.text
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
    JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) c.oid
    JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) a.atttypid
    CROSS JOIN LATERAL (SELECT
        CASE WHEN t.typtype OPERATOR(pg_catalog.=) 'd' THEN t.typbasetype ELSE a.atttypid END,
        CASE WHEN t.typtype OPERATOR(pg_catalog.=) 'd' THEN t.typtypmod ELSE a.atttypmod END)
      AS m(typid, typmod)
    JOIN pg_catalog.pg_type u ON u.oid OPERATOR(pg_catalog.=) m.typid
    JOIN pg_catalog.pg_namespace un ON un.oid OPERATOR(pg_catalog.=) u.typnamespace
    WHERE c.oid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
      AND a.attnum OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.int4[])
      AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
      AND c.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'v', 'f', 'p']::pg_catalog."char"[])
      AND \(hideOtherTempSchemas) AND \(columnPrivilegeFilter)
    """

  /// Exact row count. The actor turns a query failure into 0.
  func rowCount(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws
    -> Int
  {
    let dialect = SQLDialect.postgresql
    let relation = try dialect.quoteIdentifier(schema) + "." + dialect.quoteIdentifier(table)
    let query = "SELECT pg_catalog.count(*) AS row_count FROM \(relation)"
    for row in try await rows(in: session, sql: query) {
      if let count = row.first.flatMap(CatalogValue.int) { return count }
    }
    return 0
  }

  /// Primary key column names in key order. `tableName` is bound and resolved with `to_regclass`
  /// through the session's search_path on purpose: it is the user's table name, resolved as the
  /// user's SQL resolves it (the carve-out to the pg_catalog rule above).
  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws
    -> [String]
  {
    let query = """
      SELECT a.attname::pg_catalog.text AS column_name
      FROM pg_catalog.pg_index i
      JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) i.indrelid
        AND a.attnum OPERATOR(pg_catalog.=) ANY (i.indkey)
      WHERE i.indrelid OPERATOR(pg_catalog.=) pg_catalog.to_regclass($1)
        AND i.indisprimary
      ORDER BY pg_catalog.array_position(i.indkey, a.attnum)
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

  /// Same type string the actor built from information_schema cells (`columnTypeSQL` columns).
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

  /// An `array_agg` of attnums as text: `{1,2}` in order, `[]` for NULL (no row aggregated).
  /// Nil for any other text, e.g. an array with explicit bounds (`[0:1]={1,2}`, an int2vector
  /// cast to `int2[]`) or an element that is not a positive `int2`: never a partial list.
  static func attnumList(_ value: CellValue) -> [Int16]? {
    if case .null = value { return [] }
    guard let text = string(value), text.first == "{", text.last == "}" else { return nil }
    let body = text.dropFirst().dropLast()
    if body.isEmpty { return [] }
    var attnums: [Int16] = []
    for element in body.split(separator: ",", omittingEmptySubsequences: false) {
      guard let attnum = Int16(element), attnum > 0 else { return nil }
      attnums.append(attnum)
    }
    return attnums
  }

  /// `[["a", "b"], ...]` JSON text (`json_agg(json_build_array(a, b))`) as pairs
  static func stringPairs(_ value: CellValue) -> [(String, String)] {
    guard let text = string(value), let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([[String]].self, from: data)
    else { return [] }
    return decoded.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
  }

  /// Parse PostgreSQL array string format: {val1,val2,val3}, a quoted element's `\"` and `\\`
  /// read as `"` and `\`. Walks scalars: a quote followed by a combining mark is one `Character`.
  private static func parsePostgresArray(_ arrayString: String) -> [String] {
    var str = Substring(arrayString.trimmingCharacters(in: .whitespaces)).unicodeScalars
    if str.first == "{" { str = str.dropFirst() }
    if str.last == "}" { str = str.dropLast() }
    if str.isEmpty { return [] }

    var result: [String] = []
    var current = ""
    var inQuotes = false
    var escaped = false
    for char in str {
      if escaped {
        current.unicodeScalars.append(char)
        escaped = false
      } else if char == "\\" && inQuotes {
        escaped = true
      } else if char == "\"" {
        inQuotes.toggle()
      } else if char == "," && !inQuotes {
        result.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.unicodeScalars.append(char)
      }
    }
    if !current.isEmpty {
      result.append(current.trimmingCharacters(in: .whitespaces))
    }
    return result
  }
}
