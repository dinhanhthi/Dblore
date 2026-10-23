// CascadePreviewModelTests.swift
// Staged delete impact: counted on a separate read-only session closed after the check, never
// while a transaction is open on the tab's session. A blocker with rows holds the commit until
// the user picks Commit Anyway; a count that times out or fails never does.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Cascade preview model")
struct CascadePreviewModelTests {
  @Test("A RESTRICT key with rows holds the commit until Commit Anyway; counted on its own session")
  func blockerWithRowsAsksBeforeCommit() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(3)]])
    let (viewModel, _) = try await makeViewModel(factory)
    #expect(viewModel.stageDelete(rows: [0]) == nil)

    // Cancel: nothing is sent, the staged set stays
    let cancelled = Task { await viewModel.commitStaged() }
    let prompt = try #require(await blockerPrompt(viewModel))
    #expect(
      prompt.blockers.map(\.text) == [
        #"Blocked by foreign key "orders_user_fk" on "orders": 3 rows still refer to these rows."#
      ])
    #expect(!factory.statements.contains { $0.contains("DELETE") })
    viewModel.resolveStagedBlockerPrompt(commitAnyway: false)
    await cancelled.value
    #expect(viewModel.stagedBlockerPrompt == nil)
    #expect(viewModel.dataViewer?.changeSet?.isEmpty == false)
    #expect(!factory.statements.contains { $0.contains("DELETE") })
    // The tab's session sent no count: a second, read-only session did, with its key bound
    let tab = try #require(factory.sessions.first)
    #expect(!tab.statements.contains { $0.contains("COUNT(*)") })
    let side = try #require(factory.sessions.dropFirst().first)
    let index = try #require(side.statements.firstIndex { $0.hasPrefix("SELECT COUNT(*)") })
    #expect(!side.statements[index].contains("42"))
    #expect(side.statementBinds[index] == [.text("42")])
    #expect(side.statements.contains("BEGIN TRANSACTION READ ONLY"))
    #expect(await closed(side))

    // Commit Anyway: the database decides, the DELETE is sent
    let confirmed = Task { await viewModel.commitStaged() }
    #expect(await blockerPrompt(viewModel) != nil)
    viewModel.resolveStagedBlockerPrompt(commitAnyway: true)
    await confirmed.value
    #expect(tab.statements.contains { $0.hasPrefix("DELETE") })
  }

  @Test("Commit Anyway, from the prompt or the preview sheet, still stops at Safe Mode")
  func commitAnywayStillConfirmsSafeMode() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(3)]])
    let (viewModel, _) = try await makeViewModel(factory, safeMode: .alertRead)
    #expect(viewModel.stageDelete(rows: [0]) == nil)
    let blocker =
      #"Blocked by foreign key "orders_user_fk" on "orders": 3 rows still refer to these rows."#
    let tab = try #require(factory.sessions.first)

    // The prompt's Commit Anyway
    let confirmed = Task { await viewModel.commitStaged() }
    #expect(await blockerPrompt(viewModel) != nil)
    viewModel.resolveStagedBlockerPrompt(commitAnyway: true)
    await confirmed.value
    #expect(viewModel.pendingStagedBatch != nil)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.alsoAffected.contains(blocker))
    #expect(!tab.statements.contains { $0.hasPrefix("DELETE") })

    // The sheet's Commit Anyway: awaited directly, a blocker prompt here would hang the run
    viewModel.queryConfirmationState.clear()
    viewModel.pendingStagedBatch = nil
    await viewModel.commitStaged(ignoringBlockers: true)
    #expect(viewModel.stagedBlockerPrompt == nil)
    #expect(viewModel.pendingStagedBatch != nil)
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.alsoAffected.contains(blocker))
    #expect(!tab.statements.contains { $0.hasPrefix("DELETE") })
  }

  @Test("An open blocker prompt refuses a second commit with a toast; Discard cancels it")
  func discardCancelsTheBlockerPrompt() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(3)]])
    let (viewModel, _) = try await makeViewModel(factory)
    #expect(viewModel.stageDelete(rows: [0]) == nil)
    let first = Task { await viewModel.commitStaged() }
    #expect(await blockerPrompt(viewModel) != nil)
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }

    await viewModel.commitStaged()
    #expect(toasts.count == 1)
    #expect(toasts.first?.contains("Commit Anyway") == true)
    #expect(viewModel.stagedBlockerPrompt != nil)

    viewModel.discardStaged()
    #expect(viewModel.stagedBlockerPrompt == nil)
    viewModel.resolveStagedBlockerPrompt(commitAnyway: false)  // a no-op now; a regression must not hang the run
    await first.value
    #expect(!factory.statements.contains { $0.contains("DELETE") })
  }

  @Test("Staged edits beside the deletes make a blocker only may block: no extra prompt")
  func editsBesideDeletesMayBlock() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(3)]])
    let (viewModel, _) = try await makeViewModel(factory)
    #expect(viewModel.stageDelete(rows: [0]) == nil)
    #expect(viewModel.stageEdit(row: 1, column: "name", value: .string("z")) == nil)

    let impact = try #require(await viewModel.stagedDeleteImpact())
    #expect(!impact.blocksCommit)
    #expect(impact.affected.map(\.effect) == [.mayBlock])

    await viewModel.commitStaged()

    #expect(viewModel.stagedBlockerPrompt == nil)
    let tab = try #require(factory.sessions.first)
    #expect(tab.statements.contains { $0.hasPrefix("DELETE") })
    #expect(tab.statements.contains { $0.hasPrefix("UPDATE") })
  }

  @Test("With a transaction open nothing is counted and the commit is not refused")
  func openTransactionSkipsCounts() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract(), rows: [[.int(3)]])
    let (viewModel, manager) = try await makeViewModel(factory)
    _ = try await manager.execute(
      userSQL: "BEGIN", policy: ProtectionPolicy(protectionLevel: .none))
    #expect(viewModel.stageDelete(rows: [0]) == nil)

    let impact = try #require(await viewModel.stagedDeleteImpact())

    #expect(!impact.blocksCommit)
    #expect(impact.note?.contains("A transaction is open") == true)
    #expect(factory.sessions.count == 1)
    #expect(!factory.statements.contains { $0.contains("COUNT(*)") })
    #expect(await manager.userTxOpen)
  }

  @Test("A count that times out or fails never blocks the commit")
  func failedCountNeverBlocks() async throws {
    let slow = FakeDatabaseSessionFactory(
      capabilities: .contract(), rows: [[.int(3)]], slowQueries: true)
    let slowManager = try await connect(slow)
    let stopped = Stopped()
    let timedOut = await NotebookViewModel.cascadeImpact(
      budget: .milliseconds(100), stop: { await stopped.mark() }
    ) {
      try await count(slowManager)
    }
    // The read the budget stopped waiting for is still parked in the fake: end it
    for session in slow.sessions { await session.interrupt() }
    #expect(await stopped.wait())

    let failingManager = try await connect(
      FakeDatabaseSessionFactory(
        capabilities: .contract(), rows: [[.int(3)]], failingQuery: "COUNT"))
    let failed = await NotebookViewModel.cascadeImpact { try await count(failingManager) }

    for summary in [timedOut, failed] {
      #expect(!summary.blocksCommit)
      #expect(summary.blockers.isEmpty)
      #expect(summary.note?.hasPrefix("Impact not computed") == true)
    }
  }

  @Test("SQLite: the side connection opens the file read-only and still reads the WAL")
  func sqliteSideIsReadOnly() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-cascade-side-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    let tab = DatabaseConnectionManager()
    try await tab.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    _ = try await tab.executeInternal("PRAGMA journal_mode = WAL")
    _ = try await tab.executeInternal("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    _ = try await tab.executeInternal("INSERT INTO t VALUES (1)")
    #expect(await tab.config?.readOnlyFile == false)
    let side = tab.makeReadOnlySideManager()

    try await NotebookViewModel.connectSide(side, like: tab)

    #expect(await side.config?.readOnlyFile == true)
    // Rows still in the tab's WAL are seen
    let result = try await side.execute(
      userSQL: "SELECT COUNT(*) FROM t", policy: ProtectionPolicy(protectionLevel: .readOnly))
    #expect(result.rows.first?.first == .int(1))
    await side.disconnect()
    await tab.disconnect()
  }

  /// The users page with row ids 42 and 43, on a connected tab manager whose catalog has
  /// `orders.user_id` referencing `users.id` ON DELETE RESTRICT.
  private func makeViewModel(
    _ factory: FakeDatabaseSessionFactory, safeMode: SafeMode = .silent
  ) async throws -> (NotebookViewModel, DatabaseConnectionManager) {
    let manager = try await connect(factory, safeMode: safeMode)
    let epoch = await manager.connectionEpoch
    let usersID = TableRef.postgresql(oid: 1)
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = config(safeMode: safeMode)
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4", origin: ColumnOrigin(tableID: usersID, columnOrdinal: 1)),
        ColumnInfo(
          name: "name", type: "text", origin: ColumnOrigin(tableID: usersID, columnOrdinal: 2)),
      ],
      rows: [[.int(42), .string("a")], [.int(43), .string("b")]],
      rowCount: 2,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: usersID, primaryKeyColumns: ["id"],
        connectionEpoch: epoch, updateOnly: true, schema: "public", name: "users"))
    viewModel.connectionManager = manager
    return (viewModel, manager)
  }

  private func connect(
    _ factory: FakeDatabaseSessionFactory, safeMode: SafeMode = .silent
  ) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: ForeignKeyCatalogFactory(inner: factory))
    try await manager.connect(config: config(safeMode: safeMode))
    return manager
  }

  private func config(safeMode: SafeMode = .silent) -> ConnectionConfig {
    ConnectionConfig(
      host: "fake", port: 1, database: "db", username: "u", password: "p", sslMode: .disable,
      protectionLevel: .none, safeMode: safeMode, protectedMode: false)
  }

  /// The Commit Anyway prompt of a commit running in another task: wait for it, bounded
  private func blockerPrompt(_ viewModel: NotebookViewModel) async -> CascadeImpactSummary? {
    for _ in 0..<500 where viewModel.stagedBlockerPrompt == nil {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return viewModel.stagedBlockerPrompt
  }

  /// The side session is closed off the commit's path: wait for it, bounded
  private func closed(_ session: FakeDatabaseSession) async -> Bool {
    for _ in 0..<200 {
      if session.didClose { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return session.didClose
  }
}

/// Counts for deleting `public.users` id 42, which `orders.user_id` references ON DELETE
/// RESTRICT.
private func count(_ manager: DatabaseConnectionManager) async throws -> CascadeImpactSummary {
  let impact = CascadeImpactPlanner.impact(
    deletingFrom: "public", table: "users", keyColumns: ["id"], keys: [[.int(42)]],
    foreignKeys: try await manager.fetchForeignKeys(), dialect: .postgresql)
  return try await NotebookViewModel.countCascadeImpact(
    impact, connectionManager: manager, counter: manager, dialect: .postgresql, caller: nil,
    expectedEpoch: nil)
}

/// Set once the timed-out check asked to stop its session
private actor Stopped {
  private var done = false

  func mark() { done = true }

  func wait() async -> Bool {
    for _ in 0..<200 where !done {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return done
  }
}

/// Sessions of `inner` whose PostgreSQL foreign key catalog read returns
/// `orders_user_fk` (`public.orders(user_id)` → `public.users(id)`, RESTRICT).
private struct ForeignKeyCatalogFactory: DatabaseSessionFactory {
  let inner: FakeDatabaseSessionFactory

  func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
    ForeignKeyCatalogSession(inner: inner.makeSession(config: config))
  }
}

private final class ForeignKeyCatalogSession: DatabaseSession {
  let inner: any DatabaseSession

  init(inner: any DatabaseSession) {
    self.inner = inner
  }

  var capabilities: DatabaseCapabilities { inner.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { inner.closeEvents }

  func open() async throws { try await inner.open() }
  func close() async { await inner.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let source = try await inner.query(sql, binds: binds)
    guard sql.contains("pg_constraint") else { return source }
    let row: [CellValue] = [
      .string("orders_user_fk"), .string("public"), .string("orders"), .string("public"),
      .string("users"), .string("a"), .string("r"), .string("{user_id}"), .string("{id}"),
    ]
    return SessionRowSource(
      columns: [],
      rows: AsyncThrowingStream { continuation in
        continuation.yield(row)
        continuation.finish()
      })
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await inner.command(sql, binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await inner.openCursor(sql, binds: binds)
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
