// DatabaseConnectionManager+Gate.swift
// Execution gate: every user SQL is classified and checked against the protection policy
// before any statement is sent. App-owned SQL uses `executeInternal`.

import Foundation
import Logging
import PostgresNIO

/// One user statement after `:name` replacement, with the names that statement binds.
private nonisolated struct RewrittenUserStatement: Sendable {
  let statement: ClassifiedStatement
  let names: [String]
  let original: String
}

/// Outcome of checking a classified script against a `ProtectionPolicy`.
nonisolated enum GateDecision: Sendable, Equatable {
  case allowed
  /// `statementIndex` is the 0-based index of the first violating statement
  case blocked(statementIndex: Int, kind: StatementKind, reason: String)
}

extension DatabaseConnectionManager {
  // MARK: - Gated entry points (user SQL)

  /// Execute user SQL (one or more statements) and return the combined result.
  /// Throws `DatabaseError.blockedByProtection` before anything is sent if ANY statement
  /// violates `policy`. Under Protected mode, writes run in the app transaction; while it is
  /// pending, a `caller` (tab token) other than the one that opened it is refused
  /// (`DatabaseError.transactionPendingInAnotherTab`). With `expectedEpoch`, nothing is sent
  /// unless the connection is still that one (`DatabaseError.sessionChanged`).
  /// `parameters` nil sends `userSQL` unchanged. A dictionary rewrites each statement's
  /// `:name` placeholders and binds those values.
  func execute(
    userSQL: String, parameters: [String: SQLBindValue]? = nil, policy: ProtectionPolicy,
    maxRows: Int = defaultMaxFetchRows, caller: UUID? = nil, expectedEpoch: UInt64? = nil
  ) async throws -> QueryResult {
    let run = try await runUserSQL(
      userSQL, parameters: parameters, policy: policy, maxRows: maxRows, caller: caller,
      expectedEpoch: expectedEpoch)
    return Self.combined(run.results.map(\.result), totalTime: run.totalTime)
  }

  /// Execute user SQL and return one result per statement.
  /// Throws `DatabaseError.blockedByProtection` before anything is sent if ANY statement
  /// violates `policy`. Under Protected mode, writes run in the app transaction (same `caller`
  /// rule as `execute`, same `expectedEpoch` check). `parameters` nil sends `userSQL`
  /// unchanged; a dictionary rewrites `:name` the same way `execute` does.
  func executeDetailed(
    userSQL: String, parameters: [String: SQLBindValue]? = nil, policy: ProtectionPolicy,
    maxRows: Int = defaultMaxFetchRows, caller: UUID? = nil, expectedEpoch: UInt64? = nil
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    try await runUserSQL(
      userSQL, parameters: parameters, policy: policy, maxRows: maxRows, caller: caller,
      expectedEpoch: expectedEpoch)
  }

  /// `parameters` nil keeps the authorize path. A dictionary rewrites first, then uses the
  /// same effective policy; missing names are refused only after that policy allows the script.
  private func runUserSQL(
    _ userSQL: String, parameters: [String: SQLBindValue]?, policy: ProtectionPolicy,
    maxRows: Int, caller: UUID?, expectedEpoch: UInt64?
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    guard let parameters else {
      let (statements, protectedMode) = try authorize(userSQL, policy: policy)
      return try await runUserStatements(
        statements, protectedMode: protectedMode, maxRows: maxRows, caller: caller,
        expectedEpoch: expectedEpoch)
    }
    let plan = try planNamedParameters(userSQL, parameters: parameters, policy: policy)
    return try await runUserStatements(
      plan.statements, protectedMode: plan.protectedMode, maxRows: maxRows, caller: caller,
      expectedEpoch: expectedEpoch, binds: plan.binds, originalTexts: plan.originalTexts)
  }

