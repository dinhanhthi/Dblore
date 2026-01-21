//
//  NotebookViewModel+Connection.swift
//  SQLNotebook
//

import Foundation

// MARK: - Connection Management

extension NotebookViewModel {
  /// Connect to database
  func connect() async throws {
    connectionState = .connecting

    do {
      try await connectionManager.connect(config: editingConnectionConfig)
      notebook.connectionConfig = editingConnectionConfig
      connectionState = .connected

      // Save connection to history if remember connection is enabled
      SessionManager.saveConnection(editingConnectionConfig)

      // Auto-load database schema after successful connection
      await loadDatabaseSchema()

      // Refresh autocomplete schema
      await autocompleteProvider.refreshSchema()
    } catch {
      // Set to disconnected instead of error state
      // Error message will be shown in the connection form, not in the header
      connectionState = .disconnected
      throw error
    }
  }

  /// Disconnect from database
  func disconnect() {
    Task { @MainActor [connectionManager] in
      await connectionManager.disconnect()
      connectionState = .disconnected

      // Note: We don't clear history on disconnect anymore
      // History persists across disconnects for easy reconnection

      // Clear database schema when disconnected
      databaseTables = []

      // Clear autocomplete schema
      await autocompleteProvider.refreshSchema()
    }
  }

  /// Test the current connection configuration
  func testConnection() async throws -> Bool {
    return try await connectionManager.testConnection(config: editingConnectionConfig)
  }

  /// Auto-connect to saved session if available
  func autoConnectIfNeeded() {
    Task { @MainActor [weak self] in
      guard let self else { return }

      // Load most recent connection from history
      guard let savedConfig = SessionManager.loadMostRecentConnection()
      else {
        return
      }

      // Load the saved config
      self.editingConnectionConfig = savedConfig

      // Attempt to connect automatically
      do {
        try await self.connect()
        await AppLogger.shared.info(
          "Auto-connected to saved session: \(savedConfig.safeDisplayString)",
          category: "Connection")
      } catch {
        // If auto-connect fails, just log it and let user manually connect
        await AppLogger.shared.warning(
          "Auto-connect failed: \(error.localizedDescription)", category: "Connection")
        connectionState = .disconnected
      }
    }
  }
}
