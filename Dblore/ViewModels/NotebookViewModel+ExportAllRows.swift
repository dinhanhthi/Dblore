// NotebookViewModel+ExportAllRows.swift
// The Export sheet's "All rows" source. The grid holds only part of a result cut by the row
// cap, stopped at the byte budget or with cut cells, and only one page of a data viewer: such a
// result's read runs again on a separate connection (`ResultExportRunner`) and every row is
// written. Offered only for a read that may run again without the user: one statement that
// `ReadOnlyQueryGuard` passes, without `:name` parameters (a data viewer page reads its whole
// relation with `DataViewerState.exportSQL`); never for MongoDB.

import Foundation

/// The read an all-rows export runs again, and the result columns it must answer
nonisolated struct AllRowsExportSource: Equatable, Sendable {
  /// One read without `:name` parameters (checked again by the runner)
  var sql: String
  var columns: [ColumnInfo]
  /// The unquoted table of a SQL INSERT export
  var schema: String?
  var name: String?
}

/// What the Export sheet offers past the shown rows
enum AllRowsExportOffer: Equatable {
  case available(AllRowsExportSource)
  /// The shown rows are not every row, and they cannot be read again: why
  case unavailable(reason: String)

  var source: AllRowsExportSource? {
    if case .available(let source) = self { return source }
    return nil
  }

  var reason: String? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

extension NotebookViewModel {
  static let allRowsMongoDBReason = "MongoDB results export only the shown rows."
  static let allRowsNotReadReason =
    "Only a read can export all rows: running this query again could change data."
  static let allRowsMultipleStatementsReason =
    "Only one statement can export all rows: this query has more than one."
  static let allRowsNotAutomaticReason =
    "This query reads files or calls functions that never run again on their own,"
    + " so all rows cannot be exported."
  static let allRowsNoQueryReason = "This result has no query to run again."

  /// The all-rows export of `result` (of the cell `cellId`, nil in the editor): every SQL data
  /// viewer page, whatever it shows; an editor or notebook result only when the grid holds part
  /// of it (row cap, byte budget, cut cells). Nil when the shown rows are every row.
  func allRowsExportOffer(for result: CellResult, cellId: UUID?) -> AllRowsExportOffer? {
    guard result.error == nil else { return nil }
    let page = cellId == nil ? dataViewer : nil
    if let page {
      guard page.databaseType != .mongodb else {
        return .unavailable(reason: Self.allRowsMongoDBReason)
      }
      return .available(
        AllRowsExportSource(
          sql: page.exportSQL, columns: result.columns, schema: page.schema, name: page.name))
    }
    guard result.wasLimited || result.stoppedAtByteBudget || !result.cutCells.isEmpty else {
      return nil
    }
    let engine = notebook.connectionConfig?.databaseType ?? .postgresql
    guard engine != .mongodb else { return .unavailable(reason: Self.allRowsMongoDBReason) }
    guard let query = result.sourceQuery else {
      return .unavailable(reason: Self.allRowsNoQueryReason)
    }
    let statement: String
    do {
      statement = try ResultExportRunner.checkedRead(query, dialect: engine.dialect)
    } catch {
      return .unavailable(reason: Self.allRowsRefusalReason(error))
    }
    let table = insertTable(dataViewer: nil, editTarget: result.editTarget)
    return .available(
      AllRowsExportSource(
        sql: statement, columns: result.columns, schema: table.schema, name: table.name))
  }

  /// Why the query of a result cannot run again, in the sheet's words (never the guard's
  /// "runs automatically")
  private static func allRowsRefusalReason(_ error: Error) -> String {
    switch error {
    case ReadOnlyQueryGuard.Refusal.multipleStatements: allRowsMultipleStatementsReason
    case ReadOnlyQueryGuard.Refusal.empty, ReadOnlyQueryGuard.Refusal.notRead:
      allRowsNotReadReason
    case is ReadOnlyQueryGuard.Refusal: allRowsNotAutomaticReason
    default: error.localizedDescription
    }
  }

  /// Runs `source` again on a separate connection and writes every row with `options` to
  /// `destination` (replaced once whole). Masked columns follow the connection's rules now: their
  /// cells are masked as the grid's are and redacted as the shown rows' export redacts them.
  /// Returns the rows written; `progress` gets them as they are written.
  /// - Throws: `DatabaseError.notConnected`, and the errors of `ResultExportRunner.write`
  ///   (staged or open changes refused before anything connects, `CancellationError`).
  func exportAllRows(
    _ source: AllRowsExportSource, options: ExportOptions, to destination: URL,
    progress: @escaping @Sendable (Int) -> Void = { _ in }
  ) async throws -> Int {
    guard let manager = connectionManager, let config = await manager.config else {
      throw DatabaseError.notConnected
    }
    let runner = ResultExportRunner(
      tabManager: manager, config: config, material: await manager.activeUnrememberedCertificate,
      sshCredential: await manager.activeUnrememberedSSHCredential,
      sshHostKeyPrompt: manager.sshHostKeyPolicy.prompt)
    // The rules and the read in one task, while the tab is still connected
    let plan = await manager.maskPlan(for: source.columns)
    var columns = source.columns
    for index in plan.maskedColumns where columns.indices.contains(index) {
      let column = columns[index]
      columns[index] = ColumnInfo(
        name: column.name, type: column.type, origin: column.origin,
        sourceName: column.sourceName, wallClock: column.wallClock, masked: true)
    }
    let request = ResultExportRequest(
      sql: source.sql, columns: columns, format: .download(options.redactingMasked(columns)),
      schema: source.schema, name: source.name)
    return try await runner.write(
      request, to: destination, hasStagedChanges: hasStagedAllRowsChanges,
      mask: { plan.mask($0) }, progress: progress)
  }

  /// The workspace an all-rows export belongs to (Running Work), nil when none is open
  var allRowsExportWorkspaceID: UUID? {
    connectionManager.flatMap { RunningWorkRegistry.workspaceID(of: $0) }
  }

  /// Changes the tab holds that a separate connection would not see: staged data viewer edits,
  /// or another tab's pending Protected transaction on this connection
  private var hasStagedAllRowsChanges: Bool {
    dataViewer?.changeSet != nil || isTransactionPendingElsewhere
  }
}
