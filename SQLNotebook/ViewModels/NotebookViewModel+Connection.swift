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

      // Save session if remember connection is enabled
      SessionManager.saveSession(editingConnectionConfig)

      // Auto-load database schema after successful connection
      await loadDatabaseSchema()
    } catch {
      connectionState = .error(error.localizedDescription)
      throw error
    }
  }

  /// Disconnect from database
  func disconnect() {
    Task {
      await connectionManager.disconnect()
      connectionState = .disconnected

      // Clear saved session when manually disconnecting
      SessionManager.clearSession()

      // Clear database schema when disconnected
      databaseTables = []
    }
  }

  /// Test the current connection configuration
  func testConnection() async -> Bool {
    do {
      return try await connectionManager.testConnection(config: editingConnectionConfig)
    } catch {
      return false
    }
  }

  /// Auto-connect to saved session if available
  func autoConnectIfNeeded() {
    Task {
      guard SessionManager.hasSession(),
            let savedConfig = SessionManager.loadSession() else {
        return
      }

      // Load the saved config
      editingConnectionConfig = savedConfig

      // Attempt to connect automatically
      do {
        try await connect()
        print("Auto-connected to saved session: \(savedConfig.displayString)")
      } catch {
        // If auto-connect fails, just log it and let user manually connect
        print("Auto-connect failed: \(error.localizedDescription)")
        connectionState = .disconnected
      }
    }
  }
}
