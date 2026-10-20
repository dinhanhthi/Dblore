// DatabaseConnectionManager+Rewind.swift
// Data Rewind capture in the gated edit paths. With a `RewindPlan`, the row a keyed statement
// writes is read in text form (`RewindCaptureSQL`) inside the same transaction, right before
// the statement (UPDATE, DELETE) and right after it (UPDATE, INSERT). Each read runs in its own
// app savepoint, rolled back when it fails (PostgreSQL would abort the transaction otherwise),
// so a failed read only marks the entry "not captured" and the edit goes on. When that rollback
// fails too the transaction is gone (MySQL rolls it back whole on a deadlock): the read throws
// and the edit takes the same undo path as a failing statement. The reads are
// app-built SELECTs (identifiers quoted, values bound), sent like the MySQL row check: the gate
// already checked the edit statements. The entry is written after RELEASE / COMMIT: committed
// after the app's own COMMIT, else pending until the transaction ends (`closeRewindEntries`).

import Foundation

/// What a data viewer edit asks the gated paths to read, built by the caller. Images hold the
/// plan's columns: a data viewer reads every column of its table.
nonisolated struct RewindPlan: Sendable, Equatable {
  /// One statement of the edit, in statement order.
  nonisolated struct Step: Sendable, Equatable {
    var operation: RewindRow.Operation
    /// Key of the row before the write (`target.primaryKeyColumns` order); nil for an INSERT
    var keyBefore: [CellValue]?
    /// Key of the row after the write; nil for a DELETE and for an INSERT without its whole key
    var keyAfter: [CellValue]?
  }

  var target: EditTarget
  var columns: [RewindColumn]
  var editKind: RewindEntry.EditKind
  var steps: [Step]

  /// Why an entry with an INSERT whose key the database fills cannot be rewound (D4)
  static let generatedKeyReason = "generated key"

  var notRewindableReason: String? {
    steps.contains { $0.operation == .insert && $0.keyAfter == nil }
      ? Self.generatedKeyReason : nil
  }

  /// The plan for `steps` on `target`, or nil: recording is off, the engine has no Data Rewind,
  /// the target has no key or table name, or there is nothing to read.
  static func make(
    target: EditTarget, resultColumns: [ColumnInfo], editKind: RewindEntry.EditKind,
    steps: [Step], engine: DatabaseType?, enabled: Bool
  ) -> RewindPlan? {
    guard enabled, let engine else { return nil }
    switch engine {
    case .postgresql, .mysql, .sqlite: break
    case .duckdb, .mongodb: return nil
    }
    guard !target.primaryKeyColumns.isEmpty, target.name != nil, !steps.isEmpty else {
      return nil
    }
    var seen: Set<String> = []
    let columns = resultColumns.compactMap { column in
      seen.insert(column.name).inserted
        ? RewindColumn(name: column.name, typeName: column.type) : nil
    }
    guard target.primaryKeyColumns.allSatisfy(seen.contains) else { return nil }
    return RewindPlan(target: target, columns: columns, editKind: editKind, steps: steps)
  }

  /// The step of an inline UPDATE setting `assignments` on the row `rowData`. A key column it
  /// sets is read back by its new value, bound as the UPDATE bound it. Nil without the key.
  static func inlineStep(
    assignments: [(column: String, value: String?)], primaryKeyColumns: [String],
    rowData: [String: CellValue]
  ) -> Step? {
    let before = primaryKeyColumns.compactMap { rowData[$0] }
    guard !before.isEmpty, before.count == primaryKeyColumns.count else { return nil }
    let after = primaryKeyColumns.compactMap { column -> CellValue? in
      guard let assignment = assignments.first(where: { $0.column == column }) else {
        return rowData[column]
      }
      return assignment.value.map(CellValue.string)
    }
    return Step(
      operation: .update, keyBefore: before,
      keyAfter: after.count == primaryKeyColumns.count ? after : nil)
  }
}

