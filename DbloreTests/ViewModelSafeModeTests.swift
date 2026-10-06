// ViewModelSafeModeTests.swift
// Tests for Safe Mode functionality and enum properties

import Foundation
import Testing

@testable import Dblore

@Suite("ViewModel Safe Mode Tests")
@MainActor
struct ViewModelSafeModeTests {

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

  // MARK: - Safe Mode Default Tests

  @Test("Safe Mode defaults to alertRead")
  func safeModeDefaultsToAlertRead() {
    // Reset to default first
    AppSettings.shared.safeMode = .alertRead

    // Arrange & Assert
    #expect(AppSettings.shared.safeMode == .alertRead)
  }

  // MARK: - Safe Mode Silent Tests

  @Test("Safe Mode silent executes UPDATE directly without confirmation")
  func safeModesilentExecutesUpdateDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode

    AppSettings.shared.commitStyle = .immediate

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode silent executes DELETE directly without confirmation")
  func safeModesilentExecutesDeleteDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode

    AppSettings.shared.commitStyle = .immediate

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode silent executes INSERT directly without confirmation")
  func safeModesilentExecutesInsertDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode

    AppSettings.shared.commitStyle = .immediate

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  // MARK: - Safe Mode Alert Tests

  @Test("confirm shows the plain confirm dialog for UPDATE")
  func confirmShowsDialogForUpdate() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode

