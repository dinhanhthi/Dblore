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

  /// The diagram of a large catalog shows a subset: saving it must not drop the others
  @Test("Saving a two-table subset keeps a third table's saved position")
  func subsetSaveKeepsOthers() {
    let key = "SchemaPositionsStoreTests-\(UUID().uuidString)"
    defer { SchemaPositionsStore.clearPositions(forConnection: key) }
    func position(_ name: String, _ x: CGFloat) -> SavedNodePosition {
      SavedNodePosition(tableQualifiedName: name, position: CGPoint(x: x, y: x + 1))
    }
    SchemaPositionsStore.savePositions(
      [position("public.a", 10), position("public.b", 20), position("public.c", 30)],
      forConnection: key)

    SchemaPositionsStore.savePositions(
      [position("public.a", 110), position("public.b", 120)], forConnection: key,
      keepingOthers: true)

    let saved = SchemaPositionsStore.loadPositions(forConnection: key)
    #expect(
      saved == [position("public.a", 110), position("public.b", 120), position("public.c", 30)])
  }

  /// Reset Layout on a subset: only the shown tables lose their saved positions
  @Test("Removing two tables' positions keeps a third table's")
  func removeSubsetKeepsOthers() {
    let key = "SchemaPositionsStoreTests-\(UUID().uuidString)"
    defer { SchemaPositionsStore.clearPositions(forConnection: key) }
    func position(_ name: String, _ x: CGFloat) -> SavedNodePosition {
      SavedNodePosition(tableQualifiedName: name, position: CGPoint(x: x, y: x + 1))
    }
    SchemaPositionsStore.savePositions(
      [position("public.a", 10), position("public.b", 20), position("public.c", 30)],
      forConnection: key)

    SchemaPositionsStore.removePositions(forTables: ["public.a", "public.b"], forConnection: key)

    #expect(SchemaPositionsStore.loadPositions(forConnection: key) == [position("public.c", 30)])
  }
}
