// SequentialBatchGateTests.swift
// `executeGatedSequentialBatch` on fake sessions: the same gate as a staged batch (epoch,
// stricter policy, owner), refused with a transaction open or under Protected mode, then sent
// one by one without BEGIN/COMMIT, stopping at the first failure with "Applied k of n changes".

import Foundation
import Testing

@testable import Dblore

@Suite("Sequential batch gate")
struct SequentialBatchGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none)
  private let protectedRefusal =
    "Turn Protected mode off for this connection to run these changes one by one."
  private let dml = [
    "INSERT INTO t (id) VALUES (1)", "UPDATE t SET v = 2 WHERE id = 2",
    "DELETE FROM t WHERE id = 3",
  ]

  private static func config(
    _ type: DatabaseType, level: ConnectionProtectionLevel = .none, protectedMode: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: "fake", port: type == .mongodb ? 27017 : 3306, database: "db",
      username: "u", sslMode: .disable, protectionLevel: level, safeMode: .silent,
      protectedMode: protectedMode)
  }

  private func connect(
    _ type: DatabaseType, level: ConnectionProtectionLevel = .none, protectedMode: Bool = false,
    commandRows: (@Sendable (String) -> Int?)? = nil
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: type.capabilities, commandRows: commandRows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: Self.config(type, level: level, protectedMode: protectedMode))
    return (manager, factory)
  }

  /// Runs the batch and returns the error it throws, or nil when it succeeds.
  private func refusal(
    _ manager: DatabaseConnectionManager, _ statements: [String], policy: ProtectionPolicy,
    epoch: UInt64? = nil, caller: UUID? = nil, expectedRows: [Int]? = nil
  ) async -> DatabaseError? {
    let current = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedSequentialBatch(
        statements, policy: policy, connectionEpoch: epoch ?? current, caller: caller,
        expectedRows: expectedRows)
      return nil
    } catch let error as DatabaseError {
      return error
    } catch {
      Issue.record("Unexpected error \(error)")
      return nil
    }
  }

  private func refusedReason(_ error: DatabaseError?) -> String? {
    if case .sequentialBatchRefused(let reason)? = error { return reason }
    return nil
  }

  // MARK: - Refused before anything is sent

  @Test("A stale connection epoch is refused before anything is sent")
  func staleEpoch() async throws {
    let (manager, factory) = try await connect(.mysql)
    let epoch = await manager.connectionEpoch
    let error = await refusal(manager, dml, policy: open, epoch: epoch &+ 1)
    guard case .notEditable(let reason)? = error else {
      Issue.record("Expected notEditable, got \(String(describing: error))")
      return
    }
    #expect(reason.contains("connection changed"))
    #expect(factory.statements.isEmpty)
  }

  @Test("A read-only caller on an unprotected connection cannot write")
  func stricterCallerPolicy() async throws {
    let (manager, factory) = try await connect(.mysql)
    let error = await refusal(
      manager, ["SELECT 1"] + dml, policy: ProtectionPolicy(protectionLevel: .readOnly))
    guard case .blockedByProtection(let index, let kind, _)? = error else {
      Issue.record("Expected blockedByProtection, got \(String(describing: error))")
      return
    }
    #expect(index == 1)
    #expect(kind == .dml)
    #expect(factory.statements.isEmpty)
  }

  @Test(
    "Schema-only blocks DDL and $out per evaluateBatch", arguments: [DatabaseType.mysql, .mongodb])
  func schemaOnlyBlocks(type: DatabaseType) async throws {
    let (manager, factory) = try await connect(type, level: .schemaOnly)
    let statements =
      type == .mongodb
      ? ["db.c.insertOne({x: 1})", "db.c.aggregate([{$match: {}}, {$out: \"copy\"}])"]
      : ["INSERT INTO t (id) VALUES (1)", "CREATE TABLE u (id int)"]
    let error = await refusal(manager, statements, policy: open)
    guard case .blockedByProtection(let index, let kind, _)? = error else {
      Issue.record("Expected blockedByProtection, got \(String(describing: error))")
      return
    }
    #expect(index == 1)
    #expect(kind == .ddl)
    #expect(factory.statements.isEmpty)
  }

  @Test("A DML-only MySQL batch is refused under Protected mode and nothing is sent")
  func protectedModeRefused() async throws {
    let (manager, factory) = try await connect(.mysql, protectedMode: true)
    let error = await refusal(manager, dml, policy: open)
    #expect(refusedReason(error) == protectedRefusal)
    #expect(error?.errorDescription == "\(protectedRefusal) Nothing was executed.")
    #expect(factory.statements.isEmpty)
  }

  @Test("An open app or user transaction is refused, and that message wins over Protected mode")
  func openTransactionWins() async throws {
    let origin = UUID()
    let (appManager, appFactory) = try await connect(.mysql, protectedMode: true)
    _ = try await appManager.execute(
      userSQL: "UPDATE t SET v = 1 WHERE id = 1", policy: open, caller: origin)
    #expect(await appManager.txState != .idle)
    let appSent = appFactory.statements.count
    let appError = await refusal(appManager, dml, policy: open, caller: origin)

    let (userManager, userFactory) = try await connect(.mysql)
    _ = try await userManager.execute(userSQL: "BEGIN", policy: open)
    #expect(await userManager.userTxOpen)
    let userSent = userFactory.statements.count
    let userError = await refusal(
      userManager, dml, policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true))

    let expected = "Commit or roll back the open transaction first, then run these changes."
    #expect(refusedReason(appError) == expected)
    #expect(refusedReason(userError) == expected)
    #expect(appFactory.statements.count == appSent)
    #expect(userFactory.statements.count == userSent)
  }

  @Test("Another caller is refused while the app transaction is pending")
  func ownedByAnotherCaller() async throws {
    let (manager, factory) = try await connect(.mysql, protectedMode: true)
    _ = try await manager.execute(
      userSQL: "UPDATE t SET v = 1 WHERE id = 1", policy: open, caller: UUID())
    let sent = factory.statements.count
    let error = await refusal(manager, dml, policy: open, caller: UUID())
    guard case .transactionPendingInAnotherTab? = error else {
      Issue.record("Expected transactionPendingInAnotherTab, got \(String(describing: error))")
      return
    }
    #expect(factory.statements.count == sent)
  }

  @Test("Expected row counts must match the statements")
  func expectedRowsCountMismatch() async throws {
    let (manager, factory) = try await connect(.mysql)
    let error = await refusal(manager, dml, policy: open, expectedRows: [1, 1])
    #expect(refusedReason(error) == "Each change needs exactly one expected row count.")
    #expect(factory.statements.isEmpty)
  }

  // MARK: - Sending

  @Test("Statements are sent one by one without BEGIN or COMMIT; an empty batch sends nothing")
  func sendsOneByOne() async throws {
    let (manager, factory) = try await connect(.mysql)
    let epoch = await manager.connectionEpoch
    let empty = try await manager.executeGatedSequentialBatch(
      [], policy: open, connectionEpoch: epoch, caller: nil, expectedRows: nil)
    #expect(empty.isEmpty)
    #expect(factory.statements.isEmpty)

    let counts = try await manager.executeGatedSequentialBatch(
      dml, policy: open, connectionEpoch: epoch, caller: nil, expectedRows: [1, 1, 1])
    #expect(counts == [1, 1, 1])
    #expect(factory.statements == dml)
    #expect(await manager.txState == .idle)
  }

  @Test("A row count mismatch on statement 2 of 3 stops before statement 3")
  func rowCountMismatchStops() async throws {
    let (manager, factory) = try await connect(
      .mysql, commandRows: { $0.contains("id = 2") ? 0 : nil })
    let error = await refusal(manager, dml, policy: open, expectedRows: [1, 1, 1])
    guard case .batchPartiallyApplied(let applied, let total, let reason)? = error else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 1)
    #expect(total == 3)
    #expect(reason == "expected to affect 1 row, affected 0")
    #expect(
      error?.errorDescription == "Applied 1 of 3 changes: expected to affect 1 row, affected 0")
    #expect(factory.statements == Array(dml.prefix(2)))
  }

  @Test("A send failure on statement 2 of 3 stops before statement 3")
  func sendFailureStops() async throws {
    let (manager, factory) = try await connect(.mysql)
    factory.sessions.last?.failNextCommand(containing: "id = 2")
    let error = await refusal(manager, dml, policy: open)
    guard case .batchPartiallyApplied(let applied, let total, let reason)? = error else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 1)
    #expect(total == 3)
    #expect(!reason.isEmpty)
    #expect(error?.errorDescription == "Applied 1 of 3 changes: \(reason)")
    #expect(factory.statements == Array(dml.prefix(2)))
  }

  @Test("MongoDB commands run one by one with the default config (Protected mode ignored)")
  func mongoCommandsSucceed() async throws {
    let config = Self.config(.mongodb, protectedMode: true)
    let (manager, factory) = try await connect(
      .mongodb, protectedMode: true, commandRows: { _ in 1 })
    let commands = [
      "db.c.deleteOne({_id: 1})", "db.c.updateOne({_id: 2}, {$set: {a: 1}})",
      "db.c.insertOne({_id: 3})",
    ]
    let counts = try await manager.executeGatedSequentialBatch(
      commands, policy: ProtectionPolicy(config: config),
      connectionEpoch: await manager.connectionEpoch, caller: UUID(), expectedRows: [1, 1, 1])
    #expect(counts == [1, 1, 1])
    #expect(factory.statements == commands)
  }
}