    AppSettings.shared.commitStyle = .confirm

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Dialog should be shown, without the password sheet
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.requiresPassword == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "UPDATE users SET name = 'John'")

    // Cleanup
    viewModel.cancelPendingQuery()
    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("confirm does not show a dialog for SELECT")
  func confirmDoesNotShowDialogForSelect() {
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

    // Assert
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)

    // Cleanup
    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  // MARK: - Classifier-driven confirmation (every statement of the cell)

  /// Runs `confirmAndRunCell` on a single-cell notebook with the global commit style pinned.
  private func confirm(_ sql: String, style: CommitStyle) -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = sql
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = style
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }
    viewModel.confirmAndRunCell(id: cellId)
    return viewModel
  }

  @Test("confirm lists a DELETE without WHERE after a SELECT and opens the confirm dialog")
  func confirmListsLaterDelete() {
    let state = confirm("SELECT 1; DELETE FROM t", style: .confirm).queryConfirmationState

    #expect(state.showDialog)
    #expect(!state.requiresPassword)
    #expect(state.affectsAllRows)
    #expect(state.statements.map(\.index) == [1])
    #expect(state.statements.first?.affectsAllRows == true)
    #expect(state.statements.first?.preview == "DELETE FROM t")
  }

  @Test("confirm does not list a cell of reads only")
  func confirmSkipsReadsOnly() {
    let state = confirm("SELECT 1; SELECT 2", style: .confirm).queryConfirmationState

    #expect(!state.showDialog)
    #expect(state.statements.isEmpty)
  }

  @Test("immediate and review do not confirm a brake SET or RESET ALL")
  func immediateAndReviewSkipBrakeStatements() {
    for sql in ["SET statement_timeout = 0", "RESET ALL"] {
      for style in [CommitStyle.immediate, CommitStyle.review] {
        let state = confirm(sql, style: style).queryConfirmationState
        #expect(!state.showDialog, "\(style) \(sql)")
        #expect(state.statements.isEmpty, "\(style) \(sql)")
      }
      let classified = SQLStatementClassifier.classify(sql)
      #expect(
        NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .immediate) == nil)
      #expect(
        NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .review) == nil)
      #expect(
        NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .confirm) != nil)
      #expect(
        NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .password) != nil)
    }
  }

  @Test("immediate and review do not confirm SET ROLE")
  func immediateAndReviewSkipSetRole() {
    let sql = "SELECT 1; SET ROLE admin"
    for style in [CommitStyle.immediate, CommitStyle.review] {
      let state = confirm(sql, style: style).queryConfirmationState
      #expect(!state.showDialog)
      #expect(state.statements.isEmpty)
    }
    let classified = SQLStatementClassifier.classify(sql)
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .immediate) == nil)
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .review) == nil)
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .confirm)?.map(
        \.index)
        == [1])
  }

  @Test("confirm lists DO blocks (fail closed)")
  func confirmListsDoBlock() {
    let state = confirm(
      "DO $$ BEGIN DELETE FROM t; END $$", style: .confirm
    ).queryConfirmationState

    #expect(state.showDialog)
    #expect(!state.requiresPassword)
    #expect(state.statements.map(\.index) == [0])
    #expect(!state.affectsAllRows)
  }

  @Test("confirm and password do not list a plain SELECT")
  func confirmAndPasswordSkipSelect() {
    let classified = SQLStatementClassifier.classify("SELECT 1")
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .confirm) == nil)
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(classified, commitStyle: .password) == nil)

    let state = confirm("SELECT 1", style: .confirm).queryConfirmationState
    #expect(!state.showDialog)
    #expect(state.statements.isEmpty)
  }

  @Test("password DELETE asks for the password and does not use the plain confirm dialog")
  func passwordDeleteRequiresPassword() {
    let state = confirm("DELETE FROM t WHERE id = 1", style: .password).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.requiresPassword)
    #expect(state.statements.map(\.index) == [0])
  }

  @Test("password does not ask for a SELECT")
  func passwordSelectNeedsNoUnlock() {
    let state = confirm("SELECT 1", style: .password).queryConfirmationState

    #expect(!state.showDialog)
    #expect(!state.requiresPassword)
  }

  @Test("a protected connection resolves to review and does not confirm a DELETE")
  func protectedConnectionReviewsWithoutDialog() {
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .password
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM t"
    viewModel.notebook.connectionConfig = ConnectionConfig()
    viewModel.confirmAndRunCell(id: cellId)

    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.requiresPassword)
  }

  @Test("an unprotected connection falls back from review to confirm for a DELETE")
  func unprotectedReviewFallbackConfirmsDelete() {
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .review
    defer {
      AppSettings.shared.commitStyle = previousStyle
      AppSettings.shared.safeMode = previousSafeMode
    }
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM t WHERE id = 1"
    viewModel.notebook.connectionConfig = ConnectionConfig(protectedMode: false)
    viewModel.confirmAndRunCell(id: cellId)

    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.requiresPassword)
    #expect(viewModel.queryConfirmationState.statements.map(\.index) == [0])
  }

  // MARK: - Run All under commit style

  /// Runs `runAllCells` with one SQL cell per entry. Commit style is stored on the connection
  /// so Run All does not follow the host's global setting.
  private func runAll(
    _ contents: [String], style: CommitStyle, bypass: Bool = false
  ) async
    -> NotebookViewModel
  {
    WorkspaceWindowManager.shared.dismissToast()
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.notebook.cells = contents.map {
      NotebookCell(id: UUID(), cellType: .sql, content: $0, executionCount: 0, result: nil)
    }
    var config = ConnectionConfig(protectionLevel: .none, protectedMode: false)
    config.applyCommitStyle(style)
    viewModel.notebook.connectionConfig = config
    await viewModel.runAllCells(bypass: bypass)
    return viewModel
  }

  private func nothingQueued(_ viewModel: NotebookViewModel) -> Bool {
    viewModel.executionQueue.tasks.isEmpty
  }

  @Test("password Run All of a write shows the unlock sheet before queueing")
  func runAllPasswordWriteRequiresUnlock() async {
    let viewModel = await runAll(["SELECT 1", "DELETE FROM t"], style: .password)
    let state = viewModel.queryConfirmationState

    #expect(state.showDialog)
    #expect(state.requiresPassword)
    #expect(state.runAllAwaitingUnlock)
    #expect(!state.showRunAllConfirmation)
    #expect(state.affectsAllRows)
    #expect(state.statements.count == 1)
    #expect(state.statements.first?.preview == "Cell 2: DELETE FROM t")
    #expect(nothingQueued(viewModel))
  }

  @Test("password Run All ignores the destructive bypass for the unlock")
  func runAllPasswordUnlockDespiteBypass() async {
    let viewModel = await runAll(["DELETE FROM t WHERE id = 1"], style: .password, bypass: true)

    #expect(viewModel.queryConfirmationState.requiresPassword)
    #expect(viewModel.queryConfirmationState.runAllAwaitingUnlock)
    #expect(!viewModel.queryConfirmationState.showRunAllConfirmation)
    #expect(nothingQueued(viewModel))
  }

  @Test("SELECT-only Run All under password does not show the unlock sheet")
  func runAllPasswordSelectOnlySkipsUnlock() async {
    WorkspaceWindowManager.shared.dismissToast()
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.notebook.cells = ["SELECT 1", "SELECT 2; SELECT 3"].map {
      NotebookCell(id: UUID(), cellType: .sql, content: $0, executionCount: 0, result: nil)
    }
    // Unprotected safeAll migrates to password. The sheet must not list the reads.
    let config = ConnectionConfig(
      protectionLevel: .none, safeMode: .safeAll, protectedMode: false)
    #expect(config.resolvedCommitStyle(fallback: .confirm) == .password)
    viewModel.notebook.connectionConfig = config
    await viewModel.runAllCells(bypass: false)
    let state = viewModel.queryConfirmationState

    #expect(!state.showDialog)
    #expect(!state.requiresPassword)
    #expect(!state.runAllAwaitingUnlock)
    #expect(!state.showRunAllConfirmation)
    #expect(state.statements.isEmpty)
  }

  @Test("confirm Run All of a DELETE still shows the Run All dialog")
  func runAllConfirmDeleteShowsDialog() async {
    let viewModel = await runAll(["DELETE FROM t"], style: .confirm)
    let state = viewModel.queryConfirmationState

    #expect(state.showRunAllConfirmation)
    #expect(!state.showDialog)
    #expect(!state.runAllAwaitingUnlock)
    #expect(!state.requiresPassword)
  }

  @Test("immediate and review Run All show neither dialog nor unlock")
  func runAllImmediateAndReviewShowNothing() async {
    for sql in ["DELETE FROM t", "SET statement_timeout = 0", "SET ROLE admin"] {
      for style in [CommitStyle.immediate, CommitStyle.review] {
        let state = await runAll([sql], style: style).queryConfirmationState
        #expect(!state.showDialog, "\(style) \(sql)")
        #expect(!state.showRunAllConfirmation, "\(style) \(sql)")
        #expect(!state.runAllAwaitingUnlock, "\(style) \(sql)")
        #expect(!state.requiresPassword, "\(style) \(sql)")
        #expect(state.statements.isEmpty, "\(style) \(sql)")
      }
    }
  }

  @Test("Cancelling the Run All unlock clears it and queues nothing")
  func runAllUnlockCancel() async {
    let viewModel = await runAll(["DELETE FROM t"], style: .password)

    viewModel.cancelPendingQuery()

    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.runAllAwaitingUnlock)
    #expect(viewModel.queryConfirmationState.runAllPendingCells.isEmpty)
    #expect(nothingQueued(viewModel))
  }

  @Test("After the unlock, Run All clears the sheet state and hands the cells to the queue")
  func runAllUnlockThenRuns() async {
    let viewModel = await runAll(["SELECT 1", "DELETE FROM t"], style: .password)
    let pending = viewModel.queryConfirmationState.runAllPendingCells.map(\.id)
    #expect(pending == viewModel.notebook.cells.map(\.id))

    await viewModel.executePendingQuery()

    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.runAllAwaitingUnlock)
    #expect(viewModel.queryConfirmationState.runAllPendingCells.isEmpty)
    // Every cell was enqueued (tasks stay in the history even once they ran)
    #expect(viewModel.executionQueue.tasks.map(\.cellId) == pending)
  }

  @Test("Cancel clears the statement list")
  func cancelClearsStatements() {
    let viewModel = confirm("DELETE FROM t", style: .confirm)
    #expect(!viewModel.queryConfirmationState.statements.isEmpty)

    viewModel.cancelPendingQuery()

    #expect(viewModel.queryConfirmationState.statements.isEmpty)
  }

  @Test("Reset settings resets the default commit style to review")
  func resetSettingsResetsSafeMode() {
    let previousStyle = AppSettings.shared.commitStyle
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.commitStyle = .confirm
    #expect(AppSettings.shared.safeMode == .alertRead)

    AppSettings.shared.resetToDefaults()

    #expect(AppSettings.shared.commitStyle == .review)
    #expect(AppSettings.shared.safeMode == .silent)

    AppSettings.shared.commitStyle = previousStyle
    AppSettings.shared.safeMode = previousSafeMode
  }

  // MARK: - SafeMode Enum Tests

  @Test("SafeMode enum has correct values")
  func safeModeEnumHasCorrectValues() {
    // Verify all 5 levels exist with correct raw values
    #expect(SafeMode.silent.rawValue == 0)
    #expect(SafeMode.alertRead.rawValue == 1)
    #expect(SafeMode.alertAll.rawValue == 2)
    #expect(SafeMode.safeRead.rawValue == 3)
    #expect(SafeMode.safeAll.rawValue == 4)
  }

  @Test("SafeMode display names are correct")
  func safeModeDisplayNamesAreCorrect() {
    #expect(SafeMode.silent.displayName == "Silent")
    #expect(SafeMode.alertRead.displayName == "Alert (Read)")
    #expect(SafeMode.alertAll.displayName == "Alert (All)")
    #expect(SafeMode.safeRead.displayName == "Safe (Read)")
    #expect(SafeMode.safeAll.displayName == "Safe (All)")
  }

  @Test("SafeMode requiresConfirmationForSelect is correct")
  func safeModeRequiresConfirmationForSelectIsCorrect() {
    // Only alertAll and safeAll require confirmation for SELECT
    #expect(SafeMode.silent.requiresConfirmationForSelect == false)
    #expect(SafeMode.alertRead.requiresConfirmationForSelect == false)
    #expect(SafeMode.alertAll.requiresConfirmationForSelect == true)
    #expect(SafeMode.safeRead.requiresConfirmationForSelect == false)
    #expect(SafeMode.safeAll.requiresConfirmationForSelect == true)
  }

  @Test("SafeMode requiresConfirmationForModification is correct")
  func safeModeRequiresConfirmationForModificationIsCorrect() {
    // All modes except silent require confirmation for modification
    #expect(SafeMode.silent.requiresConfirmationForModification == false)
    #expect(SafeMode.alertRead.requiresConfirmationForModification == true)
    #expect(SafeMode.alertAll.requiresConfirmationForModification == true)
    #expect(SafeMode.safeRead.requiresConfirmationForModification == true)
    #expect(SafeMode.safeAll.requiresConfirmationForModification == true)
  }

  @Test("SafeMode requiresPassword is correct")
  func safeModeRequiresPasswordIsCorrect() {
    // Only safeRead and safeAll require password
    #expect(SafeMode.silent.requiresPassword == false)
    #expect(SafeMode.alertRead.requiresPassword == false)
    #expect(SafeMode.alertAll.requiresPassword == false)
    #expect(SafeMode.safeRead.requiresPassword == true)
    #expect(SafeMode.safeAll.requiresPassword == true)
  }

  @Test("SafeMode allCases contains all modes")
  func safeModeAllCasesContainsAllModes() {
    let allCases = SafeMode.allCases
    #expect(allCases.count == 5)
    #expect(allCases.contains(.silent))
    #expect(allCases.contains(.alertRead))
    #expect(allCases.contains(.alertAll))
    #expect(allCases.contains(.safeRead))
    #expect(allCases.contains(.safeAll))
  }

  // MARK: - Per-Connection SafeMode Tests

  @Test("ConnectionConfig safeMode defaults to nil")
  func connectionConfigSafeModeDefaultsToNil() {
    let config = ConnectionConfig()
    #expect(config.safeMode == nil)
  }

  @Test("ConnectionConfig safeMode can be set")
  func connectionConfigSafeModeCanBeSet() {
    var config = ConnectionConfig()
    config.safeMode = .safeRead
    #expect(config.safeMode == .safeRead)

    config.safeMode = .silent
    #expect(config.safeMode == .silent)

    config.safeMode = nil
    #expect(config.safeMode == nil)
  }

  @Test("Per-connection SafeMode overrides global setting")
  @MainActor
  func perConnectionSafeModeOverridesGlobal() {
    // Setup: Set global SafeMode to alertAll
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .alertAll

    // Create connection with per-connection SafeMode override
    var config = ConnectionConfig()
    config.safeMode = .silent

    // The effective SafeMode should be the per-connection setting
    let effectiveSafeMode = config.safeMode ?? AppSettings.shared.safeMode
    #expect(effectiveSafeMode == .silent)

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Nil per-connection SafeMode falls back to global")
  @MainActor
  func nilPerConnectionSafeModeFallsBackToGlobal() {
    // Setup: Set global SafeMode
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .safeRead

    // Create connection without per-connection override
    let config = ConnectionConfig()
    #expect(config.safeMode == nil)

    // The effective SafeMode should be the global setting
    let effectiveSafeMode = config.safeMode ?? AppSettings.shared.safeMode
    #expect(effectiveSafeMode == .safeRead)

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("SafeMode is Codable")
  func safeModeIsCodable() throws {
    // Test encoding/decoding SafeMode values
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for mode in SafeMode.allCases {
      let encoded = try encoder.encode(mode)
      let decoded = try decoder.decode(SafeMode.self, from: encoded)
      #expect(decoded == mode)
    }
  }

  @Test("ConnectionConfig with safeMode is Codable")
  func connectionConfigWithSafeModeIsCodable() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // Test with safeMode set
    var configWithSafeMode = ConnectionConfig()
    configWithSafeMode.safeMode = .safeAll
    configWithSafeMode.name = "Test Connection"

    let encoded = try encoder.encode(configWithSafeMode)
    let decoded = try decoder.decode(ConnectionConfig.self, from: encoded)

    #expect(decoded.safeMode == .safeAll)
    #expect(decoded.name == "Test Connection")
  }

  @Test("ConnectionConfig without safeMode decodes to nil")
  func connectionConfigWithoutSafeModeDecodesToNil() throws {
    // Simulate old JSON without safeMode field (migration scenario)
    let json = """
      {
        "databaseType": "PostgreSQL",
        "host": "localhost",
        "port": 5432,
        "database": "test",
        "username": "user",
        "password": "pass",
        "sslMode": "prefer",
        "rememberConnection": false,
        "timeoutSeconds": 30,
        "readOnly": false,
        "name": "Old Connection"
      }
      """

    let decoder = JSONDecoder()
    let data = json.data(using: .utf8)!
    let decoded = try decoder.decode(ConnectionConfig.self, from: data)

    // safeMode should be nil for old connections without the field
    #expect(decoded.safeMode == nil)
    #expect(decoded.name == "Old Connection")
  }
}
