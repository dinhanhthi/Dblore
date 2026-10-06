// TransactionState.swift
// Protected mode transaction state and the pure rules deciding which user statements open,
// join or are recorded in the app-owned transaction.

import Foundation

/// One statement that ran inside the app transaction (shown in the pending-changes banner).
nonisolated struct StatementSummary: Sendable, Equatable {
  static let maxPreviewLength = 200

  /// Statement text with whitespace collapsed, cut at `maxPreviewLength` (plus an ellipsis)
  let sqlPreview: String
  /// First keyword of the statement (UPDATE, CREATE, SET, ...)
  let kindLabel: String
  /// Rows reported by the server for DML; nil when unknown or not applicable
  let affectedRows: Int?
  /// The statement may have changed rows but their number is unknown (nil `affectedRows` of
  /// DML / utility / unrecognized statements, e.g. a data-modifying WITH). DDL and SET without
  /// a count are "not applicable", not unknown.
  let rowsUnknown: Bool
  /// Synthetic entry for a user transaction adopted when Protected mode was turned on: what
  /// ran in it before is not known
  let isEarlierChanges: Bool
  let executedAt: Date

  init(statement: ClassifiedStatement, affectedRows: Int?, executedAt: Date = Date()) {
    let collapsed = statement.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    sqlPreview =
      collapsed.count > Self.maxPreviewLength
      ? String(collapsed.prefix(Self.maxPreviewLength)) + "…" : collapsed
    kindLabel =
      SQLTokenizer.tokens(statement.text).first { $0.kind == .word }?.keyword
      ?? DatabaseConnectionManager.describe(statement.kind)
    self.affectedRows = affectedRows
    rowsUnknown =
      affectedRows == nil
      && [.dml, .utility, .unknown].contains(SQLStatementClassifier.effectiveKind(statement.kind))
    isEarlierChanges = false
    self.executedAt = executedAt
  }

  private init(earlierChangesAt executedAt: Date) {
    sqlPreview = "Transaction opened before Protected mode was enabled — contents unknown"
    kindLabel = "EARLIER"
    affectedRows = nil
    rowsUnknown = true
    isEarlierChanges = true
    self.executedAt = executedAt
  }

  /// The pending entry of an adopted user transaction (its contents were never reviewed)
  static func earlierChanges(at executedAt: Date = Date()) -> StatementSummary {
    StatementSummary(earlierChangesAt: executedAt)
  }

  /// "N rows", "rows unknown", or "" when a row count does not apply
  var rowsText: String {
    if let affectedRows { return "\(affectedRows) row\(affectedRows == 1 ? "" : "s")" }
    return rowsUnknown ? "rows unknown" : ""
  }
}

/// Commit only what the user reviewed: `generation` changes with every transaction state change
/// (BEGIN, adoption, each recorded statement / edit, abort, end) and `inFlight` counts gated user
/// statements and edits being sent. Pure, so the refusal rule is testable without a database.
nonisolated struct CommitGuard: Sendable, Equatable {
  var generation: UInt64 = 0
  var inFlight = 0

  /// Commit is refused while a gated statement runs (COMMIT would queue behind it and commit it
  /// too) or when the transaction changed since the confirmation showed `expectedGeneration`.
  func refusesCommit(expectedGeneration: UInt64) -> Bool {
    inFlight > 0 || generation != expectedGeneration
  }

  /// Rollback is refused while a gated statement runs: its next statement would be sent after
  /// ROLLBACK and autocommit.
  var refusesRollback: Bool { inFlight > 0 }
}

/// Which end of the app transaction is being sent
nonisolated enum TransactionEndKind: Sendable, Equatable {
  case commit
  case rollback
}

/// Transaction state of a connection under Protected mode.
nonisolated enum TransactionState: Sendable, Equatable {
  /// No app transaction: statements autocommit
  case idle
  /// The app sent BEGIN; `pending` ran inside it and wait for Commit / Rollback
  case appTx(pending: [StatementSummary])
  /// A statement failed inside the app transaction: the server refuses everything until
  /// ROLLBACK, so only Rollback is allowed
  case aborted(reason: String, pending: [StatementSummary])
  /// COMMIT / ROLLBACK was sent and is awaited: every gated entry is refused (it would run after
  /// the end, in autocommit) and catalog queries stay paused until the state is idle
  case ending(kind: TransactionEndKind, pending: [StatementSummary])

  var pending: [StatementSummary] {
    switch self {
    case .idle: []
    case .appTx(let pending), .aborted(_, let pending), .ending(_, let pending): pending
    }
  }

  /// The end in progress, nil unless `.ending`
  var endingKind: TransactionEndKind? {
    if case .ending(let kind, _) = self { return kind }
    return nil
  }

  var isIdle: Bool { self == .idle }
}

