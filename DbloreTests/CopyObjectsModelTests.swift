// CopyObjectsModelTests.swift
// The Copy Objects sheet model's guards on the target: a locked target asks to unlock before its
// password is read (a cancelled unlock reads and opens nothing); Read-only and Schema-only
// targets are refused when picked, before any prompt, password read or connection; a Review
// target (Protected mode, a legacy row included) and a Confirm target ask Safe Mode before the
// first statement reaches the target, a Password target too (always, even when the DDL lists
// nothing), an Immediate target copies at once. A late confirm, a DDL edit after the step, a
// close during a plan load or a copy, and a target locked again after the plan send nothing.
// Each test injects its own LockRegistry, prompter double and password reader; PostgreSQL
// targets use fake sessions, SQLite source and target are files in the temporary folder (no
// server).

import AppKit
import Foundation
import Testing
import os

@testable import Dblore

/// Answers every unlock with `answer` without showing anything; `onAsk` runs while it is open
@MainActor
private final class AnsweringUnlockPrompter: UnlockPrompter {
  var answer: Bool
  let onAsk: () -> Void
  private(set) var asked: [LockIdentity] = []

  init(answer: Bool, onAsk: @escaping () -> Void = {}) {
    self.answer = answer
    self.onAsk = onAsk
  }

  func unlock(
    _ item: LockIdentity, reason: String, anchor: NSWindow?, lockVault: UnlockPasswordVault
  ) async -> Bool {
    asked.append(item)
    onAsk()
    return answer
  }
}

@Suite("Copy Objects model")
@MainActor
struct CopyObjectsModelTests {
  typealias TableRef = CopyObjectsModel.TableRef

  @Test("A locked target asks to unlock before its password is read")
  func lockedTargetAsksFirst() async throws {
    let registry = LockRegistry()
    var config = Self.postgres(level: .none)
    config.isLocked = true
    registry.setLockedConnections([LockIdentity(config)])
    let entry = ConnectionHistoryEntry(config: config)
    let reads = OSAllocatedUnfairLock(initialState: 0)
    var readsWhileAsking: [Int] = []
    let prompter = AnsweringUnlockPrompter(answer: false) {
      readsWhileAsking.append(reads.withLock { $0 })
    }
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities, openError: FakeQueryError())
    var context = Self.context(source: DatabaseConnectionManager(lockSource: registry))
    context.password = { _ in
      reads.withLock { $0 += 1 }
      return "secret"
    }
    context.lockCenter = Self.lockCenter(registry, prompter)
    context.makeTargetManager = {
      DatabaseConnectionManager(sessionFactory: factory, lockSource: registry)
    }
    let model = CopyObjectsModel(
      context: context, tables: [Self.items], selected: [Self.items], savedConnections: [entry])
    #expect(model.targets.first?.isLocked == true)

    // Cancelled unlock: nothing read or opened, the pick goes quietly
    model.selectTarget(entry.id)
    #expect(model.targetID == entry.id)
    await model.waitForPlan()
    #expect(prompter.asked == [LockIdentity(config)])
    #expect(reads.withLock { $0 } == 0)
    #expect(factory.sessions.isEmpty)
    #expect(model.targetID == nil)
    #expect(model.planError == nil)

