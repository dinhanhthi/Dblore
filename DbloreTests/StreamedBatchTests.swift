// StreamedBatchTests.swift
// The streamed batch of a Generate Rows run (`executeGatedBatch(streamed:)`): chunks made one at a
// time inside one transaction. A cancel, a failing chunk, a read-only connection and a relock leave
// the table as it was; progress counts chunks. A prelude (CREATE TABLE) and a postlude run in the
// same transaction: a failing postlude, a relock before it or a cancel leaves no table, and MySQL
// refuses DDL there before anything is sent, as is a prelude the policy forbids or with two
// statements. Real SQLite file in the temporary folder, no server (MySQL: a fake session). The
// cancel waits on a handshake from the chunk source, never on a timer.

import Foundation
import Testing
import os

@testable import Dblore

@Suite("Streamed batch")
struct StreamedBatchTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

  @Test(
    "A cancel between chunks rolls back every chunk sent", .timeLimit(.minutes(1)),
    arguments: [false, true])
  func cancelMidRun(protectedMode: Bool) async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let pause = BatchPause()
    let feed = ChunkFeed(try chunks([["a", "b"], ["c"]]), pauseBefore: 1, pause: pause)
    let epoch = await manager.connectionEpoch
    let policy = ProtectionPolicy(protectionLevel: .none, protectedMode: protectedMode)
    let run = Task {
      try await manager.executeGatedBatch(
        streamed: try source(feed), policy: policy, connectionEpoch: epoch)
    }
    await pause.waitUntilArrived()
    let status = await manager.runningStatementStatus()
    #expect(status.inFlight)
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    await pause.resume()
    do {
      _ = try await run.value
      Issue.record("Expected the cancelled run to stop")
    } catch DatabaseError.batchCancelled {
      // Every chunk sent must be rolled back below
    }
    #expect(try await rowCount(manager) == 0)
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("A chunk the server refuses or the source fails to make rolls back the run")
  func failingChunkRollsBack() async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let epoch = await manager.connectionEpoch
    // "b" again breaks the UNIQUE column in the second chunk
    let refused = ChunkFeed(try chunks([["a", "b"], ["b"]]))
    do {
      _ = try await manager.executeGatedBatch(
        streamed: try source(refused), policy: open, connectionEpoch: epoch)
      Issue.record("Expected the duplicate to fail the run")
    } catch DatabaseError.batchStatementFailed(let index, _, _, let rolledBack) {
      #expect(index == 1)
      #expect(rolledBack)
    }
    #expect(try await rowCount(manager) == 0)

    let failing = ChunkFeed(try chunks([["a", "b"]]), failAt: 1)
    await #expect(throws: ColumnValueGenerator.Error.self) {
      _ = try await manager.executeGatedBatch(
        streamed: try source(failing), policy: open, connectionEpoch: epoch)
    }
    #expect(try await rowCount(manager) == 0)
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("A read-only connection is refused before any chunk is made")
  func readOnlyRefusedFirst() async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let feed = ChunkFeed(try chunks([["a"]]))
    let epoch = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedBatch(
        streamed: try source(feed), policy: ProtectionPolicy(protectionLevel: .readOnly),
        connectionEpoch: epoch)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, let kind, let reason) {
      #expect(index == 0)
      #expect(kind == .dml)
      #expect(reason.contains("read-only"))
    }
    #expect(await feed.calls == 0)
    #expect(try await rowCount(manager) == 0)
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("A relocked connection is refused before any chunk is made")
  func relockedRefusedFirst() async throws {
    let registry = LockRegistry()
    let (manager, url) = try await connectedManager(lockSource: registry)
    defer { removeDatabase(url) }
    let feed = ChunkFeed(try chunks([["a"]]))
    let epoch = await manager.connectionEpoch
    let config = try #require(await manager.config)
    registry.setLockedConnections([LockIdentity(config)])
    do {
      _ = try await manager.executeGatedBatch(
        streamed: try source(feed), policy: open, connectionEpoch: epoch)
      Issue.record("Expected connectionLocked")
    } catch DatabaseError.connectionLocked {
      // Refused before the source was asked for a chunk
    }
    #expect(await feed.calls == 0)
    registry.setLockedConnections([])
    #expect(try await rowCount(manager) == 0)
    await manager.disconnect()
  }

  @Test("A relock before the postlude stops the run and leaves no table from the prelude")
  func relockBeforePostlude() async throws {
    let registry = LockRegistry()
    let (manager, url) = try await connectedManager(lockSource: registry)
    defer { removeDatabase(url) }
    let epoch = await manager.connectionEpoch
    let identity = LockIdentity(try #require(await manager.config))
    let feed = ChunkFeed(try chunks([["a"]], table: "u"))
    // The source relocks the connection once it has no chunk left
    let relocking = StreamedBatch(
      relation: try SQLDialect.sqlite.qualified(schema: nil, name: "u"),
      nextChunk: {
        let chunk = try await feed.next()
        if case .none = chunk { registry.setLockedConnections([identity]) }
        return chunk
      })
    do {
      _ = try await manager.executeGatedBatch(
        streamed: relocking, policy: open, connectionEpoch: epoch,
        prelude: [ddl("CREATE TABLE u (v TEXT)")],
        postlude: [ddl("CREATE INDEX u_v ON u (v)")])
      Issue.record("Expected connectionLocked")
    } catch DatabaseError.connectionLocked {
      // Refused before the postlude was sent
    }
    #expect(await feed.calls == 2)
    registry.setLockedConnections([])
    #expect(try await tableExists("u", manager) == false)
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("Progress counts each chunk once, in order, and Protected mode keeps one summary")
  func progressIsMonotonic() async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let feed = ChunkFeed(try chunks([["a", "b"], ["c"], ["d", "e", "f"]]))
    let epoch = await manager.connectionEpoch
    let reported = OSAllocatedUnfairLock(initialState: [Int]())
    let rows = try await manager.executeGatedBatch(
      streamed: try source(feed),
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true),
      connectionEpoch: epoch, progress: { done in reported.withLock { $0.append(done) } })
    #expect(rows == 6)
    #expect(reported.withLock { $0 } == [1, 2, 3])
    let pending = await manager.transactionSnapshot().pending
    #expect(pending.count == 1)
    #expect(pending.first?.kindLabel == "INSERT")
    #expect(pending.first?.affectedRows == 6)
    #expect(pending.first?.sql == #"INSERT INTO "t": 6 generated rows"#)
    #expect(try await rowCount(manager) == 6)
    try await manager.rollbackAppTransaction()
    #expect(try await rowCount(manager) == 0)
    await manager.disconnect()
  }

  @Test("A failing postlude rolls back the prelude's CREATE TABLE and every chunk")
  func failingPostludeRollsBackPrelude() async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let epoch = await manager.connectionEpoch
    let feed = ChunkFeed(try chunks([["a", "b"], ["c"]], table: "u"))
    do {
      _ = try await manager.executeGatedBatch(
        streamed: try source(feed, table: "u"), policy: open, connectionEpoch: epoch,
        prelude: [ddl("CREATE TABLE u (v TEXT)")],
        postlude: [ddl("CREATE INDEX u_missing ON u (missing)")])
      Issue.record("Expected the postlude to fail the run")
    } catch DatabaseError.batchStatementFailed(_, let sqlPrefix, _, let rolledBack) {
      #expect(sqlPrefix.hasPrefix("CREATE INDEX"))
      #expect(rolledBack)
    }
    #expect(await feed.calls == 3)
    #expect(try await tableExists("u", manager) == false)
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("A cancel mid-run leaves no table from the prelude", .timeLimit(.minutes(1)))
  func cancelLeavesNoPreludeTable() async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let pause = BatchPause()
    let feed = ChunkFeed(try chunks([["a"], ["b"]], table: "u"), pauseBefore: 1, pause: pause)
    let epoch = await manager.connectionEpoch
    let run = Task {
      try await manager.executeGatedBatch(
        streamed: try source(feed, table: "u"), policy: open, connectionEpoch: epoch,
        prelude: [ddl("CREATE TABLE u (v TEXT)")])
    }
    await pause.waitUntilArrived()
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    await pause.resume()
    await #expect(throws: DatabaseError.self) { _ = try await run.value }
    #expect(try await tableExists("u", manager) == false)
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test(
    "A prelude the policy forbids, or with two statements, is refused before anything is sent")
  func framingRefused() async throws {
    let (manager, url) = try await connectedManager()
    defer { removeDatabase(url) }
    let epoch = await manager.connectionEpoch
    let cases: [(ProtectionPolicy, String, String)] = [
      (ProtectionPolicy(protectionLevel: .schemaOnly), "CREATE TABLE u (v TEXT)", "Schema"),
      (open, "CREATE TABLE u (v TEXT); CREATE TABLE w (v TEXT)", "alone"),
    ]
    for (policy, prelude, expected) in cases {
      let feed = ChunkFeed(try chunks([["a"]], table: "u"))
      do {
        _ = try await manager.executeGatedBatch(
          streamed: try source(feed, table: "u"), policy: policy, connectionEpoch: epoch,
          prelude: [ddl(prelude)])
        Issue.record("Expected blockedByProtection")
      } catch DatabaseError.blockedByProtection(let index, _, let reason) {
        #expect(index == 0)
        #expect(reason.contains(expected), "\(reason)")
      }
      #expect(await feed.calls == 0)
      #expect(try await tableExists("u", manager) == false)
    }
    // The read-only refusal names the run's operation
    let feed = ChunkFeed(try chunks([["a"]]))
    var copy = try source(feed)
    copy.operation = "Copying rows"
    do {
      _ = try await manager.executeGatedBatch(
        streamed: copy, policy: ProtectionPolicy(protectionLevel: .readOnly),
        connectionEpoch: epoch)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(_, _, let reason) {
      #expect(reason == "Copying rows is not allowed on a read-only connection")
    }
    #expect(await manager.transactionSnapshot().isIdle)
    await manager.disconnect()
  }

  @Test("MySQL refuses DDL in the prelude before anything is sent")
  func mysqlPreludeDDLRefused() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.mysql.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .mysql, host: "fake", port: 3306, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    let sentBefore = factory.statements
    let feed = ChunkFeed([])
    let epoch = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedBatch(
        streamed: StreamedBatch(
          relation: try SQLDialect.mysql.qualified(schema: nil, name: "u"),
          nextChunk: { try await feed.next() }),
        policy: open, connectionEpoch: epoch, prelude: [ddl("CREATE TABLE u (v TEXT)")])
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, let kind, let reason) {
      #expect(index == 0)
      #expect(kind == .ddl)
      #expect(reason.contains("commits implicitly"))
    }
    #expect(await feed.calls == 0)
    #expect(factory.statements == sentBefore)
    await manager.disconnect()
  }

  // MARK: - Helpers

  private func ddl(_ sql: String) -> BoundStatement {
    BoundStatement(sql: sql, values: [], expectedRows: nil)
  }

  private func tableExists(
    _ name: String, _ manager: DatabaseConnectionManager
  ) async throws -> Bool {
    let result = try await manager.executeInternal(
      "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'")
    guard case .int(let count) = result.rows.first?.first else { return true }
    return count > 0
  }

  private func connectedManager(
    lockSource: LockRegistry = LockRegistry()
  ) async throws -> (DatabaseConnectionManager, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-streamed-\(UUID().uuidString).sqlite")
    let manager = DatabaseConnectionManager(lockSource: lockSource)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    _ = try await manager.executeInternal("CREATE TABLE t (v TEXT UNIQUE)")
    return (manager, url)
  }

  private func removeDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  private func chunks(_ values: [[String]], table: String = "t") throws -> [[BoundStatement]] {
    try values.map { chunk in
      try ImportSQLBuilder.insertStatements(
        schema: nil, table: table, columns: ["v"], rows: chunk.map { [$0] }, dialect: .sqlite)
    }
  }

  private func source(_ feed: ChunkFeed, table: String = "t") throws -> StreamedBatch {
    StreamedBatch(
      relation: try SQLDialect.sqlite.qualified(schema: nil, name: table),
      nextChunk: { try await feed.next() })
  }

  private func rowCount(_ manager: DatabaseConnectionManager) async throws -> Int {
    let result = try await manager.executeInternal("SELECT count(*) FROM t")
    guard case .int(let count) = result.rows.first?.first else { return -1 }
    return count
  }
}