/// What the runner does with one allowed statement under Protected mode.
nonisolated enum ProtectedStatementAction: Sendable, Equatable {
  /// Send as is (autocommit, or inside the pending transaction), not recorded
  case run
  /// Send inside the pending transaction and record it
  case record
  /// Send BEGIN first, then the statement, and record it
  case open
}

/// Pure Protected mode rules. Transaction control and non-transactional statements never
/// reach these rules: the gate (`DatabaseConnectionManager.evaluate`) refuses them.
nonisolated enum ProtectedTransactionRules {

  /// Statements that may change data run inside the app transaction: DML, DDL (also under
  /// EXPLAIN ANALYZE), utility commands that can run in a transaction (DO, CALL, COPY, LOCK, ...)
  /// and unrecognized statements (fail closed: whatever they do can be rolled back).
  static func opensTransaction(_ statement: ClassifiedStatement) -> Bool {
    switch SQLStatementClassifier.effectiveKind(statement.kind) {
    case .dml, .ddl, .utility, .unknown: true
    default: false
    }
  }

  /// Reads run as is (inside the transaction when one is pending, so they see its changes).
  /// Session SET/RESET does not open a transaction, but inside one it is recorded because it
  /// is rolled back with it.
  static func action(
    for statement: ClassifiedStatement, inTransaction: Bool
  ) -> ProtectedStatementAction {
    if opensTransaction(statement) { return inTransaction ? .record : .open }
    if case .sessionSet = statement.kind, inTransaction { return .record }
    return .run
  }

  /// DDL (including under `EXPLAIN ANALYZE`) and `SELECT INTO` / `CREATE TABLE AS`.
  /// Once one of these commits, the sidebar schema is stale.
  static func changesVisibleSchema(_ statement: ClassifiedStatement) -> Bool {
    statement.createsTable || SQLStatementClassifier.effectiveKind(statement.kind) == .ddl
  }

  /// `COMMIT` / `END` that persisted the user transaction. `ROLLBACK`, `ABORT`, and `PREPARE`
  /// do not. The caller already saw the transaction close, or a `COMMIT AND CHAIN` that
  /// committed and opened the next one.
  static func committedUserTransaction(_ statement: ClassifiedStatement) -> Bool {
    guard statement.kind == .tcl else { return false }
    let first = SQLTokenizer.tokens(statement.text).first { $0.kind == .word }?.keyword ?? ""
    return first == "COMMIT" || first == "END"
  }

  /// Statements that may change the schema (fail closed: DDL, also under EXPLAIN ANALYZE,
  /// utility and unrecognized statements) invalidate the cached inline edit tables.
  static func invalidatesEditTables(_ statement: ClassifiedStatement) -> Bool {
    switch SQLStatementClassifier.effectiveKind(statement.kind) {
    case .ddl, .utility, .unknown: true
    default: false
    }
  }

  /// Tracks a transaction the user opened while Protected mode is off: BEGIN / START open it;
  /// COMMIT / END / ROLLBACK / ABORT / PREPARE TRANSACTION close it (ROLLBACK TO keeps it).
  /// `... AND CHAIN` (not `AND NO CHAIN`) starts a new transaction right away: still open.
  /// A failed statement changes nothing, except a failed COMMIT / END, which ends the
  /// transaction on the server (the chained transaction is not started).
  static func userTxOpen(
    after statement: ClassifiedStatement, current: Bool, succeeded: Bool
  ) -> Bool {
    guard statement.kind == .tcl else { return current }
    let words = SQLTokenizer.tokens(statement.text).map { $0.keyword ?? "" }
    let first = words.first ?? ""
    guard succeeded else { return first == "COMMIT" || first == "END" ? false : current }
    let chains = zip(words, words.dropFirst()).contains { $0 == "AND" && $1 == "CHAIN" }
    switch first {
    case "BEGIN", "START": return true
    case "COMMIT", "END", "ABORT": return chains
    case "PREPARE": return false
    // ROLLBACK [WORK | TRANSACTION] TO [SAVEPOINT] name
    case "ROLLBACK": return words.contains("TO") ? current : chains
    default: return current
    }
  }
}
