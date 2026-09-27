//
//  WorkspaceManager+Transaction.swift
//  SQLNotebook
//
//  Workspace-level Protected transaction: the observable mirror of the actor's state (shown
//  by `PendingTransactionBanner`), Commit (confirmation, Safe Mode unlock) / Rollback, and the
//  single `resolvePendingTransaction(action:)` decision used before closing the workspace, the
//  tab that opened the transaction, disconnecting and quitting.
//
//  If the app is force-quit (or crashes, or the network drops) the connection closes without
//  COMMIT, so the server rolls the pending transaction back: nothing is committed silently.
//

import AppKit
import Foundation

/// Asks the user how to resolve the pending transaction before `action`, offering the given
/// answers (`WorkspaceTransactionRules.resolutions(for:statementInFlight:)`)
typealias PendingTransactionPrompt =
  @MainActor (
    PendingTransactionAction, PendingTransactionSummary, [PendingTransactionResolution]
  ) async -> PendingTransactionResolution

extension WorkspaceManager {
  // MARK: - Mirror

  /// Schema browser and autocomplete serve cached metadata until Commit / Rollback
  var isSchemaPaused: Bool { !pendingTransaction.isIdle }

  /// Every statement execution in the tab refreshes the mirror. A new tab never opened the
  /// pending transaction, so it starts blocked while one is pending.
  func attachTransactionHook(to viewModel: NotebookViewModel) {
    viewModel.isTransactionPendingElsewhere = !pendingTransaction.isIdle
    viewModel.onStatementsExecuted = { [weak self] in
      await self?.refreshPendingTransaction()
    }
  }

  /// Read the actor's transaction state into `pendingTransaction`. The origin tab is the tab
  /// whose token (`NotebookViewModel.id`) the actor recorded as the transaction owner.
  func refreshPendingTransaction() async {
    let status = await connectionManager.transactionStatus()
    let originTabId = status.owner.flatMap { owner in
      viewModels.first { $0.value.id == owner }?.key
    }
    pendingTransactionGeneration = status.generation
    isStatementInFlight = status.inFlight
    applyTransactionState(status.state, originTabId: originTabId)
  }

  /// The tab that opened the pending transaction is running cells or an editor query: Commit
  /// and Rollback wait (the actor refuses them anyway while a gated statement is in flight).
  var isTransactionOriginRunning: Bool {
    guard let origin = transactionOriginTabId, let viewModel = viewModels[origin] else {
      return false
    }
    return (viewModel.executionQueue?.isProcessing ?? false) || viewModel.isEditorQueryRunning
  }

  /// Some tab is running cells or an editor query: the mirror may still be idle while its
  /// statement opened a transaction (it is refreshed after the statements finished)
  var isAnyTabExecuting: Bool {
    viewModels.values.contains {
      ($0.executionQueue?.isProcessing ?? false) || $0.isEditorQueryRunning
    }
  }

  /// Opening time is set on the idle -> pending transition; everything is cleared on idle.
  /// Every tab but the origin is blocked while a transaction is pending.
  func applyTransactionState(_ state: TransactionState, originTabId: UUID?) {
    if state.isIdle {
      transactionOpenedAt = nil
      isCommitConfirmationVisible = false
      isCommitUnlockVisible = false
      commitReviewedGeneration = nil
    } else if pendingTransaction.isIdle {
      transactionOpenedAt = state.pending.first?.executedAt ?? Date()
    }
    let origin = state.isIdle ? nil : originTabId
    if transactionOriginTabId != origin { transactionOriginTabId = origin }
    if pendingTransaction != state { pendingTransaction = state }
    for (tabId, viewModel) in viewModels {
      let blocked = !state.isIdle && tabId != origin
      if viewModel.isTransactionPendingElsewhere != blocked {
        viewModel.isTransactionPendingElsewhere = blocked
      }
    }
  }

  // MARK: - Commit

  /// Banner Commit: show the confirmation ("Commit N statements · M rows?") for the list shown
  /// now (its generation is what Commit may commit). Not possible while aborted (only Rollback).
  func requestCommit() {
    guard case .appTx = pendingTransaction else { return }
    commitReviewedGeneration = pendingTransactionGeneration
    isCommitConfirmationVisible = true
  }

  /// Confirmation accepted: commit the reviewed list now, or first ask for the Safe Mode unlock
  /// when the effective Safe Mode requires a password. Does nothing without `requestCommit()`.
  /// - Returns: true if committed (or nothing was pending).
  @discardableResult
  func confirmCommit(globalSafeMode: SafeMode = AppSettings.shared.safeMode) async -> Bool {
    isCommitConfirmationVisible = false
    guard let reviewed = commitReviewedGeneration else { return false }
    if commitRequiresUnlock(globalSafeMode: globalSafeMode) {
      isCommitUnlockVisible = true
      return false
    }
    return await performCommit(expectedGeneration: reviewed)
  }

