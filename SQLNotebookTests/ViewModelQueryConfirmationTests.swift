// ViewModelQueryConfirmationTests.swift
// Tests for query confirmation dialog functionality (Phase 6.0.3)

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Query Confirmation Tests")
@MainActor
struct ViewModelQueryConfirmationTests {

  // Helper to create a test notebook
  func createTestNotebook() -> SQLNotebook {
    SQLNotebook(
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

    // Pin global SafeMode (loaded from UserDefaults; other tests persist different values)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead
    defer { AppSettings.shared.safeMode = previousSafeMode }

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == true)
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

    // Pin global SafeMode (loaded from UserDefaults; other tests persist different values)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead
    defer { AppSettings.shared.safeMode = previousSafeMode }

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == true)
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

    // Pin global SafeMode (loaded from UserDefaults; other tests persist different values)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead
    defer { AppSettings.shared.safeMode = previousSafeMode }

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == true)
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

    // Ensure SafeMode is alertRead (only confirms modification queries, not SELECT)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown for SELECT in alertRead mode
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Cancel pending query clears state")
  func cancelPendingQueryClearsState() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users"
    // Pin global SafeMode (loaded from UserDefaults; other tests persist different values)
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertRead
    defer { AppSettings.shared.safeMode = previousSafeMode }
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
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .silent
    defer { AppSettings.shared.safeMode = previousSafeMode }

    // Reset the process-wide toast so leftovers from other tests can't leak in
    WorkspaceWindowManager.shared.dismissToast()
    viewModel.confirmAndRunCell(id: cellId)

    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.type == .error)
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.queryConfirmationState.statements.isEmpty)
  }

  // MARK: - Editor mode

  /// Runs `runEditorQuery` on the whole editor content with SafeMode and Simple Mode pinned.
  private func runEditor(_ sql: String, safeMode: SafeMode) async -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.connectionState = .connected
    viewModel.editorContent = sql
    let previousSafeMode = AppSettings.shared.safeMode
    let previousSimpleMode = AppSettings.shared.editorSimpleMode
    AppSettings.shared.safeMode = safeMode
    AppSettings.shared.editorSimpleMode = false
    defer {
      AppSettings.shared.safeMode = previousSafeMode
      AppSettings.shared.editorSimpleMode = previousSimpleMode
    }
    await viewModel.runEditorQuery()
    return viewModel
  }

  @Test("Editor alertRead confirms a DELETE without WHERE after a SELECT")
  func editorAlertReadConfirmsLaterDelete() async {
    let state = await runEditor("SELECT 1; DELETE FROM t", safeMode: .alertRead)
      .queryConfirmationState

    #expect(state.showDialog)
    #expect(state.pendingCellId == nil)
    #expect(state.affectsAllRows)
    #expect(state.statements.map(\.index) == [1])
  }

  @Test("Editor silent confirms a SET of a brake GUC")
  func editorSilentConfirmsBrakeSet() async {
    let state = await runEditor("SET lock_timeout = 0", safeMode: .silent).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.first?.touchesBrake == true)
  }

  @Test("Editor alertRead confirms CALL (fail closed)")
  func editorAlertReadConfirmsCall() async {
    let state = await runEditor("CALL do_things()", safeMode: .alertRead).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.map(\.index) == [0])
  }

  // MARK: - Run All

  /// Runs `runAllCells` on one SQL cell per entry with the given bypass setting.
  private func runAll(
    _ contents: [String], bypass: Bool, protection: ConnectionProtectionLevel = .none
  ) async -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.notebook.cells = contents.map {
      NotebookCell(id: UUID(), cellType: .sql, content: $0, executionCount: 0, result: nil)
    }
    // Pin Safe Mode per connection: Run All asks for the unlock under safeRead/safeAll, and the
    // global setting comes from the host's UserDefaults
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: protection, safeMode: .alertRead)
    // Pass the bypass explicitly: parallel tests mutate the global setting
    await viewModel.runAllCells(bypass: bypass)
    return viewModel
  }

  @Test("Run All confirms a brake SET even when the destructive bypass is on")
  func runAllConfirmsBrakeSetDespiteBypass() async {
    let state = await runAll(["SELECT 1", "SET statement_timeout = 0"], bypass: true)
      .queryConfirmationState

    #expect(state.showRunAllConfirmation)
    #expect(state.runAllConfirmCells.map(\.number) == [2])
    #expect(state.runAllConfirmCells.first?.isSafetyCritical == true)
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
      classified, safeMode: .alertRead)

    #expect(statements?.first?.preview == "DELETE FROM t")
  }

  @Test("Confirmation summary lists the first 8 statements, then how many more")
  func confirmationSummaryIsCapped() throws {
    let sql = (1...10).map { "SELECT \($0)" }.joined(separator: "; ")
    let statements = try #require(
      NotebookViewModel.statementsNeedingConfirmation(
        SQLStatementClassifier.classify(sql), safeMode: .alertAll))

    let lines = NotebookViewModel.confirmationSummary(statements).split(separator: "\n")

    #expect(lines.count == 9)
    #expect(lines.first == "1. SELECT 1")
    #expect(lines[7] == "8. SELECT 8")
    #expect(lines.last == "…and 2 more")
  }

  @Test("Run All summary prefixes each statement with its cell number")
  func runAllSummaryNamesCells() throws {
    let statements = try #require(
      NotebookViewModel.statementsNeedingConfirmation(
        SQLStatementClassifier.classify("SET statement_timeout = 0"), safeMode: .silent))
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
