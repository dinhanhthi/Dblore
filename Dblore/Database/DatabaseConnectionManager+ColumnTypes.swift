//
//  DatabaseConnectionManager+ColumnTypes.swift
//  Dblore
//
//  Column type enrichment (precision, scale, length) as information_schema reports it,
//  MySQL result column origins, and the tables mask rules match result columns against
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Column Type Enrichment

  /// Enrich column type information with modifiers (precision, scale, length)
  /// Reads the modifiers information_schema reports (from pg_catalog), always read fresh
  /// (MCP, CLI and the app's own reads never take a cached type). Skipped (driver types kept)
  /// while the app transaction is pending: a failing catalog query would abort it.
  /// MySQL: resolves the result column origins instead (`resolveMySQLOrigins`).
  func enrichColumnTypes(columns: [ColumnInfo], query: String) async -> [ColumnInfo] {
    // Only PostgreSQL has modifiers to add. SQLite keeps declared types; DuckDB has no
    // enrichment yet. MySQL types already come from the column definitions. MongoDB has no
    // catalog types.
    switch databaseType {
    case .postgresql: break
    case .mysql: return await resolveMySQLOrigins(columns)
    case .sqlite, .duckdb, .mongodb, nil: return columns
    }
    guard !columns.isEmpty, Self.enrichesColumnTypes(query) else { return columns }
    return await freshColumnTypes(columns, query: query) ?? columns
  }

  /// PostgreSQL `columns` (as the driver reported them) with the types the catalog reports
  /// now, stored in `columnTypeCache` next to the driver's types. Nil when no catalog query
  /// may be sent (app transaction pending, no connection) or it failed.
  func freshColumnTypes(_ columns: [ColumnInfo], query: String) async -> [ColumnInfo]? {
    guard !isMetadataPaused else { return nil }
    let epoch = connectionEpoch
    let generation = columnTypeCache.generation
    let enriched: [ColumnInfo]
    if let hook = columnTypeReadHook {
      enriched = await hook(columns)
    } else {
      guard _postgresConnection != nil else { return nil }
      do {
        enriched = try await withSession { session in
          guard let postgres = self.introspector as? PostgresSchemaIntrospector else {
            return columns
          }
          return try await postgres.enrichedColumns(columns, query: query, in: session)
        }
      } catch {
        await AppLogger.shared.warning(
          "Failed to enrich column types: \(error)", category: "Database")
        return nil
      }
    }
    if epoch == connectionEpoch {
      columnTypeCache.store(driver: columns, enriched: enriched, readAt: generation)
    }
    return enriched
  }

  /// Whether a read the app shows before enriching it (`deferEnrichment`) keeps the driver's
  /// types for the caller's background read (`freshColumnTypes`): a PostgreSQL read of one
  /// table. False enriches now (other engines: MySQL origins resolve on the critical path).
  func defersColumnTypes(_ columns: [ColumnInfo], query: String) -> Bool {
    databaseType == .postgresql && !columns.isEmpty && Self.enrichesColumnTypes(query)
  }

  /// `columns` (as the driver reported them) with their cached PostgreSQL types, or nil: what
  /// the app shows at once before its background read (`deferEnrichment`). A type cached while
  /// the driver reported another one (the column was altered since) is never served.
  func cachedColumnTypes(_ columns: [ColumnInfo]) -> [ColumnInfo]? {
    columnTypeCache.columns(columns)
  }

  // MARK: - MySQL Column Origins

  /// `origin` of each column read from a table: the identity built from the column
  /// definition's schema and org_table, and the ORDINAL_POSITION of its org_name (the
  /// `EditTable.attributeNames` key). An expression, or a table the catalog does not list
  /// (temporary), has no origin. Ordinals are cached per table (`mysqlTableColumns`); a miss
  /// reads information_schema, never while metadata is paused. Source names stay, so the
  /// lookup relation can check a cached ordinal against the column it was read for.
  /// Runs on capped reads too: the capped statement was killed or drained, so the catalog
  /// read does not wait on it.
  func resolveMySQLOrigins(_ columns: [ColumnInfo]) async -> [ColumnInfo] {
    guard columns.contains(where: { $0.sourceName != nil }) else { return columns }
    var tables: [TableRef: MySQLTableColumns?] = [:]
    var resolved: [ColumnInfo] = []
    for column in columns {
      guard let source = column.sourceName else {
        resolved.append(column)
        continue
      }
      let tableID = TableRef.mysql(database: source.schema, table: source.table)
      if tables[tableID] == nil {
        tables[tableID] = .some(await mysqlColumns(of: source, tableID: tableID))
      }
      let ordinal = tables[tableID]??.ordinals[source.column]
      resolved.append(
        ColumnInfo(
          name: column.name, type: column.type,
          origin: ordinal.map { ColumnOrigin(tableID: tableID, columnOrdinal: $0) },
          sourceName: source, wallClock: column.wallClock, masked: column.masked))
    }
    return resolved
  }

  /// Cached ordinals of `source`'s table, or one catalog read. Nil when paused, not listed,
  /// the read fails, or the connection changed or the cache was cleared meanwhile.
  private func mysqlColumns(
    of source: ColumnSourceName, tableID: TableRef
  ) async -> MySQLTableColumns? {
    if let cached = mysqlTableColumns[tableID],
      cached.database.unicodeScalars.elementsEqual(source.schema.unicodeScalars),
      cached.table.unicodeScalars.elementsEqual(source.table.unicodeScalars)
    {
      return cached
    }
    guard !isMetadataPaused, let mysql = introspector as? MySQLSchemaIntrospector else {
      return nil
    }
    let epoch = connectionEpoch
    let generation = mysqlTableColumns.generation
    do {
      let ordinals = try await withCatalogSession { session in
        try await mysql.columnOrdinals(schema: source.schema, table: source.table, in: session)
      }
      // A clear meanwhile (DDL, schema reload) may make these ordinals stale: not stored, and
      // not used for this result either.
      guard epoch == connectionEpoch, !ordinals.isEmpty else { return nil }
      let columns = MySQLTableColumns(
        database: source.schema, table: source.table, ordinals: ordinals)
      guard mysqlTableColumns.store(columns, for: tableID, readAt: generation) else { return nil }
      return columns
    } catch {
      await AppLogger.shared.warning(
        "Failed to resolve MySQL column origins: \(error)", category: "Database")
      return nil
    }
  }
}