  func commitRequiresUnlock(globalSafeMode: SafeMode = AppSettings.shared.safeMode) -> Bool {
    let state = ConnectionSafetyState(
      config: workspace.connectionConfig, globalSafeMode: globalSafeMode)
    return WorkspaceTransactionRules.commitRequiresUnlock(safeMode: state.safeMode)
  }

  /// Safe Mode unlock succeeded (only while the unlock for a confirmed Commit is shown)
  @discardableResult
  func completeCommitUnlock() async -> Bool {
    guard isCommitUnlockVisible, let reviewed = commitReviewedGeneration else { return false }
    isCommitUnlockVisible = false
    return await performCommit(expectedGeneration: reviewed)
  }

  /// Confirmation cancelled: nothing reviewed any more
  func cancelCommitConfirmation() {
    commitReviewedGeneration = nil
  }

  func cancelCommitUnlock() {
    isCommitUnlockVisible = false
    commitReviewedGeneration = nil
  }

  /// Commit the app transaction the user reviewed (`expectedGeneration`, after confirmation /
  /// unlock). Errors, including "the list changed — review again", surface as a toast.
  /// - Returns: true if committed (or nothing was pending).
  @discardableResult
  private func performCommit(expectedGeneration: UInt64) async -> Bool {
    commitReviewedGeneration = nil
    let before = await connectionManager.transactionSnapshot()
    guard !before.isIdle else {
      await refreshPendingTransaction()
      return true
    }
    let summary = PendingTransactionSummary(state: before)
    // The banner shows "Committing…" with its buttons disabled until the refresh below
    applyTransactionState(
      .ending(kind: .commit, pending: before.pending), originTabId: transactionOriginTabId)
    do {
      try await connectionManager.commitAppTransaction(expectedGeneration: expectedGeneration)
      await refreshPendingTransaction()
      showTransactionToast(
        "Committed \(Self.statements(summary.statementCount))", type: .success)
      return true
    } catch {
      await refreshPendingTransaction()
      showTransactionToast(error.localizedDescription, type: .error)
      return false
    }
  }

  // MARK: - Rollback

  /// Roll back the app transaction (no confirmation: the safe direction). Errors surface as
  /// a toast.
  /// - Returns: true if rolled back (or nothing was pending).
  @discardableResult
  func rollback() async -> Bool {
    let before = await connectionManager.transactionSnapshot()
    guard !before.isIdle else {
      await refreshPendingTransaction()
      return true
    }
    applyTransactionState(
      .ending(kind: .rollback, pending: before.pending), originTabId: transactionOriginTabId)
    do {
      try await connectionManager.rollbackAppTransaction()
      await refreshPendingTransaction()
      showTransactionToast("Rolled back \(Self.statements(before.pending.count))", type: .info)
      return true
    } catch {
      await refreshPendingTransaction()
      showTransactionToast(error.localizedDescription, type: .error)
      return false
    }
  }

  // MARK: - Resolve before close / disconnect / quit

  /// The single decision before an action that would end or hide the pending transaction.
  /// Idle (or a tab that did not open it) proceeds. Otherwise `resolution` (or the prompt's
  /// answer) is applied: Cancel keeps everything; Commit under a password Safe Mode opens the
  /// unlock and cancels the action (repeat it after committing); Discard (offered while a
  /// statement is in flight) and Disconnect (offered while COMMIT / ROLLBACK is awaited)
  /// disconnect, so the server ends the transaction. When the prompted Commit / Rollback fails
  /// (e.g. refused because a statement started meanwhile), the prompt is shown again with the
  /// current options (Discard while it runs). Refused while another resolve prompt is open.
  /// - Returns: true if the action may proceed (nothing is pending any more).
  func resolvePendingTransaction(
    action: PendingTransactionAction, resolution: PendingTransactionResolution? = nil,
    globalSafeMode: SafeMode = AppSettings.shared.safeMode
  ) async -> Bool {
    guard !isResolvingPendingTransaction else { return false }
    while true {
      await refreshPendingTransaction()
      guard
        WorkspaceTransactionRules.requiresResolution(
          state: pendingTransaction, action: action, originTabId: transactionOriginTabId)
      else { return true }

      let options = WorkspaceTransactionRules.resolutions(
        for: pendingTransaction, statementInFlight: isStatementInFlight)
      let summary = PendingTransactionSummary(state: pendingTransaction)
      // The prompt shows this list: Commit may only commit it
      let reviewed = pendingTransactionGeneration
      let answer: PendingTransactionResolution
      if let resolution {
        answer = resolution
      } else {
        // Only while the prompt is open: a hung COMMIT / ROLLBACK chosen here must stay
        // escapable from the banner, a close or a quit
        isResolvingPendingTransaction = true
        answer = await promptForResolution(action: action, summary: summary, options: options)
        isResolvingPendingTransaction = false
      }
      guard options.contains(answer) else { return false }
      // A queued cell of the origin tab must not start a new transaction (or send BEGIN to a
      // closing connection) once the answer is applied
      if answer != .cancel { cancelOriginTabExecution() }
      switch answer {
      case .cancel:
        return false
      case .discard, .disconnect, .disconnectUnknownOutcome:
        await performDisconnect()
        return pendingTransaction.isIdle
      case .rollback:
        await rollback()
      case .commit:
        if commitRequiresUnlock(globalSafeMode: globalSafeMode) {
          commitReviewedGeneration = reviewed
          isCommitUnlockVisible = true
          return false
        }
        await performCommit(expectedGeneration: reviewed)
      }
      // Prompted Commit / Rollback refused (a statement started meanwhile, or the list changed):
      // ask again with the current list and options
      guard resolution == nil, !pendingTransaction.isIdle else { return pendingTransaction.isIdle }
    }
  }

