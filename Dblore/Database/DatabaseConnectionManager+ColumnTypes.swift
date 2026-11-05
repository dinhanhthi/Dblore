//
//  DatabaseConnectionManager+ColumnTypes.swift
//  Dblore
//
//  Column type enrichment (precision, scale, length) as information_schema reports it, and
//  MySQL result column origins
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
          sourceName: source, wallClock: column.wallClock))
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

/// Enriched PostgreSQL result column types by origin (table identity and attnum), each with
/// the type the driver reported when it was read, so a table read again shows its types
/// without a catalog read. A hit needs the driver to report the same type now (a column altered
/// to another base type misses); the app's background read refreshes the rest (modifiers). A
/// clear also rejects enrichment reads still in flight (`generation`).
nonisolated struct ColumnTypeCache: Sendable {
  private struct Entry: Sendable {
    let driver: String
    let enriched: String
  }

  private var types: [ColumnOrigin: Entry] = [:]
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
        sourceName: column.sourceName, wallClock: column.wallClock)
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

  mutating func removeAll() {
    types.removeAll()
    generation &+= 1
  }
}

extension DatabaseConnectionManager {
  /// Test hook (see `columnTypeReadHook`): answers the PostgreSQL column type catalog read in
  /// place of the server. Nil in the app.
  func setColumnTypeReadHook(_ hook: (@Sendable ([ColumnInfo]) async -> [ColumnInfo])?) {
    columnTypeReadHook = hook
  }
}
