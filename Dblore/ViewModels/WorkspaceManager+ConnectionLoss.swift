//
//  WorkspaceManager+ConnectionLoss.swift
//  Dblore
//
//  A capped read or a user cancel reset the session (`sessionResets`): a warning toast, still
//  connected.
//  The server (or the network) closed the workspace connection: the actor already forgot the
//  session (`DatabaseConnectionManager.sessionEvents`); the workspace shows it as disconnected
//  with "Connection lost" and a Reconnect button (`ConnectionLostBanner`). Never reconnects on
//  its own: a pending Protected transaction was rolled back by the server and the user must
//  know.
//

import Foundation

extension WorkspaceManager {
  /// Listen for session-lost and session-reset events of `connectionManager` for the life of
  /// the workspace
  func startSessionLossListener() {
    let events = connectionManager.sessionEvents
    Task { [weak self] in
      for await event in events {
        await self?.connectionWasLost(event)
      }
    }
    let resets = connectionManager.sessionResets
    Task { [weak self] in
      for await event in resets {
        self?.sessionWasReset(event)
      }
    }
  }

  /// A capped read or a cancel closed and reopened the shared session (still connected): every tab lost
  /// its temp tables and SET values. The result itself shows the details.
  func sessionWasReset(_ event: SessionResetEvent) {
    // The reopened session starts locked again (the actor forgot its unlock with the old one)
    writeUnlock.end()
    // The closed session took its transaction along: the tables written in it were rolled back.
    // When the reset ended none, a held table had no transaction to roll back with (the mirror
    // lagged): its write was committed, so its tabs are marked rather than missed.
    let endedTransaction: Bool
    switch event.reason {
    case .rowCap: endedTransaction = event.userTxRolledBack
    case .cancelled(let pendingCount): endedTransaction = event.userTxRolledBack || pendingCount > 0
    }
    resolveHeldWrittenRelations(committed: !endedTransaction)
    switch event.reason {
    case .rowCap:
      WorkspaceWindowManager.shared.showToast(
        "Connection was reset to stop a large result — temp tables, SET and search_path were "
          + "lost.", type: .warning)
    case .cancelled(let pendingCount):
      WorkspaceWindowManager.shared.showToast(
        DatabaseError.cancelMessage(
          pendingCount: pendingCount, userTxRolledBack: event.userTxRolledBack),
        type: .warning)
    }
  }

  /// Clear everything that came from the lost connection (like Disconnect) and show the loss.
  /// Ignored when the workspace is not connected (it already disconnected, or is connecting)
  /// or when the actor already holds a newer connection. A Vault lease end says so; Reconnect
  /// takes a new lease.
  func connectionWasLost(_ event: SessionLostEvent) async {
    guard connectionState.isConnected, await !connectionManager.isConnected else { return }
    // Read before the disconnect, which clears it
    let leaseEnd = await connectionManager.lastLeaseEnd
    await performDisconnect(preserveCertificateForReconnect: true)
    connectionLostMessage = Self.connectionLostMessage(for: event, leaseEnd: leaseEnd)
  }

  /// The banner text of a loss: the event's (what was rolled back, then "Reconnect to
  /// continue."), after "Vault lease ended." when the loss was that connection's lease end.
  nonisolated static func connectionLostMessage(
    for event: SessionLostEvent, leaseEnd: VaultLeaseEnd?
  ) -> String {
    guard let leaseEnd, leaseEnd.epoch == event.epoch else { return event.message }
    return (["Vault lease ended."] + [leaseEnd.detail].compactMap { $0 } + [event.message])
      .joined(separator: " ")
  }

  /// Banner Reconnect: connect again with the workspace connection (errors as a toast), with the
  /// password typed for it when it asks on connect (held through the loss: nothing is asked)
  func reconnectAfterConnectionLoss() async {
    guard var config = workspace.connectionConfig else { return }
    if config.askPasswordOnConnect, config.password.isEmpty, let typed = activeTypedPassword {
      config.password = typed
    }
    await reconnect(
      config, certificate: activeUnrememberedCertificate,
      sshCredential: activeUnrememberedSSHCredential)
  }

  /// The Reconnect with the unremembered secrets it started with (the connect clears the
  /// workspace's), so a changed SSH host key's Replace Pin can run it again.
  private func reconnect(
    _ config: ConnectionConfig, certificate: ClientCertificateStoreFactory.ConnectionMaterial?,
    sshCredential: SSHCredentialStoreFactory.ConnectionCredential?
  ) async {
    let scoped = certificate.map {
      ClientCertificateStoreFactory.ScopedMaterial(account: $0.account, material: $0.material)
    }
    let scopedSSH = sshCredential.map {
      SSHCredentialStoreFactory.ScopedSSHCredential(
        account: $0.account, credential: $0.credential)
    }
    defer {
      scoped?.clear()
      scopedSSH?.clear()
    }
    let lostMessage = connectionLostMessage
    connectionLostMessage = nil
    do {
      try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
        try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
          try await connect(config: config)
        }
      }
    } catch WorkspaceConnectError.unlockRequired {
      // The unlock was cancelled (or the Safe Mode unlock is pending): still disconnected, the
      // banner and its Reconnect stay
      connectionLostMessage = lostMessage
    } catch {
      let message = SSHHostKeyTrustCoordinator.shared.report(error) { [weak self] in
        Task {
          await self?.reconnect(config, certificate: certificate, sshCredential: sshCredential)
        }
      }
      WorkspaceWindowManager.shared.showToast("Reconnect failed: \(message)", type: .error)
    }
  }

  func dismissConnectionLost() {
    connectionLostMessage = nil
    if !connectionState.isConnected {
      activeUnrememberedCertificate = nil
      activeUnrememberedSSHCredential = nil
      dropTypedPassword()
    }
  }

  /// Drops an ask-on-connect connection's typed password from the workspace's configs (they
  /// hold it only while connected), and `activeTypedPassword` too unless `keepingHeldCopy` (a
  /// session loss, for the banner Reconnect).
  func dropTypedPassword(keepingHeldCopy: Bool = false) {
    if !keepingHeldCopy { activeTypedPassword = nil }
    if workspace.connectionConfig?.askPasswordOnConnect == true {
      workspace.connectionConfig?.password = ""
    }
    if editingConnectionConfig.askPasswordOnConnect { editingConnectionConfig.password = "" }
  }
}