extension DatabaseConnectionManager {
  // MARK: - Mask Rule Origins

  /// The table each of `columns` was read from, for the mask rules (`ColumnMaskRuleSet`). Nil
  /// when unknown, so a table-qualified rule matches on its column alone (fails closed): a view
  /// or other non-table relation, a partition or inheritance child, a table the catalog does
  /// not list, a lookup that failed, was skipped (`mayRead` false: a PostgreSQL read the row
  /// cap cut that still drains) or saw the connection or the column type cache change
  /// meanwhile. Read again for every result while metadata may be read: another client may
  /// rename a table or move it to another schema at any time. While it is paused (app or user
  /// transaction pending) the last answer for each table this connection read (`ColumnTypeCache`
  /// memo) stands in, whatever `mayRead` says (no I/O); a table not read since the last clear
  /// has none. One read per result: PostgreSQL reads all its OIDs
  /// (`maskOriginSQL`), MySQL checks all its source tables are BASE TABLEs
  /// (`mysqlBaseTableSQL`); SQLite origins carry the names; DuckDB and MongoDB results have
  /// none.
  func maskOrigins(
    _ columns: [ColumnInfo], databaseType: DatabaseType, mayRead: Bool
  ) async -> [ColumnMaskRule.Origin?] {
    switch databaseType {
    case .postgresql:
      let oids = Set(columns.compactMap { $0.tableOrigin?.tableID.postgresOID })
      // The memo needs no I/O: it answers while paused even when `mayRead` is false (a capped
      // read inside a transaction keeps its session, so it is never reset)
      guard !oids.isEmpty, isMetadataPaused || mayRead,
        let relations = await readMaskRelations(oids)
      else {
        return columns.map { _ in nil }
      }
      return columns.map { column in
        column.tableOrigin?.tableID.postgresOID.flatMap { relations[$0] }
      }
    case .mysql:
      let sources = columns.map { column in
        column.sourceName.map { MaskSourceTable(schema: $0.schema, table: $0.table) }
      }
      var distinct: [MaskSourceTable] = []
      for source in sources.compactMap({ $0 }) where !distinct.contains(source) {
        distinct.append(source)
      }
      let baseTables =
        (isMetadataPaused || mayRead) && !distinct.isEmpty
        ? await readMySQLBaseTables(distinct) : []
      return sources.map { source in
        source.flatMap {
          baseTables.contains($0) ? ColumnMaskRule.Origin(schema: $0.schema, table: $0.table) : nil
        }
      }
    case .sqlite:
      return columns.map { column in
        column.origin?.tableID.sqliteComponents.map {
          ColumnMaskRule.Origin(schema: $0.schema, table: $0.table)
        }
      }
    case .duckdb, .mongodb:
      return columns.map { _ in nil }
    }
  }

