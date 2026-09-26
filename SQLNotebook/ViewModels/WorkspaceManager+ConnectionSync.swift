//
//  WorkspaceManager+ConnectionSync.swift
//  SQLNotebook
//
//  The workspace connection config is the single source of protection level, per-connection
//  Safe Mode and protected mode for every tab and for the connection actor. Connecting to the
//  same database with weaker settings goes through the same Safe Mode unlock as a runtime change.
//

import Foundation

/// A connect held by `WorkspaceManager.connect(config:globalSafeMode:)`
enum WorkspaceConnectError: Error, Equatable {
  /// Same database with weaker safety settings: waiting for the Safe Mode unlock
  case unlockRequired
}

extension WorkspaceManager {
  /// Give a tab ViewModel the workspace connection config and route its runtime protection
  /// changes back to the workspace.
  func shareConnectionConfig(with viewModel: NotebookViewModel) {
    viewModel.applyWorkspaceConnectionConfig(workspace.connectionConfig)
    viewModel.onConnectionProtectionChanged = { [weak self] config in
      self?.updateConnectionProtection(from: config)
    }
  }

  /// A tab changed the protection level, Safe Mode or protected mode of the connection:
  /// update the workspace config, every tab and the actor's connected config.
  func updateConnectionProtection(from config: ConnectionConfig) {
    guard var current = workspace.connectionConfig else { return }
    current.protectionLevel = config.protectionLevel
    current.safeMode = config.safeMode
    current.protectedMode = config.protectedMode
    guard current != workspace.connectionConfig else { return }
    workspace.connectionConfig = current
    editingConnectionConfig.protectionLevel = current.protectionLevel
    editingConnectionConfig.safeMode = current.safeMode
    editingConnectionConfig.protectedMode = current.protectedMode
    markDirtyAndScheduleAutoSave()
    syncConnectionStateToTabs()
    let connectionManager = connectionManager
    Task {
      await connectionManager.updateConnectedProtection(from: current)
    }
  }

  // MARK: - Connect (weakening needs the Safe Mode unlock)

  /// True if connecting with `new` needs the Safe Mode unlock: `new` targets the same database
  /// as `current` (host, port, database, username; strings trimmed and compared
  /// case-insensitively, so a case variant cannot dodge the check) and the change weakens the
  /// safety settings while the current effective Safe Mode requires a password
  /// (`NotebookViewModel.requiresUnlockForChange`). A different target is a new connection.
  nonisolated static func connectRequiresUnlock(
    current: ConnectionConfig?, new: ConnectionConfig, globalSafeMode: SafeMode
  ) -> Bool {
    guard let current, isSameTarget(current, new) else { return false }
    return NotebookViewModel.requiresUnlockForChange(
      from: ConnectionSafetyState(config: current, globalSafeMode: globalSafeMode),
      to: ConnectionSafetyState(config: new, globalSafeMode: globalSafeMode))
  }

  nonisolated private static func isSameTarget(
    _ lhs: ConnectionConfig, _ rhs: ConnectionConfig
  )
    -> Bool
  {
    func normalized(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    return lhs.port == rhs.port && normalized(lhs.host) == normalized(rhs.host)
      && normalized(lhs.database) == normalized(rhs.database)
      && normalized(lhs.username) == normalized(rhs.username)
  }

  /// The single connect entry point. Compared against the workspace's current config whether
  /// or not it is connected right now: the workspace keeps the last config after a disconnect,
  /// so reconnecting to the same database with weaker settings needs the unlock too.
  /// - Throws: `WorkspaceConnectError.unlockRequired` when the connect is held in
  ///   `pendingWeakeningConnect` (nothing changed); connect with
  ///   `completePendingWeakeningConnect()` after the unlock.
  func connect(
    config: ConnectionConfig, globalSafeMode: SafeMode = AppSettings.shared.safeMode
  ) async throws {
    if Self.connectRequiresUnlock(
      current: workspace.connectionConfig, new: config, globalSafeMode: globalSafeMode)
    {
      pendingWeakeningConnect = config
      throw WorkspaceConnectError.unlockRequired
    }
    pendingWeakeningConnect = nil
    try await connectWithoutUnlockCheck(config: config)
  }

  /// Connect with the held config after a successful Safe Mode unlock. No-op without one.
  /// The config stays held while connecting and after a failure (a retry needs a new unlock);
  /// it is cleared on success.
  func completePendingWeakeningConnect() async throws {
    guard let config = pendingWeakeningConnect else { return }
    try await connectWithoutUnlockCheck(config: config)
    pendingWeakeningConnect = nil
  }

  /// Unlock cancelled: nothing connects (the form keeps its values).
  func cancelPendingWeakeningConnect() {
    pendingWeakeningConnect = nil
  }

  /// Connect/disconnect: results shown in every tab came from the previous connection, so none
  /// of them stays editable (the actor also refuses their targets by connection epoch).
  func invalidateEditTargetsInTabs() {
    for viewModel in viewModels.values {
      viewModel.invalidateEditTargets()
    }
  }
}
