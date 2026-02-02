//
//  ConnectionInfoModal.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Disconnect Button

struct ConnectionInfoDisconnectButton: View {
  let onDisconnect: () -> Void

  @State private var showDisconnectConfirmation = false

  var body: some View {
    Button(action: {
      showDisconnectConfirmation = true
    }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "bolt.slash")
        Text("Disconnect")
      }
    }
    .buttonStyle(DangerButtonStyle())
  }
}

// MARK: - WorkspaceManager Connection Info Modal

/// Modal for showing connection info in workspace context
struct WorkspaceConnectionInfoModal: View {
  @Bindable var workspaceManager: WorkspaceManager
  @Binding var isPresented: Bool

  private var headerTitle: String {
    if let config = workspaceManager.workspace.connectionConfig, !config.name.isEmpty {
      return config.name
    }
    return "Connection Details"
  }

  var body: some View {
    GenericModal(
      title: headerTitle,
      titleIcon: "bolt.fill",
      titleIconColor: .success,
      width: 380,
      height: 420,
      isPresented: $isPresented
    ) {
      WorkspaceConnectionInfoContent(workspaceManager: workspaceManager)
    } footer: {
      GenericModalFooter {
        Spacer()
        ConnectionInfoDisconnectButton(
          onDisconnect: {
            Task {
              await workspaceManager.disconnect()
            }
            isPresented = false
          }
        )
      }
    }
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
  /// Shows a connection info modal bound to a WorkspaceManager with zoom animation
  func connectionInfoModal(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.isConnectionInfoModalVisible },
      set: { workspaceManager.isConnectionInfoModalVisible = $0 }
    )

    return modalOverlay(isPresented: isPresented) {
      WorkspaceConnectionInfoModal(
        workspaceManager: workspaceManager,
        isPresented: isPresented
      )
    }
  }
}

// MARK: - Preview

#Preview("Connection Info Modal - Workspace") {
  @Previewable @State var workspaceManager = WorkspaceManager(workspace: Workspace())

  Color.appBackground
    .onAppear {
      workspaceManager.workspace.connectionConfig = ConnectionConfig(
        host: "db.example.com",
        port: 5432,
        database: "my_database",
        username: "admin_user",
        password: "secret123",
        sslMode: .require,
        protectionLevel: .readOnly,
        name: "Production DB"
      )
    }
    .sheet(isPresented: .constant(true)) {
      WorkspaceConnectionInfoModal(
        workspaceManager: workspaceManager,
        isPresented: .constant(true)
      )
    }
    .frame(width: 600, height: 500)
    .preferredColorScheme(.dark)
}