  /// The tables of `oids` a rule may name: a table (`r`) or partitioned table (`p`) that is no
  /// partition or inheritance child (an OID missing from the answer has none). Nil after an
  /// error, or a connection or column type cache change meanwhile. While metadata is paused,
  /// the memo's answers (`ColumnTypeCache.maskRelations`); every answer read is memoized.
  private func readMaskRelations(_ oids: Set<UInt32>) async -> [UInt32: ColumnMaskRule.Origin]? {
    guard !isMetadataPaused else { return columnTypeCache.maskRelations(oids) }
    let epoch = connectionEpoch
    let generation = columnTypeCache.generation
    let list = "{" + oids.sorted().map(String.init).joined(separator: ",") + "}"
    do {
      let rows = try await withCatalogSession { session in
        var rows: [[CellValue]] = []
        for try await row in try await session.query(Self.maskOriginSQL, binds: [.text(list)])
          .rows
        {
          rows.append(row)
        }
        return rows
      }
      guard epoch == connectionEpoch, generation == columnTypeCache.generation else { return nil }
      var found: [UInt32: ColumnMaskRule.Origin] = [:]
      for row in rows {
        guard let (oid, origin) = Self.maskRelation(row), oids.contains(oid) else { continue }
        found[oid] = origin
      }
      columnTypeCache.memoize(maskRelations: found, of: oids)
      return found
    } catch {
      await AppLogger.shared.warning(
        "Failed to read mask rule origins: \(error)", category: "Database")
      return nil
    }
  }

  /// OID and origin of one `maskOriginSQL` row: the origin only for a table (`r`) or a
  /// partitioned table (`p`) that is no partition or inheritance child. Nil for a row it cannot
  /// read.
  private nonisolated static func maskRelation(
    _ row: [CellValue]
  ) -> (oid: UInt32, origin: ColumnMaskRule.Origin?)? {
    guard row.count == 5 else { return nil }
    let oid: UInt32?
    switch row[0] {
    case .int(let value): oid = UInt32(exactly: value)
    case .string(let text), .decimal(let text): oid = UInt32(text)
    default: oid = nil
    }
    guard let oid else { return nil }
    guard case .string(let schema) = row[1], case .string(let table) = row[2],
      case .string(let kind) = row[3], case .bool(let hasParent) = row[4],
      kind == "r" || kind == "p", !hasParent
    else { return (oid, nil) }
    return (oid, ColumnMaskRule.Origin(schema: schema, table: table))
  }

