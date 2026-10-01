//
//  NotebookViewModel+RunAll.swift
//  Dblore
//

import Foundation

// MARK: - Run All Cells

extension NotebookViewModel {
  /// Run all cells sequentially by adding them to the queue.
  ///
  /// 1. Every cell is checked with the protection gate first: if any cell is blocked, Run All
  ///    stops with the gate's error toast and nothing runs.
  /// 2. A cell needs confirmation if any statement modifies data or schema, is a utility
  ///    (DO, CALL, COPY, ...) or unrecognized statement, changes the session brakes or changes
  ///    role/privileges (same rules as Safe Mode `alertRead`).
  /// 3. The dialog is shown if a cell changes the session brakes or privileges (ALWAYS, even
  ///    when `bypassDestructiveQueryConfirmation` is on), or if any cell needs confirmation and
  ///    the bypass is off. With the bypass on, only the safety-critical cells are listed/skippable.
  /// 4. Safe Mode `safeRead` (any cell needs confirmation) or `safeAll` (always): Run All first
  ///    asks for the Safe Mode unlock (Touch ID or password sheet) instead of the dialog, even
  ///    with the bypass on; after the unlock every cell runs.
  /// - Parameter bypass: snapshot of the setting, taken when Run All is requested.
  func runAllCells(
    bypass: Bool = AppSettings.shared.bypassDestructiveQueryConfirmation
  ) async {
    // Force blur to ensure text content is saved
    NotificationCenter.default.post(name: .unfocusEditor, object: nil)
    try? await Task.sleep(for: .milliseconds(50))

    let candidates = notebook.cells.enumerated().filter {
      $0.element.cellType == .sql && !executionQueue.isInQueue(cellId: $0.element.id)
    }
    guard !candidates.isEmpty else { return }
    guard !refuseWhileTransactionPendingElsewhere() else { return }

    // Protection level: fail fast, nothing runs if any cell is blocked
    for (offset, cell) in candidates {
      if let message = protectionBlockMessage(for: cell.content) {
        showToast("Run All stopped (cell \(offset + 1)): \(message)", type: .error)
        return
      }
    }

    let allCells = candidates.map { offset, cell in
      RunAllCell(
        id: cell.id, number: offset + 1, query: cell.content,
        statements: Self.statementsNeedingConfirmation(
          SQLStatementClassifier.classify(cell.content, dialect: sqlDialect), safeMode: .alertRead)
          ?? [])
    }

    // Safe Mode password levels: unlock before anything runs (the bypass does not apply)
    let safeMode = notebook.connectionConfig?.safeMode ?? AppSettings.shared.safeMode
    if safeMode.requiresPassword,
      safeMode == .safeAll || allCells.contains(where: \.needsConfirmation)
    {
      presentRunAllUnlock(allCells, safeMode: safeMode)
      return
    }

    // With the bypass on, only safety-critical cells still need confirmation
    let pendingCells = allCells.map { cell in
      guard bypass, !cell.isSafetyCritical else { return cell }
      return RunAllCell(id: cell.id, number: cell.number, query: cell.query, statements: [])
    }

    if pendingCells.contains(where: \.needsConfirmation) {
      queryConfirmationState.runAllPendingCells = pendingCells
      queryConfirmationState.showRunAllConfirmation = true
      return
    }

    executeRunAllCells(pendingCells: pendingCells, skipConfirmable: false)
  }

  /// Execute Run All Cells after user confirmation (runs every cell)
  func executeRunAllCellsWithDestructive() async {
    let pendingCells = queryConfirmationState.runAllPendingCells
    queryConfirmationState.clearRunAll()

    executeRunAllCells(pendingCells: pendingCells, skipConfirmable: false)
  }

  /// Execute Run All Cells skipping the cells that needed confirmation
  func executeRunAllCellsSkipDestructive() async {
    let pendingCells = queryConfirmationState.runAllPendingCells
    let skippedCount = queryConfirmationState.runAllConfirmCells.count
    queryConfirmationState.clearRunAll()

    executeRunAllCells(pendingCells: pendingCells, skipConfirmable: true)

    // Show toast about skipped cells
    if skippedCount > 0 {
      let cellWord = skippedCount == 1 ? "cell" : "cells"
      showToast("\(skippedCount) \(cellWord) skipped", type: .warning)
    }
  }

  /// Cancel Run All Cells operation
  func cancelRunAllCells() {
    queryConfirmationState.clearRunAll()
  }

  /// Shows the Safe Mode unlock sheet for Run All, listing the statements `safeMode` confirms,
  /// numbered across cells ("Cell N: ...") so every row has a unique id.
  private func presentRunAllUnlock(_ cells: [RunAllCell], safeMode: SafeMode) {
    let listed = cells.flatMap { cell in
      (Self.statementsNeedingConfirmation(
        SQLStatementClassifier.classify(cell.query, dialect: sqlDialect), safeMode: safeMode) ?? [])
        .map { (cell.number, $0) }
    }
    queryConfirmationState.clear()
    queryConfirmationState.statements = listed.enumerated().map { offset, entry in
      let (number, statement) = entry
      return StatementConfirmation(
        index: offset, preview: "Cell \(number): \(statement.preview)",
        kindLabel: statement.kindLabel, affectsAllRows: statement.affectsAllRows,
        touchesBrake: statement.touchesBrake, changesPrivileges: statement.changesPrivileges)
    }
    queryConfirmationState.affectsAllRows = listed.contains { $0.1.affectsAllRows }
    queryConfirmationState.requiresPassword = true
    queryConfirmationState.runAllPendingCells = cells
    queryConfirmationState.runAllAwaitingUnlock = true
    queryConfirmationState.showDialog = true
  }

  /// Runs every Run All cell after the Safe Mode unlock succeeded
  func executeUnlockedRunAll() {
    let pendingCells = queryConfirmationState.runAllPendingCells
    queryConfirmationState.clear()
    queryConfirmationState.clearRunAll()
    executeRunAllCells(pendingCells: pendingCells, skipConfirmable: false)
  }

  /// Internal helper to execute Run All Cells
  private func executeRunAllCells(pendingCells: [RunAllCell], skipConfirmable: Bool) {
    // Reset execution counter to start counting from 1 again
    executionCounter = 0

    // One batch: its cells only run on the connection its first cell started on
    let batchId = UUID()
    // Enqueue cells, optionally skipping the ones that needed confirmation
    for cell in pendingCells {
      if skipConfirmable && cell.needsConfirmation {
        continue
      }
      executionQueue.enqueue(cellId: cell.id, query: cell.query, batchId: batchId)
    }
  }
}
