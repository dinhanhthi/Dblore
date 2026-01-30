//
//  RightSidebarOverlay.swift
//  SQLNotebook
//

import SwiftUI

/// Right sidebar that overlays the main content instead of pushing it
struct RightSidebarOverlay: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var width: CGFloat = 380

  private let minWidth: CGFloat = 320
  private let maxWidth: CGFloat = 600

  var body: some View {
    VStack(spacing: 0) {
      // Header with close button
      RightSidebarOverlayHeader(
        title: headerTitle,
        onClose: { workspaceManager.hideRightSidebar() }
      )

      // Content
      Group {
        if let content = workspaceManager.rightSidebarContent {
          rightSidebarContent(for: content)
        } else {
          EmptyView()
        }
      }
    }
    .frame(width: width)
    .background(Color.cardBackground)
    .overlay(alignment: .leading) {
      // Left edge border
      Rectangle()
        .fill(Color.border)
        .frame(width: 1)
    }
    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
    .overlay(alignment: .leading) {
      // Resize handle
      ResizeHandle(
        width: $width,
        minWidth: minWidth,
        maxWidth: maxWidth
      )
    }
  }

  private var headerTitle: String {
    guard let content = workspaceManager.rightSidebarContent else { return "" }
    switch content {
    case .connectionForm: return "Connection"
    case .connectionDetails: return "Connection Details"
    case .settings: return "Settings"
    case .jsonViewer: return "JSON Viewer"
    case .cellInfo: return "Cell Info"
    case .executedQuery: return "Executed Query"
    }
  }

  @ViewBuilder
  private func rightSidebarContent(for content: SidebarContent) -> some View {
    switch content {
    case .connectionForm:
      WorkspaceConnectionFormContent(workspaceManager: workspaceManager)

    case .connectionDetails:
      WorkspaceConnectionDetailsView(workspaceManager: workspaceManager)

    case .settings:
      WorkspaceSettingsContent(workspaceManager: workspaceManager)

    case .jsonViewer(let json, let path):
      JSONViewerContent(json: json, path: path, onSave: nil)

    case .cellInfo(
      let columnName, let columnType, let value, _, _, _,
      _, _):
      CellInfoContent(
        columnName: columnName,
        columnType: columnType,
        value: value,
        onSave: nil,
        isReadOnly: true
      )

    case .executedQuery(let query, let cellId, let limitWasCapped, let actualLimit):
      ExecutedQuerySidebarContent(
        query: query,
        cellId: cellId,
        limitWasCapped: limitWasCapped,
        actualLimit: actualLimit
      )
    }
  }
}

// MARK: - Header

struct RightSidebarOverlayHeader: View {
  let title: String
  let onClose: () -> Void

  var body: some View {
    HStack {
      Text(title)
        .font(.headline)
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
    .padding(.vertical, Spacing.sm)
    .background(Color.cardBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

// MARK: - Resize Handle

struct ResizeHandle: View {
  @Binding var width: CGFloat
  let minWidth: CGFloat
  let maxWidth: CGFloat

  @State private var isDragging = false

  var body: some View {
    Rectangle()
      .fill(Color.clear)
      .frame(width: 8)
      .contentShape(Rectangle())
      .cursor(.resizeLeftRight)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            isDragging = true
            // Dragging left = increase width, dragging right = decrease width
            let newWidth = width - value.translation.width
            width = min(max(newWidth, minWidth), maxWidth)
          }
          .onEnded { _ in
            isDragging = false
          }
      )
      .overlay {
        if isDragging {
          Rectangle()
            .fill(Color.accent.opacity(0.3))
            .frame(width: 2)
        }
      }
  }
}

// MARK: - Connection Form Content

struct WorkspaceConnectionFormContent: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var errorMessage: String?
  @State private var isConnecting = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Connection status
        if workspaceManager.connectionState == .connected {
          HStack {
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.green)
            Text("Connected")
              .foregroundColor(.foreground)
            Spacer()
            Button("Disconnect") {
              Task {
                await workspaceManager.disconnect()
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .padding()
          .background(Color.green.opacity(0.1))
          .cornerRadius(CornerRadius.md)
        }

        // Error message
        if let error = errorMessage {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.red)
            Text(error)
              .font(.caption)
              .foregroundColor(.red)
          }
          .padding()
          .background(Color.red.opacity(0.1))
          .cornerRadius(CornerRadius.md)
        }

        // Connection form fields
        ConnectionFormFields(config: $workspaceManager.editingConnectionConfig)

        // Connect button
        if workspaceManager.connectionState != .connected {
          HStack {
            Spacer()
            Button {
              connect()
            } label: {
              if isConnecting {
                ProgressView()
                  .scaleEffect(0.7)
              } else {
                Text("Connect")
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
          }
        }
      }
      .padding(Spacing.md)
    }
  }

  private func connect() {
    isConnecting = true
    errorMessage = nil

    Task {
      do {
        try await workspaceManager.connect(config: workspaceManager.editingConnectionConfig)
        workspaceManager.hideRightSidebar()
      } catch {
        errorMessage = error.localizedDescription
      }
      isConnecting = false
    }
  }
}

/// Simple connection form fields
struct ConnectionFormFields: View {
  @Binding var config: ConnectionConfig

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Database type
      Picker("Database", selection: $config.databaseType) {
        ForEach(DatabaseType.allCases, id: \.self) { type in
          Text(type.displayName).tag(type)
        }
      }

      if config.databaseType == .postgresql {
        // Host
        LabeledContent("Host") {
          TextField("localhost", text: $config.host)
            .textFieldStyle(.roundedBorder)
        }

        // Port
        LabeledContent("Port") {
          TextField("5432", value: $config.port, format: .number)
            .textFieldStyle(.roundedBorder)
        }

        // Database
        LabeledContent("Database") {
          TextField("database", text: $config.database)
            .textFieldStyle(.roundedBorder)
        }

        // Username
        LabeledContent("Username") {
          TextField("username", text: $config.username)
            .textFieldStyle(.roundedBorder)
        }

        // Password
        LabeledContent("Password") {
          SecureField("password", text: $config.password)
            .textFieldStyle(.roundedBorder)
        }

        // SSL Mode
        Picker("SSL Mode", selection: $config.sslMode) {
          ForEach(SSLMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
      }

      // Remember connection
      Toggle("Remember connection", isOn: $config.rememberConnection)
    }
  }
}

// MARK: - Connection Details View

struct WorkspaceConnectionDetailsView: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if let config = workspaceManager.workspace.connectionConfig {
          LabeledContent("Database Type", value: config.databaseType.displayName)
          LabeledContent("Host", value: config.host)
          LabeledContent("Port", value: "\(config.port)")
          LabeledContent("Database", value: config.database)
          LabeledContent("Username", value: config.username)
          LabeledContent("SSL Mode", value: config.sslMode.displayName)
        } else {
          Text("Not connected")
            .foregroundColor(.foregroundMuted)
        }
      }
      .padding(Spacing.md)
    }
  }
}