  /// Which of `tables` are a BASE TABLE in information_schema.TABLES (exact names: the catalog
  /// collation may ignore case), in one read. Empty after an error, or a connection or column
  /// type cache change meanwhile. While metadata is paused, the memo's answers
  /// (`ColumnTypeCache.baseTables`); every answer read is memoized.
  private func readMySQLBaseTables(_ tables: [MaskSourceTable]) async -> Set<MaskSourceTable> {
    guard !isMetadataPaused else { return columnTypeCache.baseTables(tables) }
    let epoch = connectionEpoch
    let generation = columnTypeCache.generation
    let binds = tables.flatMap { [SQLBindValue.text($0.schema), .text($0.table)] }
    do {
      let rows = try await withCatalogSession { session in
        var rows: [[CellValue]] = []
        for try await row in try await session.query(
          Self.mysqlBaseTableSQL(count: tables.count), binds: binds
        ).rows {
          rows.append(row)
        }
        return rows
      }
      guard epoch == connectionEpoch, generation == columnTypeCache.generation else { return [] }
      func exact(_ row: [CellValue], _ index: Int, _ name: String) -> Bool {
        MySQLCatalogValue.string(row, index)?.unicodeScalars.elementsEqual(name.unicodeScalars)
          ?? false
      }
      let found = Set(
        tables.filter { table in
          rows.contains {
            exact($0, 0, table.schema) && exact($0, 1, table.table) && exact($0, 2, "BASE TABLE")
          }
        })
      columnTypeCache.memoize(baseTables: found, of: tables)
      return found
    } catch {
      await AppLogger.shared.warning(
        "Failed to read mask rule origins: \(error)", category: "Database")
      return []
    }
  }

  /// The information_schema.TABLES read of `count` (schema, table) pairs, bound in order
  nonisolated static func mysqlBaseTableSQL(count: Int) -> String {
    let pairs = Array(repeating: "(TABLE_SCHEMA = ? AND TABLE_NAME = ?)", count: count)
    return """
      SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
      WHERE \(pairs.joined(separator: " OR "))
      """
  }
}