  // MARK: - Disconnect

  /// Disconnect; a pending Protected transaction is resolved first (prompt, or `resolution`).
  /// - Returns: false if the user cancelled (still connected, transaction kept).
  @discardableResult
  func disconnect(resolution: PendingTransactionResolution? = nil) async -> Bool {
    let wasConnected = connectionState == .connected
    guard await resolvePendingTransaction(action: .disconnect, resolution: resolution) else {
      return false
    }
    // Discard / Disconnect already closed the connection
    if wasConnected && connectionState != .connected { return true }
    await performDisconnect()
    return true
  }

  /// Close the connection and clear everything that came from it (no resolve: the caller did it,
  /// or chose to discard the pending changes by disconnecting)
  func performDisconnect() async {
    await connectionManager.disconnect()
    await refreshPendingTransaction()
    connectionState = .disconnected
    invalidateEditTargetsInTabs()

    // Clear schema
    databaseTables = []
    databaseViews = []
    databaseFunctions = []
    databaseProcedures = []
    databaseUsers = []
    databaseRoles = []
    databaseForeignKeys = []

    // Clear autocomplete cache
    autocompleteProvider.clearCache()

    // Update all tab ViewModels
    syncConnectionStateToTabs()
  }

  /// Closing the tab that opened the pending transaction: resolve first, then close again.
  /// While a resolve prompt is open the close is dropped (no second prompt).
  /// - Returns: true if the close is deferred to the resolution.
  func deferCloseTabForPendingTransaction(id: UUID) -> Bool {
    guard !isResolvingPendingTransaction else { return true }
    guard
      WorkspaceTransactionRules.requiresResolution(
        state: pendingTransaction, action: .closeTab(id), originTabId: transactionOriginTabId)
    else { return false }
    Task {
      if await resolvePendingTransaction(action: .closeTab(id)) { requestCloseTab(id: id) }
    }
    return true
  }

  // MARK: - Private

  /// Cancel the queued and running cells of the tab that opened the transaction (queue only, no
  /// cancel prompt). The editor has no queue: its run is one actor call, refused or failing once
  /// the transaction ended.
  private func cancelOriginTabExecution() {
    guard let origin = transactionOriginTabId, let viewModel = viewModels[origin] else { return }
    viewModel.cancelAllCells()
  }

  private func promptForResolution(
    action: PendingTransactionAction, summary: PendingTransactionSummary,
    options resolutions: [PendingTransactionResolution]
  ) async -> PendingTransactionResolution {
    if let pendingTransactionPrompt {
      return await pendingTransactionPrompt(action, summary, resolutions)
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      summary.isAborted
      ? "The pending transaction in \"\(workspace.name)\" failed"
      : "Uncommitted changes in \"\(workspace.name)\""
    let decision = WorkspaceTransactionRules.promptDecision(
      summary: summary, options: resolutions, action: action)
    // What Commit would make permanent (or Rollback / Discard throws away)
    alert.informativeText = "\(summary.headline). \(decision)\n\n\(summary.reviewText)"
    for resolution in resolutions {
      let button = alert.addButton(withTitle: WorkspaceTransactionRules.title(for: resolution))
      if resolution == .cancel {
        button.keyEquivalent = "\u{1b}"
      } else if resolution != .rollback {
        button.keyEquivalent = ""  // never commit / disconnect on Return
      }
      button.hasDestructiveAction = WorkspaceTransactionRules.isDestructive(resolution)
    }
    let response: NSApplication.ModalResponse
    if let window = NewWindowStore.shared.findWindow(for: id) ?? NSApp.keyWindow {
      response = await alert.beginSheetModal(for: window)
    } else {
      response = alert.runModal()  // quitting with no window open
    }
    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    return resolutions.indices.contains(index) ? resolutions[index] : .cancel
  }

  private static func statements(_ count: Int) -> String {
    "\(count) statement\(count == 1 ? "" : "s")"
  }

  private func showTransactionToast(_ message: String, type: ToastMessage.ToastType) {
    WorkspaceWindowManager.shared.showToast(message, type: type)
  }
}
