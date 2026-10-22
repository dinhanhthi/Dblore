//
//  NotebookViewModel+CascadePreview.swift
//  Dblore
//
//  What the staged DELETEs also change through foreign keys: the `CascadeImpactPlanner` COUNTs,
//  each checked by `ReadOnlyQueryGuard` and sent through the gate under a read-only policy
//  (`DatabaseConnectionManager.execute`), never a raw session call. The foreign keys and the
//  counts are read on a separate single-use read-only connection
//  (`makeReadOnlySideManager`, statement timeout at most the budget), never on the tab's
//  session: a failed count cannot abort the tab's transaction, and a count still running cannot
//  hold up the commit's batch. The connection is closed when the check ends, times out or is
//  cancelled. Only SQLite's `PRAGMA foreign_keys` is read on the tab's session (the setting is
//  per connection). Nothing is counted while a transaction is open on the tab (another
//  connection cannot see its uncommitted changes) or on DuckDB (no second connection to the
//  file). All of it shares one 5 s budget and stops with the caller's task (the preview sheet
//  closing). A blocker with rows holds the commit until the user picks Commit Anyway (rows a
//  cascade of the same delete deletes are not counted); rows that only may block (the delete
//  order, the batch's other edits and inserts, or a cascade the check did not follow decides),
//  a timeout, a cancel or an error never do: the server still enforces its foreign keys.
//  Temporary tables are not counted (the other connection cannot see them).
//

import Foundation

/// The counted impact of the staged deletes, grouped for the "Also affected" section.
nonisolated struct CascadeImpactSummary: Sendable, Equatable {
  /// Rows of one table deleted by cascade, set to NULL, set to their default, or that may
  /// block through foreign key `constraint` (`CascadeImpactPlanner.Effect.mayBlock`, an upper
  /// bound: its counts may share rows).
  struct Affected: Sendable, Equatable, Identifiable {
    var schema: String
    var table: String
    var effect: CascadeImpactPlanner.Effect
    var count: Int
    /// Set for `.mayBlock` only
    var constraint: String? = nil
    var id: String { "\(schema)\u{0}\(table)\u{0}\(effect)\u{0}\(constraint ?? "")" }

    var text: String {
      let rows = count == 1 ? "1 row" : "\(count.formatted()) rows"
      switch effect {
      case .deleted: return "\(table): \(rows) deleted by cascade"
      case .setNull: return "\(table): \(rows) set to NULL"
      case .setDefault: return "\(table): \(rows) set to their default"
      // `grouped` keeps `.blocking` counts in `blockers`
      case .blocking, .mayBlock:
        return
          "\(table): up to \(rows) may still block the delete through foreign key "
          + "\"\(constraint ?? "")\" (the delete order, the other staged changes or a deeper "
          + "cascade decides)"
      }
    }
  }

  /// Rows of `table` that foreign key `constraint` (RESTRICT / NO ACTION) still ties to the
  /// deleted rows: the delete fails while there are any.
  struct Blocker: Sendable, Equatable, Identifiable {
    var schema: String
    var table: String
    var constraint: String
    var count: Int
    var id: String { "\(schema)\u{0}\(table)\u{0}\(constraint)" }

    var text: String {
      let rows = count == 1 ? "1 row still refers" : "\(count.formatted()) rows still refer"
      return "Blocked by foreign key \"\(constraint)\" on \"\(table)\": \(rows) to these rows."
    }
  }

  var affected: [Affected] = []
  var blockers: [Blocker] = []
  /// "Impact not computed …" or "not enforced": shown, never blocking
  var note: String? = nil

  /// Only a counted blocker with rows holds the commit (until Commit Anyway)
  var blocksCommit: Bool { !blockers.isEmpty }

  static func notComputed(_ reason: String) -> CascadeImpactSummary {
    CascadeImpactSummary(note: "Impact not computed: \(reason) The database still checks it.")
  }

  static let notEnforced = CascadeImpactSummary(
    note: "Foreign keys are not enforced on this connection (PRAGMA foreign_keys is off).")

  /// Lines for the Safe Mode confirmation (text only)
  var lines: [String] {
    var lines = blockers.map(\.text) + affected.map(\.text)
    if lines.isEmpty, note == nil { lines.append("No related rows.") }
    if let note { lines.append(note) }
    return ["Also affected:"] + lines
  }

  /// Sums the counts per table and effect; blockers and `.mayBlock` rows keep their
  /// constraint. Zero counts drop.
  static func grouped(
    _ counts: [(step: CascadeImpactPlanner.CountStep, count: Int)]
  )
    -> CascadeImpactSummary
  {
    var summary = CascadeImpactSummary()
    for (step, count) in counts where count > 0 {
      if step.effect == .blocking {
        let blocker = Blocker(
          schema: step.schema, table: step.table, constraint: step.constraintName, count: count)
        if let index = summary.blockers.firstIndex(where: { $0.id == blocker.id }) {
          summary.blockers[index].count += count
        } else {
          summary.blockers.append(blocker)
        }
      } else {
        let affected = Affected(
          schema: step.schema, table: step.table, effect: step.effect, count: count,
          constraint: step.effect == .mayBlock ? step.constraintName : nil)
        if let index = summary.affected.firstIndex(where: { $0.id == affected.id }) {
          summary.affected[index].count += count
        } else {
          summary.affected.append(affected)
        }
      }
    }
    return summary
  }
}

