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
  /// or when the actor already holds a newer connection.
  func connectionWasLost(_ event: SessionLostEvent) async {
    guard connectionState.isConnected, await !connectionManager.isConnected else { return }
    await performDisconnect()
    connectionLostMessage = event.message
  }

  /// Banner Reconnect: connect again with the workspace connection (errors as a toast)
  func reconnectAfterConnectionLoss() async {
    guard let config = workspace.connectionConfig else { return }
    connectionLostMessage = nil
    do {
      try await connect(config: config)
    } catch {
      WorkspaceWindowManager.shared.showToast(
        "Reconnect failed: \(error.localizedDescription)", type: .error)
    }
  }

  func dismissConnectionLost() {
    connectionLostMessage = nil
  }
}