/// The rows read so far for one edit with a plan.
nonisolated struct RewindCapture: Sendable {
  let plan: RewindPlan
  let engine: DatabaseType
  let connectionKey: String
  /// Connection the edit runs on: an open entry of a forgotten session is not recorded
  let epoch: UInt64
  var rows: [RewindRow] = []
  var notCaptured = false
  /// A read lost the transaction (`readImage` threw): the server rolled it back whole
  var transactionLost = false
}

extension DatabaseConnectionManager {
  /// App-owned savepoint around one capture read
  static let captureSavepoint = "dblore_capture"

  func setRewindRecorder(_ recorder: RewindRecorder?) {
    rewindRecorder = recorder
  }

  /// The capture of `plan` over `statementCount` statements, or nil (nothing is read): no plan,
  /// nothing records, a step count that does not match, an engine without Data Rewind, or a
  /// target of another connection or with a name the server did not format.
  func startRewindCapture(_ plan: RewindPlan?, statementCount: Int) -> RewindCapture? {
    guard let plan, let config, plan.steps.count == statementCount,
      plan.target.connectionEpoch == connectionEpoch,
      CellUpdateStatement.isServerQualifiedName(
        plan.target.qualifiedName, dialect: config.databaseType.dialect)
    else { return nil }
    switch config.databaseType {
    case .postgresql, .mysql, .sqlite: break
    case .duckdb, .mongodb: return nil
    }
    guard activeRewindRecorder() != nil else { return nil }
    return RewindCapture(
      plan: plan, engine: config.databaseType,
      connectionKey: RewindEntry.connectionKey(for: config), epoch: connectionEpoch)
  }

  /// Reads the row of step `index` before its statement runs (UPDATE, DELETE).
  /// - Throws: the read's error when the transaction is gone (see `readImage`).
  func captureBefore(_ index: Int, into capture: inout RewindCapture?) async throws {
    guard let current = capture, current.plan.steps.indices.contains(index) else { return }
    let step = current.plan.steps[index]
    var row = RewindRow(operation: step.operation, primaryKey: [:], before: nil, after: nil)
    if let key = step.keyBefore {
      row.before = try await read(key: key, capture: &capture)
      if row.before == nil { capture?.notCaptured = true }
    }
    capture?.rows.append(row)
  }

  /// Reads the row of step `index` again after its statement ran (UPDATE, INSERT), and keys
  /// the row by what the server stored (the row before it, for a DELETE).
  /// - Throws: the read's error when the transaction is gone (see `readImage`).
  func captureAfter(_ index: Int, into capture: inout RewindCapture?) async throws {
    guard let current = capture, current.rows.indices.contains(index) else { return }
    let step = current.plan.steps[index]
    var row = current.rows[index]
    if let key = step.keyAfter {
      row.after = try await read(key: key, capture: &capture)
      if row.after == nil { capture?.notCaptured = true }
    }
    let keys = Set(current.plan.target.primaryKeyColumns)
    if let image = row.after ?? row.before {
      row.primaryKey = image.filter { keys.contains($0.key) }
    }
    capture?.rows[index] = row
  }

  /// Writes the entry after RELEASE / COMMIT. `committed`: the app's own COMMIT returned.
  /// Otherwise it stays pending until the transaction ends. Dropped when the connection changed
  /// meanwhile, committed or not: the server rolled it back with the session (a COMMIT on a
  /// new PostgreSQL session still answers with a COMMIT tag).
  func recordRewind(_ capture: RewindCapture?, committed: Bool) {
    guard let capture, let recorder = rewindRecorder, capture.epoch == connectionEpoch else {
      return
    }
    let plan = capture.plan
    let entry = RewindEntry(
      id: 0, connectionKey: capture.connectionKey, schema: plan.target.schema,
      table: plan.target.name ?? "", qualifiedName: plan.target.qualifiedName,
      engine: capture.engine, created: Date(), state: committed ? .committed : .pending,
      editKind: plan.editKind, statementCount: plan.steps.count, columns: plan.columns,
      notCaptured: capture.notCaptured, notRewindableReason: plan.notRewindableReason)
    recorder.record(entry, rows: capture.rows, scope: committed ? nil : rewindScope)
  }

