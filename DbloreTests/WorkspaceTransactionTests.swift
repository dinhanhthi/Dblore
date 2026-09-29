// WorkspaceTransactionTests.swift
// Workspace-level Protected transaction (P3): pure banner / resolve / unlock rules, and the
// WorkspaceManager mirror driven by a tab ViewModel against the docker test database
// (TEST_DB_* env, port 5435 in CI/autopilot). A second manager checks what is committed.
// P4: other tabs blocked, metadata served from cache, reconnect resolves the transaction.

import Foundation
import Testing

@testable import Dblore

// MARK: - Pure rules

@Suite("Workspace Transaction - Rules")
struct WorkspaceTransactionRulesTests {
  private func summary(_ sql: String, rows: Int?) -> StatementSummary {
    guard let statement = SQLStatementClassifier.classifyStatement(sql) else {
      Issue.record("Could not classify \(sql)")
      return StatementSummary(
        statement: SQLStatementClassifier.classify("SELECT 1")[0], affectedRows: rows)
    }
    return StatementSummary(statement: statement, affectedRows: rows)
  }

  private var twoPending: [StatementSummary] {
    [
      summary("UPDATE t SET v = 1 WHERE id <= 3", rows: 3),
      summary("CREATE TABLE x (id int)", rows: nil),
      summary("DELETE FROM t WHERE id = 9", rows: 2),
    ]
  }

  // MARK: Banner summary

  @Test("Summary counts statements and sums known affected rows")
  func summaryTotals() {
    let summary = PendingTransactionSummary(state: .appTx(pending: twoPending))
    #expect(summary.statementCount == 3)
    #expect(summary.affectedRows == 5)
    #expect(!summary.isAborted)
    #expect(summary.abortReason == nil)
    #expect(summary.headline == "3 pending statements · 5 rows affected")
    #expect(summary.commitPrompt == "Commit 3 statements · 5 rows?")
  }

  @Test("Summary uses singular forms for one statement and one row")
  func summarySingular() {
    let pending = [summary("UPDATE t SET v = 1 WHERE id = 1", rows: 1)]
    let summary = PendingTransactionSummary(state: .appTx(pending: pending))
    #expect(summary.headline == "1 pending statement · 1 row affected")
    #expect(summary.commitPrompt == "Commit 1 statement · 1 row?")
  }

  @Test("DML with an unknown count is shown as unknown, never as 0 rows")
  func summaryUnknownRowsOnly() {
    let pending = [
      summary("WITH d AS (DELETE FROM t RETURNING id) SELECT count(*) FROM d", rows: nil)
    ]
    let summary = PendingTransactionSummary(state: .appTx(pending: pending))
    #expect(summary.hasUnknownRows)
    #expect(summary.headline == "1 pending statement · rows affected unknown")
    #expect(summary.commitPrompt == "Commit 1 statement · rows unknown?")
    #expect(pending.first?.rowsText == "rows unknown")
  }

  @Test("Known and unknown counts: the known total is a lower bound")
  func summaryKnownAndUnknownRows() {
    let pending = twoPending + [summary("CALL p()", rows: nil)]
    let summary = PendingTransactionSummary(state: .appTx(pending: pending))
    #expect(summary.hasUnknownRows)
    #expect(summary.headline == "4 pending statements · 5+ rows affected (some unknown)")
    #expect(summary.commitPrompt == "Commit 4 statements · 5+ rows (some unknown)?")
  }

  @Test("DDL / SET without a count are not unknown rows; row texts per statement")
  func statementRowsText() {
    #expect(summary("CREATE TABLE x (id int)", rows: nil).rowsUnknown == false)
    #expect(summary("CREATE TABLE x (id int)", rows: nil).rowsText == "")
    #expect(summary("SET search_path = public", rows: nil).rowsUnknown == false)
    #expect(summary("DELETE FROM t", rows: nil).rowsUnknown)
    #expect(summary("DELETE FROM t", rows: 3).rowsText == "3 rows")
    #expect(summary("DELETE FROM t", rows: 1).rowsText == "1 row")
    #expect(summary("DELETE FROM t", rows: 0).rowsText == "0 rows")
  }

