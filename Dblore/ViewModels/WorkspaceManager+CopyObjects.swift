// WorkspaceManager+CopyObjects.swift
// File > Copy Objects..., and the sidebar's Copy to Another Connection... on a table (that table
// ticked) or on a schema or the database (all its tables ticked). The source is this workspace's
// PostgreSQL, MySQL / MariaDB, SQLite or DuckDB connection and its sidebar tables (temporary
// tables live in this session only, so they are not offered). The targets are the saved
// connections the model takes, except this connection's own saved row. A copy reloads the
// sidebar schema of every open workspace connected to the target.

import Foundation

extension WorkspaceManager {
  /// PostgreSQL, MySQL / MariaDB, SQLite and DuckDB; MongoDB is no source
  var supportsCopyObjects: Bool {
    switch workspace.connectionConfig?.databaseType {
    case .postgresql, .mysql, .sqlite, .duckdb: true
    case .mongodb, .clickhouse, .sqlserver, .redis, nil: false
    }
  }

  /// A supported engine, connected, a schema read since the last connect, and the catalog not
  /// paused by a pending transaction
  var canCopyObjects: Bool {
    supportsCopyObjects && connectionState.isConnected && schemaConnectionEpoch != nil
      && !isSchemaPaused
  }

  /// File > Copy Objects...: the table shown in the active data viewer tab is ticked
  func openCopyObjects() {
    guard let state = activeViewModel?.dataViewer else { return openCopyObjects(ticking: []) }
    openCopyObjects(ticking: [.init(schema: state.schema, name: state.name)])
  }

  /// Copy to Another Connection... on a schema (its tables ticked) or the database (`schema`
  /// nil: every table ticked)
  func openCopyObjects(schema: String?) {
    openCopyObjects(ticks: { schema == nil || $0.schema == schema })
  }

  /// Opens the sheet with `ticking` ticked (those the sidebar lists)
  func openCopyObjects(ticking: [CopyObjectsModel.TableRef]) {
    let ticked = Set(ticking)
    openCopyObjects(ticks: { ticked.contains($0) })
  }

  /// Opens the sheet at once; the sidebar's tables and those `ticks` are read off the main
  /// actor behind it
  private func openCopyObjects(
    ticks: @escaping @Sendable (CopyObjectsModel.TableRef) -> Bool
  ) {
    guard canCopyObjects, copyObjects == nil, let config = workspace.connectionConfig else {
      return
    }
    let tables = databaseTables
    // A locked target asks over the sheet, on this workspace's window
    let windowID = id
    let context = CopyObjectsContext(
      source: connectionManager, sourceConfig: config, sourceTriggers: databaseTriggers,
      recorder: AppSettings.shared.historyEnabled
        ? NotebookViewModel.defaultHistoryRecorder() : nil,
      workspaceID: workspace.id, workspaceName: workspace.name, lockCenter: lockCenter,
      unlockAnchor: { NewWindowStore.shared.findWindow(for: windowID) })
    // Copying into this connection's own saved row would copy the tables onto themselves
    let saved = SessionManager.loadHistory(passwords: NoPasswordStore())
      .filter { !$0.isSavedRow(of: config) }
    let model = CopyObjectsModel(
      context: context, tables: [], selected: [], savedConnections: saved)
    model.loadTables { await Self.copyObjectsTables(tables, ticks: ticks) }
    model.onCopied = { target in
      await WorkspaceManager.refreshSchema(ofWorkspacesOn: target)
    }
    copyObjects = model
  }

  /// Hides the sheet; kept open while a copy runs. A plan load stops and both connections close.
  func closeCopyObjects() {
    guard let model = copyObjects, !model.isRunning else { return }
    model.close()
    copyObjects = nil
  }

  /// The sidebar's tables without the temporary ones, those `ticks` and whether they span
  /// several schemas. Off the main actor: a large catalog has tens of thousands of tables.
  @concurrent private nonisolated static func copyObjectsTables(
    _ tables: [DatabaseTable], ticks: @Sendable (CopyObjectsModel.TableRef) -> Bool
  ) async -> CopyObjectsModel.TableSource {
    let listed = tables.filter { !$0.isTemporary }.map {
      CopyObjectsModel.TableRef(schema: $0.schema, name: $0.name)
    }
    return (listed, Set(listed.filter(ticks)), CopyObjectsModel.spansSchemas(listed))
  }

  /// Every open workspace connected to `target` (its engine and Keychain identity) reloads its
  /// sidebar schema; one with a pending transaction keeps its catalog paused until it ends
  private static func refreshSchema(ofWorkspacesOn target: ConnectionConfig) async {
    let key = ConnectionKeychainKey.password(for: target)
    for manager in WorkspaceWindowManager.shared.workspaces.values {
      guard let config = manager.workspace.connectionConfig,
        config.databaseType == target.databaseType,
        ConnectionKeychainKey.password(for: config) == key, manager.connectionState == .connected
      else { continue }
      await manager.connectionManager.restoreSchemaRefresh()
      await manager.refreshSchemaAfterStatements()
    }
  }
}
