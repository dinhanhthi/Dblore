// MongoManagerTests.swift
// MongoDB through DatabaseConnectionManager with the real session factory (MongoSession) against
// the docker fixture (mongo:8.0 on 27018, users in `admin`): the row cap and its truncated flag
// on 1,000 documents, write counts, countDocuments and distinct, a maxTimeMS timeout and a
// killOp cancel that keeps the connection. Opt-in (`.requiresMongo`), serialized; every
// collection is dropped before and after its test. Collections use `manager_`.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoManagerTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  /// Runs `body` with a manager connected to the plain fixture (with `statementTimeout`, if
  /// set) and an empty `collection`, then disconnects and drops it.
  private func withManager(
    _ collection: String, statementTimeout: Int? = nil,
    _ body: (DatabaseConnectionManager) async throws -> Void
  ) async throws {
    await MongoSessionTests.drop(collection)
    var config = MongoSessionTests.config()
    config.statementTimeoutSeconds = statementTimeout
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: config)
      #expect(await manager.session is MongoSession)
      try await body(manager)
    } catch {
      await manager.disconnect()
      await MongoSessionTests.drop(collection)
      throw error
    }
    await manager.disconnect()
    await MongoSessionTests.drop(collection)
  }

  private func run(
    _ manager: DatabaseConnectionManager, _ text: String, maxRows: Int = 1_000
  ) async throws -> QueryResult {
    try await manager.execute(userSQL: text, policy: open, maxRows: maxRows)
  }

  // MARK: - Row cap

  @Test("1,000 documents: reads stop at the cap with the truncated flag", .requiresMongo)
  func capOnThousandDocuments() async throws {
    let name = "manager_cap"
    try await withManager(name) { manager in
      let documents = (0..<1_000).map { "{_id: \($0), g: \($0 % 2)}" }.joined(separator: ", ")
      let seeded = try await run(manager, "db.\(name).insertMany([\(documents)])")
      #expect(seeded.affectedRows == 1_000)
      let epoch = await manager.connectionEpoch

      let capped = try await run(manager, "db.\(name).find().sort({_id: 1})", maxRows: 100)
      #expect(capped.rows.count == 100)
      #expect(capped.truncated)
      #expect(!capped.sessionReset)
      #expect(capped.columns.map(\.name) == ["_id", "g"])
      #expect(capped.rows.first?.first == .int(0))
      #expect(capped.rows.last?.first == .int(99))

      // A user limit below the cap is kept; exactly the cap is not truncated.
      let limited = try await run(manager, "db.\(name).find().limit(40)", maxRows: 100)
      #expect(limited.rows.count == 40)
      #expect(!limited.truncated)
      let all = try await run(manager, "db.\(name).find()", maxRows: 1_000)
      #expect(all.rows.count == 1_000)
      #expect(!all.truncated)

      let grouped = try await run(manager, "db.\(name).aggregate([{$match: {g: 1}}])", maxRows: 100)
      #expect(grouped.rows.count == 100)
      #expect(grouped.truncated)

      // The capped reads kept the connection.
      #expect(await manager.connectionEpoch == epoch)
      let count = try await run(manager, "db.\(name).countDocuments()")
      #expect(count.rows == [[.int(1_000)]])
    }
  }

  // MARK: - Writes and reads

  @Test("Write counts as the manager reports them", .requiresMongo)
  func writeCounts() async throws {
    let name = "manager_writes"
    let target = "manager_writes_out"
    await MongoSessionTests.drop(target)
    try await withManager(name) { manager in
      func affected(_ text: String) async throws -> Int? {
        let result = try await run(manager, text)
        #expect(result.rows.isEmpty, "\(text)")
        return result.affectedRows
      }
      #expect(try await affected("db.\(name).insertOne({_id: 1, g: 1})") == 1)
      #expect(
        try await affected("db.\(name).insertMany([{_id: 2, g: 1}, {_id: 3, g: 0}, {_id: 4}])")
          == 3)
      #expect(try await affected("db.\(name).updateMany({g: 1}, {$set: {v: 1}})") == 2)
      // Matched, not modified: the same update still reports 2.
      #expect(try await affected("db.\(name).updateMany({g: 1}, {$set: {v: 1}})") == 2)
      #expect(try await affected("db.\(name).updateOne({_id: 9}, {$set: {g: 5}})") == 0)
      #expect(try await affected("db.\(name).replaceOne({_id: 3}, {g: 7})") == 1)
      // AGGREGATE has no count.
      #expect(
        try await affected("db.\(name).aggregate([{$match: {g: 1}}, {$out: \"\(target)\"}])")
          == nil)
      #expect(try await affected("db.\(name).deleteMany({})") == 4)

      // A multi-command cell reports each piece.
      let detailed = try await manager.executeDetailed(
        userSQL: "db.\(name).insertOne({_id: 5})\ndb.\(name).deleteOne({_id: 5})", policy: open,
        maxRows: 1_000)
      #expect(detailed.results.map(\.result.affectedRows) == [1, 1])
      let copied = try await run(manager, "db.\(target).countDocuments()")
      #expect(copied.rows == [[.int(2)]])
    }
    await MongoSessionTests.drop(target)
  }

  @Test("countDocuments and distinct results", .requiresMongo)
  func countAndDistinct() async throws {
    let name = "manager_count"
    try await withManager(name) { manager in
      _ = try await run(
        manager,
        "db.\(name).insertMany([{city: \"Oslo\"}, {city: \"Rome\"}, {city: \"Oslo\"}, {n: 1}])")
      let count = try await run(manager, "db.\(name).countDocuments({city: \"Oslo\"})")
      #expect(count.columns.map(\.name) == ["count"])
      #expect(count.rows == [[.int(2)]])
      #expect(!count.truncated)
      let none = try await run(manager, "db.\(name).countDocuments({city: \"Paris\"})")
      #expect(none.rows == [[.int(0)]])

      let cities = try await run(manager, "db.\(name).distinct(\"city\")")
      #expect(cities.columns.map(\.name) == ["city"])
      #expect(cities.rows.sorted { $0[0] < $1[0] } == [[.string("Oslo")], [.string("Rome")]])
    }
  }

  // MARK: - Time limit and cancel

  @Test("The statement timeout stops a slow find with a MaxTimeMSExpired message", .requiresMongo)
  func maxTimeMSExpired() async throws {
    let name = "manager_timeout"
    try await withManager(name, statementTimeout: 1) { manager in
      _ = try await run(manager, "db.\(name).insertOne({_id: 1})")
      let start = ContinuousClock.now
      let error = await #expect(throws: DatabaseError.self) {
        try await run(manager, "db.\(name).find({$where: \"sleep(3000) || true\"})")
      }
      #expect(ContinuousClock.now - start < .seconds(3))
      guard case .queryFailed(let message, _)? = error else {
        Issue.record("expected queryFailed, got \(String(describing: error))")
        return
      }
      // What the cell shows (`error.localizedDescription`): `MongoSession.formatError`'s text.
      #expect(
        message
          == "Statement timed out after 1s (MaxTimeMSExpired) — change it in the connection's "
          + "Safety settings", "\(message)")
      #expect(!message.contains("\n"))
      #expect(error?.localizedDescription == "Query failed: \(message)")
      // The connection stays usable.
      let count = try await run(manager, "db.\(name).countDocuments()")
      #expect(count.rows == [[.int(1)]])
    }
  }

  @Test(
    "Cancel of a $where sleep keeps the connection; the next command runs", .requiresMongo)
  func cancelKeepsConnection() async throws {
    let name = "manager_cancel"
    try await withManager(name) { manager in
      _ = try await run(manager, "db.\(name).insertOne({_id: 1})")
      let epoch = await manager.connectionEpoch
      let open = open
      let sleeping = Task {
        try await manager.execute(
          userSQL: "db.\(name).find({$where: \"sleep(10000) || true\"})", policy: open)
      }
      var status = await manager.runningStatementStatus()
      while !status.inFlight {
        try await Task.sleep(for: .milliseconds(10))
        status = await manager.runningStatementStatus()
      }
      try await Task.sleep(for: .milliseconds(300))
      let start = ContinuousClock.now
      // Repeat: a killOp sent before the find reached the server stops nothing.
      var first = true
      while await manager.runningStatementStatus().inFlight {
        let outcome = await manager.cancelRunningStatement(
          expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
          expectedEpoch: status.epoch)
        if first { #expect(outcome == .cancelled) }
        first = false
        try await Task.sleep(for: .milliseconds(200))
      }
      let error = await #expect(throws: DatabaseError.self) { try await sleeping.value }
      #expect(ContinuousClock.now - start < .seconds(5))
      guard case .queryCancelled(let pending, let rolledBack, let kept)? = error else {
        Issue.record("expected queryCancelled, got \(String(describing: error))")
        return
      }
      #expect(pending == 0 && !rolledBack && kept)
      #expect(error?.localizedDescription == "Query cancelled. The connection was kept.")

      #expect(await manager.connectionEpoch == epoch)
      let count = try await run(manager, "db.\(name).countDocuments()")
      #expect(count.rows == [[.int(1)]])
    }
  }
}
