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
  @State private var draftConnectionName = ""

  private var workspace: Workspace {
    workspaceManager.workspace
  }

  private var displayName: String {
    !workspace.isSaved && workspace.name == "Untitled" ? "Untitled Workspace" : workspace.name
  }

  private var canApply: Bool {
    switch workspaceManager.workspaceInfoTab {
    case .workspace:
      let trimmed = draftWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && trimmed != displayName
    case .connection:
      guard workspace.connectionConfig != nil else { return false }
      let trimmed = draftConnectionName.trimmingCharacters(in: .whitespacesAndNewlines)
      let current = workspace.connectionConfig?.name ?? ""
      return !trimmed.isEmpty && trimmed != current
    }
  }

  private var showsFooter: Bool {
    workspaceManager.workspaceInfoTab == .workspace || workspace.connectionConfig != nil
  }

  private var showsDisconnect: Bool {
    workspaceManager.workspaceInfoTab == .connection && workspaceManager.connectionState.isConnected
  }

  var body: some View {
    GenericModal(
      title: "Details",
      titleIcon: "info.circle",
      width: 420,
      height: 520,
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
          Button("Apply") { applyName() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canApply)
          Spacer()
          if showsDisconnect {
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
        }
      }
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
        ScrollView {
          VStack(spacing: Spacing.sm) {
            band(0) {
              nameField(title: "Name", text: $draftConnectionName, prompt: "Connection name")
            }
            band(1) {
              infoRow(
                label: "Status",
                value: FooterView.connectionStatusText(
                  for: workspaceManager.connectionState,
                  config: workspace.connectionConfig)
              )
              if let config = workspace.connectionConfig {
                infoRow(label: "Type", value: config.databaseType.displayName)
              }
            }
            band(2) {
              connectionTargetRows
            }
            band(3) {
              if let config = workspace.connectionConfig {
                infoRow(
                  label: "Protection",
                  value: ConnectionSafetyBadge(config: config).protectionLabel)
                infoRow(label: "Safe Mode", value: effectiveSafeMode(config).displayName)
              }
              if workspaceManager.connectionState.isConnected {
                if workspaceManager.isLoadingSchema && workspaceManager.databaseTables.isEmpty {
                  infoRow(label: "Schema", value: "Loading...")
                } else {
                  infoRow(label: "Tables", value: "\(workspaceManager.databaseTables.count)")
                  infoRow(label: "Views", value: "\(workspaceManager.databaseViews.count)")
                }
              }
            }
          }
          .padding(Spacing.md)
        }
      }
    }
  }

  @ViewBuilder
  private var connectionTargetRows: some View {
    if let config = workspace.connectionConfig {
      if config.databaseType.capabilities.usesNetwork {
        infoRow(label: "Host", value: display(config.host))
        infoRow(label: "Port", value: String(config.port))
        infoRow(label: "Database", value: display(config.database))
        infoRow(label: "Username", value: display(config.username))
        infoRow(label: "SSL Mode", value: config.sslMode.displayName)
      } else {
        infoRow(label: "Database file", value: display(config.database))
        if config.readOnlyFile {
          infoRow(label: "File access", value: "Read-only")
        }
      }
    }
  }

  private var tabsValue: String {
    let tabs = workspaceManager.tabs
    let unsaved = tabs.filter(\.isDirty).count
    if unsaved == 0 { return "\(tabs.count)" }
    return "\(tabs.count) (\(unsaved) unsaved)"
  }

  private func effectiveSafeMode(_ config: ConnectionConfig) -> SafeMode {
    config.safeMode ?? AppSettings.shared.safeMode
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
    draftConnectionName = workspace.connectionConfig?.name ?? ""
  }

  private func applyName() {
    switch workspaceManager.workspaceInfoTab {
    case .workspace:
      workspaceManager.renameWorkspace(to: draftWorkspaceName)
      draftWorkspaceName = displayName
    case .connection:
      workspaceManager.renameConnection(to: draftConnectionName)
      draftConnectionName = workspace.connectionConfig?.name ?? ""
    }
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

  private func infoRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundSubtle)

      Text(value)
        .font(.mono)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
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
        safeMode: .alertRead
      )
      workspaceManager.connectionState = .connected
    }
    .modalOverlay(isPresented: $isPresented) {
      WorkspaceInfoModal(workspaceManager: workspaceManager, isPresented: $isPresented)
    }
}
