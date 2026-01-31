//
//  ConnectionInfoModal.swift
//  SQLNotebook
//

import SwiftUI

/// Modal wrapper for ConnectionInfoContent
/// Shows connection details and disconnect button when connected
struct ConnectionInfoModal: View {
  @Bindable var viewModel: NotebookViewModel
  @Binding var isPresented: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Header
      ConnectionInfoModalHeader(
        connectionConfig: viewModel.notebook.connectionConfig,
        onClose: { isPresented = false }
      )

      // Content
      ConnectionInfoContent(viewModel: viewModel)

      // Footer with Disconnect button
      ConnectionInfoModalFooter(
        onDisconnect: {
          viewModel.disconnect()
          isPresented = false
        }
      )
    }
    .frame(width: 380, height: 420)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.sm)
  }
}

// MARK: - Modal Header

struct ConnectionInfoModalHeader: View {
  let connectionConfig: ConnectionConfig?
  let onClose: () -> Void

  var body: some View {
    HStack {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "bolt.fill")
          .foregroundColor(.success)

        Text(headerTitle)
          .font(.subheading)
          .foregroundColor(.foreground)
      }

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

  private var headerTitle: String {
    if let config = connectionConfig, !config.name.isEmpty {
      return config.name
    }
    return "Connection Details"
  }
}

// MARK: - Modal Footer

struct ConnectionInfoModalFooter: View {
  let onDisconnect: () -> Void

  @State private var showDisconnectConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack {
        Spacer()

        Button(action: {
          showDisconnectConfirmation = true
        }) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "bolt.slash")
            Text("Disconnect")
          }
        }
        .buttonStyle(DangerButtonStyle())
        .confirmationDialog(
          "Disconnect from database?",
          isPresented: $showDisconnectConfirmation,
          titleVisibility: .visible
        ) {
          Button("Disconnect", role: .destructive) {
            onDisconnect()
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("This will close the database connection and you won't be able to run queries.")
        }
      }
      .padding(Spacing.md)
    }
    .background(Color.cardBackground)
  }
}

// MARK: - View Extension for Connection Info Modal

extension View {
  /// Shows a connection info modal
  func connectionInfoModal(
    isPresented: Binding<Bool>,
    viewModel: NotebookViewModel
  ) -> some View {
    self.sheet(isPresented: isPresented) {
      ConnectionInfoModal(
        viewModel: viewModel,
        isPresented: isPresented
      )
    }
  }
}

// MARK: - NotebookViewModel Connection Info Modal Extension

extension View {
  /// Shows a connection info modal bound to a NotebookViewModel
  func connectionInfoModal(viewModel: NotebookViewModel) -> some View {
    self.connectionInfoModal(
      isPresented: Binding(
        get: { viewModel.isConnectionInfoModalVisible },
        set: { viewModel.isConnectionInfoModalVisible = $0 }
      ),
      viewModel: viewModel
    )
  }
}

// MARK: - WorkspaceManager Connection Info Modal

/// Modal for showing connection info in workspace context
struct WorkspaceConnectionInfoModal: View {
  @Bindable var workspaceManager: WorkspaceManager
  @Binding var isPresented: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Header
      ConnectionInfoModalHeader(
        connectionConfig: workspaceManager.workspace.connectionConfig,
        onClose: { isPresented = false }
      )

      // Content
      WorkspaceConnectionInfoContent(workspaceManager: workspaceManager)

      // Footer with Disconnect button
      ConnectionInfoModalFooter(
        onDisconnect: {
          Task {
            await workspaceManager.disconnect()
          }
          isPresented = false
        }
      )
    }
    .frame(width: 380, height: 420)
    .background(Color.cardBackground)
    .cornerRadius(CornerRadius.sm)
  }
}

// MARK: - Workspace Connection Info Content

struct WorkspaceConnectionInfoContent: View {
  @Bindable var workspaceManager: WorkspaceManager

  private var config: ConnectionConfig? {
    workspaceManager.workspace.connectionConfig
  }

  var body: some View {
    if let config {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          // Connection name (if provided)
          if !config.name.isEmpty {
            infoRow(label: "Connection Name", value: config.name)
          }

          infoRow(label: "Host", value: config.host)
          infoRow(label: "Port", value: String(config.port))
          infoRow(label: "Database", value: config.database)
          infoRow(label: "Username", value: config.username)
          infoRow(label: "SSL Mode", value: config.sslMode.displayName)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } else {
      VStack(spacing: Spacing.sm) {
        Image(systemName: "cable.connector.slash")
          .font(.system(size: 32))
          .foregroundColor(.foregroundMuted)

        Text("No connection configured")
          .font(.caption)
          .foregroundColor(.foregroundMuted)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func infoRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
    }
  }
}

// MARK: - WorkspaceManager Connection Info Modal Extension

extension View {
  /// Shows a connection info modal bound to a WorkspaceManager
  func connectionInfoModal(workspaceManager: WorkspaceManager) -> some View {
    self.sheet(
      isPresented: Binding(
        get: { workspaceManager.isConnectionInfoModalVisible },
        set: { workspaceManager.isConnectionInfoModalVisible = $0 }
      )
    ) {
      WorkspaceConnectionInfoModal(
        workspaceManager: workspaceManager,
        isPresented: Binding(
          get: { workspaceManager.isConnectionInfoModalVisible },
          set: { workspaceManager.isConnectionInfoModalVisible = $0 }
        )
      )
    }
  }
}

// MARK: - Preview

#Preview("Connection Info Modal") {
  @Previewable @State var viewModel: NotebookViewModel = {
    let vm = NotebookViewModel()
    vm.notebook.connectionConfig = ConnectionConfig(
      host: "db.example.com",
      port: 5432,
      database: "my_database",
      username: "admin_user",
      password: "secret123",
      sslMode: .require,
      protectionLevel: .readOnly,
      name: "Production DB"
    )
    vm.connectionState = .connected
    return vm
  }()

  Color.appBackground
    .sheet(isPresented: .constant(true)) {
      ConnectionInfoModal(
        viewModel: viewModel,
        isPresented: .constant(true)
      )
    }
    .frame(width: 600, height: 500)
    .preferredColorScheme(.dark)
}
