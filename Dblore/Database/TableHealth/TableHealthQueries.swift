// TableHealthQueries.swift
// Table Health's reads of the engine's statistics, each on the session it is given (Table Health
// runs them on a side connection, never on a tab's session).
//
// PostgreSQL: indexes never scanned (`pg_stat_user_indexes.idx_scan = 0`), leaving out unique,
// primary-key, exclusion-constraint and partitioned-parent indexes, which can't be dropped for
// being unused, and a partition's index attached to its parent's (`pg_inherits`), which
// PostgreSQL refuses to drop on its own; tables whose dead rows are over 20% of their rows and
// over 10,000 (`pg_stat_user_tables`, the ratio computed here). With `track_counts` off both are
// zero everywhere, so they are skipped with a note; statistics reset in the last 7 days
// (`pg_stat_database.stats_reset`) give a note. Every statement names pg_catalog for each
// relation, function, operator and cast (the session's search_path is the user's).
//
// MySQL / MariaDB: `sys.schema_unused_indexes` (performance_schema counters since the server
// started) and `sys.schema_redundant_indexes`, for the bound schema. Without performance_schema
// its tables are empty and every index would look used, so a probe reads `@@performance_schema`
// and whether both sys views exist first. A missing or unreadable sys schema (common on MariaDB)
// gives one note and nothing else (a failure the server did not answer, such as a lost
// connection, is thrown); performance_schema off gives one note and skips the unused indexes.

import Foundation