  @Test("Adopted transaction: the synthetic entry makes rows unknown and warns on Commit")
  func summaryEarlierChanges() {
    let earlier = StatementSummary.earlierChanges()
    #expect(earlier.isEarlierChanges)
    #expect(earlier.kindLabel == "EARLIER")
    #expect(earlier.affectedRows == nil)
    #expect(earlier.rowsUnknown)
    #expect(earlier.sqlPreview.contains("contents unknown"))

    let summary = PendingTransactionSummary(state: .appTx(pending: [earlier]))
    #expect(summary.includesEarlierChanges)
    #expect(summary.headline.contains("unknown"))
    #expect(!summary.headline.contains("0 rows"))
    #expect(summary.commitPrompt.contains("unknown"))
    #expect(summary.earlierChangesWarning?.contains("before Protected mode") == true)
    #expect(
      PendingTransactionSummary(state: .appTx(pending: twoPending)).earlierChangesWarning == nil)
  }

  @Test("Aborted summary keeps the reason and the pending statements")
  func summaryAborted() {
    let summary = PendingTransactionSummary(
      state: .aborted(reason: "division by zero", pending: twoPending))
    #expect(summary.isAborted)
    #expect(summary.abortReason == "division by zero")
    #expect(summary.statementCount == 3)
  }

  @Test("Idle summary is empty")
  func summaryIdle() {
    let summary = PendingTransactionSummary(state: .idle)
    #expect(summary.statementCount == 0)
    #expect(summary.affectedRows == 0)
  }

  @Test("Open duration formats mm:ss, then h:mm:ss after one hour")
  func openDuration() {
    #expect(PendingTransactionSummary.openDuration(0) == "00:00")
    #expect(PendingTransactionSummary.openDuration(65.7) == "01:05")
    #expect(PendingTransactionSummary.openDuration(3723) == "1:02:03")
    #expect(PendingTransactionSummary.openDuration(-5) == "00:00")
  }

  // MARK: Resolve decision

  @Test("Idle: close, disconnect and quit proceed without a prompt")
  func idleProceeds() {
    let tab = UUID()
    for action in [
      PendingTransactionAction.closeWindow, .closeTab(tab), .disconnect, .quit,
    ] {
      #expect(
        !WorkspaceTransactionRules.requiresResolution(
          state: .idle, action: action, originTabId: tab))
    }
  }

  @Test("Pending: close window, disconnect and quit need a resolution")
  func pendingNeedsResolution() {
    let state = TransactionState.appTx(pending: twoPending)
    for action in [PendingTransactionAction.closeWindow, .disconnect, .quit] {
      #expect(
        WorkspaceTransactionRules.requiresResolution(
          state: state, action: action, originTabId: UUID()))
    }
  }

  @Test("Closing a tab needs a resolution only for the tab that opened the transaction")
  func closeTabOnlyOrigin() {
    let origin = UUID()
    let state = TransactionState.appTx(pending: twoPending)
    #expect(
      WorkspaceTransactionRules.requiresResolution(
        state: state, action: .closeTab(origin), originTabId: origin))
    #expect(
      !WorkspaceTransactionRules.requiresResolution(
        state: state, action: .closeTab(UUID()), originTabId: origin))
    let aborted = TransactionState.aborted(reason: "x", pending: twoPending)
    #expect(
      WorkspaceTransactionRules.requiresResolution(
        state: aborted, action: .closeTab(origin), originTabId: origin))
  }

  @Test("Resolutions: pending offers Commit / Roll back / Cancel, aborted no Commit")
  func resolutions() {
    #expect(WorkspaceTransactionRules.resolutions(for: .idle).isEmpty)
    #expect(
      WorkspaceTransactionRules.resolutions(for: .appTx(pending: twoPending))
        == [.commit, .rollback, .cancel])
    #expect(
      WorkspaceTransactionRules.resolutions(for: .aborted(reason: "x", pending: twoPending))
        == [.rollback, .cancel])
  }

  @Test("Statement in flight: only Discard and disconnect / Cancel, never Commit or Roll back")
  func resolutionsWhileStatementInFlight() {
    for state in [
      TransactionState.appTx(pending: twoPending), .appTx(pending: []),
      .aborted(reason: "x", pending: twoPending),
    ] {
      let options = WorkspaceTransactionRules.resolutions(for: state, statementInFlight: true)
      #expect(options == [.discard, .cancel])
      #expect(!options.contains(.commit))
      #expect(!options.contains(.rollback))
    }
    #expect(
      !WorkspaceTransactionRules.resolutions(
        for: .appTx(pending: twoPending), statementInFlight: false
      ).contains(.discard))
    #expect(WorkspaceTransactionRules.resolutions(for: .idle, statementInFlight: true).isEmpty)
  }

  @Test("Commit / Rollback awaited: a kind-specific disconnect answer and Cancel")
  func resolutionsWhileEnding() {
    let committing = TransactionState.ending(kind: .commit, pending: twoPending)
    let rollingBack = TransactionState.ending(kind: .rollback, pending: twoPending)
    #expect(
      WorkspaceTransactionRules.resolutions(for: committing) == [
        .disconnectUnknownOutcome, .cancel,
      ])
    #expect(WorkspaceTransactionRules.resolutions(for: rollingBack) == [.disconnect, .cancel])
    #expect(
      WorkspaceTransactionRules.resolutions(for: committing, statementInFlight: true)
        == [.disconnectUnknownOutcome, .cancel])
  }

  @Test("Disconnect answers: destructive, titled and explained truthfully per kind")
  func disconnectWording() {
    typealias Rules = WorkspaceTransactionRules
    #expect(Rules.title(for: .disconnectUnknownOutcome) == "Disconnect (outcome unknown)")
    #expect(Rules.title(for: .disconnect) == "Disconnect")
    #expect(Rules.title(for: .discard) == "Discard Changes and Disconnect")
    for resolution in [
      PendingTransactionResolution.discard, .disconnect, .disconnectUnknownOutcome,
    ] {
      #expect(Rules.isDestructive(resolution))
    }
    for resolution in [PendingTransactionResolution.commit, .rollback, .cancel] {
      #expect(!Rules.isDestructive(resolution))
    }

    let committing = PendingTransactionSummary(
      state: .ending(kind: .commit, pending: twoPending))
    let commitText = Rules.promptDecision(
      summary: committing, options: [.disconnectUnknownOutcome, .cancel], action: .quit)
    #expect(
      commitText
        == "Commit was sent and has not answered. Disconnecting closes the connection: the "
        + "changes may or may not have been committed. Check the data after reconnecting.")
    #expect(!commitText.contains("nothing is committed"))

    let rollingBack = PendingTransactionSummary(
      state: .ending(kind: .rollback, pending: twoPending))
    #expect(
      Rules.promptDecision(summary: rollingBack, options: [.disconnect, .cancel], action: .quit)
        == "Rollback was sent and has not answered. Disconnecting closes the connection; the "
        + "server discards the pending changes.")

    let pending = PendingTransactionSummary(state: .appTx(pending: twoPending))
    #expect(
      Rules.promptDecision(summary: pending, options: [.discard, .cancel], action: .disconnect)
        .contains("(nothing is committed)"))
    #expect(
      Rules.promptDecision(
        summary: pending, options: [.commit, .rollback, .cancel], action: .disconnect)
        == "Commit or roll back before disconnecting.")
    let aborted = PendingTransactionSummary(state: .aborted(reason: "boom", pending: twoPending))
    #expect(
      Rules.promptDecision(summary: aborted, options: [.rollback, .cancel], action: .quit)
        .hasPrefix("Only Rollback is possible (boom)"))
  }

  @Test("Forced close: first safe non-commit answer, never Commit or an unknown outcome")
  func forcedResolution() {
    typealias Rules = WorkspaceTransactionRules
    #expect(Rules.forcedResolution(for: .idle) == nil)
    #expect(Rules.forcedResolution(for: .appTx(pending: twoPending)) == .rollback)
    #expect(Rules.forcedResolution(for: .aborted(reason: "x", pending: twoPending)) == .rollback)
    #expect(
      Rules.forcedResolution(for: .appTx(pending: twoPending), statementInFlight: true) == .discard)
    #expect(Rules.forcedResolution(for: .ending(kind: .rollback, pending: [])) == .disconnect)
    // Disconnecting during COMMIT might commit: a forced close still asks
    #expect(Rules.forcedResolution(for: .ending(kind: .commit, pending: [])) == nil)
  }

  @Test("Banner offers Disconnect only once Commit / Rollback takes longer than 5 s")
  func slowEndingPrompt() {
    typealias Summary = PendingTransactionSummary
    #expect(Summary.slowEndingPrompt(nil, elapsed: 60) == nil)
    #expect(Summary.slowEndingPrompt(.commit, elapsed: 4.9) == nil)
    #expect(Summary.slowEndingPrompt(.commit, elapsed: 5) == "Commit is taking long — Disconnect…")
    #expect(
      Summary.slowEndingPrompt(.rollback, elapsed: 12) == "Rollback is taking long — Disconnect…")
  }

  // MARK: Review text (Commit confirmation and resolve prompt)

  @Test("Review text lists each statement with kind, preview and rows")
  func reviewTextListsStatements() {
    let text = PendingTransactionSummary(state: .appTx(pending: twoPending)).reviewText
    #expect(text.contains("UPDATE t SET v = 1 WHERE id <= 3"))
    #expect(text.contains("3 rows"))
    #expect(text.contains("CREATE TABLE x (id int)"))
    #expect(text.contains("DELETE FROM t WHERE id = 9"))
    #expect(text.contains("2 rows"))
    #expect(!text.contains("more"))
    #expect(!text.contains("Warning"))
  }

  @Test("Review text shows rows unknown, the earlier-changes warning and the overflow count")
  func reviewTextUnknownWarningAndMore() {
    let unknown = summary("DELETE FROM t WHERE id > 5", rows: nil)
    let adopted = PendingTransactionSummary(
      state: .appTx(pending: [.earlierChanges(), unknown])
    ).reviewText
    #expect(adopted.contains("EARLIER"))
    #expect(adopted.contains("DELETE FROM t WHERE id > 5 (rows unknown)"))
    #expect(adopted.contains("before Protected mode"))

    let many = (1...13).map { summary("UPDATE t SET v = \($0) WHERE id = \($0)", rows: 1) }
    let long = PendingTransactionSummary(state: .appTx(pending: many)).reviewText
    #expect(long.contains("UPDATE t SET v = 10 WHERE id = 10"))
    #expect(!long.contains("UPDATE t SET v = 11 WHERE id = 11"))
    #expect(long.contains("… and 3 more"))
  }

  // MARK: Commit unlock

  @Test("Commit requires the Safe Mode unlock only under safeRead / safeAll")
  func commitUnlock() {
    #expect(WorkspaceTransactionRules.commitRequiresUnlock(safeMode: .safeRead))
    #expect(WorkspaceTransactionRules.commitRequiresUnlock(safeMode: .safeAll))
    #expect(!WorkspaceTransactionRules.commitRequiresUnlock(safeMode: .silent))
    #expect(!WorkspaceTransactionRules.commitRequiresUnlock(safeMode: .alertRead))
    #expect(!WorkspaceTransactionRules.commitRequiresUnlock(safeMode: .alertAll))
  }
}