  private func planNamedParameters(
    _ sql: String, parameters: [String: SQLBindValue], policy: ProtectionPolicy
  ) throws -> (
    statements: [ClassifiedStatement], protectedMode: Bool, binds: [[SQLBindValue]],
    originalTexts: [String]
  ) {
    let dialect = Self.dialect(of: config)
    let original = Self.classifyUserSQL(sql, config: config)
    if Self.hasMixedPlaceholders(original, dialect: dialect) {
      throw DatabaseError.mixedPlaceholders
    }
    let rewritten = Self.rewriteNamedParameters(original, dialect: dialect)
    let effective = effectivePolicy(for: policy)
    let statements = rewritten.map(\.statement)
    if case .blocked(let index, let kind, let reason) = Self.evaluate(statements, policy: effective)
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    let missing = Self.missingParameterNames(in: rewritten, parameters: parameters)
    guard missing.isEmpty else { throw DatabaseError.missingParameters(missing) }
    return (
      statements, effective.protectedMode, Self.bindValues(for: rewritten, parameters: parameters),
      rewritten.map(\.original)
    )
  }

  /// True when any statement both names a `:name` and contains a positional placeholder.
  /// The whole script is scanned before a caller may classify the rewritten text for policy.
  private nonisolated static func hasMixedPlaceholders(
    _ statements: [ClassifiedStatement], dialect: SQLDialect
  ) -> Bool {
    statements.contains { statement in
      let names = SQLParameterRewriter.parameterNames(in: statement.text, dialect: dialect)
      return !names.isEmpty
        && SQLParameterRewriter.containsPositionalPlaceholder(
          in: statement.text, dialect: dialect)
    }
  }

  /// Replace `:name` per statement. A statement the classifier drops (empty / comment-only)
  /// is omitted, so binds stay aligned with what will be sent.
  private nonisolated static func rewriteNamedParameters(
    _ statements: [ClassifiedStatement], dialect: SQLDialect
  ) -> [RewrittenUserStatement] {
    statements.compactMap { statement in
      let (text, names) = SQLParameterRewriter.rewrite(statement: statement.text, dialect: dialect)
      guard let classified = SQLStatementClassifier.classifyStatement(text, dialect: dialect) else {
        return nil
      }
      return RewrittenUserStatement(statement: classified, names: names, original: statement.text)
    }
  }

  /// Distinct names in first-occurrence order across `rewritten` that `parameters` does not have.
  private nonisolated static func missingParameterNames(
    in rewritten: [RewrittenUserStatement], parameters: [String: SQLBindValue]
  ) -> [String] {
    var ordered: [String] = []
    var seen: Set<String> = []
    for piece in rewritten {
      for name in piece.names where seen.insert(name).inserted {
        ordered.append(name)
      }
    }
    return ordered.filter { parameters[$0] == nil }
  }

  private nonisolated static func bindValues(
    for rewritten: [RewrittenUserStatement], parameters: [String: SQLBindValue]
  ) -> [[SQLBindValue]] {
    rewritten.map { piece in piece.names.compactMap { parameters[$0] } }
  }

  /// Send an inline grid edit (app-built UPDATE, values as bind parameters); it must update
  /// exactly one row (command tag, not result rows), so the returned count is always 1.
  /// Throws `DatabaseError.notEditable` before anything is sent if `connectionEpoch` (of the
  /// edit target) is not the current connection's, and `DatabaseError.blockedByProtection` if
  /// `policy` forbids it. Under Protected mode the edit opens / joins the app transaction
  /// (same `caller` rule as `execute`, see `runProtectedEdit`); otherwise it is committed on its
  /// own or runs in the user's open transaction (`runUnprotectedEdit`). `commitImmediately`
  /// (the user's "commit inline edits immediately" setting) commits on its own even under
  /// Protected mode, unless an app transaction is already pending (the edit then joins it).
  /// Any other row count throws `DatabaseError.editRowCountMismatch`.
  func executeGatedUpdate(
    _ statement: CellUpdateStatement, policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, commitImmediately: Bool = false
  )
    async throws -> Int
  {
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    let (statements, protectedMode) = try authorize(statement.sql, policy: policy)
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    if protectedMode, !commitImmediately || !txState.isIdle {
      return try await runProtectedEdit(statement, classified: statements.first, caller: caller)
    }
    return try await runUnprotectedEdit(statement)
  }

