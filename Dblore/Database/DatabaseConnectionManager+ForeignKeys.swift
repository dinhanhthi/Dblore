//
//  DatabaseConnectionManager+ForeignKeys.swift
//  Dblore
//
//  Foreign key introspection methods for DatabaseConnectionManager
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Foreign Key Introspection

  /// Fetch all foreign key relationships from the database, through the connected engine's
  /// introspector (pg_constraint on PostgreSQL; information_schema KEY_COLUMN_USAGE and
  /// REFERENTIAL_CONSTRAINTS on MySQL)
  func fetchForeignKeys() async throws -> [ForeignKey] {
    try await fetchCatalog("foreign keys") { session in
      try await self.introspector.foreignKeys(in: session)
    }
  }
}
