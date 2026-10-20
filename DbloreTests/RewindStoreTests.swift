// RewindStoreTests.swift
// The Data Rewind store keeps entries and row images in its own SQLite file, moves entries
// through validated states, and prunes by age and size.

import Foundation
import SQLite3
import Testing

@testable import Dblore

@Suite("Rewind store", .serialized)
struct RewindStoreTests {
  @Test("An entry and its rows round-trip, NULL stays apart from the text NULL")
  func entryRoundTrip() throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try RewindStore(url: url)
    let rows = [
      RewindRow(
        operation: .update, primaryKey: ["id": "1"],
        before: ["id": "1", "name": "NULL", "note": nil, "empty": ""],
        after: ["id": "1", "name": "x", "note": nil, "empty": ""]),
      RewindRow(
        operation: .delete, primaryKey: ["id": "2"], before: ["id": "2", "name": "b"],
        after: nil),
      RewindRow(operation: .insert, primaryKey: [:], before: nil, after: nil),
    ]
    let id = try store.record(Self.entry(), rows: rows)

    let entries = try store.entries(connectionKey: Self.key)
    #expect(entries.count == 1)
    var expected = Self.entry()
    expected.id = id
    #expect(entries.first == expected)
    #expect(try store.rows(entryID: id) == rows)
    let stored = try #require(try store.rows(entryID: id).first?.before)
    #expect(stored["name"] == .some("NULL"))
    #expect(stored["note"] == .some(nil))
    #expect(try store.entries(connectionKey: "PostgreSQL|other|5432|db").isEmpty)

    let handle = try SQLiteHandle(url: url)
    #expect(handle.userVersion == 1)
  }

  @Test("State changes follow the lifecycle and a refused change leaves every entry as it was")
  func stateTransitions() throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try RewindStore(url: url)
    let first = try store.record(Self.entry(), rows: [])
    let second = try store.record(Self.entry(), rows: [])

    try store.setState(.committed, ids: [first])
    try store.setState(.rewound, ids: [first])
    // A rewind under Protected mode that rolls back goes back to committed
    try store.setState(.committed, ids: [first])
    #expect(throws: RewindStoreError.invalidTransition(from: .committed, to: .pending)) {
      try store.setState(.pending, ids: [second, first])
    }
    try store.setState(.discarded, ids: [second])
    #expect(throws: RewindStoreError.invalidTransition(from: .discarded, to: .committed)) {
      try store.setState(.committed, ids: [second])
    }

    let states = Dictionary(
      uniqueKeysWithValues: try store.entries(connectionKey: Self.key).map { ($0.id, $0.state) })
    #expect(states == [first: .committed, second: .discarded])
  }

  @Test("Prune drops entries past the retention days, then the oldest past the size cap")
  func pruneByAgeAndSize() throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day: TimeInterval = 24 * 60 * 60
    let row = RewindRow(
      operation: .delete, primaryKey: ["id": "1"],
      before: ["id": "1", "body": String(repeating: "x", count: 400)], after: nil)
    let store = try RewindStore(url: url, maxBytes: 1_000)
    let old = try store.record(Self.entry(created: now.addingTimeInterval(-40 * day)), rows: [])
    let older = try store.record(Self.entry(created: now.addingTimeInterval(-3 * day)), rows: [row])
    let recent = try store.record(
      Self.entry(created: now.addingTimeInterval(-2 * day)), rows: [row])

    try store.prune(retentionDays: 30, now: now)
    #expect(Set(try store.entries(connectionKey: nil).map(\.id)) == [older, recent])
    #expect(!(try store.entries(connectionKey: nil).map(\.id)).contains(old))

    // Each row image is over 400 bytes; a third one passes 1,000, so the oldest goes
    let newest = try store.record(Self.entry(created: now.addingTimeInterval(-day)), rows: [row])
    #expect(Set(try store.entries(connectionKey: nil).map(\.id)) == [recent, newest])
    #expect(try store.rows(entryID: older).isEmpty)
  }

  @Test("The size cap in prune keeps the newest entry, as record does")
  func pruneKeepsNewestEntry() throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let row = RewindRow(
      operation: .delete, primaryKey: ["id": "1"],
      before: ["id": "1", "body": String(repeating: "x", count: 400)], after: nil)
    let store = try RewindStore(url: url, maxBytes: 100)
    let id = try store.record(Self.entry(created: now), rows: [row])

    try store.prune(retentionDays: 30, now: now)

    #expect(try store.entries(connectionKey: nil).map(\.id) == [id])
  }

  @Test("Pruned row images leave no readable bytes in the file or its WAL")
  func pruneScrubsDeletedRows() throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let marker = "dblore-rewind-marker-7f3a9c"
    let store = try RewindStore(url: url)
    try store.record(
      Self.entry(created: now.addingTimeInterval(-40 * 24 * 60 * 60)),
      rows: [
        RewindRow(
          operation: .delete, primaryKey: ["id": "1"], before: ["id": "1", "body": marker],
          after: nil)
      ])

    try store.prune(retentionDays: 30, now: now)

    #expect(try store.count() == 0)
    for path in [url.path, url.path + "-wal"] where FileManager.default.fileExists(atPath: path) {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
      #expect(bytes.range(of: Data(marker.utf8)) == nil, "marker found in \(path)")
    }
  }

  @Test("The store directory is private to the user and excluded from backups")
  func directoryIsPrivateAndNotBackedUp() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-rewind-dir-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // An existing directory with looser permissions is tightened
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

    try RewindStore.prepareDirectory(directory)

    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let fresh = URL(fileURLWithPath: directory.path, isDirectory: true)
    let values = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test("deleteAll removes every entry and row and shrinks the file")
  func deleteAllEmptiesTheFile() throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let store = try RewindStore(url: url)
    let big = RewindRow(
      operation: .delete, primaryKey: ["id": "1"],
      before: ["body": String(repeating: "y", count: 200_000)], after: nil)
    let id = try store.record(Self.entry(), rows: [big])
    let grown = try store.fileSize()

    try store.deleteAll()

    #expect(try store.count() == 0)
    #expect(try store.rows(entryID: id).isEmpty)
    #expect(try store.fileSize() < grown)
  }

  // MARK: - Fixtures

  private static let key = "PostgreSQL|localhost|5432|app"

  private static func entry(
    created: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> RewindEntry {
    RewindEntry(
      id: 0, connectionKey: key, schema: "public", table: "people",
      qualifiedName: "public.people", engine: .postgresql, created: created, state: .pending,
      editKind: .staged, statementCount: 3,
      columns: [
        RewindColumn(name: "id", typeName: "int4"), RewindColumn(name: "name", typeName: "text"),
      ],
      notCaptured: true, notRewindableReason: "generated key")
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-rewind-\(UUID().uuidString).sqlite")
  }

  private func removeDatabase(at url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }
}