/// Enriched PostgreSQL result column types by origin (table identity and attnum), each with
/// the type the driver reported when it was read, so a table read again shows its types
/// without a catalog read. A hit needs the driver to report the same type now (a column altered
/// to another base type misses); the app's background read refreshes the rest (modifiers). A
/// clear also rejects enrichment reads still in flight (`generation`). A hit takes `masked`
/// from the incoming column, so a stale entry never undoes a mask rule edit.
/// Also memoizes the tables mask rules match against, as each per-result read last answered
/// (`maskOrigins`): read back only while metadata is paused, so a pending transaction keeps
/// table-qualified rules on the tables this connection already read. Cleared with the types,
/// so DDL sent on this connection (`ProtectedTransactionRules.invalidatesEditTables`) drops it.
/// Accepted limitation: while a transaction pauses metadata, a rename done by another session,
/// or by a function a read calls, is not seen until the transaction ends. PostgreSQL keys the
/// memo by OID, so a renamed table keeps its old name here (a rule naming the new name misses
/// it). MySQL keys it by the names the result column carries, so a renamed table comes back
/// under its new name: a name the memo does not know has no origin and its rules match on the
/// column alone (fails closed); a name it knows is still the name the result was read from.
nonisolated struct ColumnTypeCache: Sendable {
  private struct Entry: Sendable {
    let driver: String
    let enriched: String
  }

  private var types: [ColumnOrigin: Entry] = [:]
  /// PostgreSQL relation by OID: its origin, or nil for one a rule may not name
  private var relations: [UInt32: ColumnMaskRule.Origin?] = [:]
  /// MySQL source table: whether it is a BASE TABLE
  private var baseTableFlags: [MaskSourceTable: Bool] = [:]
  private(set) var generation: UInt64 = 0

  var isEmpty: Bool { types.isEmpty }

  /// `columns` (driver types) with their cached types, or nil unless every column read from a
  /// PostgreSQL table has one read while the driver reported its current type
  func columns(_ columns: [ColumnInfo]) -> [ColumnInfo]? {
    let read = columns.filter { $0.tableOrigin?.tableID.postgresOID != nil }
    guard !read.isEmpty,
      read.allSatisfy({ column in
        column.tableOrigin.flatMap { types[$0] }?.driver == column.type
      })
    else { return nil }
    return columns.map { column in
      guard let origin = column.tableOrigin, let entry = types[origin] else { return column }
      return ColumnInfo(
        name: column.name, type: entry.enriched, origin: column.origin,
        sourceName: column.sourceName, wallClock: column.wallClock, masked: column.masked)
    }
  }

  /// Stores the `enriched` types of the `driver` columns (same order) read from a PostgreSQL
  /// table, unless the cache was cleared since `generation` (read before the catalog query)
  mutating func store(driver: [ColumnInfo], enriched: [ColumnInfo], readAt generation: UInt64) {
    guard generation == self.generation, driver.count == enriched.count else { return }
    for (read, column) in zip(driver, enriched) {
      guard let origin = read.tableOrigin, origin == column.tableOrigin,
        origin.tableID.postgresOID != nil
      else { continue }
      types[origin] = Entry(driver: read.type, enriched: column.type)
    }
  }

  /// The memoized origins of `oids` (a miss, like a non-table, has none)
  func maskRelations(_ oids: Set<UInt32>) -> [UInt32: ColumnMaskRule.Origin] {
    oids.reduce(into: [:]) { found, oid in
      if case .some(.some(let origin)) = relations[oid] { found[oid] = origin }
    }
  }

  /// Memoizes `found` (a read of `oids`): an OID it lacks has no origin
  mutating func memoize(maskRelations found: [UInt32: ColumnMaskRule.Origin], of oids: Set<UInt32>)
  {
    for oid in oids {
      relations[oid] = .some(found[oid])
    }
  }

  /// Which of `tables` the memo knows as a BASE TABLE
  func baseTables(_ tables: [MaskSourceTable]) -> Set<MaskSourceTable> {
    Set(tables.filter { baseTableFlags[$0] == true })
  }

  /// Memoizes `found` (a read of `tables`): a table it lacks is no BASE TABLE
  mutating func memoize(baseTables found: Set<MaskSourceTable>, of tables: [MaskSourceTable]) {
    for table in tables {
      baseTableFlags[table] = found.contains(table)
    }
  }

  mutating func removeAll() {
    types.removeAll()
    relations.removeAll()
    baseTableFlags.removeAll()
    generation &+= 1
  }
}

/// A MySQL source table of a result column, by its exact names
nonisolated struct MaskSourceTable: Hashable, Sendable {
  let schema: String
  let table: String
}

extension DatabaseConnectionManager {
  /// The relations of result columns by table OID, for the mask rules (`maskOrigins`): schema,
  /// name, kind and whether it is a partition or inheritance child. `$1` is an `oid[]` literal.
  nonisolated static let maskOriginSQL = """
    SELECT c.oid::pg_catalog.int8, n.nspname::pg_catalog.text, c.relname::pg_catalog.text,
           c.relkind::pg_catalog.text,
           EXISTS (SELECT 1 FROM pg_catalog.pg_inherits i
                   WHERE i.inhrelid OPERATOR(pg_catalog.=) c.oid) AS has_parent
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
    WHERE c.oid OPERATOR(pg_catalog.=) ANY($1::pg_catalog.oid[])
    """

  /// Test seam: where the saved rows' mask rules are read (`SavedMaskRules` on `.standard` in
  /// the app)
  func setSavedMaskRules(_ rules: @escaping @Sendable (ConnectionConfig) -> [ColumnMaskRule]) {
    savedMaskRules = rules
  }

  /// Test hook (see `columnTypeReadHook`): answers the PostgreSQL column type catalog read in
  /// place of the server. Nil in the app.
  func setColumnTypeReadHook(_ hook: (@Sendable ([ColumnInfo]) async -> [ColumnInfo])?) {
    columnTypeReadHook = hook
  }
}
