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

/// The INSERTs of a Generate Rows, Copy Objects or streamed import run, made one chunk at a time
/// inside the run's transaction (`executeGatedBatch(streamed:)`), so the whole run is never in
/// memory.
nonisolated struct StreamedBatch: Sendable {
  /// The quoted table the rows go into: the run's one pending summary names it
  let relation: String
  /// The next chunk's INSERT statements (each with its `expectedRows`); nil once the run is done
  let nextChunk: @Sendable () async throws -> [BoundStatement]?
  /// What the run does, as the read-only refusal names it
  var operation = "Generating rows"
  /// The rows, as the pending summary names them ("INSERT INTO <relation>: N <rowsLabel>")
  var rowsLabel = "generated rows"
  /// Sent before the first chunk, ahead of the caller's `prelude` (an import's CREATE TABLE)
  var prelude: [BoundStatement] = []
  /// A table import: the engine's data-import rule applies instead of the row-edit one (DuckDB
  /// imports outside Protected mode and any open transaction)
  var isDataImport = false
  /// The file rows of the run's row statement N (from 0, the prelude not counted), which its
  /// failure names; nil when unknown
  var rowRange: (@Sendable (Int) async -> ClosedRange<Int>?)? = nil
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
  /// `deferEnrichment` (the app's grid only): PostgreSQL column types are returned as the driver
  /// reported them, outside any transaction, marked `typesDeferred` for the caller to enrich
  /// after showing the rows. The default awaits the enrichment (MCP, CLI, internal reads).
  /// `readLimits`: what each read keeps per cell and in total (`CappedReadLimits.app` for the
  /// app's editor and notebook results); nil keeps whole values. A manager with limits of its
  /// own (MCP) keeps them.
  func execute(
    userSQL: String, parameters: [String: SQLBindValue]? = nil, policy: ProtectionPolicy,
    maxRows: Int = defaultMaxFetchRows, caller: UUID? = nil, expectedEpoch: UInt64? = nil,
    deferEnrichment: Bool = false, readLimits: CappedReadLimits? = nil
  ) async throws -> QueryResult {
    let run = try await runUserSQL(
      userSQL, parameters: parameters, policy: policy, maxRows: maxRows, caller: caller,
      expectedEpoch: expectedEpoch, deferEnrichment: deferEnrichment, readLimits: readLimits)
    return Self.combined(run.results.map(\.result), totalTime: run.totalTime)
  }

  /// Execute user SQL and return one result per statement.
  /// Throws `DatabaseError.blockedByProtection` before anything is sent if ANY statement
  /// violates `policy`. Under Protected mode, writes run in the app transaction (same `caller`
  /// rule as `execute`, same `expectedEpoch` check). `parameters` nil sends `userSQL`
  /// unchanged; a dictionary rewrites `:name` the same way `execute` does. Same
  /// `deferEnrichment` and `readLimits` as `execute`.
  func executeDetailed(
    userSQL: String, parameters: [String: SQLBindValue]? = nil, policy: ProtectionPolicy,
    maxRows: Int = defaultMaxFetchRows, caller: UUID? = nil, expectedEpoch: UInt64? = nil,
    deferEnrichment: Bool = false, readLimits: CappedReadLimits? = nil
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    try await runUserSQL(
      userSQL, parameters: parameters, policy: policy, maxRows: maxRows, caller: caller,
      expectedEpoch: expectedEpoch, deferEnrichment: deferEnrichment, readLimits: readLimits)
  }

  /// `parameters` nil keeps the authorize path. A dictionary rewrites first, then uses the
  /// same effective policy; missing names are refused only after that policy allows the script.
  /// The results leave with the connection's mask rules applied (`applyingMaskRules`).
  private func runUserSQL(
    _ userSQL: String, parameters: [String: SQLBindValue]?, policy: ProtectionPolicy,
    maxRows: Int, caller: UUID?, expectedEpoch: UInt64?, deferEnrichment: Bool,
    readLimits: CappedReadLimits?
  ) async throws -> (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval) {
    try refuseIfRelocked(config)
    // The config the statements run with: a disconnect meanwhile never drops its rules
    let ruleConfig = config
    let run: (results: [(queryText: String, result: QueryResult)], totalTime: TimeInterval)
    if let parameters {
      let plan = try planNamedParameters(userSQL, parameters: parameters, policy: policy)
      run = try await runUserStatements(
        plan.statements, protectedMode: plan.protectedMode, maxRows: maxRows, caller: caller,
        expectedEpoch: expectedEpoch, binds: plan.binds, originalTexts: plan.originalTexts,
        deferEnrichment: deferEnrichment, readLimits: readLimits)
    } else {
      let (statements, protectedMode) = try authorize(userSQL, policy: policy)
      run = try await runUserStatements(
        statements, protectedMode: protectedMode, maxRows: maxRows, caller: caller,
        expectedEpoch: expectedEpoch, deferEnrichment: deferEnrichment, readLimits: readLimits)
    }
    guard let ruleConfig else { return run }
    return (await applyingMaskRules(run.results, config: ruleConfig), run.totalTime)
  }

  // MARK: - Mask rules

  /// The mask rules results get now: the config's and its saved row's (`applyingMaskRules`).
  /// For displays outside `runUserSQL`, such as the Data Rewind preview.
  func currentMaskRules() -> [ColumnMaskRule] {
    guard let config else { return [] }
    return ColumnMaskRule.union(config.maskRules, savedMaskRules(config))
  }

  /// `results` with the mask rules of `config` applied: its own and its saved row's
  /// (`SavedMaskRules`, read now, so a rule saved in another window applies at once). A column
  /// a rule matches is `masked` and its cells hold the rule's mask; no rule, no work. The app's
  /// own reads (`executeInternal`, catalog reads, the Data Rewind capture) never come here.
  private func applyingMaskRules(
    _ results: [(queryText: String, result: QueryResult)], config: ConnectionConfig
  ) async -> [(queryText: String, result: QueryResult)] {
    let rules = ColumnMaskRule.union(config.maskRules, savedMaskRules(config))
    guard !rules.isEmpty else { return results }
    let ruleSet = ColumnMaskRuleSet(rules)
    var masked = results
    for index in masked.indices {
      masked[index].result = await applying(
        ruleSet, to: masked[index].result, databaseType: config.databaseType)
    }
    return masked
  }

  /// The mask rules results get now (`currentMaskRules`) resolved for `columns` as a result's
  /// are (`applying`): same origin reads, nil origins fail closed. For a streamed read of the
  /// same columns, such as the all-rows export: the origins are read now (the export refuses a
  /// tab that is not idle, so no read is draining). No config (disconnected): no rules, an empty
  /// plan, as `runUserSQL` applies none then.
  func maskPlan(for columns: [ColumnInfo]) async -> ColumnMaskPlan {
    guard let config else { return ColumnMaskPlan(matches: columns.map { _ in nil }) }
    return await maskPlan(
      ColumnMaskRuleSet(currentMaskRules()), for: columns, databaseType: config.databaseType,
      mayRead: true)
  }

  /// `rules` matched once per column. Without an origin a rule matches the most columns, so
  /// only the columns that match then need theirs (`maskOrigins`), and only when a rule that
  /// names a table or schema names one of them. `mayRead` false: no catalog read, the origins
  /// are nil (fail closed), or the memo's while metadata is paused (`maskOrigins`).
  private func maskPlan(
    _ rules: ColumnMaskRuleSet, for columns: [ColumnInfo], databaseType: DatabaseType,
    mayRead: Bool
  ) async -> ColumnMaskPlan {
    var matches = columns.map { rules.matchingRule(column: $0.name, origin: nil) }
    let candidates = matches.indices.filter { matches[$0] != nil }
    if !candidates.isEmpty, rules.needsOrigin(forColumns: candidates.map { columns[$0].name }) {
      let origins = await maskOrigins(
        candidates.map { columns[$0] }, databaseType: databaseType, mayRead: mayRead)
      for (index, origin) in zip(candidates, origins) {
        matches[index] = rules.matchingRule(column: columns[index].name, origin: origin)
      }
    }
    return ColumnMaskPlan(matches: matches)
  }

  /// `result` with `rules` applied (`maskPlan`). A PostgreSQL read cut by the row cap and not
  /// reset is still draining: no catalog read for its origins (`mayRead` false).
  private func applying(
    _ rules: ColumnMaskRuleSet, to result: QueryResult, databaseType: DatabaseType
  ) async -> QueryResult {
    let mayRead = databaseType != .postgresql || !result.truncated || result.sessionReset
    let plan = await maskPlan(
      rules, for: result.columns, databaseType: databaseType, mayRead: mayRead)
    return Self.masking(result, with: plan, cutAfter: readLimits?.maxCellCharacters)
  }

  /// `result` with each column of `plan.maskedColumns` marked `masked` and its cells masked.
  /// `cutAfter`: the capped read's cell limit (MCP managers); a cell in `result.cutCells` is
  /// cut too. A masked cell shows only mask text, so it leaves `cutCells`.
  private nonisolated static func masking(
    _ result: QueryResult, with plan: ColumnMaskPlan, cutAfter limit: Int?
  ) -> QueryResult {
    let maskedColumns = Set(plan.maskedColumns)
    guard !maskedColumns.isEmpty else { return result }
    let columns = result.columns.enumerated().map { index, column in
      maskedColumns.contains(index)
        ? ColumnInfo(
          name: column.name, type: column.type, origin: column.origin,
          sourceName: column.sourceName, wallClock: column.wallClock, masked: true)
        : column
    }
    let rows = result.rows.enumerated().map { rowIndex, row in
      plan.mask(row, cutAfter: limit) {
        result.cutCells.contains(CellPosition(row: rowIndex, column: $0))
      }
    }
    var masked = QueryResult(
      columns: columns, rows: rows, rowCount: result.rowCount,
      executionTime: result.executionTime, wasLimited: result.wasLimited,
      affectedRows: result.affectedRows)
    masked.truncated = result.truncated
    masked.sessionReset = result.sessionReset
    masked.skippedStatements = result.skippedStatements
    masked.typesDeferred = result.typesDeferred
    masked.cutCells = result.cutCells.filter { !maskedColumns.contains($0.column) }
    masked.stoppedAtByteBudget = result.stoppedAtByteBudget
    return masked
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
    if case .blocked(let index, let kind, let reason) = Self.evaluate(
      statements, policy: effective, dialect: dialect)
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
  /// Any other row count throws `DatabaseError.editRowCountMismatch`. `rewind` (one step)
  /// reads the row for Data Rewind around the UPDATE; nil sends the same statements as before.
  func executeGatedUpdate(
    _ statement: CellUpdateStatement, policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, commitImmediately: Bool = false, rewind: RewindPlan? = nil
  )
    async throws -> Int
  {
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    try refuseIfRowEditsUnsupported()
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
      return try await runProtectedEdit(
        statement, classified: statements.first, caller: caller, rewind: rewind)
    }
    return try await runUnprotectedEdit(statement, rewind: rewind)
  }

  /// Send a staged batch (app-built DELETE / UPDATE / INSERT, values as bind parameters).
  /// Every statement is classified and checked against the same merged policy as `authorize`
  /// before anything is sent: the first violation throws `DatabaseError.blockedByProtection`
  /// and the batch is not sent. An empty batch returns `[]`. `connectionEpoch` must still be
  /// `epoch` (`DatabaseError.notEditable` otherwise). Each statement must affect exactly one
  /// row. Returns those counts (all 1s). Under Protected mode the batch joins the app
  /// transaction (`runStagedBatch`); otherwise it commits on its own or runs in the user's
  /// open transaction. `rewind` (one step per statement) reads each row for Data Rewind around
  /// its statement; nil sends the same statements as before. `rewinding`: the Data Rewind entries
  /// this batch undoes (a rewind's own batch), marked rewound once it is committed (D5).
  /// `isDataImport` (a table import): the engine must support data import rather than row
  /// edits, and on DuckDB, which has no savepoint, Protected mode or an open transaction is
  /// refused (`DatabaseError.sequentialBatchRefused`) before anything is sent.
  func executeGatedBatch(
    _ statements: [BoundStatement], policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, rewind: RewindPlan? = nil, rewinding: [Int64] = [],
    isDataImport: Bool = false
  ) async throws -> [Int] {
    try refuseIfRelocked(config)
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    try refuseIfRowEditsUnsupported(isDataImport: isDataImport)
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
    if isDataImport, let reason = duckDBImportRefusalReason(policy: policy) {
      throw DatabaseError.sequentialBatchRefused(reason)
    }
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    let cancellationGeneration = batchCancellationGeneration
    return try await runStagedBatch(
      statements, caller: caller, protectedMode: effective.protectedMode,
      cancellationGeneration: cancellationGeneration, rewind: rewind, rewinding: rewinding)
  }

  /// Send a streamed batch (Generate Rows, Copy Objects) in one transaction, under the same
  /// rules as the staged batch above. A run always writes, so a read-only connection is refused
  /// before any chunk is made; every other check runs before anything is sent, and each chunk is
  /// classified and checked against the policy as it is made (it must be DML), before it is
  /// sent. `prelude` runs before the first chunk and `postlude` after the last, in the same
  /// transaction: each must be one statement, and all are classified and checked against the
  /// policy before anything is sent (`statementIndex` counts the prelude, then the postlude). On
  /// MySQL / MariaDB a schema change or other implicit-commit statement there is refused: it
  /// would commit the run halfway. `progress` gets the number of chunks done after each one. A
  /// cancel, a chunk the source fails to make, a statement the server refuses, or a relock rolls
  /// back the whole run, prelude and postlude included. `source.prelude` runs first;
  /// `source.isDataImport` takes the staged import's engine rules (DuckDB refused in Protected
  /// mode or with a transaction open), and a failed row statement names `source.rowRange`.
  /// - Returns: the rows inserted.
  func executeGatedBatch(
    streamed source: StreamedBatch, policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil, prelude: [BoundStatement] = [], postlude: [BoundStatement] = [],
    progress: (@Sendable (Int) -> Void)? = nil
  ) async throws -> Int {
    try refuseIfRelocked(config)
    guard epoch == connectionEpoch else {
      throw DatabaseError.notEditable("the connection changed; run the query again to edit")
    }
    try refuseIfRowEditsUnsupported(isDataImport: source.isDataImport)
    let prelude = source.prelude + prelude
    let effective = effectivePolicy(for: policy)
    if effective.protectionLevel == .readOnly {
      throw DatabaseError.blockedByProtection(
        statementIndex: 0, kind: .dml,
        reason: "\(source.operation) is not allowed on a read-only connection")
    }
    try Self.refuseFraming(prelude + postlude, policy: effective, dialect: Self.dialect(of: config))
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    if source.isDataImport, let reason = duckDBImportRefusalReason(policy: policy) {
      throw DatabaseError.sequentialBatchRefused(reason)
    }
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    let cancellationGeneration = batchCancellationGeneration
    do {
      return try await runStreamedBatch(
        source, caller: caller, policy: effective, cancellationGeneration: cancellationGeneration,
        prelude: prelude, postlude: postlude, progress: progress)
    } catch {
      throw await Self.namingRows(error, source: source, preludeCount: prelude.count)
    }
  }

  /// A failed row statement of `source` with the file rows it sent ("Rows 3–7: ..."), as a
  /// staged import names them; any other error as is
  private nonisolated static func namingRows(
    _ error: any Error, source: StreamedBatch, preludeCount: Int
  ) async -> any Error {
    guard let rowRange = source.rowRange,
      case DatabaseError.batchStatementFailed(let index, let sql, let reason, let rolledBack) =
        error,
      index >= preludeCount, let range = await rowRange(index - preludeCount)
    else { return error }
    return DatabaseError.batchStatementFailed(
      index: index, sqlPrefix: sql,
      reason: "Rows \(range.lowerBound)–\(range.upperBound): \(reason)", rolledBack: rolledBack)
  }

  /// The streamed batch's prelude and postlude: one statement each that `policy` allows and,
  /// on MySQL / MariaDB, that does not commit implicitly (DDL included)
  private nonisolated static func refuseFraming(
    _ statements: [BoundStatement], policy: ProtectionPolicy, dialect: SQLDialect
  ) throws {
    for (index, statement) in statements.enumerated() {
      let classified = SQLStatementClassifier.classify(statement.sql, dialect: dialect)
      guard classified.count == 1 else {
        throw DatabaseError.blockedByProtection(
          statementIndex: index, kind: classified.first?.kind ?? .unknown,
          reason: "Each statement before or after the rows must be sent alone")
      }
      let kind = classified[0].kind
      if dialect == .mysql,
        SQLStatementClassifier.effectiveKind(kind) == .ddl || classified[0].nonTransactional
      {
        throw DatabaseError.blockedByProtection(
          statementIndex: index, kind: kind,
          reason: "This statement commits implicitly on MySQL, which would end the run's "
            + "transaction; run schema changes one by one instead")
      }
      if case .blocked(_, let kind, let reason) = evaluate(
        classified, policy: policy, dialect: dialect)
      {
        throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
      }
    }
  }

  /// Why a DuckDB import is refused under Protected mode
  static let duckDBImportProtectedModeRefusal =
    "Turn Protected mode off for this connection to import into DuckDB: DuckDB has no "
    + "savepoint, so the import cannot wait for Commit inside the pending transaction."
  /// Why a DuckDB import is refused while a transaction is open
  static let duckDBImportTransactionOpenRefusal =
    "Commit or roll back the open transaction first, then import: DuckDB has no savepoint, "
    + "so a failed import could not be undone inside it."

  /// Throws `DatabaseError.notEditable` when the connected engine has no grid edits
  /// (`supportsRowStaging` false: DuckDB, MongoDB), or for `isDataImport` no data import
  /// (`supportsDataImport` false: MongoDB), before anything is sent or the owner is claimed.
  /// The UI already refuses them; this keeps the SQL edit paths off such a session.
  private func refuseIfRowEditsUnsupported(isDataImport: Bool = false) throws {
    guard let type = config?.databaseType else { return }
    let capabilities = type.capabilities
    if isDataImport {
      guard !capabilities.supportsDataImport else { return }
      throw DatabaseError.notEditable(
        "data import is not available for \(type.rawValue) connections")
    }
    guard !capabilities.supportsRowStaging else { return }
    throw DatabaseError.notEditable(
      "row edits are not available for \(type.rawValue) connections")
  }

  /// Why a data import with `policy` is refused on DuckDB, nil when it may run (or on another
  /// engine). DuckDB has no SAVEPOINT, which the batch sends inside a transaction (Protected
  /// mode, or the user's own). The import sheet asks before Safe Mode confirms; the gate asks
  /// again before anything is sent.
  func duckDBImportRefusalReason(policy: ProtectionPolicy) -> String? {
    guard config?.databaseType == .duckdb else { return nil }
    if effectivePolicy(for: policy).protectedMode { return Self.duckDBImportProtectedModeRefusal }
    if !txState.isIdle || userTxOpen { return Self.duckDBImportTransactionOpenRefusal }
    return nil
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
    combined.cutCells = last.cutCells
    combined.stoppedAtByteBudget = last.stoppedAtByteBudget
    combined.sessionReset = last.sessionReset
    combined.skippedStatements = last.skippedStatements
    return combined
  }

  // MARK: - Gate

  /// The stricter of `policy` and the connected config. A pending app transaction keeps
  /// Protected mode rules until Commit / Rollback, even if the toggle was turned off.
  func effectivePolicy(for policy: ProtectionPolicy) -> ProtectionPolicy {
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
  func authorize(
    _ sql: String, policy: ProtectionPolicy
  ) throws -> (statements: [ClassifiedStatement], protectedMode: Bool) {
    try refuseIfRelocked(config)
    let effective = effectivePolicy(for: policy)
    let statements = Self.classifyUserSQL(sql, config: config)
    if case .blocked(let index, let kind, let reason) = Self.evaluate(
      statements, policy: effective, dialect: Self.dialect(of: config))
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    return (statements, effective.protectedMode)
  }

  /// Throws `DatabaseError.connectionLocked` when `config`'s identity is locked and not
  /// unlocked in this session (after a relock), before anything is sent. Checked by every
  /// user-initiated entry, every read that returns rows or documents (export and backup
  /// streams, the SQL dump snapshot, the Schema tab's sample) and Commit; only catalog and
  /// introspection refreshes and this manager's internal resets are not checked. A SQLite
  /// connection is refused too while any file it attached (configured, or by a typed ATTACH) is
  /// refused (`SQLiteFileAccess.refusesAttaching`), until a reconnect leaves that file out.
  func refuseIfRelocked(_ config: ConnectionConfig?) throws {
    guard let config else { return }
    if let refusal = lockSource.refusal(for: config) { throw refusal }
    guard config.databaseType == .sqlite else { return }
    let attached = Set(config.attachedDatabases.map(\.path))
      .union((session as? SQLiteSession)?.attachedFiles ?? [])
    if attached.contains(where: {
      SQLiteFileAccess.refusesAttaching($0, lockSource: lockSource, servesMCP: servesMCP)
    }) {
      throw DatabaseError.connectionLocked
    }
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
  ///   a transaction (the app owns the transaction); `dialect` picks the MySQL wording for an
  ///   implicit commit, and refuses every MongoDB write (no transactions).
  /// `statements` may be lazy (a file-backed restore plan's, built one at a time).
  nonisolated static func evaluate(
    _ statements: some Sequence<ClassifiedStatement>, policy: ProtectionPolicy,
    dialect: SQLDialect = .postgresql
  ) -> GateDecision {
    for (index, statement) in statements.enumerated() {
      if let reason = violation(statement, level: policy.protectionLevel)
        ?? (policy.protectedMode ? protectedModeViolation(statement, dialect: dialect) : nil)
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
        SQLStatementClassifier.classify(statement.sql, dialect: dialect), policy: policy,
        dialect: dialect)
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
      if statement.isReadOnlySafe && statement.resetsSessionBrakes
        && !statement.changesPrivileges
      {
        return "This statement lifts a session safety limit (a timeout or read-only setting, "
          + "for example through an optimizer hint), which is not allowed on a read-only "
          + "connection"
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
    _ statement: ClassifiedStatement, dialect: SQLDialect
  ) -> String? {
    // Backstop: Protected mode should never reach a MongoDB write (it has no transactions).
    if dialect == .mongodb, !statement.isReadOnlySafe {
      return "MongoDB has no transactions, so Protected mode cannot hold this change. Use Confirm."
    }
    if statement.kind == .tcl {
      return "Transaction control is managed by Protected mode — use Commit / Rollback"
    }
    if statement.nonTransactional, dialect == .mysql {
      return "This statement commits implicitly on MySQL, which would end the Protected mode "
        + "transaction; turn Protected mode off for this connection to run it"
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

/// The mask rules of one result's columns, resolved once (`maskPlan(for:)`): the grid's results
/// (`applying`) and a streamed export of the same columns mask each row with it, so they agree.
nonisolated struct ColumnMaskPlan: Sendable {
  /// Per column, in order: the rule that masks it, nil when none does
  let matches: [ColumnMaskRule?]

  /// The columns a rule masks: the result's `ColumnInfo.masked` ones, which an export redacts
  /// (`ExportOptions.redactingMasked`)
  var maskedColumns: [Int] { matches.indices.filter { matches[$0] != nil } }

  /// `row` with its masked columns' cells masked. For whole values: nothing is cut.
  func mask(_ row: [CellValue]) -> [CellValue] {
    mask(row, cutAfter: nil) { _ in false }
  }

  /// `row` with its masked columns' cells masked; `isCut(column)`: a capped read cut that cell,
  /// `cutAfter` its cell limit (MCP managers)
  func mask(_ row: [CellValue], cutAfter limit: Int?, isCut: (Int) -> Bool) -> [CellValue] {
    var row = row
    for (index, rule) in matches.enumerated() where row.indices.contains(index) {
      guard let rule else { continue }
      row[index] = Self.maskedCell(
        row[index], style: rule.style, cutAfter: limit, isCut: isCut(index))
    }
    return row
  }

  /// `cell` as `style` shows it. A cell a capped read cut (`isCut`, or text longer than `limit`:
  /// it keeps one character past) shows the full mask: a partial style would show part of a
  /// prefix.
  private static func maskedCell(
    _ cell: CellValue, style: ColumnMaskRule.Style, cutAfter limit: Int?, isCut: Bool
  ) -> CellValue {
    guard style == .lastFour || style == .email else { return style.masked(cell) }
    if isCut { return ColumnMaskRule.Style.full.masked(cell) }
    guard let limit else { return style.masked(cell) }
    let text: String
    switch cell {
    case .string(let value), .json(let value), .decimal(let value): text = value
    default: return style.masked(cell)
    }
    return text.count > limit ? ColumnMaskRule.Style.full.masked(cell) : style.masked(cell)
  }
}
