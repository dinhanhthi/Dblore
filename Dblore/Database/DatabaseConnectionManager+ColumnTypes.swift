//
//  DatabaseConnectionManager+ColumnTypes.swift
//  Dblore
//
//  Column type enrichment (precision, scale, length) from information_schema, and MySQL
//  result column origins
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Column Type Enrichment

  /// Enrich column type information with modifiers (precision, scale, length)
  /// Uses information_schema to get detailed type info. Skipped (driver types kept) while the
  /// app transaction is pending: a failing catalog query would abort it.
  /// MySQL: resolves the result column origins instead (`resolveMySQLOrigins`).
  func enrichColumnTypes(columns: [ColumnInfo], query: String) async -> [ColumnInfo] {
    // Only PostgreSQL has modifiers to add. SQLite keeps declared types; DuckDB has no
    // enrichment yet. MySQL types already come from the column definitions.
    switch databaseType {
    case .postgresql: break
    case .mysql: return await resolveMySQLOrigins(columns)
    case .sqlite, .duckdb, nil: return columns
    }
    // Only proceed if we have columns and connection
    guard !columns.isEmpty, !isMetadataPaused, _postgresConnection != nil,
      Self.singleTableName(in: query) != nil
    else {
      return columns
    }

    do {
      return try await withSession { session in
        guard let postgres = self.introspector as? PostgresSchemaIntrospector else {
          return columns
        }
        return try await postgres.enrichedColumns(columns, query: query, in: session)
      }
    } catch {
      // If enrichment fails, return original columns
      await AppLogger.shared.warning(
        "Failed to enrich column types: \(error)", category: "Database")
      return columns
    }
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
          sourceName: source))
    }
    return resolved
  }

  /// Cached ordinals of `source`'s table, or one catalog read. Nil when paused, not listed,
  /// the read fails, or the connection changed or the cache was cleared meanwhile.
  private func mysqlColumns(
    of source: ColumnSourceName, tableID: TableRef
  ) async -> MySQLTableColumns? {
    if let cached = mysqlTableColumns[tableID], cached.database == source.schema,
      cached.table == source.table
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
