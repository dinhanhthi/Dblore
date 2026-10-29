// UserTypeEditorModelTests.swift
// `UserTypeEditorModel` on a `FakeDatabaseSession`-backed manager: the server version picks the
// path (below 120000 or unknown, ADD VALUE first one by one and refused inside an open
// transaction or under Review, each with its own advice; from 120000 one batch), a failure after
// some ADD VALUE committed keeps those labels loaded and the rest staged, the Safe Mode step comes
// before anything is sent, a Review (Protected mode) apply stays pending, the staged SQL never
// uses a label it adds, the next edit clears Applied and a stale error, and a new type's draft
// errors stay inline.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("UserTypeEditorModelTests")
struct UserTypeEditorModelTests {
  private static let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private static let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
  private static let mood = DatabaseUserType(
    schema: "public", name: "mood", kind: .enum(["sad", "ok"]))
  private static let add = "ALTER TYPE \"public\".\"mood\" ADD VALUE 'happy' AFTER 'ok'"
  private static let rename = "ALTER TYPE \"public\".\"mood\" RENAME VALUE 'sad' TO 'blue'"

  private func connect() async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
        password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    return (manager, factory)
  }

  private func model(
    _ manager: DatabaseConnectionManager, serverVersion: Int?, policy: ProtectionPolicy = open,
    commitStyle: CommitStyle = .immediate
  ) async -> UserTypeEditorModel {
    let context = SchemaChangeContext(
      manager: manager, databaseType: .postgresql, policy: policy,
      commitStyle: { commitStyle }, caller: nil, recordHistory: { _ in })
    let model = UserTypeEditorModel(
      type: Self.mood, context: context, serverVersion: serverVersion,
      connectionEpoch: await manager.connectionEpoch)
    model.addLabel("happy", position: .after("ok"))
    model.renameLabel("sad", to: "blue")
    return model
  }

  @Test(
    "Below 120000 or unknown, ADD VALUE runs first on its own, then the rest as one batch",
    arguments: [110_000, nil] as [Int?])
  func oldServerAddsValuesOneByOne(serverVersion: Int?) async throws {
    let (manager, factory) = try await connect()
    let model = await model(manager, serverVersion: serverVersion)
    var applied: [Bool] = []
    model.onApplied = { applied.append($0) }

    await model.apply()

    #expect(model.applyError == nil)
    #expect(factory.statements == [Self.add, "BEGIN", Self.rename, "COMMIT"])
    #expect(model.resultMessage == UserTypeEditorModel.appliedMessage)
    #expect(model.type?.kind == .enum(["blue", "ok", "happy"]))
    #expect(applied == [false])
  }

  @Test("Below 120000, ADD VALUE is refused inside an open transaction and nothing is sent")
  func oldServerRefusedInTransaction() async throws {
    let (manager, factory) = try await connect()
    _ = try await manager.execute(userSQL: "BEGIN", policy: Self.open)
    #expect(await manager.userTxOpen)
    let sent = factory.statements.count
    let model = await model(manager, serverVersion: 110_000)

    await model.apply()

    #expect(
      model.applyError
        == "This server adds enum values outside a transaction: commit or roll back first")
    #expect(factory.statements.count == sent)
    #expect(model.changes.count == 2)

    // The next edit clears the stale error
    model.addLabel("glad")
    #expect(model.applyError == nil)
  }

  @Test("Below 120000 under Review, ADD VALUE is refused with the commit style advice")
  func oldServerRefusedUnderReview() async throws {
    let (manager, factory) = try await connect()
    let model = await model(
      manager, serverVersion: 110_000, policy: Self.protected, commitStyle: .review)

    await model.apply()

    #expect(model.applyError == UserTypeEditorModel.addValueUnderReviewMessage)
    #expect(model.applyError != UserTypeEditorModel.addValueOutsideTransactionMessage)
    #expect(factory.statements.isEmpty)
    #expect(model.changes.count == 2)
  }

  @Test(
    "Below 120000, ADD VALUE committed before a failure is loaded and not resent; the rest stays",
    arguments: [
      // (a) The second ADD VALUE fails: only the first is committed
      ("'glad'", ["sad", "ok", "happy"], 2),
      // (b) Every ADD VALUE commits, then the batch fails
      ("RENAME VALUE", ["sad", "ok", "glad", "happy"], 1),
    ])
  func oldServerPartialFailure(failing: String, loaded: [String], remaining: Int) async throws {
    let (manager, factory) = try await connect()
    let model = await model(manager, serverVersion: 110_000)
    model.addLabel("glad", position: .after("ok"))
    var applied: [Bool] = []
    model.onApplied = { applied.append($0) }
    try #require(factory.sessions.first).failNextCommand(containing: failing)

    await model.apply()

    #expect(model.applyPartiallyFailed)
    #expect(model.applyError != nil)
    #expect(model.type?.kind == .enum(loaded))
    let rest: [UserTypeChange] = [
      .renameValue(label: "sad", newLabel: "blue"),
      .addValue(label: "glad", position: .after("ok")),
    ]
    #expect(model.changes == Array(rest.prefix(remaining)))
    #expect(!model.previewStatements.contains(Self.add))
    #expect(applied == [false])

    // The partial failure warning outlives the next edit: its labels stay applied
    model.addLabel("meh")
    #expect(model.applyError != nil)
  }

  @Test("From 120000 everything is one batch")
  func newServerOneBatch() async throws {
    let (manager, factory) = try await connect()
    let model = await model(manager, serverVersion: 160_000)

    await model.apply()

    #expect(model.applyError == nil)
    #expect(factory.statements == ["BEGIN", Self.add, Self.rename, "COMMIT"])
  }

  @Test("The next staged edit clears Applied")
  func editClearsApplied() async throws {
    let (manager, _) = try await connect()
    let model = await model(manager, serverVersion: 160_000)

    await model.apply()
    #expect(model.resultMessage == UserTypeEditorModel.appliedMessage)

    model.addLabel("glad")
    #expect(model.resultMessage == nil)
  }

  @Test(
    "A new type's draft error stays inline (no toast) and, like a half-filled row, blocks Create")
  func newTypeDraftErrorNoToast() async throws {
    let (manager, factory) = try await connect()
    let context = SchemaChangeContext(
      manager: manager, databaseType: .postgresql, policy: Self.open,
      commitStyle: { .immediate }, caller: nil, recordHistory: { _ in })
    let model = UserTypeEditorModel(
      newIn: "public", context: context, serverVersion: 160_000,
      connectionEpoch: await manager.connectionEpoch)
    var toasts: [String] = []
    model.toastPresenter = { message, _ in toasts.append(message) }
    // The name is trimmed: no space inside the quoted identifier
    model.newName = " d "
    func domain(_ expression: String) -> UserTypeChange {
      .createDomain(
        .init(
          baseType: "integer", notNull: false, defaultExpression: nil,
          checks: [.init(name: "", expression: expression)]))
    }

    model.define(domain("(VALUE > 0"))
    #expect(model.previewError != nil)
    #expect(!model.canApply)
    model.define(domain("(VALUE > 1"))
    #expect(model.previewError != nil)

    model.define(domain("VALUE > 0"))
    #expect(
      model.previewStatements == ["CREATE DOMAIN \"public\".\"d\" AS integer CHECK (VALUE > 0)"])
    #expect(model.canApply)
    model.incompleteDraft = "A CHECK row has a name but no expression"
    #expect(!model.canApply)
    await model.apply()

    #expect(factory.statements.isEmpty)
    #expect(toasts.isEmpty)
  }

  @Test("Under Confirm the Safe Mode step is asked before anything is sent")
  func confirmAsksFirst() async throws {
    let (manager, factory) = try await connect()
    let model = await model(manager, serverVersion: 160_000, commitStyle: .confirm)

    await model.apply()

    #expect(model.confirmation.pendingConfirmation?.isEmpty == false)
    #expect(!model.confirmation.requiresPassword)
    #expect(factory.statements.isEmpty)

    await model.confirmApply()
    #expect(model.confirmation.pendingConfirmation == nil)
    #expect(factory.statements == ["BEGIN", Self.add, Self.rename, "COMMIT"])
  }

  @Test("Under Review nothing is asked and the change is pending until Commit")
  func reviewIsPending() async throws {
    let (manager, factory) = try await connect()
    let model = await model(
      manager, serverVersion: 160_000, policy: Self.protected, commitStyle: .review)
    var applied: [Bool] = []
    model.onApplied = { applied.append($0) }

    await model.apply()

    #expect(model.confirmation.pendingConfirmation == nil)
    #expect(model.resultMessage == UserTypeEditorModel.pendingMessage)
    #expect(factory.statements.first == "BEGIN")
    #expect(factory.statements.contains(Self.add))
    #expect(!factory.statements.contains("COMMIT"))
    #expect(await manager.transactionSnapshot().pending.count == 2)
    #expect(applied == [true])
  }

  @Test("A label added here is renamed in its ADD VALUE: the SQL never uses a label it adds")
  func renameOfAddedLabelEditsTheAdd() async throws {
    let (manager, _) = try await connect()
    let model = await model(manager, serverVersion: 160_000)

    model.renameLabel("happy", to: "glad")
    model.renameLabel("blue", to: "grey")

    #expect(
      model.previewStatements == [
        "ALTER TYPE \"public\".\"mood\" ADD VALUE 'glad' AFTER 'ok'",
        "ALTER TYPE \"public\".\"mood\" RENAME VALUE 'sad' TO 'grey'",
      ])
    #expect(model.working == .enum(["grey", "ok", "glad"]))
  }
}