// MARK: - WorkspaceManager flow (no database)

@Suite("Workspace Transaction - Commit flow")
@MainActor
struct WorkspaceTransactionCommitFlowTests {
  private func workspace(safeMode: SafeMode?) -> WorkspaceManager {
    let manager = WorkspaceManager(workspace: Workspace())
    manager.workspace.connectionConfig = ConnectionConfig(
      host: "db.example.com", port: 5432, database: "app", username: "u", password: "pw",
      safeMode: safeMode, protectedMode: true)
    let pending = SQLStatementClassifier.classify("UPDATE t SET v = 1 WHERE id = 1").map {
      StatementSummary(statement: $0, affectedRows: 1)
    }
    manager.pendingTransaction = .appTx(pending: pending)
    return manager
  }

  @Test("requestCommit shows the confirmation; aborted does not")
  func requestCommitShowsConfirmation() {
    let manager = workspace(safeMode: nil)
    manager.requestCommit()
    #expect(manager.isCommitConfirmationVisible)

    let aborted = workspace(safeMode: nil)
    aborted.pendingTransaction = .aborted(reason: "x", pending: [])
    aborted.requestCommit()
    #expect(!aborted.isCommitConfirmationVisible)
  }

  @Test("Confirmed Commit under safeAll asks for the unlock and commits nothing yet")
  func confirmCommitSafeAllNeedsUnlock() async {
    let manager = workspace(safeMode: .safeAll)
    manager.requestCommit()
    await manager.confirmCommit(globalSafeMode: .silent)
    #expect(manager.isCommitUnlockVisible)
    #expect(!manager.pendingTransaction.isIdle)
  }

