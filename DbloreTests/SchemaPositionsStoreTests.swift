// SchemaPositionsStoreTests.swift
// ER-diagram position keys: PostgreSQL, SQLite and DuckDB keep the legacy `host:port/database`
// key byte for byte; MySQL keys carry the engine, so the same tuple never shares positions.

import Foundation
import Testing

@testable import Dblore

@Suite("Schema positions store")
@MainActor
struct SchemaPositionsStoreTests {
  private static func config(_ type: DatabaseType) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: "db.example", port: 3306, database: "app", username: "ada")
  }

  @Test(
    "Legacy engines keep the host:port/database key",
    arguments: [
      DatabaseType.postgresql, .sqlite, .duckdb,
    ])
  func legacyKeyUnchanged(type: DatabaseType) {
    #expect(SchemaPositionsStore.connectionKey(from: Self.config(type)) == "db.example:3306/app")
  }
}