nonisolated enum TableHealthQueries {
  static let deadRowsMinimum = 10_000
  static let deadRatioMinimum = 0.2

  static let trackCountsOffNote =
    "Statistics collection (track_counts) is off on this server, so unused indexes and dead rows "
    + "are not checked."
  static let recentResetNote =
    "Statistics were reset in the last 7 days, so an index may look unused only because it has "
    + "not been needed since."
  static let sysUnavailableNote =
    "The sys schema is not available on this server or to this user, so unused and redundant "
    + "indexes are not checked."
  static let performanceSchemaOffNote =
    "performance_schema is off on this server, so unused indexes are not checked."

  // MARK: - PostgreSQL

  /// Whether `track_counts` is on, and whether this database's statistics were reset in the last
  /// 7 days (false when never reset)
  static let postgresStatisticsStateSQL = """
    SELECT pg_catalog.current_setting('track_counts') OPERATOR(pg_catalog.=) 'on',
      COALESCE((
        SELECT d.stats_reset OPERATOR(pg_catalog.>)
          (pg_catalog.now() OPERATOR(pg_catalog.-) '7 days'::pg_catalog.interval)
        FROM pg_catalog.pg_stat_database d
        WHERE d.datname OPERATOR(pg_catalog.=) pg_catalog.current_database()
      ), false)
    """

  static let postgresUnusedIndexesSQL = """
    SELECT s.schemaname::pg_catalog.text, s.relname::pg_catalog.text,
      s.indexrelname::pg_catalog.text
    FROM pg_catalog.pg_stat_user_indexes s
    JOIN pg_catalog.pg_index i ON i.indexrelid OPERATOR(pg_catalog.=) s.indexrelid
    JOIN pg_catalog.pg_class ic ON ic.oid OPERATOR(pg_catalog.=) s.indexrelid
    WHERE s.idx_scan OPERATOR(pg_catalog.=) 0
      AND NOT i.indisunique AND NOT i.indisprimary AND NOT i.indisexclusion
      AND ic.relkind OPERATOR(pg_catalog.<>) 'I'::pg_catalog."char"
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_inherits h
        WHERE h.inhrelid OPERATOR(pg_catalog.=) s.indexrelid)
    ORDER BY 1, 2, 3
    """

  static let postgresDeadTuplesSQL = """
    SELECT s.schemaname::pg_catalog.text, s.relname::pg_catalog.text, s.n_live_tup, s.n_dead_tup
    FROM pg_catalog.pg_stat_user_tables s
    WHERE s.n_dead_tup OPERATOR(pg_catalog.>) \(deadRowsMinimum)
    ORDER BY 1, 2
    """

  struct PostgresStatisticsState: Sendable, Equatable {
    var trackCounts: Bool
    var notes: [String]
  }

  /// The statistics findings and notes. With `track_counts` off, only its note.
  static func postgresReport(in session: any DatabaseSession) async throws -> TableHealthReport {
    let state = try await postgresStatisticsState(in: session)
    guard state.trackCounts else { return TableHealthReport(notes: state.notes) }
    return TableHealthReport(
      findings: try await postgresUnusedIndexes(in: session)
        + postgresDeadTuples(in: session),
      notes: state.notes)
  }

  static func postgresStatisticsState(
    in session: any DatabaseSession
  ) async throws -> PostgresStatisticsState {
    let row = try await rows(in: session, sql: postgresStatisticsStateSQL).first ?? []
    let trackCounts = row.first.flatMap(CatalogValue.bool) ?? true
    let resetRecently = row.count > 1 && CatalogValue.bool(row[1]) == true
    guard trackCounts else { return .init(trackCounts: false, notes: [trackCountsOffNote]) }
    return .init(trackCounts: true, notes: resetRecently ? [recentResetNote] : [])
  }

  static func postgresUnusedIndexes(
    in session: any DatabaseSession
  ) async throws -> [TableHealthFinding] {
    try await rows(in: session, sql: postgresUnusedIndexesSQL).compactMap { row in
      guard row.count >= 3, let schema = CatalogValue.string(row[0]),
        let table = CatalogValue.string(row[1]), let index = CatalogValue.string(row[2])
      else { return nil }
      return TableHealthFinding(
        schema: schema, table: table, kind: .unusedIndex, objectName: index,
        reason: "Index \(index) has not been scanned since statistics were last reset, yet every "
          + "write still updates it.")
    }
  }

  static func postgresDeadTuples(
    in session: any DatabaseSession
  ) async throws -> [TableHealthFinding] {
    try await rows(in: session, sql: postgresDeadTuplesSQL).compactMap { row in
      guard row.count >= 4, let schema = CatalogValue.string(row[0]),
        let table = CatalogValue.string(row[1]), let live = CatalogValue.int(row[2]),
        let dead = CatalogValue.int(row[3]), dead > deadRowsMinimum
      else { return nil }
      let ratio = Double(dead) / Double(live + dead)
      guard ratio > deadRatioMinimum else { return nil }
      return TableHealthFinding(
        schema: schema, table: table, kind: .deadTuples,
        reason: "\(dead.formatted()) dead rows, \(Int((ratio * 100).rounded()))% of the table: "
          + "vacuum is not keeping up.")
    }
  }

  // MARK: - MySQL / MariaDB

  /// `@@performance_schema` (1 or 0) and how many of the two sys views this user can see
  static let mysqlProbeSQL = """
    SELECT @@performance_schema, (
      SELECT COUNT(*) FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = 'sys'
        AND TABLE_NAME IN ('schema_unused_indexes', 'schema_redundant_indexes'))
    """

  static let mysqlUnusedIndexesSQL = """
    SELECT object_name, index_name FROM sys.schema_unused_indexes
    WHERE object_schema = ?
    ORDER BY object_name, index_name
    """

  static let mysqlRedundantIndexesSQL = """
    SELECT table_name, redundant_index_name, redundant_index_columns, dominant_index_name,
      dominant_index_columns
    FROM sys.schema_redundant_indexes
    WHERE table_schema = ?
    ORDER BY table_name, redundant_index_name
    """

  /// The sys findings for `schema`, or one note when they can't be read. A cancellation is thrown.
  static func mysqlReport(
    schema: String, in session: any DatabaseSession
  ) async throws -> TableHealthReport {
    do {
      let probe = try await rows(in: session, sql: mysqlProbeSQL).first ?? []
      guard MySQLCatalogValue.int(probe, 1) == 2 else {
        return TableHealthReport(notes: [sysUnavailableNote])
      }
      var report = TableHealthReport(
        findings: try await mysqlRedundantIndexes(schema: schema, in: session))
      if MySQLCatalogValue.int(probe, 0) == 1 {
        report.findings += try await mysqlUnusedIndexes(schema: schema, in: session)
      } else {
        report.notes.append(performanceSchemaOffNote)
      }
      return report
    } catch {
      if error is CancellationError || Task.isCancelled { throw error }
      // Only the server's refusal (a view the user may see but not read: sys views read
      // performance_schema as the caller). A lost connection is an error, not this note.
      guard DatabaseConnectionManager.isServerRejection(error) else { throw error }
      return TableHealthReport(notes: [sysUnavailableNote])
    }
  }

  static func mysqlUnusedIndexes(
    schema: String, in session: any DatabaseSession
  ) async throws -> [TableHealthFinding] {
    try await rows(in: session, sql: mysqlUnusedIndexesSQL, binds: [.text(schema)]).compactMap {
      row in
      guard let table = MySQLCatalogValue.string(row, 0),
        let index = MySQLCatalogValue.string(row, 1)
      else { return nil }
      return TableHealthFinding(
        schema: schema, table: table, kind: .unusedIndex, objectName: index,
        reason: "Index \(index) has not been used since the server started, yet every write "
          + "still updates it.")
    }
  }

  static func mysqlRedundantIndexes(
    schema: String, in session: any DatabaseSession
  ) async throws -> [TableHealthFinding] {
    try await rows(in: session, sql: mysqlRedundantIndexesSQL, binds: [.text(schema)])
      .compactMap { row in
        guard let table = MySQLCatalogValue.string(row, 0),
          let index = MySQLCatalogValue.string(row, 1),
          let dominant = MySQLCatalogValue.string(row, 3)
        else { return nil }
        let columns = MySQLCatalogValue.string(row, 2).map { " (\($0))" } ?? ""
        let dominantColumns = MySQLCatalogValue.string(row, 4).map { " (\($0))" } ?? ""
        return TableHealthFinding(
          schema: schema, table: table, kind: .redundantIndex, objectName: index,
          reason: "Index \(index)\(columns) is redundant: \(dominant)\(dominantColumns) already "
            + "serves its lookups.")
      }
  }

  private static func rows(
    in session: any DatabaseSession, sql: String, binds: [SQLBindValue] = []
  ) async throws -> [[CellValue]] {
    var collected: [[CellValue]] = []
    for try await row in try await session.query(sql, binds: binds).rows {
      collected.append(row)
    }
    return collected
  }
}