  /// Send a staged batch (app-built DELETE / UPDATE / INSERT, values as bind parameters).
  /// Every statement is classified and checked against the same merged policy as `authorize`
  /// before anything is sent: the first violation throws `DatabaseError.blockedByProtection`
  /// and the batch is not sent. An empty batch returns `[]`. `connectionEpoch` must still be
  /// `epoch` (`DatabaseError.notEditable` otherwise). Each statement must affect exactly one
  /// row. Returns those counts (all 1s). Under Protected mode the batch joins the app
  /// transaction (`runStagedBatch`); otherwise it commits on its own or runs in the user's
  /// open transaction.
  func executeGatedBatch(
    _ statements: [BoundStatement], policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil
  ) async throws -> [Int] {
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    let effective = effectivePolicy(for: policy)
    // Decision is pure and finishes before any await that could send SQL.
    if case .blocked(let index, let kind, let reason) = Self.evaluateBatch(
      statements, policy: effective, dialect: Self.dialect(of: config))
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    if statements.isEmpty { return [] }
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    return try await runStagedBatch(
      statements, caller: caller, protectedMode: effective.protectedMode)
  }

  /// One result for a whole script: a single statement's result as is; otherwise the last
  /// result with the total time and the summed affected rows.
  private static func combined(_ results: [QueryResult], totalTime: TimeInterval) -> QueryResult {
    guard let last = results.last, results.count > 1 else {
      return results.last ?? QueryResult(columns: [], rows: [], rowCount: 0, executionTime: 0)
    }
    let total = results.compactMap(\.affectedRows).reduce(0, +)
    var combined = QueryResult(
      columns: last.columns, rows: last.rows, rowCount: last.rowCount, executionTime: totalTime,
      wasLimited: last.wasLimited, affectedRows: total > 0 ? total : last.affectedRows)
    // The rows shown are the last statement's; a session reset always ends the script
    combined.truncated = last.truncated
    combined.sessionReset = last.sessionReset
    combined.skippedStatements = last.skippedStatements
    return combined
  }

  // MARK: - Gate

  /// The stricter of `policy` and the connected config. A pending app transaction keeps
  /// Protected mode rules until Commit / Rollback, even if the toggle was turned off.
  private func effectivePolicy(for policy: ProtectionPolicy) -> ProtectionPolicy {
    let merged = policy.stricter(connectedPolicy)
    return ProtectionPolicy(
      protectionLevel: merged.protectionLevel, safeMode: merged.safeMode,
      protectedMode: merged.protectedMode || !txState.isIdle)
  }

  /// Classify every statement of `sql` and throw if the stricter of `policy` and the connected
  /// config's protection blocks any of them (a caller can never weaken the connection).
  /// A pending app transaction keeps Protected mode rules until Commit / Rollback, even if the
  /// toggle was turned off meanwhile.
  /// - Returns: the classified statements and whether Protected mode applies.
  private func authorize(
    _ sql: String, policy: ProtectionPolicy
  ) throws -> (statements: [ClassifiedStatement], protectedMode: Bool) {
    let effective = effectivePolicy(for: policy)
    let statements = Self.classifyUserSQL(sql, config: config)
    if case .blocked(let index, let kind, let reason) = Self.evaluate(statements, policy: effective)
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    return (statements, effective.protectedMode)
  }

  /// Dialect of the connected database. No connection keeps today's PostgreSQL rules.
  nonisolated static func dialect(of config: ConnectionConfig?) -> SQLDialect {
    config?.databaseType.dialect ?? .postgresql
  }

  /// Classify user SQL with the connection's dialect. PostgreSQL connections, and a missing
  /// config, use the PostgreSQL classifier.
  nonisolated static func classifyUserSQL(
    _ sql: String, config: ConnectionConfig?
  ) -> [ClassifiedStatement] {
    SQLStatementClassifier.classify(sql, dialect: dialect(of: config))
  }

