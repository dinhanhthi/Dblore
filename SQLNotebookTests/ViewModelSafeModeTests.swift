// ViewModelSafeModeTests.swift
// Tests for Safe Mode functionality and enum properties

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Safe Mode Tests")
@MainActor
struct ViewModelSafeModeTests {

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
    let previousSafeMode = AppSettings.shared.safeMode

    // Set Safe Mode to Silent (no confirmations)
    AppSettings.shared.safeMode = .silent

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode silent executes DELETE directly without confirmation")
  func safeModesilentExecutesDeleteDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "DELETE FROM users WHERE id = 1"
    let previousSafeMode = AppSettings.shared.safeMode

    // Set Safe Mode to Silent (no confirmations)
    AppSettings.shared.safeMode = .silent

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode silent executes INSERT directly without confirmation")
  func safeModesilentExecutesInsertDirectly() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "INSERT INTO users (name) VALUES ('John')"
    let previousSafeMode = AppSettings.shared.safeMode

    // Set Safe Mode to Silent (no confirmations)
    AppSettings.shared.safeMode = .silent

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == false)
    #expect(viewModel.queryConfirmationState.pendingCellId == nil)
    #expect(viewModel.queryConfirmationState.pendingQuery == "")

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  // MARK: - Safe Mode Alert Tests

  @Test("Safe Mode alertRead shows dialog for UPDATE")
  func safeModeAlertReadShowsDialogForUpdate() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "UPDATE users SET name = 'John'"
    let previousSafeMode = AppSettings.shared.safeMode

    // Ensure Safe Mode is alertRead
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Dialog should be shown
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "UPDATE users SET name = 'John'")

    // Cleanup
    viewModel.cancelPendingQuery()
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode alertAll shows dialog for SELECT")
  func safeModeAlertAllShowsDialogForSelect() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT * FROM users"
    let previousSafeMode = AppSettings.shared.safeMode

    // Ensure Safe Mode is alertAll (confirm all queries)
    AppSettings.shared.safeMode = .alertAll

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - Dialog should be shown for SELECT in alertAll mode
    #expect(viewModel.queryConfirmationState.showDialog == true)
    #expect(viewModel.queryConfirmationState.pendingCellId == cellId)
    #expect(viewModel.queryConfirmationState.pendingQuery == "SELECT * FROM users")

    // Cleanup
    viewModel.cancelPendingQuery()
    AppSettings.shared.safeMode = previousSafeMode
  }

  @Test("Safe Mode alertRead does NOT show dialog for SELECT")
  func safeModeAlertReadDoesNotShowDialogForSelect() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = "SELECT * FROM users"
    let previousSafeMode = AppSettings.shared.safeMode

    // Ensure Safe Mode is alertRead
    AppSettings.shared.safeMode = .alertRead

    // Act
    viewModel.confirmAndRunCell(id: cellId)

    // Assert - No dialog should be shown for SELECT in alertRead mode
    #expect(viewModel.queryConfirmationState.showDialog == false)

    // Cleanup
    AppSettings.shared.safeMode = previousSafeMode
  }

  // MARK: - Classifier-driven confirmation (every statement of the cell)

  /// Runs `confirmAndRunCell` on a single-cell notebook with the global SafeMode pinned.
  private func confirm(_ sql: String, safeMode: SafeMode) -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    let cellId = viewModel.notebook.cells[0].id
    viewModel.notebook.cells[0].content = sql
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = safeMode
    defer { AppSettings.shared.safeMode = previousSafeMode }
    viewModel.confirmAndRunCell(id: cellId)
    return viewModel
  }

  @Test("alertRead confirms a DELETE without WHERE after a SELECT and lists it")
  func alertReadConfirmsLaterDelete() {
    let state = confirm("SELECT 1; DELETE FROM t", safeMode: .alertRead).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.affectsAllRows)
    #expect(state.statements.map(\.index) == [1])
    #expect(state.statements.first?.affectsAllRows == true)
    #expect(state.statements.first?.preview == "DELETE FROM t")
  }

  @Test("alertRead does not confirm a cell of reads only")
  func alertReadSkipsReadsOnly() {
    let state = confirm("SELECT 1; SELECT 2", safeMode: .alertRead).queryConfirmationState

    #expect(!state.showDialog)
    #expect(state.statements.isEmpty)
  }

  @Test("silent confirms a SET of a brake GUC")
  func silentConfirmsBrakeSet() {
    let state = confirm("SET statement_timeout = 0", safeMode: .silent).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.count == 1)
    #expect(state.statements.first?.touchesBrake == true)
    #expect(state.statements.first?.reasons.contains("Changes session safety settings") == true)
  }

  @Test("silent confirms SET ROLE")
  func silentConfirmsSetRole() {
    let state = confirm("SELECT 1; SET ROLE admin", safeMode: .silent).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.map(\.index) == [1])
    #expect(state.statements.first?.changesPrivileges == true)
    #expect(state.statements.first?.reasons == ["Changes role/privileges"])
  }

  @Test("alertRead confirms DO blocks (fail closed)")
  func alertReadConfirmsDoBlock() {
    let state = confirm(
      "DO $$ BEGIN DELETE FROM t; END $$", safeMode: .alertRead
    ).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.map(\.index) == [0])
    #expect(!state.affectsAllRows)
  }

  @Test("alertAll confirms a SELECT and lists every statement")
  func alertAllConfirmsSelect() {
    let state = confirm("SELECT 1", safeMode: .alertAll).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.statements.map(\.index) == [0])
    #expect(state.statements.first?.reasons.isEmpty == true)
  }

  @Test("safeRead: a DELETE cell requires the Safe Mode unlock (global Safe Mode pinned)")
  func safeReadDeleteRequiresPassword() {
    let state = confirm("DELETE FROM t WHERE id = 1", safeMode: .safeRead).queryConfirmationState

    #expect(state.showDialog)
    #expect(state.requiresPassword)
    #expect(state.statements.map(\.index) == [0])
  }

  @Test("safeRead: a SELECT cell needs no unlock")
  func safeReadSelectNeedsNoUnlock() {
    let state = confirm("SELECT 1", safeMode: .safeRead).queryConfirmationState

    #expect(!state.showDialog)
    #expect(!state.requiresPassword)
  }

  // MARK: - Run All under Safe Mode password levels

  /// Runs `runAllCells` with one SQL cell per entry. Safe Mode is pinned per connection
  /// (not the global setting): Run All awaits, and parallel tests mutate the global setting.
  private func runAll(
    _ contents: [String], safeMode: SafeMode, bypass: Bool = false
  ) async
    -> NotebookViewModel
  {
    WorkspaceWindowManager.shared.dismissToast()
    let viewModel = NotebookViewModel(notebook: createTestNotebook())
    viewModel.notebook.cells = contents.map {
      NotebookCell(id: UUID(), cellType: .sql, content: $0, executionCount: 0, result: nil)
    }
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: .none, safeMode: safeMode)
    await viewModel.runAllCells(bypass: bypass)
    return viewModel
  }

  private func nothingQueued(_ viewModel: NotebookViewModel) -> Bool {
    viewModel.executionQueue.tasks.isEmpty
  }

  @Test("Run All under safeRead with a DELETE cell requires the unlock before queueing")
  func runAllSafeReadRequiresUnlock() async {
    let viewModel = await runAll(["SELECT 1", "DELETE FROM t"], safeMode: .safeRead)
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

  @Test("Run All under safeRead ignores the destructive bypass for the unlock")
  func runAllSafeReadUnlockDespiteBypass() async {
    let viewModel = await runAll(["DELETE FROM t WHERE id = 1"], safeMode: .safeRead, bypass: true)

    #expect(viewModel.queryConfirmationState.requiresPassword)
    #expect(viewModel.queryConfirmationState.runAllAwaitingUnlock)
    #expect(nothingQueued(viewModel))
  }

  @Test("Run All under safeAll requires the unlock even for SELECT only, ids unique")
  func runAllSafeAllRequiresUnlock() async {
    let viewModel = await runAll(["SELECT 1", "SELECT 2; SELECT 3"], safeMode: .safeAll)
    let state = viewModel.queryConfirmationState

    #expect(state.showDialog)
    #expect(state.requiresPassword)
    #expect(state.runAllAwaitingUnlock)
    #expect(state.statements.count == 3)
    #expect(Set(state.statements.map(\.id)).count == 3)
    #expect(nothingQueued(viewModel))
  }

  @Test("Run All under safeRead with reads only runs without unlock")
  func runAllSafeReadReadsOnlyRuns() async {
    let viewModel = await runAll(["SELECT 1"], safeMode: .safeRead)

    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.runAllAwaitingUnlock)
  }

  @Test("Run All under alertRead keeps the Allow/Don't Allow dialog (no password)")
  func runAllAlertReadKeepsDialog() async {
    let viewModel = await runAll(["DELETE FROM t"], safeMode: .alertRead)
    let state = viewModel.queryConfirmationState

    #expect(state.showRunAllConfirmation)
    #expect(!state.showDialog)
    #expect(!state.runAllAwaitingUnlock)
  }

  @Test("Cancelling the Run All unlock clears it and queues nothing")
  func runAllUnlockCancel() async {
    let viewModel = await runAll(["DELETE FROM t"], safeMode: .safeAll)

    viewModel.cancelPendingQuery()

    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(!viewModel.queryConfirmationState.runAllAwaitingUnlock)
    #expect(viewModel.queryConfirmationState.runAllPendingCells.isEmpty)
    #expect(nothingQueued(viewModel))
  }

  @Test("After the unlock, Run All clears the sheet state and hands the cells to the queue")
  func runAllUnlockThenRuns() async {
    let viewModel = await runAll(["SELECT 1", "DELETE FROM t"], safeMode: .safeRead)
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
    let viewModel = confirm("DELETE FROM t", safeMode: .alertRead)
    #expect(!viewModel.queryConfirmationState.statements.isEmpty)

    viewModel.cancelPendingQuery()

    #expect(viewModel.queryConfirmationState.statements.isEmpty)
  }

  @Test("Reset settings resets Safe Mode to alertRead")
  func resetSettingsResetsSafeMode() {
    // Arrange
    let previousSafeMode = AppSettings.shared.safeMode
    AppSettings.shared.safeMode = .silent
    #expect(AppSettings.shared.safeMode == .silent)

    // Act
    AppSettings.shared.resetToDefaults()

    // Assert
    #expect(AppSettings.shared.safeMode == .alertRead)

    // Cleanup (not strictly needed since we reset to defaults)
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
