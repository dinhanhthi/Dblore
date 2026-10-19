// MongoAdminActionModelTests.swift
// MongoAdminActionModel on a fake MongoDB session: refuses up front on protected connections,
// asks for the typed name on a drop whatever the commit style, shows the Safe Mode panel when the
// commit style asks (Review counts as Confirm), then sends the rendered command through the
// sequential batch gate and records it in History.

import Foundation
import SwiftUI
import Testing

@testable import Dblore

@MainActor
@Suite("MongoAdminActionModelTests")
struct MongoAdminActionModelTests {
  private static let dropItems = MongoAdminCommand.drop(collection: "items")
  private static let createIndex = MongoAdminCommand.createIndex(
    collection: "items", keys: .document([.init("name", .int32(1))]), options: nil)

  private final class Log {
    var outcomes: [QueryHistoryOutcome] = []
    var reloads = 0
    /// Runs when History records, while the command is still running
    var onRecord: (() -> Void)?
  }

  private static func config(
    level: ConnectionProtectionLevel = .none, protectedMode: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable, protectionLevel: level, safeMode: .silent, protectedMode: protectedMode)
  }

  private func makeModel(
    commitStyle: CommitStyle, level: ConnectionProtectionLevel = .none,
    protectedMode: Bool = false, reconnectAfterRead: Bool = false,
    policy: ProtectionPolicy? = nil, existing: Set<String> = [], existingFails: Bool = false,
    log: Log
  ) async throws -> (MongoAdminActionModel, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.mongodb.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = Self.config(level: level, protectedMode: protectedMode)
    try await manager.connect(config: config)
    let epoch = await manager.connectionEpoch
    // A reconnect after the objects were read (the model keeps the epoch it was given)
    if reconnectAfterRead { try await manager.connect(config: config) }
    let model = MongoAdminActionModel(
      context: MongoAdminContext(
        manager: manager, policy: policy ?? ProtectionPolicy(config: config),
        commitStyle: { commitStyle }, caller: nil,
        recordHistory: {
          log.onRecord?()
          log.outcomes += $0
        }, database: config.database,
        // The live existence check of an `$out` target (the fake is no MongoSession)
        existingNames: { _, names, _ in
          if existingFails { throw CancellationError() }
          return existing.intersection(names)
        }),
      connectionEpoch: epoch,
      onStatementsExecuted: { log.reloads += 1 })
    return (model, factory)
  }

  private func confirmation(_ model: MongoAdminActionModel) -> MongoAdminActionModel.Confirmation? {
    if case .confirming(let pending) = model.state { return pending }
    Issue.record("Expected confirming, got \(model.state)")
    return nil
  }

  @Test("A drop asks for the typed name even under Immediate; nothing is sent until it matches")
  func dropNeedsTypedName() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .immediate, log: log)
    await model.request(Self.dropItems)
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == "items")
    #expect(!pending.needsSafeModePanel)
    #expect(pending.text == Self.dropItems.render())

    await model.confirm(pending, typedName: "Items")
    #expect(factory.statements.isEmpty)
    #expect(confirmation(model) != nil)

    await model.confirm(pending, typedName: "items")
    #expect(model.state == .done)
    #expect(factory.statements == [Self.dropItems.render()])
    #expect(log.outcomes.map(\.status) == [.success])
    #expect(log.reloads == 1)
  }

  @Test("Dropping the connection's database asks for its name under Immediate; nothing sent first")
  func dropDatabaseNeedsTypedName() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .immediate, log: log)
    let drop = MongoAdminCommand.dropDatabase(database: nil)
    // A database passed by the caller never replaces the one the server drops
    await model.request(drop, database: "other")
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == "db")
    #expect(pending.database == "db")
    #expect(pending.objectKind == "database")
    #expect(!pending.needsSafeModePanel)
    #expect(pending.text == "db.dropDatabase()")

    await model.confirm(pending, typedName: "DB")
    #expect(factory.statements.isEmpty)

    await model.confirm(pending, typedName: "db")
    #expect(model.state == .done)
    #expect(factory.statements == [drop.render()])

    let (named, _) = try await makeModel(commitStyle: .immediate, log: log)
    await named.request(.dropDatabase(database: "shop"))
    let shop = try #require(confirmation(named))
    #expect(shop.typedName == "shop")
    #expect(shop.database == "shop")
    #expect(shop.objectKind == "database")
  }

  @Test("A non-destructive command runs at once under Immediate; Review shows the panel")
  func commitStyles() async throws {
    let log = Log()
    let (immediate, sent) = try await makeModel(commitStyle: .immediate, log: log)
    await immediate.request(Self.createIndex)
    #expect(immediate.state == .done)
    #expect(sent.statements == [Self.createIndex.render()])

    let (review, factory) = try await makeModel(
      commitStyle: .review, protectedMode: true, log: log)
    await review.request(Self.createIndex)
    let pending = try #require(confirmation(review))
    #expect(pending.typedName == nil)
    #expect(pending.needsSafeModePanel)
    #expect(factory.statements.isEmpty)
    await review.confirm(pending)
    #expect(review.state == .done)
    #expect(factory.statements == [Self.createIndex.render()])
  }

  @Test("Read-only refuses before any prompt with the gate's text")
  func readOnlyRefusesUpFront() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(
      commitStyle: .confirm, level: .readOnly, log: log)
    await model.request(Self.dropItems)
    #expect(model.state == .failed("Schema change is not allowed on a read-only connection"))
    let stale = MongoAdminActionModel.confirmation(
      for: Self.dropItems, text: Self.dropItems.render(), commitStyle: .confirm)
    await model.confirm(stale, typedName: "items")
    #expect(factory.statements.isEmpty)
    #expect(log.reloads == 0)
  }

  @Test("A reconnect since the indexes were read refuses the drop; nothing is sent")
  func reconnectRefusesDrop() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(
      commitStyle: .immediate, reconnectAfterRead: true, log: log)
    let dropIndex = MongoAdminCommand.dropIndex(collection: "items", index: .string("name_1"))
    await model.request(dropIndex)
    let pending = try #require(confirmation(model))
    await model.confirm(pending, typedName: "name_1")
    #expect(
      model.state == .failed("The connection changed since this list was read; nothing was sent."))
    #expect(factory.statements.isEmpty)
    #expect(log.outcomes.map(\.status) == [.error])
  }

  @Test("A server error shows its reason without the batch wrapper and is recorded")
  func serverErrorShowsReason() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .immediate, log: log)
    factory.sessions.last?.failNextCommand(containing: "createIndex")
    await model.request(Self.createIndex)
    guard case .failed(let message) = model.state else {
      Issue.record("Expected failed, got \(model.state)")
      return
    }
    #expect(!message.contains("Applied 0 of 1"))
    #expect(log.outcomes.map(\.status) == [.error])
  }

  @Test("The sheet shows a confirmed command while it runs, never one sent at once")
  func sheetWhileRunning() async throws {
    let log = Log()
    var shown: [Bool] = []
    let (immediate, _) = try await makeModel(commitStyle: .immediate, log: log)
    log.onRecord = {
      #expect(immediate.state == .running)
      shown.append(MongoAdminConfirmSheet.isPresented(immediate).wrappedValue)
    }
    await immediate.request(Self.createIndex)
    await immediate.request(Self.dropItems)
    let pending = try #require(confirmation(immediate))
    await immediate.confirm(pending, typedName: "items")
    #expect(shown == [false, true])
  }

  @Test("Closing the sheet after a confirmed command keeps done for the Create Index form")
  func cancelKeepsDone() async throws {
    let log = Log()
    let (model, _) = try await makeModel(commitStyle: .confirm, log: log)
    await model.request(Self.createIndex)
    let pending = try #require(confirmation(model))
    await model.confirm(pending)
    #expect(model.state == .done)
    model.cancel()
    #expect(model.state == .done)
    #expect(!MongoAdminConfirmSheet.isPresented(model).wrappedValue)
  }

  @Test("A late answer to a cancelled confirmation never sends the next one of the same model")
  func lateAnswerAfterCancel() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .confirm, log: log)
    await model.request(Self.createIndex)
    let first = try #require(confirmation(model))
    model.cancel()
    let other = MongoAdminCommand.createIndex(
      collection: "items", keys: .document([.init("age", .int32(1))]), options: nil)
    await model.request(other)
    let second = try #require(confirmation(model))

    #expect(!model.isPending(first))
    #expect(model.isPending(second))
    await model.confirm(first)
    #expect(factory.statements.isEmpty)
    #expect(model.isPending(second))

    await model.confirm(second)
    #expect(factory.statements == [other.render()])
  }

  // MARK: - Pipeline writes ($out / $merge)

  private static let outText = MongoCommand.aggregate(
    collection: "items", pipeline: [.document([.init("$out", .string("copy"))])]
  ).render()
  private static let mergeText = MongoCommand.aggregate(
    collection: "items",
    pipeline: [.document([.init("$merge", .document([.init("into", .string("copy"))]))])]
  ).render()

  @Test(
    "$out over an existing collection sends nothing before the exact name, even under Immediate")
  func outOverExistingNeedsTypedName() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .immediate, log: log)
    await model.requestPipelineWrite(
      text: Self.outText, target: "copy", replacesExisting: true, isOut: true)
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == "copy")
    #expect(pending.objectKind == "collection")
    #expect(!pending.needsSafeModePanel)
    #expect(pending.text == Self.outText)

    await model.confirm(pending, typedName: "Copy")
    await model.confirm(pending)
    #expect(factory.statements.isEmpty)

    await model.confirm(pending, typedName: "copy")
    #expect(model.state == .done)
    #expect(factory.statements == [Self.outText])
    #expect(log.outcomes.map(\.status) == [.success])
    #expect(log.reloads == 1)
    // A finished write is never sent again by a late answer
    await model.confirm(pending, typedName: "copy")
    #expect(factory.statements.count == 1)

    // Under Confirm the Safe Mode panel follows the typed name
    let (confirm, _) = try await makeModel(commitStyle: .confirm, log: log)
    await confirm.requestPipelineWrite(
      text: Self.outText, target: "copy", replacesExisting: true, isOut: true)
    let both = try #require(confirmation(confirm))
    #expect(both.typedName == "copy")
    #expect(both.needsSafeModePanel)
  }

  @Test("$out into a target the live check finds asks for the typed name; the list was stale")
  func outOverLiveExistingNeedsTypedName() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(
      commitStyle: .immediate, existing: ["copy"], log: log)
    await model.requestPipelineWrite(
      text: Self.outText, target: "copy", replacesExisting: false, isOut: true)
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == "copy")
    #expect(pending.action == .pipelineWrite(target: "copy", isOut: true, replacesExisting: true))
    #expect(factory.statements.isEmpty)
  }

  @Test("A failed live check of the $out target refuses the write; nothing is sent")
  func outLiveCheckFailureRefuses() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(
      commitStyle: .immediate, existingFails: true, log: log)
    await model.requestPipelineWrite(
      text: Self.outText, target: "copy", replacesExisting: false, isOut: true)
    #expect(model.state == .failed("Could not check whether copy exists; nothing was sent."))
    #expect(factory.statements.isEmpty)
    #expect(log.outcomes.isEmpty)
  }

  @Test("$merge under Confirm holds at the Safe Mode panel; nothing is sent until confirmed")
  func mergeHoldsForSafeMode() async throws {
    let log = Log()
    let (model, factory) = try await makeModel(commitStyle: .confirm, log: log)
    await model.requestPipelineWrite(
      text: Self.mergeText, target: "copy", replacesExisting: true, isOut: false)
    let pending = try #require(confirmation(model))
    #expect(pending.typedName == nil)
    #expect(pending.needsSafeModePanel)
    #expect(factory.statements.isEmpty)

    await model.confirm(pending)
    #expect(model.state == .done)
    #expect(factory.statements == [Self.mergeText])
  }

  @Test(
    "Schema-only (the connection's rules) refuses $out before any prompt and lets $merge through")
  func schemaOnlyRefusesOut() async throws {
    let log = Log()
    // The tab's policy allows everything: the refusal must come from the connection's rules
    let (model, factory) = try await makeModel(
      commitStyle: .confirm, level: .schemaOnly, policy: ProtectionPolicy(protectionLevel: .none),
      log: log)
    for replacesExisting in [true, false] {
      await model.requestPipelineWrite(
        text: Self.outText, target: "copy", replacesExisting: replacesExisting, isOut: true)
      guard case .failed = model.state else {
        Issue.record("Expected failed, got \(model.state)")
        return
      }
    }
    await model.requestPipelineWrite(
      text: Self.mergeText, target: "copy", replacesExisting: false, isOut: false)
    let pending = try #require(confirmation(model))
    #expect(factory.statements.isEmpty)
    await model.confirm(pending)
    #expect(factory.statements == [Self.mergeText])
  }

  @Test("Read-only and Protected mode refuse a pipeline write before any prompt")
  func protectedRefusesPipelineWrite() async throws {
    let log = Log()
    let (readOnly, sent) = try await makeModel(commitStyle: .confirm, level: .readOnly, log: log)
    let (protected, factory) = try await makeModel(
      commitStyle: .confirm,
      policy: ProtectionPolicy(protectionLevel: .none, protectedMode: true), log: log)
    for model in [readOnly, protected] {
      await model.requestPipelineWrite(
        text: Self.mergeText, target: "copy", replacesExisting: false, isOut: false)
      guard case .failed = model.state else {
        Issue.record("Expected failed, got \(model.state)")
        continue
      }
    }
    #expect(
      protected.state
        == .failed(
          "MongoDB has no transactions, so Protected mode cannot hold this change. Use Confirm."))
    #expect(sent.statements.isEmpty)
    #expect(factory.statements.isEmpty)
    #expect(log.reloads == 0)
  }

  @Test(
    "The typed name matches exactly and case-sensitively; an empty entry never matches",
    arguments: [
      ("items", "items", true),
      (" items\n", "items", true),
      ("Items", "items", false),
      ("", "", false),
      ("  ", "  ", false),
    ])
  func typedNameMatches(typed: String, name: String, matches: Bool) {
    #expect(TypedNameConfirmation.matches(typed, name: name) == matches)
  }
}
