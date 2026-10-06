//
//  WorkspaceInfoModal.swift
//  Dblore
//

import SwiftUI

// MARK: - Details Modal

/// Workspace and connection details. Two tabs; each section is a full-width band.
struct WorkspaceInfoModal: View {
  @Bindable var workspaceManager: WorkspaceManager
  @Binding var isPresented: Bool
  @State private var draftWorkspaceName = ""
  /// The connection form's values when the modal opened (what the live connection uses)
  @State private var appliedConfig: ConnectionConfig?

  private var workspace: Workspace {
    workspaceManager.workspace
  }

  private var displayName: String {
    !workspace.isSaved && workspace.name == "Untitled" ? "Untitled Workspace" : workspace.name
  }

  private var canApply: Bool {
    let trimmed = draftWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != displayName
  }

  /// An unsaved workspace has no file yet, so the Workspace tab offers Save instead of Apply
  private var showsSave: Bool {
    !workspace.isSaved
  }

  /// The Connections tab is the connection form, which has its own Test / Save buttons
  private var showsFooter: Bool {
    workspaceManager.workspaceInfoTab == .workspace
  }

  private var isConnectionForm: Bool {
    workspaceManager.workspaceInfoTab == .connection && workspace.connectionConfig != nil
  }

  var body: some View {
    GenericModal(
      title: "Details",
      titleIcon: "info.circle",
      width: isConnectionForm ? 440 : 420,
      height: isConnectionForm ? 640 : 520,
      isPresented: $isPresented
    ) {
      VStack(spacing: 0) {
        CapsuleTabPicker(
          selection: $workspaceManager.workspaceInfoTab,
          tabs: Array(WorkspaceInfoTab.allCases),
          height: 28
        )
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)

        Group {
          switch workspaceManager.workspaceInfoTab {
          case .workspace:
            workspacePage
          case .connection:
            connectionPage
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .onAppear(perform: resetDrafts)
    } footer: {
      if showsFooter {
        GenericModalFooter {
          Spacer()
          if showsSave {
            Button("Save") { saveWorkspace() }
              .buttonStyle(PrimaryButtonStyle())
          } else {
            Button("Apply") { applyName() }
              .buttonStyle(PrimaryButtonStyle())
              .disabled(!canApply)
          }
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: { workspaceManager.pendingWeakeningConnect != nil },
        set: { if !$0 { workspaceManager.cancelPendingWeakeningConnect() } }
      )
    ) {
      WorkspaceConnectUnlockSheet(
        workspaceManager: workspaceManager, onConnected: { isPresented = false })
    }
  }

  private var workspacePage: some View {
    ScrollView {
      VStack(spacing: Spacing.sm) {
        band(0) {
          nameField(title: "Name", text: $draftWorkspaceName, prompt: "Workspace name")
        }
        band(1) {
          infoRow(label: "File", value: workspace.fileURL?.path ?? "Not saved")
          infoRow(label: "Created", value: formatted(workspace.createdAt))
          infoRow(label: "Last opened", value: formatted(workspace.lastOpenedAt))
          if workspace.isSaved {
            infoRow(
              label: "Changes",
              value: workspaceManager.isDirty ? "Unsaved changes" : "Saved")
          }
        }
        band(2) {
          infoRow(label: "Tabs", value: tabsValue)
          infoRow(label: "Favorites", value: "\(workspace.favorites.items.count)")
          infoRow(label: "Folders", value: "\(workspace.favorites.folders.count)")
        }
      }
      .padding(Spacing.md)
    }
  }

  private var connectionPage: some View {
    Group {
      if workspace.connectionConfig == nil {
        VStack(spacing: Spacing.sm) {
          Image(systemName: "cable.connector.slash")
            .font(.system(size: 32))
            .foregroundColor(.foregroundMuted)
          Text("No connection configured")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: 0) {
          connectionStatusBand
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)

          // The same form as Add connection, so every value set there is shown and editable
          ConnectionFormContent(
            connectionConfig: $workspaceManager.editingConnectionConfig,
            onTestConnection: { config in
              try await workspaceManager.connectionManager.testConnection(config: config)
            },
            onConnect: { config in
              try await workspaceManager.connect(config: config)
            },
            onConnectionSuccess: { isPresented = false },
            submitTitle: workspaceManager.connectionState.isConnected
              ? "Save & Reconnect" : "Save & Connect",
            showsRecentHistory: false,
            unrememberedCertificate: { workspaceManager.activeUnrememberedCertificate },
            unchangedFrom: workspaceManager.connectionState.isConnected ? appliedConfig : nil,
            footerLeading: workspaceManager.connectionState.isConnected
              ? AnyView(disconnectButton) : nil
          )
        }
      }
    }
  }

  private var disconnectButton: some View {
    Button {
      Task {
        if await workspaceManager.disconnect() {
          isPresented = false
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "bolt.slash")
        Text("Disconnect")
      }
    }
    .buttonStyle(DangerButtonStyle())
  }

  private var connectionStatusBand: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        infoRow(
          label: "Status",
          value: FooterView.connectionStatusText(
            for: workspaceManager.connectionState, config: workspace.connectionConfig),
          help: FooterView.connectionFailureDetail(for: workspaceManager.connectionState)
        )
        if workspaceManager.connectionState.isConnected {
          if workspaceManager.isLoadingSchema && workspaceManager.databaseTables.isEmpty {
            infoRow(label: "Schema", value: "Loading...")
          } else {
            infoRow(
              label: "Schema",
              value:
                "\(workspaceManager.databaseTables.count) tables, \(workspaceManager.databaseViews.count) views"
            )
          }
        }
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: CornerRadius.lg).fill(Color.cardHeaderBackground))
  }

  private var tabsValue: String {
    let tabs = workspaceManager.tabs
    let unsaved = tabs.filter(\.isDirty).count
    if unsaved == 0 { return "\(tabs.count)" }
    return "\(tabs.count) (\(unsaved) unsaved)"
  }

  private func display(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "—" : trimmed
  }

  private func formatted(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private func resetDrafts() {
    draftWorkspaceName = displayName
    appliedConfig = workspaceManager.editingConnectionConfig
  }

  /// Keeps the typed name, then saves; the save panel is pre-filled with that name
  private func saveWorkspace() {
    workspaceManager.renameWorkspace(to: draftWorkspaceName)
    Task {
      try? await workspaceManager.saveWorkspace()
      draftWorkspaceName = displayName
    }
  }

  private func applyName() {
    workspaceManager.renameWorkspace(to: draftWorkspaceName)
    draftWorkspaceName = displayName
  }

  private func nameField(title: String, text: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      TextField(prompt, text: text)
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .onSubmit {
          if canApply { applyName() }
        }
    }
  }

  private func band<Content: View>(
    _ index: Int, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      content()
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.lg)
        .fill(index.isMultiple(of: 2) ? Color.cardHeaderBackground : Color.foreground.opacity(0.06))
    )
  }

  @ViewBuilder
  private func infoRow(label: String, value: String, help: String? = nil) -> some View {
    let row = VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    if let help {
      row.help(help)
    } else {
      row
    }
  }
}