  /// Pure policy check: the first statement the policy forbids, or `.allowed`.
  /// - `.readOnly`: only read-only-safe statements (reads, plain EXPLAIN of a known statement).
  /// - `.schemaOnly`: no DDL, non-transactional, utility, unknown or table-creating statements
  ///   (also under EXPLAIN ANALYZE); DML, SET and transaction control are allowed.
  /// - `.none`: everything (Safe Mode confirmation lives in the ViewModel).
  /// - Protected mode (any level): no transaction control and no statement that cannot run in
  ///   a transaction (the app owns the transaction).
  nonisolated static func evaluate(
    _ statements: [ClassifiedStatement], policy: ProtectionPolicy
  ) -> GateDecision {
    for (index, statement) in statements.enumerated() {
      if let reason = violation(statement, level: policy.protectionLevel)
        ?? (policy.protectedMode ? protectedModeViolation(statement) : nil)
      {
        return .blocked(statementIndex: index, kind: statement.kind, reason: reason)
      }
    }
    return .allowed
  }

  /// Pure batch gate: the first bound statement `policy` forbids, or `.allowed`.
  /// `statementIndex` is the index in `statements`, so one violation rejects the whole batch
  /// before anything is sent. An empty batch is allowed.
  nonisolated static func evaluateBatch(
    _ statements: [BoundStatement], policy: ProtectionPolicy,
    dialect: SQLDialect = .postgresql
  ) -> GateDecision {
    for (index, statement) in statements.enumerated() {
      if case .blocked(_, let kind, let reason) = evaluate(
        SQLStatementClassifier.classify(statement.sql, dialect: dialect), policy: policy)
      {
        return .blocked(statementIndex: index, kind: kind, reason: reason)
      }
    }
    return .allowed
  }

  private nonisolated static func violation(
    _ statement: ClassifiedStatement, level: ConnectionProtectionLevel
  ) -> String? {
    switch level {
    case .none:
      return nil
    case .readOnly:
      if statement.isReadOnlySafe && !statement.resetsSessionBrakes
        && !statement.changesPrivileges
      {
        return nil
      }
      return "\(describe(statement.kind)) is not allowed on a read-only connection"
    case .schemaOnly:
      let kind = SQLStatementClassifier.effectiveKind(statement.kind)
      let what: String
      if kind == .ddl {
        what = "Schema change"
      } else if kind == .utility || kind == .unknown {
        what = "\(describe(statement.kind)) (its effects cannot be verified)"
      } else if statement.nonTransactional {
        what = "Statement that cannot run in a transaction"
      } else if statement.createsTable {
        what = "SELECT ... INTO (creates a table)"
      } else {
        return nil
      }
      return "\(what) is blocked on a schema-protected connection"
    }
  }

  private nonisolated static func protectedModeViolation(
    _ statement: ClassifiedStatement
  ) -> String? {
    if statement.kind == .tcl {
      return "Transaction control is managed by Protected mode — use Commit / Rollback"
    }
    if statement.nonTransactional {
      return "This statement cannot run inside a transaction; turn Protected mode off for this "
        + "connection to run it"
    }
    return nil
  }

  nonisolated static func describe(_ kind: StatementKind) -> String {
    switch kind {
    case .read: "Read"
    case .dml: "Data modification"
    case .ddl: "Schema change"
    case .tcl: "Transaction control"
    case .sessionSet: "Session setting change (SET/RESET)"
    case .utility: "Utility command (DO, CALL, COPY, VACUUM, GRANT, ...)"
    case .explain(let inner, analyze: true):
      "EXPLAIN ANALYZE (runs the statement)"
        + (inner == .unknown ? "" : " of \(describe(inner).lowercased())")
    case .explain(let inner, analyze: false):
      inner == .unknown ? "EXPLAIN of an unrecognized statement" : "EXPLAIN (plan only)"
    case .unknown: "Unrecognized statement"
    }
  }
}