/// The chunks of a run, handed out one per call; optionally pausing before one or failing at one
private actor ChunkFeed {
  private let chunks: [[BoundStatement]]
  private let pauseBefore: Int?
  private let pause: BatchPause?
  private let failAt: Int?
  private(set) var calls = 0

  init(
    _ chunks: [[BoundStatement]], pauseBefore: Int? = nil, pause: BatchPause? = nil,
    failAt: Int? = nil
  ) {
    self.chunks = chunks
    self.pauseBefore = pauseBefore
    self.pause = pause
    self.failAt = failAt
  }

  func next() async throws -> [BoundStatement]? {
    let index = calls
    calls += 1
    if index == pauseBefore { await pause?.checkpoint() }
    if index == failAt { throw ColumnValueGenerator.Error.uniqueValuesExhausted(column: "v") }
    return index < chunks.count ? chunks[index] : nil
  }
}

private actor BatchPause {
  private var arrived = false
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?

  func checkpoint() async {
    arrived = true
    arrivalWaiter?.resume()
    arrivalWaiter = nil
    await withCheckedContinuation { resumeWaiter = $0 }
  }

  func waitUntilArrived() async {
    if arrived { return }
    await withCheckedContinuation { arrivalWaiter = $0 }
  }

  func resume() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }
}
