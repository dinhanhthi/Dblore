// ViewModelQueryConfirmationTests.swift
// Tests for query confirmation dialog functionality (Phase 6.0.3)

import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Query Confirmation Tests")
@MainActor
struct ViewModelQueryConfirmationTests {

  // Helper to create a test notebook
  func createTestNotebook() -> DbloreNotebook {
    DbloreNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: UUID(),
          cellType: .sql,
          content: "SELECT 1;",
          executionCount: 0,
          result: nil
        )
      ],
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Test Notebook"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )
  }

  // MARK: - Modification Query Detection Tests

  @Test("Detect UPDATE query as modification")
  func detectUpdateQueryAsModification() {
    // Act & Assert
    #expect(isModificationQuery("UPDATE users SET name = 'John' WHERE id = 1"))
    #expect(isModificationQuery("  UPDATE users SET name = 'John'  "))
    #expect(isModificationQuery("update users SET name = 'John'"))
  }

  @Test("Detect DELETE query as modification")
  func detectDeleteQueryAsModification() {
    // Act & Assert
    #expect(isModificationQuery("DELETE FROM users WHERE id = 1"))
    #expect(isModificationQuery("  DELETE FROM users  "))
    #expect(isModificationQuery("delete from users"))
  }

  @Test("Detect INSERT query as modification")
  func detectInsertQueryAsModification() {
    // Act & Assert
    #expect(isModificationQuery("INSERT INTO users (name) VALUES ('John')"))
    #expect(isModificationQuery("  INSERT INTO users VALUES (1, 'John')  "))
    #expect(isModificationQuery("insert into users (name) values ('John')"))
  }

  @Test("SELECT query is not a modification")
  func selectQueryIsNotModification() {
    // Act & Assert
    #expect(!isModificationQuery("SELECT * FROM users"))
    #expect(!isModificationQuery("  SELECT id, name FROM users WHERE id = 1  "))
    #expect(!isModificationQuery("select * from users"))
  }

  @Test("Detect DROP query as modification")
  func detectDropQueryAsModification() {
    // Act & Assert - DROP is a destructive schema modification
    #expect(isModificationQuery("DROP TABLE users"))
    #expect(isModificationQuery("DROP DATABASE mydb"))
    #expect(isModificationQuery("DROP INDEX idx_name"))
    #expect(isModificationQuery("DROP VIEW my_view"))
    #expect(isModificationQuery("drop table users"))
  }

  @Test("Detect TRUNCATE query as modification")
  func detectTruncateQueryAsModification() {
    // Act & Assert - TRUNCATE deletes all rows (destructive)
    #expect(isModificationQuery("TRUNCATE TABLE users"))
    #expect(isModificationQuery("TRUNCATE users"))
    #expect(isModificationQuery("truncate table users"))
  }

  @Test("Detect ALTER query as modification")
  func detectAlterQueryAsModification() {
    // Act & Assert - ALTER can be destructive (DROP COLUMN, etc.)
    #expect(isModificationQuery("ALTER TABLE users ADD COLUMN age INT"))
    #expect(isModificationQuery("ALTER TABLE users DROP COLUMN email"))
    #expect(isModificationQuery("ALTER TABLE users RENAME TO customers"))
    #expect(isModificationQuery("alter table users add column age int"))
  }

  @Test("Detect CREATE query as modification")
  func detectCreateQueryAsModification() {
    // Act & Assert - CREATE is a schema modification (Safe Mode confirms it, read-only blocks it)
    #expect(isModificationQuery("CREATE TABLE users (id INT)"))
    #expect(isModificationQuery("CREATE INDEX idx_name ON users(name)"))
    #expect(isModificationQuery("CREATE VIEW user_view AS SELECT * FROM users"))
  }

  // MARK: - Confirmation Dialog Tests

  @Test("Confirm and run shows dialog for UPDATE query")
  func confirmAndRunShowsDialogForUpdate() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"

    // Pin the global commit style (loaded from UserDefaults; other tests persist different values)
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .confirm
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.requiresPassword == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "UPDATE users SET name = 'John'")
  }

  @Test("Confirm and run shows dialog for DELETE query")
  func confirmAndRunShowsDialogForDelete() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"

    // Pin the global commit style (loaded from UserDefaults; other tests persist different values)
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .confirm
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.requiresPassword == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "DELETE FROM users WHERE id = 1")
  }

  @Test("Confirm and run shows dialog for INSERT query")
  func confirmAndRunShowsDialogForInsert() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"

    // Pin the global commit style (loaded from UserDefaults; other tests persist different values)
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .confirm
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.requiresPassword == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(
      viewModel.queryConfirmationState.pendingQuery == "INSERT INTO users (name) VALUES ('John')")
  }

  @Test("Confirm and run executes directly for SELECT query")
  func confirmAndRunExecutesDirectlyForSelect() async {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT * FROM users"

    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .confirm

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - confirm does not list a plain SELECT
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Cancel pending query clears state")
  func cancelPendingQueryClearsState() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users"
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .confirm
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }
    viewModel.confirmAndRunCell(id: cellId)
    #expect(viewModel.queryConfirmationState.showDialog == true)

    // Act
    viewModel.cancelPendingQuery()

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")
  }

  @Test("readOnly-blocked cell shows the protection toast and no dialog")
  func readOnlyBlockedCellShowsToastNoDialog() {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT 1; SET statement_timeout = 0"
    viewModel.notebook.connectionConfig = ConnectionConfig(protectionLevel: .readOnly)
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .immediate
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }

    // Reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.statements.isEmpty)
  }

  // MARK: - Editor mode

  /// Runs `runEditorQuery` on the whole editor content with the commit style and Simple Mode pinned.
  private func runEditor(_ sql: String, style: CommitStyle) async -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.connectionState = .connected
    viewModel.editorContent = sql
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    let previousSimpleMode = AppSettings.shared.editorSimpleMode
    AppSettings.shared.commitStyle = style
    AppSettings.shared.editorSimpleMode = false
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
      AppSettings.shared.editorSimpleMode = previousSimpleMode
    }
    await viewModel.runEditorQuery()
    return viewModel
  }

  @Test("Editor confirm lists a DELETE without WHERE after a SELECT")
  func editorConfirmListsLaterDelete() async {
    let state = await runEditor("SELECT 1; DELETE FROM t", style: .confirm)
      .queryConfirmationState

    #expect(state.showDialog)
    #expect(!state.requiresPassword)
    #expect(state.pendingCellId == nil)
    #expect(state.affectsAllRows)
    #expect(state.statements.map(\.index) == [1])
  }

  @Test("Editor immediate does not confirm a brake SET")
  func editorImmediateSkipsBrakeSet() async {
    let state = await runEditor("SET lock_timeout = 0", style: .immediate).queryConfirmationState

    #expect(!state.showDialog)
    #expect(state.statements.isEmpty)
  }

  @Test("Editor confirm lists CALL (fail closed)")
  func editorConfirmListsCall() async {
    let state = await runEditor("CALL do_things()", style: .confirm).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.map(\.index) == [0])
  }

  // MARK: - Run All

  /// Runs `runAllCells` on one SQL cell per entry. Commit style defaults to confirm so the
  /// destructive bypass applies; parallel tests mutate the global setting.
  private func runAll(
    _ contents: [String], bypass: Bool, protection: ConnectionProtectionLevel = .none,
    style: CommitStyle = .confirm
  ) async -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.notebook.cells = contents.map {
      NotebookCell(id: UUID(), cellType: .sql, content: $0, executionCount: 0, result: nil)
    }
    var config = ConnectionConfig(protectionLevel: protection, protectedMode: false)
    config.applyCommitStyle(style)
    viewModel.notebook.connectionConfig = config
    await viewModel.runAllCells(bypass: bypass)
    return viewModel
  }

  @Test("Run All confirms a brake or privilege change even when the destructive bypass is on")
  func runAllConfirmsBrakeSetDespiteBypass() async {
    for sql in ["SET statement_timeout = 0", "SET ROLE admin"] {
      let state = await runAll(["SELECT 1", sql], bypass: true).queryConfirmationState

      #expect(state.showRunAllConfirmation, "\(sql)")
      #expect(!state.runAllAwaitingUnlock, "\(sql)")
      #expect(state.runAllConfirmCells.map(\.number) == [2], "\(sql)")
      #expect(state.runAllConfirmCells.first?.isSafetyCritical == true, "\(sql)")
    }
  }

  @Test("Run All with the bypass on runs plain DML without a dialog")
  func runAllBypassSkipsDmlDialog() async {
    let state = await runAll(["DELETE FROM t", "INSERT INTO t VALUES (1)"], bypass: true)
      .queryConfirmationState

    #expect(!state.showRunAllConfirmation)
  }

  @Test("Run All with the bypass on lists only the safety-critical cell")
  func runAllBypassListsOnlySafetyCell() async {
    let state = await runAll(["DELETE FROM t", "RESET ALL"], bypass: true).queryConfirmationState

    #expect(state.showRunAllConfirmation)
    #expect(state.runAllConfirmCells.map(\.number) == [2])
  }

  @Test("Run All confirms a DO block (fail closed) when the bypass is off")
  func runAllConfirmsDoBlock() async {
    let state = await runAll(["DO $$ BEGIN PERFORM 1; END $$"], bypass: false)
      .queryConfirmationState

    #expect(state.showRunAllConfirmation)
  }

  @Test("Run All with only SELECT cells shows no dialog")
  func runAllSelectOnlyNoDialog() async {
    let state = await runAll(["SELECT 1", "SELECT 2; SELECT 3"], bypass: false)
      .queryConfirmationState

    #expect(!state.showRunAllConfirmation)
  }

  @Test("Run All stops with the protection toast when a cell is blocked; nothing runs")
  func runAllBlockedCellStopsEverything() async {
    WorkspaceWindowManager.shared.dismissToast()
    let viewModel = await runAll(
      ["SELECT 1", "DELETE FROM t WHERE id = 1"], bypass: false, protection: .readOnly)

    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
    #expect(!viewModel.queryConfirmationState.showRunAllConfirmation)
    #expect(
      viewModel.notebook.cells.allSatisfy { !viewModel.executionQueue.isInQueue(cellId: $0.id) })
  }

  @Test("Statement preview skips leading comments")
  func previewSkipsLeadingComments() {
    let classified = SQLStatementClassifier.classify("-- note\n/* block */ DELETE FROM t")
    let statements = NotebookViewModel.statementsNeedingConfirmation(
      classified, commitStyle: .confirm)

    #expect(statements?.first?.preview == "DELETE FROM t")
  }

  @Test("Confirmation summary lists the first 8 statements, then how many more")
  func confirmationSummaryIsCapped() throws {
    let sql = (1...10).map { "INSERT INTO t\($0) VALUES (1)" }.joined(separator: "; ")
    let statements = try #require(
      NotebookViewModel.statementsNeedingConfirmation(
        SQLStatementClassifier.classify(sql), commitStyle: .confirm))

    let lines = NotebookViewModel.confirmationSummary(statements).split(separator: "\n")

    #expect(lines.count == 9)
    #expect(lines.first == "1. INSERT INTO t1 VALUES (1)")
    #expect(lines[7] == "8. INSERT INTO t8 VALUES (1)")
    #expect(lines.last == "…and 2 more")
  }

  @Test("Run All summary prefixes each statement with its cell number")
  func runAllSummaryNamesCells() throws {
    let statements = try #require(
      NotebookViewModel.statementsNeedingConfirmation(
        SQLStatementClassifier.classify("SET statement_timeout = 0"), commitStyle: .confirm))
    let cell = RunAllCell(id: UUID(), number: 3, query: "", statements: statements)

    let summary = NotebookViewModel.runAllSummary([cell])

    #expect(summary.hasPrefix("Cell 3, 1. SET statement_timeout = 0"))
  }

  @Test("Confirm and run with non-existent cell does nothing")
  func confirmAndRunWithNonExistentCell() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let nonExistentId = UUID()

    // Act
    viewModel.confirmAndRunCell(id: nonExistentId)

    // Assert - Nothing should happen
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")
  }
}

/// Classifier-based replacement for the removed prefix-based `NotebookViewModel.isModificationQuery`
private func isModificationQuery(_ query: String) -> Bool {
  SQLStatementClassifier.summary(SQLStatementClassifier.classify(query)).hasModification
}
