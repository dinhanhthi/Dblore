//
//  NotebookViewModel+History.swift
//  Dblore
//
//  Records user statements after they run. Internal page and count queries are not stored.
//

import Foundation

/// Where a statement ran. `.internal` is a call-site flag only: it is never stored.
nonisolated enum QueryHistoryRecordSource: Sendable {
  case cell
  case editor
  case dataViewerEdit
  case `internal`

  var stored: QueryHistoryEntry.Source? {
    switch self {
    case .cell: .cell
    case .editor: .editor
    case .dataViewerEdit: .dataViewerEdit
    case .internal: nil
    }
  }
}

/// One statement outcome passed to `recordExecution`.
nonisolated struct QueryHistoryOutcome: Sendable {
  var sql: String
  var duration: TimeInterval
  var rowCount: Int?
  var status: QueryHistoryEntry.Status
  var errorMessage: String?
}

/// In-memory stand-in used while the process is the test host.
actor InMemoryQueryHistoryRecorder: QueryHistoryRecording {
  private var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

extension NotebookViewModel {
  /// SQLite in the app. An in-memory recorder under XCTest, so `shared` is never opened.
  nonisolated static func defaultHistoryRecorder() -> any QueryHistoryRecording {
    if SessionManager.isRunningAsTestHost {
      return InMemoryQueryHistoryRecorder()
    }
    return QueryHistoryStore.shared
  }

  /// Writes one history row per outcome. Skips `.internal`, a disabled history setting, and
  /// role/user statements that contain a password. Fire-and-forget callers use `scheduleHistory`.
  func recordExecution(_ outcomes: [QueryHistoryOutcome], source: QueryHistoryRecordSource) async {
    guard let stored = source.stored, historySettings.historyEnabled else { return }
    let connection = historyConnection()
    let workspace = historyWorkspace()
    var recorded = false
    for outcome in outcomes {
      guard !SQLStatementClassifier.containsPasswordLiteral(outcome.sql) else { continue }
      let entry = QueryHistoryEntry(
        id: 0,
        sql: outcome.sql,
        executedAt: Date(),
        durationMs: Int((outcome.duration * 1_000).rounded()),
        rowCount: outcome.rowCount,
        status: outcome.status,
        errorMessage: outcome.errorMessage,
        connectionKey: connection.key,
        connectionLabel: connection.label,
        workspaceID: workspace?.id,
        workspaceName: workspace?.name,
        source: stored)
      await historyRecorder.record(entry)
      recorded = true
    }
    if recorded {
      onHistoryRecorded?()
    }
  }

  /// Records after the query has returned. A recorder failure cannot fail the query.
  func scheduleHistory(_ outcomes: [QueryHistoryOutcome], source: QueryHistoryRecordSource) {
    Task { [weak self] in
      await self?.recordExecution(outcomes, source: source)
    }
  }

  func recordResults(
    _ statements: [(sql: String, result: CellResult)], source: QueryHistoryRecordSource
  ) {
    scheduleHistory(
      statements.map { statement in
        QueryHistoryOutcome(
          sql: statement.sql,
          duration: statement.result.executionTime,
          rowCount: Self.recordedRowCount(statement.result),
          status: .success,
          errorMessage: nil)
      },
      source: source)
  }

  func recordFailure(
    _ error: Error, sql: String, duration: TimeInterval, source: QueryHistoryRecordSource
  ) {
    scheduleHistory(
      [
        QueryHistoryOutcome(
          sql: sql, duration: duration, rowCount: nil, status: Self.historyStatus(for: error),
          errorMessage: error.localizedDescription)
      ],
      source: source)
  }

  /// Affected-row count when the statement returned no result rows; otherwise the row count.
  /// A SELECT reports `affectedRows == 0` and its fetched rows.
  private static func recordedRowCount(_ result: CellResult) -> Int {
    if result.rows.isEmpty, let affectedRows = result.affectedRows {
      return affectedRows
    }
    return result.rowCount
  }

  private static func historyStatus(for error: Error) -> QueryHistoryEntry.Status {
    if let error = error as? DatabaseError, case .queryCancelled = error {
      return .cancelled
    }
    return .error
  }

  /// `databaseType|host|port|database|username`, never the password. The label is the
  /// connection name, or `host/database` when it has none.
  private func historyConnection() -> (key: String, label: String) {
    guard let config = notebook.connectionConfig else { return ("", "") }
    let key = QueryHistoryIdentity.connectionKey(for: config)
    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = name.isEmpty ? "\(config.host)/\(config.database)" : name
    return (key, label)
  }
}
