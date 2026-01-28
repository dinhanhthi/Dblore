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

      // Clear autocomplete cache on disconnect (10.1.8 optimization)
      autocompleteProvider.clearCache()
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

  /// Set protection level for the current connection
  /// This updates both the editing config and notebook config
  func setProtectionLevel(_ level: ConnectionProtectionLevel) async {
    let oldLevel = editingConnectionConfig.protectionLevel

    // Update both configs
    editingConnectionConfig.protectionLevel = level
    notebook.connectionConfig?.protectionLevel = level

    // Log the action
    await AppLogger.shared.info(
      "Protection level changed from \(oldLevel.displayName) to \(level.displayName) for connection: \(editingConnectionConfig.safeDisplayString)",
      category: "Connection")

    // Show appropriate toast
    let message: String
    switch level {
    case .none:
      message = "Protection disabled"
    case .schemaOnly:
      message = "Schema protection enabled"
    case .readOnly:
      message = "Read-only mode enabled"
    }
    showToast(message, type: .success)

    // Sync document to save the change
    onDocumentChanged?()
  }

  /// Disable protection (set to none)
  func disableProtection() async {
    await setProtectionLevel(.none)
  }

  /// Enable read-only mode for the current connection
  func enableReadOnlyMode() async {
    await setProtectionLevel(.readOnly)
  }

  /// Enable schema-only protection for the current connection
  func enableSchemaProtection() async {
    await setProtectionLevel(.schemaOnly)
  }
}
