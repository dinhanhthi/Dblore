// WorkspaceManager+TableHealth.swift
// File > Table Health... on PostgreSQL, MySQL / MariaDB and SQLite (structure checks only):
// opens the sheet at once and starts the run on the sidebar's tables (`TableHealthModel`).
// A session's temporary tables are left out: the run's own connection can't see them.

import Foundation

extension WorkspaceManager {
  /// Connected to an engine Table Health runs on (`checksTableHealth`), with a schema read since
  /// the last connect. An open transaction does not disable it: the sheet says why the run is
  /// refused.
  var canOpenTableHealth: Bool {
    guard connectionState.isConnected, schemaConnectionEpoch != nil,
      let type = workspace.connectionConfig?.databaseType
    else { return false }
    return Self.checksTableHealth(type)
  }

  /// The engines Table Health runs on. ClickHouse and SQL Server never get it.
  nonisolated static func checksTableHealth(_ type: DatabaseType) -> Bool {
    switch type {
    case .postgresql, .sqlite, .mysql: true
    case .duckdb, .mongodb, .clickhouse, .sqlserver: false
    }
  }

  /// Shows the sheet in its loading state and starts the run
  func openTableHealth() {
    guard canOpenTableHealth, tableHealth == nil,
      let type = workspace.connectionConfig?.databaseType
    else { return }
    let model = TableHealthModel(
      tables: databaseTables.filter { !$0.isTemporary }.map {
        .init(schema: $0.schema, name: $0.name)
      },
      engine: type, databaseName: dataDictionaryDatabaseName,
      connectionManager: connectionManager)
    model.onClose = { [weak self, weak model] in
      if self?.tableHealth === model { self?.tableHealth = nil }
    }
    tableHealth = model
    model.start()
  }

  /// Show table: hides the sheet, then shows the finding's table in a data viewer tab
  func showTableHealthTable(_ finding: TableHealthFinding) {
    tableHealth?.cancel()
    let table = databaseTables.first { $0.schema == finding.schema && $0.name == finding.table }
    openDataViewer(
      schema: finding.schema, name: finding.table,
      orderColumns: table?.columns.filter(\.isPrimaryKey).map(\.name) ?? [])
  }
}