    // Granted: the password is read after the prompt (the fake connect then fails)
    prompter.answer = true
    model.selectTarget(entry.id)
    await model.waitForPlan()
    #expect(prompter.asked.count == 2)
    #expect(readsWhileAsking == [0, 0])
    #expect(reads.withLock { $0 } == 1)
    #expect(model.planError != nil)
    model.close()
  }

  @Test(
    "Read-only and Schema-only targets are refused when picked",
    arguments: [
      (ConnectionProtectionLevel.readOnly, CopyObjectsTargetError.readOnly),
      (.schemaOnly, .schemaOnly),
    ])
  func protectedLevelsRefused(
    level: ConnectionProtectionLevel, expected: CopyObjectsTargetError
  ) async throws {
    let registry = LockRegistry()
    // Locked too: the refusal comes before the unlock prompt
    var config = Self.postgres(level: level)
    config.isLocked = true
    registry.setLockedConnections([LockIdentity(config)])
    let entry = ConnectionHistoryEntry(config: config)
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let prompter = AnsweringUnlockPrompter(answer: true)
    let managersMade = OSAllocatedUnfairLock(initialState: 0)
    var context = Self.context(source: DatabaseConnectionManager(lockSource: registry))
    context.password = { _ in
      reads.withLock { $0 += 1 }
      return "secret"
    }
    context.lockCenter = Self.lockCenter(registry, prompter)
    context.makeTargetManager = {
      managersMade.withLock { $0 += 1 }
      return DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: DatabaseType.postgresql.capabilities),
        lockSource: registry)
    }
    let model = CopyObjectsModel(
      context: context, tables: [Self.items], selected: [Self.items], savedConnections: [entry])

    model.selectTarget(entry.id)
    #expect(model.targetError == expected.errorDescription)
    #expect(!model.isLoadingPlan)
    await model.waitForPlan()
    #expect(prompter.asked.isEmpty)
    #expect(reads.withLock { $0 } == 0)
    #expect(managersMade.withLock { $0 } == 0)
    #expect(model.plan == nil)
    model.close()
  }

  @Test("Closing before the plan loads opens no target")
  func closeBeforePlanOpensNothing() async throws {
    let registry = LockRegistry()
    let entry = ConnectionHistoryEntry(config: Self.postgres(level: .none))
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let managersMade = OSAllocatedUnfairLock(initialState: 0)
    var context = Self.context(source: DatabaseConnectionManager(lockSource: registry))
    context.password = { _ in
      reads.withLock { $0 += 1 }
      return "secret"
    }
    context.lockCenter = Self.lockCenter(registry, AnsweringUnlockPrompter(answer: true))
    context.makeTargetManager = {
      managersMade.withLock { $0 += 1 }
      return DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(
          capabilities: DatabaseType.postgresql.capabilities),
        lockSource: registry)
    }
    let model = CopyObjectsModel(
      context: context, tables: [Self.items], selected: [Self.items], savedConnections: [entry])

    model.selectTarget(entry.id)
    model.close()
    await model.waitForPlan()
    // The cancelled load still runs: it must not open the target
    try await Task.sleep(for: .milliseconds(300))
    #expect(reads.withLock { $0 } == 0)
    #expect(managersMade.withLock { $0 } == 0)
  }

  enum Style: String, CaseIterable, Sendable {
    case review, legacyProtectedMode, confirm, password, immediate
  }

  @Test(
    "Review and Confirm targets ask before the first statement; Immediate copies at once",
    arguments: Style.allCases)
  func safeModeBeforeFirstStatement(style: Style) async throws {
    try await withFiles { sourceURL, targetURL in
      let registry = LockRegistry()
      let source = DatabaseConnectionManager(lockSource: registry)
      try await source.connect(config: Self.sqlite(sourceURL))
      for statement in [
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)",
        "INSERT INTO items (id, name) VALUES (1, 'a'), (2, 'b')",
      ] {
        _ = try await source.executeInternal(statement)
      }
      var config = Self.sqlite(targetURL)
      switch style {
      case .review: config.applyCommitStyle(.review)
      case .legacyProtectedMode: config.protectedMode = true
      case .confirm: config.applyCommitStyle(.confirm)
      case .password: config.applyCommitStyle(.password)
      case .immediate: config.applyCommitStyle(.immediate)
      }
      if style == .legacyProtectedMode { #expect(config.commitStyle == nil) }
      let entry = ConnectionHistoryEntry(config: config)
      var context = Self.context(source: source, url: sourceURL)
      context.lockCenter = Self.lockCenter(registry, AnsweringUnlockPrompter(answer: false))
      context.makeTargetManager = { DatabaseConnectionManager(lockSource: registry) }
      let model = CopyObjectsModel(
        context: context, tables: [Self.items], selected: [Self.items],
        savedConnections: [entry])

      model.selectTarget(entry.id)
      await model.waitForPlan()
      #expect(model.planError == nil)
      #expect(model.plan != nil)
      await model.copy()

      if style == .immediate {
        #expect(model.pendingConfirmation == nil)
        #expect(model.result?.rows == 2)
        #expect(try await Self.tableCount(targetURL, registry) == 1)
      } else {
        #expect(model.pendingConfirmation?.isEmpty == false)
        #expect(model.confirmationRequiresPassword == (style == .password))
        #expect(model.result == nil)
        #expect(!model.isRunning)
        #expect(try await Self.tableCount(targetURL, registry) == 0)
        #expect(
          (model.protectedModeNote != nil) == (style == .review || style == .legacyProtectedMode))
        // Closing the sheet drops the step: a late confirm sends nothing
        model.close()
        #expect(model.pendingConfirmation == nil)
        await model.confirmCopy()
        #expect(try await Self.tableCount(targetURL, registry) == 0)
      }
      model.close()
      await source.disconnect()
    }
  }

  @Test("Safe Mode still asks, with a line for the copy, when the DDL lists no statement")
  func confirmationSummaryWhenNothingListed() {
    let listed = CopyObjectsModel.confirmationList([], tableCount: 2, dialect: .sqlite)
    #expect(listed.map(\.preview) == ["Create 2 tables and copy their rows"])
  }

  @Test("Confirm sends what Safe Mode showed; a DDL edit after the step sends nothing")
  func confirmSendsUnlessEdited() async throws {
    try await withCopyModel(style: .confirm) { (model, targetURL, registry, _) async throws in
      await model.copy()
      #expect(model.pendingConfirmation != nil)
      model.editedDDL += "\n"
      #expect(model.pendingConfirmation == nil)
      await model.confirmCopy()
      #expect(model.result == nil)
      #expect(try await Self.tableCount(targetURL, registry) == 0)

      await model.copy()
      #expect(model.pendingConfirmation != nil)
      await model.confirmCopy()
      #expect(model.result?.rows == 2)
      #expect(try await Self.tableCount(targetURL, registry) == 1)
    }
  }

  @Test("A copy whose DDL check ends after the sheet closed sends nothing")
  func closedCopySendsNothing() async throws {
    try await withCopyModel(style: .immediate) { (model, targetURL, registry, _) async throws in
      let copying = Task { await model.copy() }
      model.close()
      await copying.value
      #expect(model.result == nil)
      #expect(!model.isRunning)
      #expect(try await Self.tableCount(targetURL, registry) == 0)
    }
  }

  @Test("A target locked again after the plan asks to unlock before anything is sent")
  func relockedTargetAsksAgain() async throws {
    try await withCopyModel(style: .immediate) {
      (model, targetURL, registry, prompter) async throws in
      #expect(prompter.asked.isEmpty)
      registry.setLockedConnections([LockIdentity(Self.sqlite(targetURL))])
      await model.copy()
      #expect(prompter.asked.count == 1)
      #expect(model.result == nil)
      #expect(model.runError == nil)
      // Read past the lock
      #expect(try await Self.tableCount(targetURL, LockRegistry()) == 0)
    }
  }

  /// Copy to Another Connection... on a schema: the sheet opens at once, and that schema's
  /// tables are ticked once the list is read off the main actor
  @Test("A schema's Copy to Another Connection ticks its tables once they are read")
  func schemaOpenTicksItsTables() async throws {
    let config = Self.postgres(level: .none)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract())))
    try await manager.connectWithoutUnlockCheck(config: config, savesConnection: false)
    manager.cancelSchemaLoad()
    manager.databaseTables = [
      DatabaseTable(schema: "public", name: "a"), DatabaseTable(schema: "sales", name: "b"),
      DatabaseTable(schema: "sales", name: "c"),
    ]
    manager.schemaConnectionEpoch = 1

    manager.openCopyObjects(schema: "sales")
    let model = try #require(manager.copyObjects)
    for _ in 0..<500 where model.isLoadingTables {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.tables.count == 3)
    #expect(
      model.selectedTables == [
        TableRef(schema: "sales", name: "b"), TableRef(schema: "sales", name: "c"),
      ])
    manager.closeCopyObjects()
    await manager.performDisconnect()
  }

  // MARK: - Helpers

  private static let items = TableRef(schema: "main", name: "items")

  /// A SQLite source (at `url`, or an unconnected one), History off, the app default Immediate
  private static func context(
    source: DatabaseConnectionManager, url: URL? = nil
  ) -> CopyObjectsContext {
    CopyObjectsContext(
      source: source,
      sourceConfig: sqlite(url ?? URL(fileURLWithPath: "source.sqlite")),
      recorder: nil, password: { _ in nil }, defaultCommitStyle: { .immediate })
  }

  private static func lockCenter(
    _ registry: LockRegistry, _ prompter: AnsweringUnlockPrompter
  ) -> LockCenter {
    LockCenter(
      registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore()),
      prompter: prompter)
  }

  private static func postgres(level: ConnectionProtectionLevel) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "copy-model-\(UUID().uuidString).example", port: 1,
      database: "db", username: "u", sslMode: .disable, protectionLevel: level,
      safeMode: .silent, protectedMode: false)
  }

  private static func sqlite(_ url: URL) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  /// Tables in the target file, read on a connection of its own
  private static func tableCount(_ url: URL, _ registry: LockRegistry) async throws -> Int {
    let reader = DatabaseConnectionManager(lockSource: registry)
    try await reader.connect(config: sqlite(url))
    defer { Task { await reader.disconnect() } }
    let result = try await reader.executeInternal(
      "SELECT count(*) FROM sqlite_master WHERE type = 'table'")
    guard case .int(let count) = result.rows.first?.first else {
      Issue.record("Expected a count")
      return -1
    }
    return count
  }

  /// A SQLite source with two rows in `items` and a SQLite target under `style` (its unlock
  /// prompt answers no), the plan loaded; closed afterwards
  private func withCopyModel(
    style: CommitStyle,
    _ body: (CopyObjectsModel, URL, LockRegistry, AnsweringUnlockPrompter) async throws -> Void
  ) async throws {
    try await withFiles { sourceURL, targetURL in
      let registry = LockRegistry()
      let source = DatabaseConnectionManager(lockSource: registry)
      try await source.connect(config: Self.sqlite(sourceURL))
      for statement in [
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)",
        "INSERT INTO items (id, name) VALUES (1, 'a'), (2, 'b')",
      ] {
        _ = try await source.executeInternal(statement)
      }
      var config = Self.sqlite(targetURL)
      config.applyCommitStyle(style)
      let entry = ConnectionHistoryEntry(config: config)
      let prompter = AnsweringUnlockPrompter(answer: false)
      var context = Self.context(source: source, url: sourceURL)
      context.lockCenter = Self.lockCenter(registry, prompter)
      context.makeTargetManager = { DatabaseConnectionManager(lockSource: registry) }
      let model = CopyObjectsModel(
        context: context, tables: [Self.items], selected: [Self.items],
        savedConnections: [entry])
      model.selectTarget(entry.id)
      await model.waitForPlan()
      #expect(model.plan != nil)
      try await body(model, targetURL, registry, prompter)
      model.close()
      await source.disconnect()
    }
  }

  /// Runs `body` with two new SQLite file URLs, removed afterwards
  private func withFiles(_ body: (URL, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-copy-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(
      directory.appendingPathComponent("source.sqlite"),
      directory.appendingPathComponent("target.sqlite"))
  }
}
