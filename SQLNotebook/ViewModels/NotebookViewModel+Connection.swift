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
}