// MARK: - View Extension

extension View {
  /// Shows the details modal bound to a WorkspaceManager
  func workspaceInfoModal(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.isWorkspaceInfoModalVisible },
      set: { workspaceManager.isWorkspaceInfoModalVisible = $0 }
    )

    return modalOverlay(isPresented: isPresented) {
      WorkspaceInfoModal(workspaceManager: workspaceManager, isPresented: isPresented)
    }
  }
}

// MARK: - Preview

#Preview("Details") {
  @Previewable @State var workspaceManager = WorkspaceManager(workspace: Workspace())
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 640, height: 700)
    .onAppear {
      workspaceManager.workspace.name = "Analytics"
      workspaceManager.workspace.fileURL = URL(fileURLWithPath: "/Users/me/Analytics.sqlws")
      workspaceManager.workspace.connectionConfig = ConnectionConfig(
        host: "db.example.com",
        port: 5432,
        database: "analytics",
        username: "reader",
        sslMode: .require,
        protectionLevel: .readOnly,
        name: "Analytics reader",
        safeMode: .alertRead,
        protectedMode: false
      )
      workspaceManager.connectionState = .connected
    }
    .modalOverlay(isPresented: $isPresented) {
      WorkspaceInfoModal(workspaceManager: workspaceManager, isPresented: $isPresented)
    }
}
