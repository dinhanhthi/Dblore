// WorkspaceManager+SchemaCompare.swift
// File > Compare Schemas... and the sidebar's Compare Schemas... on PostgreSQL, MySQL / MariaDB
// and SQLite. The sheet compares a source (another schema of this connection, or a saved
// connection of the same engine) with a schema of this connection and runs the script on the
// active tab (a new SQL tab when none is open), with its rules and History. A run reloads the
// sidebar schema and closes the tabs of the tables it dropped, the way a structure editor Apply
// does (after Commit when pending).

import Foundation

extension WorkspaceManager {
  /// PostgreSQL, MySQL / MariaDB and SQLite; DuckDB and MongoDB have no Schema Compare
  var supportsSchemaCompare: Bool {
    switch workspace.connectionConfig?.databaseType {
    case .postgresql, .mysql, .sqlite: true
    case .duckdb, .mongodb, nil: false
    }
  }

  /// A supported engine, connected, a schema read since the last connect, and the catalog not
  /// paused by a pending transaction (the structure reads would be refused)
  var canCompareSchemas: Bool {
    supportsSchemaCompare && connectionState.isConnected && schemaConnectionEpoch != nil
      && !isSchemaPaused
  }

  /// Opens the sheet with this connection's default schema as the target
  func openSchemaCompare() {
    guard canCompareSchemas, schemaCompare == nil, let config = workspace.connectionConfig else {
      return
    }
    let tabID = activeTabId ?? newSQLFile()
    guard let tab = viewModel(for: tabID), let context = SchemaCompareContext(tab: tab) else {
      return
    }
    let schemas = schemaCompareSchemas(config)
    let model = SchemaCompareModel(
      context: context, targetSchemas: schemas, targetSchema: schemas.first ?? "",
      savedConnections: SessionManager.loadHistory(passwords: NoPasswordStore()))
    model.onApplied = { [weak self] in
      await self?.refreshPendingTransaction()
      await self?.refreshSchemaAfterStatements()
    }
    // As for the structure editor: a dropped table's tabs close, on Commit when pending
    model.onTableChange = { [weak self] change, pending in
      if pending {
        self?.pendingTableChanges.append(change)
      } else {
        self?.applyTableChange(change)
      }
    }
    model.toastPresenter = { [weak tab] in tab?.showToast($0, type: $1) }
    schemaCompare = model
  }

  /// Hides the sheet; kept open while a script is being sent. A compare in progress stops and
  /// its source connection closes.
  func closeSchemaCompare() {
    guard let model = schemaCompare, !model.isRunning else { return }
    model.close()
    schemaCompare = nil
  }

  /// MySQL: the connected database (the tab's session reads and writes only there). Elsewhere
  /// the schemas holding a sidebar table, the connection's default schema first.
  private func schemaCompareSchemas(_ config: ConnectionConfig) -> [String] {
    if config.databaseType == .mysql { return [config.database] }
    let defaultSchema = config.databaseType.dialect.defaultSchema
    var schemas = Set(databaseTables.map(\.schema)).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    if let index = schemas.firstIndex(of: defaultSchema) {
      schemas.insert(schemas.remove(at: index), at: 0)
    }
    return schemas.isEmpty ? [defaultSchema] : schemas
  }
}
