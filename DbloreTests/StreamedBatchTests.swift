// StreamedBatchTests.swift
// The streamed batch of a Generate Rows run (`executeGatedBatch(streamed:)`): chunks made one at
// a time inside one transaction. A cancel, a failing chunk, a read-only connection and a relock
// leave the table as it was; progress counts chunks. Real SQLite file in the temporary folder,
// no server. The cancel waits on a handshake from the chunk source, never on a timer.

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

  // MARK: - Helpers

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

  private func chunks(_ values: [[String]]) throws -> [[BoundStatement]] {
    try values.map { chunk in
      try ImportSQLBuilder.insertStatements(
        schema: nil, table: "t", columns: ["v"], rows: chunk.map { [$0] }, dialect: .sqlite)
    }
  }

  private func source(_ feed: ChunkFeed) throws -> StreamedBatch {
    StreamedBatch(
      relation: try SQLDialect.sqlite.qualified(schema: nil, name: "t"),
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
