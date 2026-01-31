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
    VStack(spacing: 0) {
      // Header
      ConnectionFormModalHeader(onClose: { isPresented = false })

      // Content
      ConnectionFormContent(
        connectionConfig: $connectionConfig,
        onTestConnection: onTestConnection,
        onConnect: onConnect,
        onConnectionSuccess: { isPresented = false }
      )
    }
    .frame(width: 420, height: 580)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.sm)
  }
}

// MARK: - Modal Header

struct ConnectionFormModalHeader: View {
  let onClose: () -> Void

  var body: some View {
    HStack {
      Text("Connect to Database")
        .font(.subheading)
        .foregroundColor(.foreground)

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

// MARK: - View Extension for Connection Form Modal

extension View {
  /// Shows a connection form modal
  func connectionFormModal(
    isPresented: Binding<Bool>,
    connectionConfig: Binding<ConnectionConfig>,
    onTestConnection: ((ConnectionConfig) async throws -> Bool)? = nil,
    onConnect: ((ConnectionConfig) async throws -> Void)? = nil
  ) -> some View {
    self.sheet(isPresented: isPresented) {
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
