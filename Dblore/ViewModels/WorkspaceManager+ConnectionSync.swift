//
//  WorkspaceManager+ConnectionSync.swift
//  Dblore
//
//  The workspace connection config is the single source of protection level, commit style,
//  per-connection Safe Mode and protected mode for every tab and for the connection actor.
//  Connecting to the same database with weaker settings goes through the same Safe Mode unlock
//  as a runtime change.
//

import Foundation

/// A connect held by `WorkspaceManager.connect(config:defaultCommitStyle:)`
enum WorkspaceConnectError: Error, Equatable {
  /// Same database with weaker safety settings: waiting for the Safe Mode unlock
  case unlockRequired
  /// A Protected transaction is pending and the user cancelled its resolution: still
  /// connected, nothing changed
  case pendingTransactionKept
}

extension WorkspaceManager {
  /// Give a tab ViewModel the workspace connection config and route its runtime protection
  /// changes back to the workspace.
  func shareConnectionConfig(with viewModel: NotebookViewModel) {
    viewModel.applyWorkspaceConnectionConfig(workspace.connectionConfig)
    viewModel.onConnectionProtectionChanged = { [weak self] config in
      self?.updateConnectionProtection(from: config)
    }
    viewModel.isCommitStyleChangeBlocked = { [weak self] in
      guard let self else { return false }
      return !self.pendingTransaction.isIdle
    }
  }

  /// A tab changed the protection level, commit style, Safe Mode or protected mode of the
  /// connection: update the workspace config, every tab and the actor's connected config.
  func updateConnectionProtection(from config: ConnectionConfig) {
    guard var current = workspace.connectionConfig else { return }
    current.protectionLevel = config.protectionLevel
    current.safeMode = config.safeMode
    current.protectedMode = config.protectedMode
    current.commitStyle = config.commitStyle
    guard current != workspace.connectionConfig else { return }
    workspace.connectionConfig = current
    editingConnectionConfig.protectionLevel = current.protectionLevel
    editingConnectionConfig.safeMode = current.safeMode
    editingConnectionConfig.protectedMode = current.protectedMode
    editingConnectionConfig.commitStyle = current.commitStyle
    markDirtyAndScheduleAutoSave()
    syncConnectionStateToTabs()
    let connectionManager = connectionManager
    Task {
      await connectionManager.updateConnectedProtection(from: current)
    }
  }

  /// Rename the active connection (workspace, editing copy, tabs and the recent list).
  func renameConnection(to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var current = workspace.connectionConfig, current.name != trimmed
    else { return }
    current.name = trimmed
    workspace.connectionConfig = current
    editingConnectionConfig.name = trimmed
    markDirtyAndScheduleAutoSave()
    syncConnectionStateToTabs()
    SessionManager.saveConnection(current)
  }

  // MARK: - Connect (weakening needs the Safe Mode unlock)

  /// True if connecting with `new` needs the Safe Mode unlock: `new` targets the same database
  /// as `current` (host, port, database, username; strings trimmed and compared
  /// case-insensitively, so a case variant cannot dodge the check) and the resolved commit
  /// style weakens under the same rule as a runtime change
  /// (`NotebookViewModel.requiresUnlockForChange`). A different target is a new connection.
  /// `defaultCommitStyle` is the fallback for a legacy unprotected connection with a nil safe mode.
  nonisolated static func connectRequiresUnlock(
    current: ConnectionConfig?, new: ConnectionConfig, defaultCommitStyle: CommitStyle,
    hasPassword: Bool, hasTouchID: Bool
  ) -> Bool {
    guard let current, isSameTarget(current, new) else { return false }
    return NotebookViewModel.requiresUnlockForChange(
      from: ConnectionSafetyState(config: current, defaultCommitStyle: defaultCommitStyle),
      to: ConnectionSafetyState(config: new, defaultCommitStyle: defaultCommitStyle),
      hasPassword: hasPassword, hasTouchID: hasTouchID)
  }

  nonisolated private static func isSameTarget(
    _ lhs: ConnectionConfig, _ rhs: ConnectionConfig
  )
    -> Bool
  {
    func normalized(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    func normalizedHost(_ value: String) -> String {
      let host = normalized(value)
      return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
    return lhs.port == rhs.port && normalizedHost(lhs.host) == normalizedHost(rhs.host)
      && normalized(lhs.database) == normalized(rhs.database)
      && normalized(lhs.username) == normalized(rhs.username)
  }

  /// The single connect entry point. Connecting replaces the current connection, so a pending
  /// Protected transaction is resolved first (Commit / Roll back / Cancel, like a disconnect).
  /// Compared against the workspace's current config whether or not it is connected right now:
  /// the workspace keeps the last config after a disconnect, so reconnecting to the same
  /// database with weaker settings needs the unlock too.
  /// - Throws: `WorkspaceConnectError.pendingTransactionKept` when the pending transaction was
  ///   not resolved (still connected, nothing changed); `WorkspaceConnectError.unlockRequired`
  ///   when the connect is held in `pendingWeakeningConnect` (nothing changed); connect with
  ///   `completePendingWeakeningConnect()` after the unlock.
  func connect(
    config: ConnectionConfig, defaultCommitStyle: CommitStyle = AppSettings.shared.commitStyle,
    isAutoConnect: Bool = false,
    hasPassword: Bool = AppSettings.shared.hasCustomPasswordSet,
    hasTouchID: Bool = AppSettings.shared.isBiometricEnabled
  ) async throws {
    if !isAutoConnect { await supersedeAutoConnect() }
    guard await resolvePendingTransaction(action: .disconnect, defaultCommitStyle: defaultCommitStyle)
    else {
      throw WorkspaceConnectError.pendingTransactionKept
    }
    if Self.connectRequiresUnlock(
      current: workspace.connectionConfig, new: config, defaultCommitStyle: defaultCommitStyle,
      hasPassword: hasPassword, hasTouchID: hasTouchID)
    {
      pendingWeakeningConnect = config
      pendingWeakeningCertificate = ClientCertificateStoreFactory.operationMaterial?.material
      throw WorkspaceConnectError.unlockRequired
    }
    pendingWeakeningConnect = nil
    pendingWeakeningCertificate = nil
    try await connectWithoutUnlockCheck(config: config, isAutoConnect: isAutoConnect)
  }

  /// Connect with the held config after a successful Safe Mode unlock. No-op without one.
  /// The config stays held while connecting and after a failure (a retry needs a new unlock);
  /// it is cleared on success.
  func completePendingWeakeningConnect() async throws {
    guard let config = pendingWeakeningConnect else { return }
    let scopedMaterial = pendingWeakeningCertificate.map {
      ClientCertificateStoreFactory.ScopedMaterial(
        account: ClientCertificateStoreFactory.account(for: config), material: $0)
    }
    pendingWeakeningCertificate = nil
    defer { scopedMaterial?.clear() }
    do {
      try await ClientCertificateStoreFactory.$operationMaterial.withValue(scopedMaterial) {
        try await connectWithoutUnlockCheck(config: config)
      }
    } catch {
      pendingWeakeningConnect = nil
      throw error
    }
    pendingWeakeningConnect = nil
  }

  /// Unlock cancelled: nothing connects (the form keeps its values).
  func cancelPendingWeakeningConnect() {
    pendingWeakeningConnect = nil
    pendingWeakeningCertificate = nil
  }

  /// Connect/disconnect: results shown in every tab came from the previous connection, so none
  /// of them stays editable (the actor also refuses their targets by connection epoch).
  func invalidateEditTargetsInTabs() {
    for viewModel in viewModels.values {
      viewModel.invalidateEditTargets()
    }
  }
}
