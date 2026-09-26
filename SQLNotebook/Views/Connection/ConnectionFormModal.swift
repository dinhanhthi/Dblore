//
//  ConnectionFormModal.swift
//  SQLNotebook
//

import SwiftUI

/// Modal wrapper for ConnectionFormContent
/// Used consistently across the app for showing connection forms
struct ConnectionFormModal: View {
  @Binding var isPresented: Bool
  @Binding var connectionConfig: ConnectionConfig

  var onTestConnection: ((ConnectionConfig) async throws -> Bool)?
  var onConnect: ((ConnectionConfig) async throws -> Void)?

  var body: some View {
    GenericModal(
      title: "Connect to Database",
      width: 420,
      height: 580,
      isPresented: $isPresented
    ) {
      ConnectionFormContent(
        connectionConfig: $connectionConfig,
        onTestConnection: onTestConnection,
        onConnect: onConnect,
        onConnectionSuccess: { isPresented = false }
      )
    }
  }
}

// MARK: - View Extension for Connection Form Modal

extension View {
  /// Shows a connection form modal with zoom animation from center
  func connectionFormModal(
    isPresented: Binding<Bool>,
    connectionConfig: Binding<ConnectionConfig>,
    onTestConnection: ((ConnectionConfig) async throws -> Bool)? = nil,
    onConnect: ((ConnectionConfig) async throws -> Void)? = nil
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
      ConnectionFormModal(
        isPresented: isPresented,
        connectionConfig: connectionConfig,
        onTestConnection: onTestConnection,
        onConnect: onConnect
      )
    }
  }
}

// MARK: - WorkspaceManager Connection Form Modal Extension

extension View {
  /// Shows a connection form modal bound to a WorkspaceManager
  func connectionFormModal(workspaceManager: WorkspaceManager) -> some View {
    self.connectionFormModal(
      isPresented: Binding(
        get: { workspaceManager.isConnectionFormModalVisible },
        set: { workspaceManager.isConnectionFormModalVisible = $0 }
      ),
      connectionConfig: Binding(
        get: { workspaceManager.editingConnectionConfig },
        set: { workspaceManager.editingConnectionConfig = $0 }
      ),
      onTestConnection: { _ in
        try await workspaceManager.testConnection()
      },
      onConnect: { config in
        try await workspaceManager.connect(config: config)
      }
    )
    .sheet(
      isPresented: Binding(
        get: { workspaceManager.pendingWeakeningConnect != nil },
        set: { if !$0 { workspaceManager.cancelPendingWeakeningConnect() } }
      )
    ) {
      WorkspaceConnectUnlockSheet(workspaceManager: workspaceManager)
    }
  }
}

/// Safe Mode unlock before connecting to the same database with weaker safety settings.
/// Cancel: nothing connects, the form keeps its values. Unlock: connect, then close the form.
private struct WorkspaceConnectUnlockSheet: View {
  let workspaceManager: WorkspaceManager

  @State private var isConnecting = false
  @State private var connectError: String?

  private var message: String {
    let base =
      "Safe Mode requires verification to reconnect to this database with weaker protection or Safe Mode settings."
    guard let connectError else { return base }
    return "Connection failed: \(connectError)\n\nVerify again to retry."
  }

  var body: some View {
    if isConnecting {
      ProgressView("Connecting...")
        .padding(Spacing.xl)
        .frame(width: 350)
        .background(Color.appBackground)
    } else {
      SafeModeUnlockSheet(
        message: message,
        biometricReason: "Reconnect with weaker protection",
        // The current connection's password, never the one typed into the form
        storedDatabasePassword: workspaceManager.workspace.connectionConfig?.password,
        onUnlock: connect,
        onCancel: { workspaceManager.cancelPendingWeakeningConnect() })
    }
  }

  private func connect() {
    guard !isConnecting else { return }
    isConnecting = true
    connectError = nil
    Task { @MainActor in
      do {
        try await workspaceManager.completePendingWeakeningConnect()
        workspaceManager.isConnectionFormModalVisible = false
      } catch {
        connectError = error.localizedDescription
      }
      isConnecting = false
    }
  }
}

// MARK: - Preview

#Preview("Connection Form Modal") {
  @Previewable @State var isPresented = true
  @Previewable @State var config = ConnectionConfig()

  Color.appBackground
    .frame(width: 800, height: 700)
    .overlay {
      ZStack {
        if isPresented {
          Color.black.opacity(0.4)
            .ignoresSafeArea()

          ConnectionFormModal(
            isPresented: $isPresented,
            connectionConfig: $config,
            onTestConnection: { _ in true },
            onConnect: { _ in }
          )
        }
      }
    }
}
