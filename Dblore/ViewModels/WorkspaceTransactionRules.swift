//
//  WorkspaceTransactionRules.swift
//  Dblore
//
//  Pure rules for the workspace-level Protected transaction: banner texts and totals, and which
//  window / tab / connection actions must resolve a pending transaction first. Banner Commit
//  never asks for a password.
//

import Foundation

/// A workspace action that would end (or hide) the pending app transaction
nonisolated enum PendingTransactionAction: Sendable, Equatable {
  case closeWindow
  case closeTab(UUID)
  case disconnect
  case quit

  /// Used in the prompt: "Commit or roll back before ..."
  var displayName: String {
    switch self {
    case .closeWindow: "closing the workspace"
    case .closeTab: "closing this tab"
    case .disconnect: "disconnecting"
    case .quit: "quitting"
    }
  }
}

/// The user's answer to the "Commit / Roll back / Cancel" prompt
nonisolated enum PendingTransactionResolution: Sendable, Equatable {
  case commit
  case rollback
  /// Keep the transaction (and the window / tab / connection)
  case cancel
  /// A statement is still running, so Commit and Rollback are refused: close the connection
  /// instead (the server discards the pending changes), then continue the action
  case discard
  /// ROLLBACK was sent and has not answered: close the connection (the server discards the
  /// pending changes), then continue the action
  case disconnect
  /// COMMIT was sent and has not answered: close the connection, then continue the action. The
  /// changes may or may not have been committed.
  case disconnectUnknownOutcome
}

/// Texts and totals of the pending-changes banner and the Commit confirmation
nonisolated struct PendingTransactionSummary: Sendable, Equatable {
  /// Statements listed by `reviewText`
  static let reviewLimit = 10

  let pending: [StatementSummary]
  let statementCount: Int
  /// Sum of the known affected rows (statements without a count add nothing)
  let affectedRows: Int
  /// Some statement changed an unknown number of rows: `affectedRows` is only a lower bound
  let hasUnknownRows: Bool
  /// The transaction was adopted with contents that were never listed
  let includesEarlierChanges: Bool
  let isAborted: Bool
  let abortReason: String?
  /// Commit / Rollback is being sent: the banner shows it and disables its buttons
  let ending: TransactionEndKind?

  init(state: TransactionState) {
    let pending = state.pending
    self.pending = pending
    statementCount = pending.count
    affectedRows = pending.reduce(0) { $0 + ($1.affectedRows ?? 0) }
    hasUnknownRows = pending.contains(where: \.rowsUnknown)
    includesEarlierChanges = pending.contains(where: \.isEarlierChanges)
    ending = state.endingKind
    if case .aborted(let reason, _) = state {
      isAborted = true
      abortReason = reason
    } else {
      isAborted = false
      abortReason = nil
    }
  }

  /// "N pending statements · M rows affected"; with unknown counts "rows affected unknown" or
  /// "M+ rows affected (some unknown)" (never "0 rows"); "Committing N statements…" /
  /// "Rolling back N statements…" while the end is in progress
  var headline: String {
    switch ending {
    case .commit: return "Committing \(Self.count(statementCount, "statement"))…"
    case .rollback: return "Rolling back \(Self.count(statementCount, "statement"))…"
    case nil: break
    }
    let rows =
      switch (hasUnknownRows, affectedRows) {
      case (false, _): "\(Self.count(affectedRows, "row")) affected"
      case (true, 0): "rows affected unknown"
      case (true, _): "\(affectedRows)+ rows affected (some unknown)"
      }
    return "\(Self.count(statementCount, "pending statement")) · \(rows)"
  }

  /// "Commit N statements · M rows?"; with unknown counts "rows unknown" or
  /// "M+ rows (some unknown)"
  var commitPrompt: String {
    let rows =
      switch (hasUnknownRows, affectedRows) {
      case (false, _): Self.count(affectedRows, "row")
      case (true, 0): "rows unknown"
      case (true, _): "\(affectedRows)+ rows (some unknown)"
      }
    return "Commit \(Self.count(statementCount, "statement")) · \(rows)?"
  }

  /// Shown with every Commit prompt of an adopted transaction
  var earlierChangesWarning: String? {
    guard includesEarlierChanges else { return nil }
    return "Warning: this transaction was opened before Protected mode was enabled. Commit also "
      + "makes permanent the earlier changes made in it, which are not listed here."
  }

  /// What Commit makes permanent, one line per statement (the first `reviewLimit`): kind (when
  /// the preview does not start with it), SQL preview, affected rows ("rows unknown" included),
  /// then "… and N more" and the earlier-changes warning. Used by the resolve prompt
  /// before close / disconnect / quit.
  var reviewText: String {
    let shown = pending.prefix(Self.reviewLimit).map { statement -> String in
      let preview = String(statement.sqlPreview.prefix(80))
      let kind =
        preview.uppercased().hasPrefix(statement.kindLabel) ? "" : "\(statement.kindLabel): "
      let rows = statement.rowsText.isEmpty ? "" : " (\(statement.rowsText))"
      return "• \(kind)\(preview)\(rows)"
    }
    let more =
      pending.count > Self.reviewLimit ? ["… and \(pending.count - Self.reviewLimit) more"] : []
    let warning = earlierChangesWarning.map { ["", $0] } ?? []
    return (shown + more + warning).joined(separator: "\n")
  }

  /// Commit / Rollback awaited this long: the banner offers to disconnect
  static let slowEndingThreshold: TimeInterval = 5

  /// Banner button once Commit / Rollback has been awaited for `slowEndingThreshold`
  static func slowEndingPrompt(_ ending: TransactionEndKind?, elapsed: TimeInterval) -> String? {
    guard let ending, elapsed >= slowEndingThreshold else { return nil }
    return "\(ending == .commit ? "Commit" : "Rollback") is taking long — Disconnect…"
  }

  /// "mm:ss", or "h:mm:ss" from one hour on (negative intervals count as zero)
  static func openDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }
}