extension NotebookViewModel {
  /// Total time for the connection, the foreign key lookup and every count of one check
  nonisolated static let cascadeImpactBudgetSeconds = 5
  nonisolated static let cascadeImpactBudget: Duration = .seconds(cascadeImpactBudgetSeconds)

  /// The impact of the staged deletes, nil when nothing existing is staged for deletion (or
  /// on MongoDB). Never throws: a failure is a not-computed note.
  func stagedDeleteImpact() async -> CascadeImpactSummary? {
    guard !stagesDocuments, let target = stagedEditTarget, let set = dataViewer?.changeSet
    else { return nil }
    let keys = set.deletes.filter { $0.tempID == nil }.map(\.values)
    guard !keys.isEmpty else { return nil }
    // Later statements of the batch can remove a blocker before a deferred check
    let alsoWrites = !set.edits.isEmpty || !set.inserts.isEmpty
    guard let connectionManager else { return .notComputed("Not connected.") }
    guard let table = target.name else {
      return .notComputed("The table name is not known.")
    }
    let dialect = stagingDialect
    guard dialect != .duckdb else {
      return .notComputed("Related rows are not counted on DuckDB.")
    }
    guard !Self.isTemporarySchema(target.schema, dialect: dialect) else {
      return .notComputed("Related rows are not counted for temporary tables.")
    }
    guard await connectionManager.isOutsideAnyTransaction else {
      return .notComputed("A transaction is open, and its changes are not visible to the check.")
    }
    let schema = target.schema ?? ""
    let keyColumns = target.primaryKeyColumns
    let caller = id
    let epoch = target.connectionEpoch
    let side = connectionManager.makeReadOnlySideManager()
    return await Self.cascadeImpact(stop: { await side.disconnect() }) {
      do {
        try await Self.connectSide(side, like: connectionManager)
        // A connect that finished after the budget or the cancel ends here: the catch below
        // disconnects it (`stop` may have run before it was connected)
        try Task.checkCancellation()
        let impact = CascadeImpactPlanner.impact(
          deletingFrom: schema, table: table, keyColumns: keyColumns, keys: keys,
          foreignKeys: try await side.fetchForeignKeys(), dialect: dialect,
          batchAlsoWrites: alsoWrites)
        let summary = try await Self.countCascadeImpact(
          impact, connectionManager: connectionManager, counter: side, dialect: dialect,
          caller: caller, expectedEpoch: epoch)
        await side.disconnect()
        return summary
      } catch {
        await side.disconnect()
        throw error
      }
    }
  }

  /// SQLite's `temp` schema, PostgreSQL's `pg_temp…`: only the tab's session sees their tables
  private nonisolated static func isTemporarySchema(_ schema: String?, dialect: SQLDialect) -> Bool
  {
    guard let schema else { return false }
    switch dialect {
    case .sqlite: return schema.caseInsensitiveCompare("temp") == .orderedSame
    case .postgresql: return schema.hasPrefix("pg_temp")
    default: return false
    }
  }