  @Test("Global safeRead fallback also asks for the unlock")
  func confirmCommitGlobalSafeReadNeedsUnlock() async {
    let manager = workspace(safeMode: nil)
    manager.requestCommit()
    await manager.confirmCommit(globalSafeMode: .safeRead)
    #expect(manager.isCommitUnlockVisible)
  }

  @Test("Confirmed Commit without a password Safe Mode commits directly (no unlock)")
  func confirmCommitSilentCommits() async {
    let manager = workspace(safeMode: .alertAll)
    manager.requestCommit()
    await manager.confirmCommit(globalSafeMode: .silent)
    #expect(!manager.isCommitUnlockVisible)
    // Disconnected actor: nothing pending there, the mirror is refreshed to idle
    #expect(manager.pendingTransaction.isIdle)
  }

  @Test("Commit needs the confirmation (and the unlock) first: direct calls do nothing")
  func commitOnlyThroughConfirmation() async {
    let manager = workspace(safeMode: .alertAll)
    #expect(!(await manager.confirmCommit(globalSafeMode: .silent)))
    #expect(!manager.pendingTransaction.isIdle)
    #expect(!(await manager.completeCommitUnlock()))
    #expect(!manager.pendingTransaction.isIdle)
    // A cancelled confirmation leaves nothing to confirm
    manager.requestCommit()
    manager.cancelCommitConfirmation()
    #expect(!(await manager.confirmCommit(globalSafeMode: .silent)))
    #expect(!manager.pendingTransaction.isIdle)
  }
}

