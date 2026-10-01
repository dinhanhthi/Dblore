//
//  DatabaseConnectionManager+ForeignKeys.swift
//  Dblore
//
//  Foreign key introspection methods for DatabaseConnectionManager
//

import Foundation

extension DatabaseConnectionManager {
  // MARK: - Foreign Key Introspection

  /// Fetch all foreign key relationships from the database
  /// Queries pg_constraint system catalog for foreign key constraints
  func fetchForeignKeys() async throws -> [ForeignKey] {
    try await fetchCatalog("foreign keys") { session in
      try await self.introspector.foreignKeys(in: session)
    }
  }
}