nonisolated enum WorkspaceTransactionRules {
  /// True if `action` must first resolve the pending transaction (Commit / Roll back / Cancel).
  /// Idle never does. Closing a tab only does for the tab that opened the transaction (the
  /// transaction lives on the workspace connection, so other tabs can close freely).
  static func requiresResolution(
    state: TransactionState, action: PendingTransactionAction, originTabId: UUID?
  ) -> Bool {
    guard !state.isIdle else { return false }
    if case .closeTab(let tabId) = action {
      return tabId == originTabId
    }
    return true
  }

  /// Answers the prompt offers: an aborted transaction can only be rolled back. While a
  /// statement of the transaction is in flight the actor refuses Commit and Rollback, so the way
  /// out is Discard (close the connection: the server discards the pending changes). While
  /// COMMIT / ROLLBACK is awaited (it may never answer) the way out is disconnecting: after
  /// COMMIT the outcome is unknown, after ROLLBACK the server discards the changes.
  static func resolutions(
    for state: TransactionState, statementInFlight: Bool = false
  ) -> [PendingTransactionResolution] {
    switch state {
    case .idle: []
    case .appTx where statementInFlight, .aborted where statementInFlight: [.discard, .cancel]
    case .appTx: [.commit, .rollback, .cancel]
    case .aborted: [.rollback, .cancel]
    case .ending(.commit, _): [.disconnectUnknownOutcome, .cancel]
    case .ending(.rollback, _): [.disconnect, .cancel]
    }
  }

  /// A forced close answers without a prompt: the first answer that neither commits nor may
  /// commit (Rollback, Discard, or Disconnect while ROLLBACK is awaited). Nil when idle, or while
  /// COMMIT is awaited (disconnecting might commit: the prompt decides).
  static func forcedResolution(
    for state: TransactionState, statementInFlight: Bool = false
  ) -> PendingTransactionResolution? {
    resolutions(for: state, statementInFlight: statementInFlight).first {
      $0 == .rollback || $0 == .discard || $0 == .disconnect
    }
  }

  /// Button title of an answer in the resolve prompt
  static func title(for resolution: PendingTransactionResolution) -> String {
    switch resolution {
    case .commit: "Commit"
    case .rollback: "Roll Back"
    case .cancel: "Cancel"
    case .discard: "Discard Changes and Disconnect"
    case .disconnect: "Disconnect"
    case .disconnectUnknownOutcome: "Disconnect (outcome unknown)"
    }
  }

  /// Answers that close the connection: destructive buttons, never on Return
  static func isDestructive(_ resolution: PendingTransactionResolution) -> Bool {
    switch resolution {
    case .discard, .disconnect, .disconnectUnknownOutcome: true
    case .commit, .rollback, .cancel: false
    }
  }

  /// What the resolve prompt explains, for the answers it offers (truthful per answer: only
  /// Discard / Disconnect after ROLLBACK promise that nothing is committed)
  static func promptDecision(
    summary: PendingTransactionSummary, options: [PendingTransactionResolution],
    action: PendingTransactionAction
  ) -> String {
    if options.contains(.disconnectUnknownOutcome) {
      return "Commit was sent and has not answered. Disconnecting closes the connection: the "
        + "changes may or may not have been committed. Check the data after reconnecting."
    }
    if options.contains(.disconnect) {
      return "Rollback was sent and has not answered. Disconnecting closes the connection; the "
        + "server discards the pending changes."
    }
    if options.contains(.discard) {
      return "A statement is still running, so Commit and Roll Back are not possible now. "
        + "\"Discard Changes and Disconnect\" closes the connection before \(action.displayName): "
        + "the server then discards the pending changes (nothing is committed)."
    }
    if summary.isAborted {
      return "Only Rollback is possible (\(summary.abortReason ?? "")). "
        + "Roll back before \(action.displayName)?"
    }
    return "Commit or roll back before \(action.displayName)."
  }

  /// Banner Commit never asks for a password, for every commit style. A connection whose
  /// stored safe mode is `.safeRead` or `.safeAll` and whose resolved style is review is
  /// included: the yellow banner confirms the list, then commits.
  static func commitRequiresUnlock() -> Bool {
    false
  }
}
