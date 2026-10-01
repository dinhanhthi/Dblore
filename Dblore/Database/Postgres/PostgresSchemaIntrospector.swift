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

  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] {
    let query = """
      SELECT
        n.nspname::text,
        c.relname::text,
        CASE WHEN c.reltuples < 0 OR (c.reltuples = 0 AND c.relpages = 0)
          THEN NULL ELSE c.reltuples::bigint END AS row_estimate
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
      guard row.count >= 3,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1])
      else { continue }
      tables.append(
        DatabaseTable(schema: schema, name: name, rowCount: CatalogValue.optionalInt(row[2])))
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
        pg_get_function_arguments(p.oid) AS arguments
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'f'
      ORDER BY n.nspname, p.proname
      """
    var functions: [DatabaseFunction] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 4,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]),
        let returnType = CatalogValue.string(row[2]),
        let arguments = CatalogValue.string(row[3])
      else { continue }
      functions.append(
        DatabaseFunction(
          schema: schema, name: name, returnType: returnType, arguments: arguments,
          definition: nil))
    }
    return functions
  }

  func procedures(in session: any DatabaseSession) async throws -> [DatabaseProcedure] {
    let query = """
      SELECT
        n.nspname AS schema,
        p.proname AS name,
        pg_get_function_arguments(p.oid) AS arguments
      FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND p.prokind = 'p'
      ORDER BY n.nspname, p.proname
      """
    var procedures: [DatabaseProcedure] = []
    for row in try await rows(in: session, sql: query) {
      guard row.count >= 3,
        let schema = CatalogValue.string(row[0]),
        let name = CatalogValue.string(row[1]),
        let arguments = CatalogValue.string(row[2])
      else { continue }
      procedures.append(
        DatabaseProcedure(schema: schema, name: name, arguments: arguments, definition: nil))
    }
    return procedures
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

  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] {
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
          SELECT array_agg(a.attname ORDER BY x.n)
          FROM pg_attribute a
          CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
          WHERE a.attrelid = c.conrelid AND a.attnum = x.attnum
        ) AS source_columns,
        (
          SELECT array_agg(a.attname ORDER BY x.n)
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
    let query = """
      SELECT c.oid::int8, a.attnum::int4, a.attname::text,
             COALESCE((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(att, ord)
                       WHERE k.att = a.attnum), 0)::int4,
             format('%I.%I', n.nspname, c.relname), c.relkind::text, c.relhassubclass
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
    for row in try await rows(in: session, sql: query, binds: [.text(name)]) {
      guard row.count >= 7 else { throw CatalogRowError() }
      guard let tableOID = CatalogValue.int(row[0]),
        let attnum = CatalogValue.int(row[1]),
        let columnName = CatalogValue.string(row[2]),
        let keyPosition = CatalogValue.int(row[3]),
        let qualified = CatalogValue.string(row[4]),
        let kind = CatalogValue.string(row[5]),
        let subclass = CatalogValue.bool(row[6])
      else { throw CatalogRowError() }
      guard let number = Int16(exactly: attnum), let tableID = UInt32(exactly: tableOID) else {
        continue
      }
      oid = tableID
      qualifiedName = qualified
      relationKind = kind
      hasSubclass = subclass
      names[number] = columnName
      if keyPosition > 0 { keyPositions.append((keyPosition, columnName)) }
    }
    guard oid != 0, relationKind == "p" || (relationKind == "r" && !hasSubclass) else {
      return nil
    }
    let primaryKey = keyPositions.sorted { $0.position < $1.position }.map(\.name)
    return EditTable(
      oid: oid, attributeNames: names, primaryKeyColumns: primaryKey, qualifiedName: qualifiedName,
      updateOnly: relationKind == "r")
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

  /// Column modifiers from `information_schema`. Throws when the catalog query fails so the
  /// actor can map a closed session; returns `columns` when the statement is not one table.
  func enrichedColumns(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async throws -> [ColumnInfo] {
    guard !columns.isEmpty, let tableName = DatabaseConnectionManager.singleTableName(in: query)
    else { return columns }

    let columnNames = columns.map { "'\($0.name)'" }.joined(separator: ", ")
    let typeQuery = """
      SELECT column_name, data_type,
             character_maximum_length,
             numeric_precision,
             numeric_scale,
             datetime_precision,
             interval_type,
             udt_name
      FROM information_schema.columns
      WHERE table_name = '\(tableName)'
        AND column_name IN (\(columnNames))
      """
    var typeMap: [String: String] = [:]
    for row in try await rows(in: session, sql: typeQuery) {
      guard row.count >= 8,
        let columnName = CatalogValue.string(row[0]),
        let dataType = CatalogValue.string(row[1])
      else { continue }
      typeMap[columnName] = Self.detailedType(dataType: dataType, row: row)
    }
    return columns.map { column in
      guard let enrichedType = typeMap[column.name] else { return column }
      return ColumnInfo(name: column.name, type: enrichedType, origin: column.origin)
    }
  }

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
private nonisolated enum CatalogValue {
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
