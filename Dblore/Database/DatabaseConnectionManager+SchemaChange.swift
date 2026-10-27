// DatabaseConnectionManager+SchemaChange.swift
// Structure editor DDL through the gate: the statements the preview showed are re-classified
// and checked before anything is sent. PostgreSQL and SQLite run them as one staged batch
// (atomic; inside the app transaction under Protected mode). MySQL commits each DDL
// implicitly, so it runs them one by one, only with no transaction open.

import Foundation

/// Outcome of `executeGatedSchemaChange`.
nonisolated struct SchemaChangeResult: Sendable, Equatable {
  /// The statements sent, exactly as passed in
  let statements: [String]
  /// True when they joined the Protected mode transaction and wait for Commit / Rollback
  let pending: Bool
  /// True when the user's own transaction was open: they ran inside it behind a savepoint and
  /// only persist if it is committed (under Protected mode it was adopted: `pending` too)
  let insideUserTransaction: Bool
  let duration: TimeInterval
}

extension DatabaseConnectionManager {
  /// Apply structure editor DDL (`StructureDDLBuilder` output, unchanged from the preview).
  /// Refused before anything is sent (`DatabaseError.schemaChangeRefused`) when
  /// `connectionEpoch` is not `epoch`, a string is not exactly one DDL statement, the engine is
  /// DuckDB or MongoDB, or (MySQL) a transaction is open; `DatabaseError.blockedByProtection` when the
  /// merged policy forbids a statement (read-only, schema-only, MySQL under Protected mode).
  /// PostgreSQL / SQLite: `runStagedBatch` with no row-count check, so a failure rolls every
  /// statement back (`DatabaseError.batchStatementFailed`). MySQL: one by one; a failure of the
  /// first is thrown as is, a later one as `DatabaseError.schemaChangePartiallyApplied`. Cached
  /// edit tables are cleared afterwards.
  func executeGatedSchemaChange(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch epoch: UInt64,
    caller: UUID? = nil
  ) async throws -> SchemaChangeResult {
    try refuseIfRelocked(config)
    guard epoch == connectionEpoch else {
      throw DatabaseError.schemaChangeRefused(
        "The connection changed; reload the structure and try again")
    }
    let effective = effectivePolicy(for: policy)
    let dialect = Self.dialect(of: config)
    // Decisions are pure and finish before any await that could send SQL.
    if let reason = Self.schemaChangeRefusal(
      statements, databaseType: config?.databaseType,
      transactionOpen: !txState.isIdle || userTxOpen)
    {
      throw DatabaseError.schemaChangeRefused(reason)
    }
    let bound = statements.map { BoundStatement(sql: $0, values: [], expectedRows: nil) }
    if case .blocked(let index, let kind, let reason) = Self.evaluateBatch(
      bound, policy: effective, dialect: dialect)
    {
      throw DatabaseError.blockedByProtection(statementIndex: index, kind: kind, reason: reason)
    }
    if statements.isEmpty {
      return SchemaChangeResult(
        statements: [], pending: false, insideUserTransaction: false, duration: 0)
    }
    let insideUserTransaction = userTxOpen
    try refuseIfEnding()
    try refuseIfOwnedByAnotherCaller(caller)
    try refuseIfAborted()
    guard session != nil else { throw DatabaseError.notConnected }
    try refuseIfConnectionClosed()
    // Counted before the first suspension, so a Commit / Rollback arriving meanwhile is refused
    commitGuard.inFlight += 1
    defer { commitGuard.inFlight -= 1 }
    // Anything sent may have changed columns: inline edits must read the table again
    defer {
      editTableCache.removeAll()
      mysqlTableColumns.removeAll()
    }
    let start = Date()
    if config?.databaseType == .mysql {
      try await runMySQLSchemaChange(statements)
    } else {
      _ = try await runStagedBatch(
        bound, caller: caller, protectedMode: effective.protectedMode,
        cancellationGeneration: batchCancellationGeneration)
    }
    return SchemaChangeResult(
      statements: statements, pending: effective.protectedMode,
      insideUserTransaction: insideUserTransaction, duration: Date().timeIntervalSince(start))
  }

  /// Why the structure editor may not send `statements`, or nil. DuckDB is view-only. MongoDB
  /// is refused before any classification (an `aggregate` with `$out` classifies as DDL). MySQL
  /// DDL would commit an open transaction (the app's pending changes or the user's own). Each
  /// string must classify as exactly one DDL statement in the connection's dialect.
  nonisolated static func schemaChangeRefusal(
    _ statements: [String], databaseType: DatabaseType?, transactionOpen: Bool
  ) -> String? {
    switch databaseType {
    case .duckdb:
      return "DuckDB table structure cannot be changed in Dblore"
    case .mongodb:
      return "MongoDB collections have no table structure to change in Dblore"
    case .mysql where transactionOpen:
      return "MySQL commits a schema change immediately, together with the open transaction; "
        + "commit or roll back first"
    default:
      break
    }
    let dialect = databaseType?.dialect ?? .postgresql
    for (index, sql) in statements.enumerated() {
      let classified = SQLStatementClassifier.classify(sql, dialect: dialect)
      guard classified.count == 1, classified[0].kind == .ddl else {
        return "Change \(index + 1) is not a single schema statement"
      }
    }
    return nil
  }

  // MARK: - Private

  /// Send each statement on its own (each commits implicitly). Stops at the first failure, once
  /// the connection changed / was cancelled, or once a transaction was opened meanwhile. With
  /// nothing applied the error is thrown as is; later, it reports how many were applied.
  private func runMySQLSchemaChange(_ statements: [String]) async throws {
    let dialect = Self.dialect(of: config)
    let epoch = connectionEpoch
    let generation = batchCancellationGeneration
    for (index, sql) in statements.enumerated() {
      do {
        try refuseIfSessionChanged(
          since: epoch, generation: generation, remaining: statements.count - index)
        if index > 0, !txState.isIdle || userTxOpen {
          throw DatabaseError.schemaChangeRefused(
            "A transaction was opened meanwhile; the rest would commit it")
        }
        _ = try await affectedRows(sql: sql, binds: [])
      } catch {
        guard index > 0 else { throw error }
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        throw DatabaseError.schemaChangePartiallyApplied(
          applied: index, total: statements.count, reason: reason)
      }
      if let classified = SQLStatementClassifier.classify(sql, dialect: dialect).first {
        noteSchemaChange(classified)
        noteTemporaryTable(classified)
      }
      await batchCheckpointHook?(index)
    }
  }
}
