//
//  WorkspaceManager+DuckDBFiles.swift
//  Dblore
//
//  "Query Parquet/CSV File...": the user picks a file, the DuckDB session gets it in
//  `allowed_paths`, and `SELECT * FROM read_parquet/read_csv('<path>') LIMIT 100;` goes into
//  the active SQL editor or cell. The session locks its configuration at open, so a new file
//  means reopening the session (same tabs, same config). Access to the picked files is held
//  until the connection ends (disconnect, another database, workspace closed); it is not kept
//  across launches.
//

import AppKit
import Foundation

/// The SQL the action inserts for one picked file.
nonisolated enum DuckDBFileQuery {
  enum Failure: Error, Equatable, LocalizedError {
    /// NUL or a line break in the path
    case unsupportedPath
    /// The file no longer exists or its path cannot be resolved
    case unresolvable(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedPath:
        "This file's path contains a line break or NUL character; rename it to query it"
      case .unresolvable(let name):
        "\"\(name)\" cannot be found"
      }
    }
  }

  /// `read_parquet` for `.parquet`, `read_csv` otherwise (CSV, TSV: DuckDB detects the delimiter).
  static func readFunction(forExtension pathExtension: String) -> String {
    pathExtension.lowercased() == "parquet" ? "read_parquet" : "read_csv"
  }

  /// The file's path with every symlink resolved (`realpath`), the form DuckDB compares
  /// against `allowed_paths`. The same string goes into the SQL.
  static func canonicalPath(of url: URL) throws -> String {
    guard url.isFileURL, let resolved = realpath(url.path, nil) else {
      throw Failure.unresolvable(url.lastPathComponent)
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// `SELECT * FROM <function>('<path>') LIMIT 100;`, the path a DuckDB string literal.
  static func sql(path: String, function: String) throws -> String {
    guard !path.contains(where: { $0 == "\0" || $0.isNewline }) else {
      throw Failure.unsupportedPath
    }
    return "SELECT * FROM \(function)(\(SQLDialect.duckdb.literal(.string(path)))) LIMIT 100;"
  }
}

extension WorkspaceManager {
  /// The workspace's DuckDB connection, connected or not; nil for other engines.
  var duckDBFileQueryConfig: ConnectionConfig? {
    guard let config = workspace.connectionConfig, config.databaseType == .duckdb else {
      return nil
    }
    return config
  }

  /// Canonical paths of the picked files: the DuckDB session's `allowed_paths`.
  var duckDBAllowedPaths: [String] {
    duckDBFileAccess.keys.sorted()
  }

  /// A connect to the same DuckDB database keeps the picked files; any other connect drops them.
  func keepsDuckDBFileAccess(for config: ConnectionConfig) -> Bool {
    guard let current = workspace.connectionConfig else { return false }
    return config.databaseType == .duckdb && current.databaseType == .duckdb
      && config.database == current.database
  }

  /// Starts access to `url`, recorded under its canonical `path`. False, with nothing started,
  /// when that file is already held.
  @discardableResult
  func addDuckDBFileAccess(_ url: URL, path: String) -> Bool {
    guard duckDBFileAccess[path] == nil else { return false }
    duckDBFileAccess[path] = accessHooks.startAccess(url)
    return true
  }

  func releaseDuckDBFileAccess() {
    for token in duckDBFileAccess.values { token.release() }
    duckDBFileAccess = [:]
  }

  /// Asks for a file, grants it to the DuckDB session (reconnecting when the session does not
  /// have it yet) and inserts its query into the tab active at the start. Returns the SQL; nil
  /// when the action stopped or that tab was closed meanwhile.
  @discardableResult
  func queryDuckDBFile() async -> String? {
    guard let started = duckDBFileQueryConfig, !connectionState.isConnecting else { return nil }
    let wasConnected = connectionState.isConnected
    let targetTabId = activeTabId
    let message = Self.duckDBFilePanelMessage(
      connected: wasConnected, inMemory: started.database == DuckDBSession.inMemoryPath,
      readOnly: started.readOnlyFile)
    guard let url = await accessHooks.chooseDataFile(message) else { return nil }
    // The panel does not block the window: the connection may have changed meanwhile
    guard
      let config = unchangedDuckDBFileConfig(
        database: started.database, wasConnected: wasConnected)
    else { return nil }
    let inMemory = config.database == DuckDBSession.inMemoryPath

    let path: String
    let sql: String
    do {
      path = try DuckDBFileQuery.canonicalPath(of: url)
      sql = try DuckDBFileQuery.sql(
        path: path, function: DuckDBFileQuery.readFunction(forExtension: url.pathExtension))
    } catch {
      WorkspaceWindowManager.shared.showToast(error.localizedDescription, type: .error)
      return nil
    }
    let granted = connectionState.isConnected && duckDBFileAccess[path] != nil
    if !granted {
      guard await grantDuckDBFile(url, path: path, config: config, inMemory: inMemory) else {
        return nil
      }
    }
    // Into the editor the action started from, not one opened or selected meanwhile
    guard let targetTabId else { return sql }
    guard let target = viewModels[targetTabId] else { return nil }
    target.insertTextIntoSelectedCell(sql)
    return sql
  }

  /// The workspace's DuckDB connection when it is still `database`, in the same connected
  /// state and not connecting. Nil (with a toast) after a switch, a disconnect or a connect.
  private func unchangedDuckDBFileConfig(
    database: String, wasConnected: Bool
  ) -> ConnectionConfig? {
    guard let config = duckDBFileQueryConfig, config.database == database,
      !connectionState.isConnecting, connectionState.isConnected == wasConnected
    else {
      WorkspaceWindowManager.shared.showToast(
        "The connection changed while choosing the file: query the file again", type: .warning)
      return nil
    }
    return config
  }

  /// Adds the file and opens the session again with it. A connected in-memory database asks
  /// first (its data is lost); a running statement or a kept transaction refuses.
  private func grantDuckDBFile(
    _ url: URL, path: String, config: ConnectionConfig, inMemory: Bool
  ) async -> Bool {
    let wasConnected = connectionState.isConnected
    if wasConnected {
      guard !isAnyTabExecuting else {
        WorkspaceWindowManager.shared.showToast(
          "A query is running: wait for it to finish, then query the file again", type: .warning)
        return false
      }
      if inMemory {
        guard await confirmInMemoryDuckDBReconnect(),
          unchangedDuckDBFileConfig(database: config.database, wasConnected: true) != nil
        else { return false }
      }
    }
    let added = addDuckDBFileAccess(url, path: path)
    do {
      // Resolves a pending transaction first; the same config needs no unlock
      try await connect(config: config)
    } catch {
      if added { duckDBFileAccess.removeValue(forKey: path)?.release() }
      if case WorkspaceConnectError.pendingTransactionKept = error { return false }
      WorkspaceWindowManager.shared.showToast(
        "DuckDB could not open the file: \(error.localizedDescription)", type: .error)
      presentConnectErrorIfActionable(error, config: config)
      return false
    }
    if wasConnected, !inMemory, !config.readOnlyFile {
      WorkspaceWindowManager.shared.showToast(
        "DuckDB reconnected to read \(url.lastPathComponent): temporary tables were discarded")
    }
    return true
  }

  private func confirmInMemoryDuckDBReconnect() async -> Bool {
    if let duckDBReconnectPrompt { return await duckDBReconnectPrompt() }
    guard !SessionManager.isRunningAsTestHost else { return false }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Reconnect the in-memory database?"
    alert.informativeText =
      "DuckDB reads a new file only after reconnecting. Every table and row in this in-memory "
      + "database will be lost."
    alert.addButton(withTitle: "Reconnect")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  nonisolated static func duckDBFilePanelMessage(
    connected: Bool, inMemory: Bool, readOnly: Bool
  ) -> String {
    let base = "Choose a Parquet or CSV file to query with DuckDB."
    guard connected else { return base }
    if inMemory {
      return base + " A new file reconnects this in-memory database: its data is lost."
    }
    return readOnly
      ? base : base + " A new file reconnects the database: temporary tables are lost."
  }
}