  /// Connects `side` like `manager` (config, unremembered certificate and SSH secret), with
  /// the statement timeout at most the budget, so the server ends a count the check gave up on.
  /// A SQLite file opens read-only: no write probe, lock or journal on the tab's file.
  nonisolated static func connectSide(
    _ side: DatabaseConnectionManager, like manager: DatabaseConnectionManager
  ) async throws {
    guard var config = await manager.config else { throw DatabaseError.notConnected }
    if config.databaseType == .sqlite { config.readOnlyFile = true }
    config.statementTimeoutSeconds = min(
      SessionBrakeLimits.clampStatementTimeout(
        config.statementTimeoutSeconds ?? cascadeImpactBudgetSeconds),
      cascadeImpactBudgetSeconds)
    do {
      try await side.reconnectWithActiveCertificate(
        config: config, material: await manager.activeUnrememberedCertificate,
        sshCredential: await manager.activeUnrememberedSSHCredential)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CascadeCheckConnectionError()
    }
  }

  /// `work` under `budget`. A timeout, the caller's cancel or a thrown error give a
  /// not-computed summary at once: the statement still running is not awaited. `stop` (closing
  /// the check's connection) then runs without being awaited, so the caller never waits on it.
  nonisolated static func cascadeImpact(
    budget: Duration = cascadeImpactBudget,
    stop: @escaping @Sendable () async -> Void = {},
    _ work: @escaping @Sendable () async throws -> CascadeImpactSummary
  ) async -> CascadeImpactSummary {
    let (results, continuation) = AsyncStream.makeStream(of: CascadeImpactSummary.self)
    let counting = Task {
      do {
        continuation.yield(try await work())
      } catch is CancellationError {
        continuation.yield(.notComputed("The check was cancelled."))
      } catch {
        continuation.yield(.notComputed(error.localizedDescription))
      }
      continuation.finish()
    }
    let timer = Task {
      try? await Task.sleep(for: budget)
      continuation.yield(.notComputed("Counting related rows took too long."))
      continuation.finish()
    }
    let first = await withTaskCancellationHandler {
      var iterator = results.makeAsyncIterator()
      return await iterator.next()
    } onCancel: {
      continuation.yield(.notComputed("The check was cancelled."))
      continuation.finish()
    }
    counting.cancel()
    timer.cancel()
    Task { await stop() }
    return first ?? .notComputed("The check was cancelled.")
  }

  /// Runs the plan's enforcement check on `connectionManager` (the tab's, for `caller` on
  /// `expectedEpoch`), then each count on `counter`, through the read path of the gate.
  nonisolated static func countCascadeImpact(
    _ impact: CascadeImpactPlanner.Impact, connectionManager: DatabaseConnectionManager,
    counter: DatabaseConnectionManager, dialect: SQLDialect, caller: UUID?,
    expectedEpoch: UInt64?
  ) async throws -> CascadeImpactSummary {
    let plan: CascadeImpactPlanner.Plan
    switch impact {
    case .notComputed(let reason): return .notComputed(reason)
    case .notEnforced: return .notEnforced
    case .plan(let planned): plan = planned
    }
    let read = {
      (
        manager: DatabaseConnectionManager, sql: String, parameters: [String: SQLBindValue]?
      )
        async throws -> Int? in
      _ = try ReadOnlyQueryGuard.check(sql, dialect: dialect)
      let tab = manager === connectionManager
      let result = try await manager.execute(
        userSQL: sql, parameters: parameters, policy: ProtectionPolicy(protectionLevel: .readOnly),
        caller: tab ? caller : nil, expectedEpoch: tab ? expectedEpoch : nil)
      return firstInteger(result)
    }
    if let check = plan.enforcementCheck, try await read(connectionManager, check, nil) == 0 {
      return .notEnforced
    }
    var counts: [(step: CascadeImpactPlanner.CountStep, count: Int)] = []
    for step in plan.steps {
      try Task.checkCancellation()
      guard let count = try await read(counter, step.sql, step.parameters) else {
        return .notComputed("A count returned no number.")
      }
      counts.append((step, count))
    }
    return .grouped(counts)
  }

  /// The check's own connection failed (its text may name the host or file: not shown)
  private nonisolated struct CascadeCheckConnectionError: LocalizedError {
    var errorDescription: String? { "The check's read-only connection could not be opened." }
  }

  private nonisolated static func firstInteger(_ result: QueryResult) -> Int? {
    switch result.rows.first?.first {
    case .int(let value): value
    case .string(let text): Int(text)
    case .double(let value): Int(exactly: value)
    case .bool(let flag): flag ? 1 : 0
    default: nil
    }
  }
}

extension DatabaseConnectionManager {
  /// No app transaction (pending or owned) and no user-opened one, read in one hop
  var isOutsideAnyTransaction: Bool { txState.isIdle && txOwner == nil && !userTxOpen }
}