// MARK: - Integration

@Suite("Workspace Transaction - Integration (Requires PostgreSQL)", .serialized)
@MainActor
struct WorkspaceTransactionIntegrationTests {
  private static func config(protectedMode: Bool = true) -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      // Explicit, so the global Safe Mode of the test host never applies
      safeMode: .silent,
      protectedMode: protectedMode
    )
  }

  private struct Fixture {
    let workspace: WorkspaceManager
    let tabId: UUID
    let viewModel: NotebookViewModel
    let observer: DatabaseConnectionManager
    let table: String
  }

  /// Creates `table (id int PRIMARY KEY, v int)` with row (1, 10) through an unprotected
  /// observer, then a workspace connected in Protected mode with one notebook tab.
  private func setUp(_ table: String) async throws -> Fixture {
    let observer = DatabaseConnectionManager()
    try await observer.connect(config: Self.config(protectedMode: false))
    _ = try await observer.executeInternal("DROP TABLE IF EXISTS \(table)")
    _ = try await observer.executeInternal("CREATE TABLE \(table) (id int PRIMARY KEY, v int)")
    _ = try await observer.executeInternal("INSERT INTO \(table) VALUES (1, 10)")

    let workspace = WorkspaceManager(workspace: Workspace())
    // Never show an NSAlert from tests: an unexpected prompt cancels
    workspace.pendingTransactionPrompt = { _, _, _ in .cancel }
    let tabId = workspace.newNotebook()
    try await workspace.connect(config: Self.config(), globalSafeMode: .silent)
    await workspace.awaitSchemaLoad()
    guard let viewModel = workspace.viewModel(for: tabId) else {
      throw DatabaseError.notConnected
    }
    return Fixture(
      workspace: workspace, tabId: tabId, viewModel: viewModel, observer: observer, table: table)
  }

  private func tearDown(_ fixture: Fixture) async {
    try? await fixture.workspace.connectionManager.rollbackAppTransaction()
    await fixture.workspace.disconnect(resolution: .rollback)
    _ = try? await fixture.observer.executeInternal("DROP TABLE IF EXISTS \(fixture.table)")
    await fixture.observer.disconnect()
  }

  /// Run `sql` in the tab like a cell run (the ViewModel execution path + hook)
  @discardableResult
  private func run(_ sql: String, in fixture: Fixture) async -> CellResult? {
    await run(sql, in: fixture.viewModel)
  }

  @discardableResult
  private func run(_ sql: String, in viewModel: NotebookViewModel) async -> CellResult? {
    let cell = NotebookCell(cellType: .sql, content: sql)
    viewModel.notebook.cells.append(cell)
    return await viewModel.executeTask(ExecutionTask(cellId: cell.id, query: sql))
  }

  /// The banner path: Commit, then the confirmation accepted (no password Safe Mode)
  private func commit(_ fixture: Fixture) async -> Bool {
    fixture.workspace.requestCommit()
    return await fixture.workspace.confirmCommit(globalSafeMode: .silent)
  }

  private func committedValue(_ fixture: Fixture) async throws -> CellValue? {
    try await fixture.observer.executeInternal(
      "SELECT v FROM \(fixture.table) WHERE id = 1"
    ).rows.first?.first
  }

  @Test("UPDATE in a tab: the workspace mirror shows 1 pending statement with its rows")
  func updateShowsPending() async throws {
    let fixture = try await setUp("p3_ws_pending")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)

    let pending = fixture.workspace.pendingTransaction.pending
    #expect(pending.count == 1)
    #expect(pending.first?.affectedRows == 1)
    #expect(fixture.workspace.transactionOriginTabId == fixture.tabId)
    #expect(fixture.workspace.transactionOpenedAt != nil)
    await tearDown(fixture)
  }

  @Test("rollback(): idle again and the row is unchanged")
  func rollbackRestores() async throws {
    let fixture = try await setUp("p3_ws_rollback")
    await run("UPDATE \(fixture.table) SET v = 30 WHERE id = 1", in: fixture)
    #expect(!fixture.workspace.pendingTransaction.isIdle)

    #expect(await fixture.workspace.rollback())
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(fixture.workspace.transactionOpenedAt == nil)
    #expect(fixture.workspace.transactionOriginTabId == nil)
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  @Test("Confirmed commit: idle again and the row is changed")
  func commitApplies() async throws {
    let fixture = try await setUp("p3_ws_commit")
    await run("UPDATE \(fixture.table) SET v = 40 WHERE id = 1", in: fixture)

    #expect(await commit(fixture))
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(try await committedValue(fixture) == .int(40))
    await tearDown(fixture)
  }

  @Test(
    "A statement run after the confirmation was shown: Commit refused, review again commits",
    .timeLimit(.minutes(1)))
  func commitRefusedWhenListChangedAfterReview() async throws {
    let fixture = try await setUp("p3_ws_changed_after_review")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    fixture.workspace.requestCommit()
    #expect(fixture.workspace.isCommitConfirmationVisible)
    // The origin tab runs another statement while the confirmation is open
    await run("UPDATE \(fixture.table) SET v = 30 WHERE id = 1", in: fixture)

    #expect(!(await fixture.workspace.confirmCommit(globalSafeMode: .silent)))
    #expect(fixture.workspace.pendingTransaction.pending.count == 2)
    #expect(try await committedValue(fixture) == .int(10))

    #expect(await commit(fixture))
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(try await committedValue(fixture) == .int(30))
    await tearDown(fixture)
  }

  @Test("Error mid-transaction: aborted, Commit refused, Rollback works")
  func abortedOnlyRollback() async throws {
    let fixture = try await setUp("p3_ws_aborted")
    await run("UPDATE \(fixture.table) SET v = 50 WHERE id = 1", in: fixture)
    await run("SELECT 1 / 0", in: fixture)

    guard case .aborted = fixture.workspace.pendingTransaction else {
      Issue.record("Expected aborted, got \(fixture.workspace.pendingTransaction)")
      await tearDown(fixture)
      return
    }
    #expect(!(await commit(fixture)))
    if case .aborted = fixture.workspace.pendingTransaction {
    } else {
      Issue.record("Commit must leave the aborted transaction for Rollback")
    }

    #expect(await fixture.workspace.rollback())
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  @Test("Disconnect with pending changes needs a resolution: Cancel keeps the connection")
  func disconnectRequiresResolution() async throws {
    let fixture = try await setUp("p3_ws_disconnect")
    await run("UPDATE \(fixture.table) SET v = 60 WHERE id = 1", in: fixture)

    // The prompt answers Cancel: nothing is lost
    #expect(!(await fixture.workspace.disconnect()))
    #expect(fixture.workspace.connectionState == .connected)
    #expect(fixture.workspace.pendingTransaction.pending.count == 1)

    // The prompt answers Roll back: disconnected, row unchanged
    fixture.workspace.pendingTransactionPrompt = { _, _, _ in .rollback }
    #expect(await fixture.workspace.disconnect())
    #expect(fixture.workspace.connectionState == .disconnected)
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  @Test("Disconnect resolved with Commit keeps the change")
  func disconnectWithCommit() async throws {
    let fixture = try await setUp("p3_ws_disconnect_commit")
    await run("UPDATE \(fixture.table) SET v = 70 WHERE id = 1", in: fixture)

    #expect(await fixture.workspace.disconnect(resolution: .commit))
    #expect(fixture.workspace.connectionState == .disconnected)
    #expect(try await committedValue(fixture) == .int(70))
    await tearDown(fixture)
  }

  // MARK: P4 - other tabs blocked, metadata from cache, reconnect

  @Test("Another tab is blocked while the transaction is pending; the origin tab still runs")
  func otherTabBlocked() async throws {
    let fixture = try await setUp("p4_ws_other_tab")
    let otherTabId = fixture.workspace.newNotebook()
    guard let other = fixture.workspace.viewModel(for: otherTabId) else {
      Issue.record("No second tab")
      await tearDown(fixture)
      return
    }
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    #expect(fixture.workspace.transactionOriginTabId == fixture.tabId)

    // Nothing is sent from the other tab: no result, still 1 pending statement
    let blocked = await run("UPDATE \(fixture.table) SET v = 99 WHERE id = 1", in: other)
    #expect(blocked == nil)
    #expect(fixture.workspace.pendingTransaction.pending.count == 1)
    #expect(fixture.workspace.transactionOriginTabId == fixture.tabId)

    // The origin tab still runs (and sees its own change)
    let read = await run("SELECT v FROM \(fixture.table) WHERE id = 1", in: fixture)
    #expect(read?.error == nil)
    #expect(read?.rows.first?.first == .int(20))

    #expect(await commit(fixture))
    #expect(try await committedValue(fixture) == .int(20))
    await tearDown(fixture)
  }

  @Test("Schema refresh while pending serves the cache and sends no SQL")
  func schemaRefreshServesCache() async throws {
    let fixture = try await setUp("p4_ws_schema_cache")
    let newTable = "p4_ws_schema_new"
    _ = try await fixture.observer.executeInternal("DROP TABLE IF EXISTS \(newTable)")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    #expect(fixture.workspace.isSchemaPaused)

    // Created and committed by another session: a refresh that queried would see it
    _ = try await fixture.observer.executeInternal("CREATE TABLE \(newTable) (id int)")
    await fixture.workspace.refreshDatabaseSchema()
    #expect(!fixture.workspace.databaseTables.contains { $0.name == newTable })
    #expect(fixture.workspace.databaseTables.contains { $0.name == fixture.table })
    guard case .appTx(let pending) = fixture.workspace.pendingTransaction else {
      Issue.record("Expected appTx, got \(fixture.workspace.pendingTransaction)")
      await tearDown(fixture)
      return
    }
    #expect(pending.count == 1)

    #expect(await fixture.workspace.rollback())
    #expect(!fixture.workspace.isSchemaPaused)
    await fixture.workspace.refreshDatabaseSchema()
    #expect(fixture.workspace.databaseTables.contains { $0.name == newTable })
    _ = try? await fixture.observer.executeInternal("DROP TABLE IF EXISTS \(newTable)")
    await tearDown(fixture)
  }

  @Test("A read inside the transaction skips type enrichment and edit lookup; Commit works")
  func readInsideTransactionSendsNoCatalogQuery() async throws {
    let fixture = try await setUp("p4_ws_enrich")
    // A column name that breaks the enrichment catalog query ('it's' in its IN list): run
    // inside the transaction, that query would fail and abort it
    _ = try await fixture.observer.executeInternal(
      "ALTER TABLE \(fixture.table) ADD COLUMN \"it's\" int")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)

    let read = await run("SELECT * FROM \(fixture.table)", in: fixture)
    #expect(read?.error == nil)
    #expect(read?.editTarget == nil)
    guard case .appTx = fixture.workspace.pendingTransaction else {
      Issue.record("Expected appTx, got \(fixture.workspace.pendingTransaction)")
      await tearDown(fixture)
      return
    }
    #expect(await commit(fixture))
    #expect(try await committedValue(fixture) == .int(20))
    await tearDown(fixture)
  }

  @Test(
    "Reconnect with pending changes: Cancel keeps connection and transaction; Roll back reconnects")
  func reconnectRequiresResolution() async throws {
    let fixture = try await setUp("p4_ws_reconnect")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)

    // The prompt answers Cancel: the connect is aborted, nothing is lost
    var prompted: PendingTransactionAction?
    fixture.workspace.pendingTransactionPrompt = { action, _, _ in
      prompted = action
      return .cancel
    }
    await #expect(throws: WorkspaceConnectError.pendingTransactionKept) {
      try await fixture.workspace.connect(config: Self.config(), globalSafeMode: .silent)
    }
    #expect(prompted == .disconnect)
    #expect(fixture.workspace.connectionState == .connected)
    #expect(fixture.workspace.pendingTransaction.pending.count == 1)
    #expect(await fixture.workspace.connectionManager.transactionSnapshot().pending.count == 1)

    // The prompt answers Roll back: reconnected, row unchanged
    fixture.workspace.pendingTransactionPrompt = { _, _, _ in .rollback }
    do {
      try await fixture.workspace.connect(config: Self.config(), globalSafeMode: .silent)
    } catch {
      Issue.record(error)
    }
    #expect(fixture.workspace.connectionState == .connected)
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }

  // MARK: Round 2 - no way out while a statement hangs

  @Test(
    "Statement in flight: disconnect offers Discard (no Commit), which returns promptly",
    .timeLimit(.minutes(1)))
  func discardWhileStatementInFlight() async throws {
    let fixture = try await setUp("p3_ws_discard_in_flight")
    await run("UPDATE \(fixture.table) SET v = 20 WHERE id = 1", in: fixture)
    let hung = Task {
      await run(
        "UPDATE \(fixture.table) SET v = 30 WHERE id = 1 AND pg_sleep(20) IS NOT NULL", in: fixture)
    }
    try await Task.sleep(for: .milliseconds(500))

    var offered: [PendingTransactionResolution] = []
    fixture.workspace.pendingTransactionPrompt = { _, _, options in
      offered = options
      return .discard
    }
    let start = Date()
    #expect(await fixture.workspace.disconnect())
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(offered.contains(.discard))
    #expect(!offered.contains(.commit))
    #expect(fixture.workspace.connectionState == .disconnected)
    #expect(!(await fixture.workspace.connectionManager.isConnected))
    #expect(fixture.workspace.pendingTransaction.isIdle)
    #expect(try await committedValue(fixture) == .int(10))

    let result = await hung.value
    #expect(result?.error != nil)
    // The server backend may still sleep holding the row lock: end it, then nothing was committed
    _ = try? await fixture.observer.executeInternal(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        + "WHERE pid <> pg_backend_pid() AND query LIKE '%\(fixture.table)%pg_sleep%'")
    #expect(try await committedValue(fixture) == .int(10))
    await tearDown(fixture)
  }
}
