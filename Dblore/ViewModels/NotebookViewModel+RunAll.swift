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
  /// 2. The write list is the same as statement confirmation: the connection's resolved commit
  ///    style. `confirm` and `password` list statements `mayWrite` treats as writes. `immediate`
  ///    and `review` list nothing, including a brake `SET`.
  /// 3. `password` shows the unlock sheet instead of the dialog when that list is non-empty.
  ///    The destructive bypass does not apply. After the unlock every cell runs.
  /// 4. `confirm` shows the Run All dialog when the list is non-empty. With
  ///    `bypassDestructiveQueryConfirmation` on, only safety-critical cells (a brake or a
  ///    privilege change) stay listed.
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

    // Protection, then missing parameters: nothing runs if any cell is refused
    for (offset, cell) in candidates {
      if let message = protectionBlockMessage(for: cell.content) {
        showToast("Run All stopped (cell \(offset + 1)): \(message)", type: .error)
        return
      }
      if let message = refuseMissingParameters(cell.content, cellId: cell.id) {
        showToast("Run All stopped (cell \(offset + 1)): \(message)", type: .error)
        return
      }
    }

    let commitStyle =
      notebook.connectionConfig?.resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
      ?? AppSettings.shared.commitStyle
    let allCells = candidates.map { offset, cell in
      let parameters = boundParameterValues(for: cell.content, cellId: cell.id) ?? [:]
      return RunAllCell(
        id: cell.id, number: offset + 1, query: cell.content,
        statements: Self.statementsNeedingConfirmation(
          classifiedStatements(for: cell.content), commitStyle: commitStyle,
          parameters: parameters, dialect: sqlDialect) ?? [],
        parameterValues: parameters)
    }

    // password replaces the dialog with the unlock sheet only when the write list is non-empty.
    // The destructive bypass does not apply on this path.
    if commitStyle == .password, allCells.contains(where: \.needsConfirmation) {
      presentRunAllUnlock(allCells)
      return
    }

    // Bypass applies to confirm only. A brake or privilege cell stays listed.
    let pendingCells = allCells.map { cell in
      guard commitStyle == .confirm, bypass, !cell.isSafetyCritical else { return cell }
      return RunAllCell(
        id: cell.id, number: cell.number, query: cell.query, statements: [],
        parameterValues: cell.parameterValues)
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

    executeRunAllCells(
      pendingCells: pendingCells, skipConfirmable: false, confirmedParameters: true)
  }

  /// Execute Run All Cells skipping the cells that needed confirmation
  func executeRunAllCellsSkipDestructive() async {
    let pendingCells = queryConfirmationState.runAllPendingCells
    let skippedCount = queryConfirmationState.runAllConfirmCells.count
    queryConfirmationState.clearRunAll()

    executeRunAllCells(
      pendingCells: pendingCells, skipConfirmable: true, confirmedParameters: true)

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

  /// Shows the unlock sheet for a password Run All. The sheet lists the write statements
  /// already attached to each cell, numbered across cells ("Cell N: ...") so every row has a
  /// unique id.
  private func presentRunAllUnlock(_ cells: [RunAllCell]) {
    let listed = cells.flatMap { cell in
      cell.statements.map { (cell.number, $0) }
    }
    queryConfirmationState.clear()
    queryConfirmationState.statements = listed.enumerated().map { offset, entry in
      let (number, statement) = entry
      return StatementConfirmation(
        index: offset, preview: "Cell \(number): \(statement.preview)",
        kindLabel: statement.kindLabel, affectsAllRows: statement.affectsAllRows,
        touchesBrake: statement.touchesBrake, changesPrivileges: statement.changesPrivileges,
        parameterNote: statement.parameterNote,
        likePatternAffectsAllRows: statement.likePatternAffectsAllRows)
    }
    queryConfirmationState.affectsAllRows = listed.contains { $0.1.affectsAllRows }
    queryConfirmationState.likePatternAffectsAllRows = cells.contains { cell in
      Self.scriptMatchesAllRowsByLike(
        classifiedStatements(for: cell.query), parameters: cell.parameterValues,
        dialect: sqlDialect)
    }
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
    executeRunAllCells(
      pendingCells: pendingCells, skipConfirmable: false, confirmedParameters: true)
  }

  /// Internal helper to execute Run All Cells.
  /// `confirmedParameters` sends each cell's snapshotted binds. A run that never showed a
  /// dialog leaves it false and reads the live values at send time.
  private func executeRunAllCells(
    pendingCells: [RunAllCell], skipConfirmable: Bool, confirmedParameters: Bool = false
  ) {
    // Reset execution counter to start counting from 1 again
    executionCounter = 0

    // One batch: its cells only run on the connection its first cell started on
    let batchId = UUID()
    // Enqueue cells, optionally skipping the ones that needed confirmation
    for cell in pendingCells {
      if skipConfirmable && cell.needsConfirmation {
        continue
      }
      if confirmedParameters {
        ConfirmedParameterSnapshot.stashCell(
          self, cellId: cell.id, query: cell.query, values: cell.parameterValues)
      } else {
        ConfirmedParameterSnapshot.dropCell(self, cellId: cell.id)
      }
      executionQueue.enqueue(cellId: cell.id, query: cell.query, batchId: batchId)
    }
  }
}
