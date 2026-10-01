//
//  DatabaseConnectionManager+ColumnTypes.swift
//  Dblore
//
//  Column type enrichment (precision, scale, length) from information_schema
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Column Type Enrichment

  /// Enrich column type information with modifiers (precision, scale, length)
  /// Uses information_schema to get detailed type info. Skipped (driver types kept) while the
  /// app transaction is pending: a failing catalog query would abort it.
  func enrichColumnTypes(columns: [ColumnInfo], query: String) async -> [ColumnInfo] {
    // Only proceed if we have columns and connection
    guard !columns.isEmpty, !isMetadataPaused, _postgresConnection != nil,
      databaseType == .postgresql,
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
}
