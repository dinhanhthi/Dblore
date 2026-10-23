// SQLiteInterruptTransactionTests.swift
// An interrupt cancel inside a transaction opened with BEGIN: SQLite rolls the whole transaction
// back when the interrupted statement was writing and keeps it when it was reading. The manager
// state and the cancel message follow what SQLite reports (`sqlite3_get_autocommit`), not an
// engine constant. In Protected mode the pending app transaction goes the same way, with its
// Data Rewind entries. Real SQLite file in the temporary folder, no server.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite interrupt inside a transaction", .serialized)
struct SQLiteInterruptTransactionTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  /// Runs far longer than any test waits (an interrupt stops it)
  private static let longWrite = """
    INSERT INTO t WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 1000000000)
    SELECT x FROM c
    """
  private static let longRead = """
    WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 1000000000)
    SELECT max(x) FROM c
    """

  @Test("An interrupted write rolls back the open transaction: no open transaction is left")
  func interruptedWriteEndsTransaction() async throws {
    let (connection, url) = try await connectInTransaction()
    defer { try? FileManager.default.removeItem(at: url) }

    let error = try await interrupt(Self.longWrite, on: connection)
    guard case .queryCancelled(_, let rolledBack, let kept) = error else {
      Issue.record("Expected queryCancelled, got \(error)")
      return
    }
    #expect(rolledBack)
    // The interrupt kept the session: nothing says it was reset
    #expect(kept)
    #expect(error.localizedDescription == "Query cancelled. Your open transaction was rolled back.")
    #expect(await connection.runningStatementStatus().userTxOpen == false)
    // The row inserted before the interrupt went with the transaction
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(0)]])
    await connection.disconnect()
  }

  @Test("An interrupted read keeps the open transaction and says so")
  func interruptedReadKeepsTransaction() async throws {
    let (connection, url) = try await connectInTransaction()
    defer { try? FileManager.default.removeItem(at: url) }

    let error = try await interrupt(Self.longRead, on: connection)
    guard case .queryCancelled(_, let rolledBack, let kept) = error else {
      Issue.record("Expected queryCancelled, got \(error)")
      return
    }
    #expect(!rolledBack)
    #expect(kept)
    #expect(error.localizedDescription == "Query cancelled. The connection was kept.")
    #expect(await connection.runningStatementStatus().userTxOpen)
    _ = try await connection.execute(userSQL: "COMMIT", policy: open)
    #expect(await connection.runningStatementStatus().userTxOpen == false)
    let count = try await connection.execute(userSQL: "SELECT count(*) FROM t", policy: open)
    #expect(count.rows == [[.int(1)]])
    await connection.disconnect()
  }

  @Test("Protected mode: an interrupted write rolls back the pending change and its entry")
  @MainActor
  func protectedInterruptedWriteDiscardsPending() async throws {
    let directory = FileManager.default.temporaryDirectory
    let url = directory.appendingPathComponent("dblore-interrupt-app-\(UUID().uuidString).sqlite")
    let storeURL = directory.appendingPathComponent(
      "dblore-interrupt-store-\(UUID().uuidString).sqlite")
    defer {
      for file in [url, storeURL] {
        for suffix in ["", "-wal", "-shm", "-journal"] {
          try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + suffix))
        }
      }
    }
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE t (x INTEGER)")
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)")
    try handle.execute("INSERT INTO items VALUES (1, 'a')")
    let connection = DatabaseConnectionManager()
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: true, statementTimeoutSeconds: 30))
    let store = try RewindStore(url: storeURL)
    let recorder = RewindRecorder(store: store)
    await connection.setRewindRecorder(recorder)
    try await stageInlineEdit(on: connection)
    #expect(await connection.transactionSnapshot().pending.count == 1)
    await recorder.flushed()
    let entry = try #require(try store.entries(connectionKey: nil).first)
    #expect(entry.state == .pending)

    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    let error = try await interrupt(Self.longWrite, on: connection, policy: protected)
    #expect(error.localizedDescription == "Query cancelled. 1 pending change was rolled back.")
    #expect(await connection.transactionSnapshot().isIdle)
    await recorder.flushed()
    #expect(try store.entries(connectionKey: nil).first { $0.id == entry.id }?.state == .discarded)
    let label = try await connection.executeInternal("SELECT label FROM items WHERE id = 1")
    #expect(label.rows == [[.string("a")]])
    await connection.disconnect()
  }

  // MARK: - Helpers

  /// One staged inline edit of `items` row 1 with its Data Rewind plan
  private func stageInlineEdit(on connection: DatabaseConnectionManager) async throws {
    let table = try #require(
      try await connection.fetchEditTable(
        tableName: "main.items", tableID: .sqlite(schema: "main", table: "items")))
    let target = EditTarget(
      qualifiedName: table.qualifiedName, tableID: table.resolvedTableRef,
      primaryKeyColumns: table.primaryKeyColumns, connectionEpoch: table.connectionEpoch,
      schema: table.schema, name: table.name)
    let edit = try CellUpdateStatement.make(
      qualifiedName: target.qualifiedName, columnName: "label", newValue: "x",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1)], dialect: .sqlite)
    let plan = try #require(
      RewindPlan.make(
        target: target,
        resultColumns: [
          ColumnInfo(name: "id", type: "INTEGER"), .init(name: "label", type: "TEXT"),
        ],
        editKind: .inline,
        steps: [
          RewindPlan.inlineStep(
            assignments: [(column: "label", value: "x")], primaryKeyColumns: ["id"],
            rowData: ["id": .int(1)])
        ].compactMap { $0 },
        engine: .sqlite, enabled: true))
    _ = try await connection.executeGatedUpdate(
      edit, policy: ProtectionPolicy(protectionLevel: .none),
      connectionEpoch: target.connectionEpoch, rewind: plan)
  }

  /// A SQLite file with table `t`, a transaction opened with BEGIN and one row inserted in it
  private func connectInTransaction() async throws -> (DatabaseConnectionManager, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-interrupt-tx-\(UUID().uuidString).sqlite")
    let connection = DatabaseConnectionManager()
    try await connection.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: false, statementTimeoutSeconds: 30))
    _ = try await connection.execute(userSQL: "CREATE TABLE t (x INTEGER)", policy: open)
    _ = try await connection.execute(userSQL: "BEGIN", policy: open)
    _ = try await connection.execute(userSQL: "INSERT INTO t VALUES (1)", policy: open)
    #expect(await connection.runningStatementStatus().userTxOpen)
    return (connection, url)
  }

  /// Runs `sql`, cancels it once while SQLite is inside the statement, and returns the error.
  /// One cancel only: a second interrupt could land on the next statement.
  private func interrupt(
    _ sql: String, on connection: DatabaseConnectionManager, policy: ProtectionPolicy? = nil
  ) async throws -> DatabaseError {
    let policy = policy ?? open
    let running = Task { try await connection.execute(userSQL: sql, policy: policy) }
    var status = await connection.runningStatementStatus()
    while !status.inFlight {
      try await Task.sleep(for: .milliseconds(10))
      status = await connection.runningStatementStatus()
    }
    try await Task.sleep(for: .milliseconds(300))
    let outcome = await connection.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let error = await #expect(throws: DatabaseError.self) { try await running.value }
    return try #require(error)
  }
}
