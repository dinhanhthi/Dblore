// MongoTypedWriteGateTests.swift
// `executeGatedMongoCommands` on fake sessions: typed MongoDB commands go through the gate of
// `executeGatedSequentialCommands` (epoch, protection on the typed classification, Protected
// mode) before anything is sent, then are sent one by one, stopping at the first failure with
// "Applied k of n changes". Also `streamMongoDocuments`, which refuses anything but a read before
// anything is sent.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB typed write gate")
struct MongoTypedWriteGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static func insert(_ id: Int) -> MongoCommand {
    .insertMany(
      collection: "c", documents: [.document([MongoValue.Field("_id", .int32(Int32(id)))])])
  }

  private func connect(
    level: ConnectionProtectionLevel = .none, failTypedAt: Int? = nil,
    typedError: any Error = FakeQueryError(),
    errorFormatter: (@Sendable (any Error) -> String)? = nil
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, errorFormatter: errorFormatter,
      failTypedAt: failTypedAt, typedError: typedError)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
        sslMode: .disable, protectionLevel: level, safeMode: .silent))
    return (manager, factory)
  }

  /// Runs the commands and returns the error they throw, or nil when they succeed.
  private func refusal(
    _ manager: DatabaseConnectionManager, _ commands: [MongoCommand], policy: ProtectionPolicy,
    epoch: UInt64? = nil
  ) async -> DatabaseError? {
    let current = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedMongoCommands(
        commands, policy: policy, connectionEpoch: epoch ?? current, expectedRows: nil)
      return nil
    } catch let error as DatabaseError {
      return error
    } catch {
      Issue.record("Unexpected error \(error)")
      return nil
    }
  }

  @Test("Read-only refuses a typed insert before anything is sent")
  func readOnlyRefusesInsert() async throws {
    let (manager, factory) = try await connect(level: .readOnly)
    let error = await refusal(manager, [Self.insert(1)], policy: open)
    guard case .blockedByProtection(let index, let kind, _)? = error else {
      Issue.record("Expected blockedByProtection, got \(String(describing: error))")
      return
    }
    #expect(index == 0)
    #expect(kind == .dml)
    #expect(factory.typedCommands.isEmpty)
  }

  @Test("Schema-only lets a typed insert run and refuses a typed createCollection")
  func schemaOnlyRefusesAdmin() async throws {
    let (manager, factory) = try await connect(level: .schemaOnly)
    #expect(await refusal(manager, [Self.insert(1)], policy: open) == nil)
    #expect(factory.typedCommands == [Self.insert(1)])

    let create = MongoCommand.admin(.createCollection(name: "d", options: nil))
    let error = await refusal(manager, [create], policy: open)
    guard case .blockedByProtection(let index, let kind, _)? = error else {
      Issue.record("Expected blockedByProtection, got \(String(describing: error))")
      return
    }
    #expect(index == 0)
    #expect(kind == .ddl)
    #expect(factory.typedCommands == [Self.insert(1)])
  }

  @Test("A changed connection epoch refuses before anything is sent")
  func staleEpoch() async throws {
    let (manager, factory) = try await connect()
    let epoch = await manager.connectionEpoch
    let error = await refusal(manager, [Self.insert(1)], policy: open, epoch: epoch &+ 1)
    guard case .notEditable(let reason)? = error else {
      Issue.record("Expected notEditable, got \(String(describing: error))")
      return
    }
    #expect(reason.contains("connection changed"))
    #expect(factory.typedCommands.isEmpty)
  }

  @Test("Protected mode refuses a typed write before anything is sent")
  func protectedModeRefuses() async throws {
    let (manager, factory) = try await connect()
    let error = await refusal(
      manager, [Self.insert(1)],
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true))
    guard case .blockedByProtection(let index, let kind, _)? = error else {
      Issue.record("Expected blockedByProtection, got \(String(describing: error))")
      return
    }
    #expect(index == 0)
    #expect(kind == .dml)
    #expect(factory.typedCommands.isEmpty)
  }

  @Test("A failure at command 1 of 3 reports one applied and sends nothing after it")
  func failureStops() async throws {
    let (manager, factory) = try await connect(failTypedAt: 1)
    let commands = [Self.insert(1), Self.insert(2), Self.insert(3)]
    let error = await refusal(manager, commands, policy: open)
    guard case .batchPartiallyApplied(let applied, let total, let reason, _)? = error else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 1)
    #expect(total == 3)
    #expect(!reason.isEmpty)
    #expect(factory.typedCommands == Array(commands.prefix(2)))
  }

  @Test("A typed send error reaches the partial-batch reason in the session's text")
  func sendErrorIsFormatted() async throws {
    let (manager, _) = try await connect(
      failTypedAt: 0, errorFormatter: { _ in "formatted by the session" })
    let error = await refusal(manager, [Self.insert(1)], policy: open)
    guard case .batchPartiallyApplied(let applied, _, let reason, _)? = error else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 0)
    #expect(reason == "Query failed: formatted by the session")
  }

  @Test("A failing insert's written count reaches the partial-batch error")
  func writtenCountSurvivesGate() async throws {
    let (manager, _) = try await connect(
      failTypedAt: 0,
      typedError: MongoSessionError(code: 11000, message: "duplicate key", written: 3))
    let error = await refusal(manager, [Self.insert(1)], policy: open)
    guard case .batchPartiallyApplied(let applied, _, _, let written)? = error else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 0)
    #expect(written == 3)
  }

  @Test("A streamed read refuses a $out aggregate and a write before anything is sent")
  func streamRefusesNonReads() async throws {
    let (manager, factory) = try await connect()
    let out = MongoCommand.aggregate(
      collection: "c", pipeline: [.document([MongoValue.Field("$out", .string("copy"))])])
    for command in [out, Self.insert(1)] {
      do {
        _ = try await manager.streamMongoDocuments(
          command, policy: open, pageSize: 100, onPage: { _ in })
        Issue.record("Expected a refusal for \(command)")
      } catch let error as MongoSessionError {
        #expect(error.message.hasPrefix("Only a read returns documents"))
      }
    }
    #expect(factory.statements.isEmpty)
    #expect(factory.typedCommands.isEmpty)
  }
}
