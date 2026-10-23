// RewindTypedStatementTests.swift
// Data Rewind entries inside the user's transaction when a typed statement fails, against a
// temporary SQLite file whose session can fail a statement with a MySQL error: a deadlock
// (ER_LOCK_DEADLOCK) rolls the server transaction back whole, a lock wait timeout does not.

import Foundation
import Testing

@testable import Dblore

@Suite("Rewind typed statement", .serialized)
@MainActor
struct RewindTypedStatementTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test("A typed statement deadlock inside the user's transaction discards its entries")
  func typedDeadlockDiscardsEntries() async throws {
    let deadlock = MySQLSessionError(code: 1213, sqlState: "40001", message: "Deadlock found")
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
    try await fixture.inlineEdit(id: 2, label: "x")
    let earlier = try await fixture.newestEntry()
    fixture.factory.intercept { sql in
      if sql.hasPrefix("UPDATE") { throw deadlock }
    }

    await #expect(throws: (any Error).self) {
      _ = try await fixture.manager.execute(
        userSQL: "UPDATE items SET label = 'z' WHERE id = 1", policy: self.open)
    }

    #expect(try await fixture.state(of: earlier.id) == .discarded)
    #expect(await fixture.recorder.openEntryIDs().isEmpty)
    #expect(await fixture.manager.userTxOpen == false)
    // The user's COMMIT (answered OK by MySQL, with no transaction left) changes nothing
    fixture.factory.intercept { _ in }
    _ = try await fixture.manager.execute(userSQL: "COMMIT", policy: open)
    #expect(try await fixture.state(of: earlier.id) == .discarded)
    await fixture.manager.disconnect()
  }

  @Test("A typed statement lock wait timeout keeps the user's transaction and its entries")
  func typedLockWaitTimeoutKeepsEntries() async throws {
    let timeout = MySQLSessionError(code: 1205, sqlState: "HY000", message: "Lock wait timeout")
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    _ = try await fixture.manager.execute(userSQL: "BEGIN", policy: open)
    try await fixture.inlineEdit(id: 2, label: "x")
    let earlier = try await fixture.newestEntry()
    fixture.factory.intercept { sql in
      if sql.hasPrefix("UPDATE") { throw timeout }
    }

    await #expect(throws: (any Error).self) {
      _ = try await fixture.manager.execute(
        userSQL: "UPDATE items SET label = 'z' WHERE id = 1", policy: self.open)
    }

    #expect(try await fixture.state(of: earlier.id) == .pending)
    #expect(await fixture.recorder.openEntryIDs() == [earlier.id])
    #expect(await fixture.manager.userTxOpen)
    await fixture.manager.disconnect()
  }
}

// MARK: - Fixture

/// A temporary `items (id INTEGER PRIMARY KEY, label TEXT)` file with rows (1, 'a'), (2, NULL),
/// a connected manager whose session can fail a statement, and a temporary rewind store.
@MainActor
private struct Fixture {
  let databaseURL: URL
  let storeURL: URL
  let factory: InterceptingSessionFactory
  let manager: DatabaseConnectionManager
  let store: RewindStore
  let recorder: RewindRecorder

  static func make() async throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
    let databaseURL = directory.appendingPathComponent("dblore-typed-\(UUID().uuidString).sqlite")
    let storeURL = directory.appendingPathComponent(
      "dblore-typed-store-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: databaseURL)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("INSERT INTO items VALUES (1, 'a'), (2, NULL)")
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: databaseURL.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    let factory = InterceptingSessionFactory()
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    let store = try RewindStore(url: storeURL)
    let recorder = RewindRecorder(store: store)
    await manager.setRewindRecorder(recorder)
    return Fixture(
      databaseURL: databaseURL, storeURL: storeURL, factory: factory, manager: manager,
      store: store, recorder: recorder)
  }

  /// One inline edit of `label` with its plan, through the gate (records a Data Rewind entry)
  func inlineEdit(id: Int, label: String) async throws {
    let table = try #require(
      try await manager.fetchEditTable(
        tableName: "main.items", tableID: .sqlite(schema: "main", table: "items")))
    let target = EditTarget(
      qualifiedName: table.qualifiedName, tableID: table.resolvedTableRef,
      primaryKeyColumns: table.primaryKeyColumns, connectionEpoch: table.connectionEpoch,
      schema: table.schema, name: table.name)
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: label,
      primaryKeyColumns: ["id"], rowData: ["id": .int(id)], dialect: .sqlite)
    let plan = try #require(
      RewindPlan.make(
        target: target,
        resultColumns: [
          ColumnInfo(name: "id", type: "INTEGER"), .init(name: "label", type: "TEXT"),
        ],
        editKind: .inline,
        steps: [
          RewindPlan.inlineStep(
            assignments: [(column: "label", value: label)], primaryKeyColumns: ["id"],
            rowData: ["id": .int(id)])
        ].compactMap { $0 },
        engine: .sqlite, enabled: true))
    _ = try await manager.executeGatedUpdate(
      edit, policy: ProtectionPolicy(protectionLevel: .none),
      connectionEpoch: target.connectionEpoch, rewind: plan)
  }

  func newestEntry() async throws -> RewindEntry {
    await recorder.flushed()
    return try #require(try store.entries(connectionKey: nil).first)
  }

  func state(of id: Int64) async throws -> RewindEntry.State? {
    await recorder.flushed()
    return try store.entries(connectionKey: nil).first { $0.id == id }?.state
  }

  /// Deletes the database and store files (the test disconnects the manager first)
  func removeFiles() {
    for url in [databaseURL, storeURL] {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
  }
}

/// Real SQLite sessions whose statements can be failed before they are sent.
private final class InterceptingSessionFactory: DatabaseSessionFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var interceptor: (@Sendable (String) async throws -> Void)?

  /// Runs before each statement is sent; throwing fails it without sending it
  func intercept(_ body: @escaping @Sendable (String) async throws -> Void) {
    lock.withLock { interceptor = body }
  }

  func check(_ sql: String) async throws -> String {
    let body = lock.withLock { interceptor }
    try await body?(sql)
    return sql
  }

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    InterceptingSession(inner: SQLiteSession(config: config), factory: self)
  }
}

private final class InterceptingSession: DatabaseSession, @unchecked Sendable {
  let inner: any DatabaseSession
  let factory: InterceptingSessionFactory

  init(inner: any DatabaseSession, factory: InterceptingSessionFactory) {
    self.inner = inner
    self.factory = factory
  }

  var capabilities: DatabaseCapabilities { inner.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { inner.closeEvents }

  func open() async throws { try await inner.open() }
  func close() async { await inner.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    try await inner.query(factory.check(sql), binds: binds)
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await inner.command(factory.check(sql), binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await inner.openCursor(factory.check(sql), binds: binds)
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    try await inner.fetch(cursor, maxRows: maxRows)
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    try await inner.closeCursor(cursor)
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await inner.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async { await inner.interrupt() }

  func formatError(_ error: Error) -> String { inner.formatError(error) }
}
