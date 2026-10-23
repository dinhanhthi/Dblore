// RewindRoundTripTests.swift
// Data Rewind end to end on a temporary SQLite file: a staged update, delete and insert with an
// explicit key, committed through the gate with their plan, then rewound through the gate from
// the store, put every row back exactly (`quote()` text, so REAL precision, blobs and NULL);
// a row changed in between rolls the whole rewind back.

import Foundation
import Testing

@testable import Dblore

@Suite("RewindRoundTripTests", .serialized)
@MainActor
struct RewindRoundTripTests {
  private static let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private static let columns = [
    ColumnInfo(name: "id", type: "INTEGER"), ColumnInfo(name: "label", type: "TEXT"),
    ColumnInfo(name: "score", type: "REAL"), ColumnInfo(name: "data", type: "BLOB"),
  ]

  @Test("Committed staged edits rewound from the store restore the original rows exactly")
  func rewindRestoresTheRows() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let original = try await fixture.snapshot()
    try await fixture.commitStagedEdits()
    #expect(try await fixture.snapshot() != original)

    let plan = try await fixture.plan()
    let counts = try await fixture.manager.executeGatedBatch(
      plan.statements, policy: Self.open, connectionEpoch: fixture.manager.connectionEpoch,
      rewinding: plan.entryIDs)

    #expect(counts == [1, 1, 1])
    #expect(try await fixture.snapshot() == original)
    await fixture.recorder.flushed()
    #expect(try fixture.store.entries(connectionKey: nil).map(\.state) == [.rewound])
  }

  @Test("A row changed after the edit rolls the whole rewind back")
  func conflictRollsBack() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    try await fixture.commitStagedEdits()
    _ = try await fixture.manager.executeInternal("UPDATE items SET label = 'other' WHERE id = 1")
    let changed = try await fixture.snapshot()

    let plan = try await fixture.plan()
    await #expect(throws: DatabaseError.self) {
      try await fixture.manager.executeGatedBatch(
        plan.statements, policy: Self.open, connectionEpoch: fixture.manager.connectionEpoch,
        rewinding: plan.entryIDs)
    }

    // The undo of the insert and of the delete ran before the conflict: both rolled back
    #expect(try await fixture.snapshot() == changed)
    await fixture.recorder.flushed()
    #expect(try fixture.store.entries(connectionKey: nil).map(\.state) == [.committed])
  }

  @MainActor
  private final class Fixture {
    let directory: URL
    let manager = DatabaseConnectionManager()
    let store: RewindStore
    let recorder: RewindRecorder

    init() async throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dblore-rewind-trip-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try await manager.connect(
        config: ConnectionConfig(
          databaseType: .sqlite, database: directory.appendingPathComponent("db.sqlite").path,
          username: "", protectionLevel: .none, safeMode: .silent, protectedMode: false))
      for statement in [
        "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, score REAL, data BLOB)",
        "INSERT INTO items VALUES (1, 'a', 0.1 + 0.2, X'00FF'), (2, NULL, 1e300, X''),"
          + " (3, 'c''s', NULL, NULL)",
      ] {
        _ = try await manager.executeInternal(statement)
      }
      store = try RewindStore(url: directory.appendingPathComponent("rewind.sqlite"))
      recorder = RewindRecorder(store: store)
      await manager.setRewindRecorder(recorder)
    }

    /// Every row as `quote()` text, so the storage class and every digit count
    func snapshot() async throws -> [[CellValue]] {
      try await manager.executeInternal(
        "SELECT quote(id), quote(label), quote(score), quote(data) FROM items ORDER BY id"
      ).rows
    }

    /// Update row 1, delete row 2, insert row 10 (explicit key), committed with their plan
    func commitStagedEdits() async throws {
      let table = try #require(
        try await manager.fetchEditTable(
          tableName: "main.items", tableID: .sqlite(schema: "main", table: "items")))
      let target = EditTarget(
        qualifiedName: table.qualifiedName, tableID: table.resolvedTableRef,
        primaryKeyColumns: table.primaryKeyColumns, connectionEpoch: table.connectionEpoch,
        schema: table.schema, name: table.name)
      var set = RowChangeSet(target: target)
      try set.stageEdit(
        row: RowChangeSet.RowKey(values: [.int(1)]), column: "label", value: .string("z"),
        original: .string("a"))
      try set.stageEdit(
        row: RowChangeSet.RowKey(values: [.int(1)]), column: "score", value: .double(2.5),
        original: .double(0.30000000000000004))
      set.stageDelete(row: RowChangeSet.RowKey(values: [.int(2)]))
      set.stageInsert(values: ["id": .int(10), "label": .string("n"), "score": .double(0.1)])
      let columns = RewindRoundTripTests.columns
      let plan = try #require(
        RewindPlan.make(
          target: target, resultColumns: columns, editKind: .staged,
          steps: try RowChangeSQLBuilder.rewindSteps(
            for: set, target: target, columns: columns, dialect: .sqlite),
          engine: .sqlite, enabled: true))
      _ = try await manager.executeGatedBatch(
        try RowChangeSQLBuilder.statements(
          for: set, target: target, columns: columns, dialect: .sqlite),
        policy: RewindRoundTripTests.open, connectionEpoch: target.connectionEpoch, rewind: plan)
    }

    /// The inverse of every stored entry, against the live table
    func plan() async throws -> RewindInverse {
      await recorder.flushed()
      let entries = try store.entries(connectionKey: nil)
      let structure = try await manager.fetchTableStructure(schema: "main", table: "items")
      return try RewindPlanner.plan(
        try entries.map { (entry: $0, rows: try store.rows(entryID: $0.id)) },
        tables: [RewindTableName(schema: "main", table: "items"): RewindTable(structure)],
        engine: .sqlite)
    }

    func remove() {
      let manager = manager
      let directory = directory
      Task {
        await manager.disconnect()
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }
}
