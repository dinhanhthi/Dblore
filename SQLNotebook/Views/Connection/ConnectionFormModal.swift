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
  }
}

// MARK: - NotebookViewModel Connection Form Modal Extension

extension View {
  /// Shows a connection form modal bound to a NotebookViewModel
  func connectionFormModal(viewModel: NotebookViewModel) -> some View {
    self.connectionFormModal(
      isPresented: Binding(
        get: { viewModel.isConnectionFormModalVisible },
        set: { viewModel.isConnectionFormModalVisible = $0 }
      ),
      connectionConfig: Binding(
        get: { viewModel.editingConnectionConfig },
        set: { viewModel.editingConnectionConfig = $0 }
      ),
      onTestConnection: { _ in
        try await viewModel.testConnection()
      },
      onConnect: { _ in
        try await viewModel.connect()
      }
    )
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