  /// The transaction holding this connection's pending entries ended: `state` committed or
  /// discarded; nil leaves them pending, unconfirmed (lost during Commit). Entries a rewind
  /// undid in it become rewound only when it committed.
  func closeRewindEntries(as state: RewindEntry.State?) {
    rewindRecorder?.close(scope: rewindScope, as: state)
  }

  /// A rewind's own batch went through (RELEASE / COMMIT): `ids` are rewound now after the
  /// app's own COMMIT, else when the transaction it joined commits (`closeRewindEntries`).
  func recordRewound(_ ids: [Int64], committed: Bool) {
    guard !ids.isEmpty else { return }
    activeRewindRecorder()?.markRewound(ids, scope: committed ? nil : rewindScope)
  }

  /// The recorder the Data Rewind sheet reads, or nil when the store cannot be opened
  func dataRewindRecorder() -> RewindRecorder? {
    activeRewindRecorder()
  }

  /// `rewindRecorder`, taking `RewindRecorder.shared` on first use (never under the test host;
  /// `connect` already opened it off the actor).
  private func activeRewindRecorder() -> RewindRecorder? {
    if rewindRecorder == nil, !SessionManager.isRunningAsTestHost {
      rewindRecorder = RewindRecorder.shared
    }
    return rewindRecorder
  }

  /// `readImage`, marking `capture.transactionLost` when it throws.
  private func read(key: [CellValue], capture: inout RewindCapture?) async throws -> RewindImage? {
    guard let current = capture else { return nil }
    do {
      return try await readImage(key: key, capture: current)
    } catch {
      capture?.transactionLost = true
      throw error
    }
  }

  /// One capture read inside `SAVEPOINT dblore_capture`. Nil when the connection changed since
  /// the capture started (nothing is read), or when the read fails, finds no row or more than
  /// one, or returns a value not in the capture's form; the savepoint is then rolled back, so
  /// the transaction goes on as before the read.
  /// - Throws: `DatabaseError.transactionAborted` when that rollback fails: the savepoint went
  ///   with the transaction, so the edit must not be sent (it would run outside it), and the
  ///   read's own error ("no such row", ...) would hide why.
  private func readImage(key: [CellValue], capture: RewindCapture) async throws -> RewindImage? {
    let plan = capture.plan
    guard capture.epoch == connectionEpoch,
      let statement = try? RewindCaptureSQL.selectStatement(
        target: plan.target, columns: plan.columns, keyValues: key, engine: capture.engine)
    else { return nil }
    do {
      _ = try await sendTransactionControl("SAVEPOINT \(Self.captureSavepoint)")
    } catch {
      return nil
    }
    do {
      let rows = try await withSession { session in
        var rows: [[CellValue]] = []
        for try await row in try await session.query(statement.sql, binds: statement.binds).rows {
          rows.append(row)
        }
        return rows
      }
      guard rows.count == 1 else { throw RewindRowNotFound() }
      let image = try RewindCaptureSQL.image(rows[0], columns: plan.columns, engine: capture.engine)
      _ = try await sendTransactionControl("RELEASE SAVEPOINT \(Self.captureSavepoint)")
      return image
    } catch {
      // Never the driver's text: it can quote the row's values or the SQL
      let reason = (error as? RewindCaptureError).map { "\($0)" } ?? "\(type(of: error))"
      do {
        _ = try await sendTransactionControl("ROLLBACK TO SAVEPOINT \(Self.captureSavepoint)")
      } catch {
        Task {
          await AppLogger.shared.warning(
            "Data Rewind lost the transaction while reading a row (\(reason))", category: "Rewind")
        }
        throw DatabaseError.transactionAborted(Self.captureTransactionLost)
      }
      _ = try? await sendTransactionControl("RELEASE SAVEPOINT \(Self.captureSavepoint)")
      Task {
        await AppLogger.shared.warning(
          "Data Rewind could not read a row (\(reason))", category: "Rewind")
      }
      return nil
    }
  }

  private static let captureTransactionLost =
    "The transaction ended while Data Rewind read the edited row (the server rolled it back), "
    + "so the edit was not saved."
}

/// The capture read found no row (or more than one) for the key.
private nonisolated struct RewindRowNotFound: LocalizedError {
  var errorDescription: String? { "the row was not found by its key" }
}
