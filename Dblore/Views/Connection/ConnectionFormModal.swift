//
//  ConnectionFormModal.swift
//  Dblore
//

import SwiftUI

/// Right-sidebar wrapper for ConnectionFormContent
/// Used consistently across the app for showing connection forms
struct ConnectionFormModal: View {
  @Binding var isPresented: Bool
  @Binding var connectionConfig: ConnectionConfig

  var title: String = "Connect to Database"
  var submitTitle: String = "Connect"
  var showsRecentHistory: Bool = true
  var onTestConnection: ((ConnectionConfig) async throws -> Bool)?
  var onConnect:
    ((ConnectionConfig, _ aiFieldsEdited: Bool, _ maskRulesEdited: Bool) async throws -> Void)?
  var unrememberedCertificate: (() -> ClientCertificateStoreFactory.ConnectionMaterial?)?
  var unrememberedSSHCredential: (() -> SSHCredentialStoreFactory.ConnectionCredential?)?
  var unlockConnectError: Binding<String?>?
  /// Opens Settings > Plugins (the missing-plugin row and connect errors offer it).
  var onOpenPluginSettings: @MainActor () -> Void = ConnectionErrorAction.postOpenPluginSettings
  /// See `ConnectionFormContent.draftGeneration`.
  var draftGeneration: Int = 0
  /// See `ConnectionFormContent.opensOnDraft`.
  var opensOnDraft: Bool = false

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: title, verticalPadding: Spacing.md, onClose: { isPresented = false }
      ) {
        databaseTypeMenu
      }
      if connectionConfig.databaseType.capabilities.requiresPlugin && !isEngineInstalled {
        missingPluginRow
      }
      ConnectionFormContent(
        connectionConfig: $connectionConfig,
        onTestConnection: onTestConnection,
        onConnect: onConnect,
        onConnectionSuccess: { isPresented = false },
        submitTitle: submitTitle,
        showsRecentHistory: showsRecentHistory,
        unrememberedCertificate: unrememberedCertificate,
        unrememberedSSHCredential: unrememberedSSHCredential,
        unlockConnectError: unlockConnectError,
        onOpenPluginSettings: onOpenPluginSettings,
        draftGeneration: draftGeneration,
        opensOnDraft: opensOnDraft
      )
    }
    .background(Color.cardBackground)
  }

  /// Width of the right sidebar the form opens in.
  static let panelWidth: CGFloat = 440

  /// Engine picker, sitting on the right of the title and before the close button.
  private var databaseTypeMenu: some View {
    let registry = PluginRegistry.shared
    let types = Self.pickerTypes(
      current: connectionConfig.databaseType,
      isPluginInstalled: { registry.isEngineInstalledOrPending($0) })
    // A capsule like the form's dropdowns, so it is white on the header in light
    return Menu {
      Picker("Database", selection: engineChoice) {
        ForEach(EnginePickerChoice.choices(for: types), id: \.self) { choice in
          Text(choice.displayName).tag(choice)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HeaderDropdownLabel(title: connectionConfig.engineDisplayName)
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
  }

  /// Sets engine, flavor and port in one change (`applying`). Another engine resets the form
  /// (`ConnectionFormContent`), keeping the preset.
  private var engineChoice: Binding<EnginePickerChoice> {
    Binding(
      get: { EnginePickerChoice(connectionConfig) },
      set: { choice in
        guard choice != EnginePickerChoice(connectionConfig) else { return }
        connectionConfig = Self.applying(choice, to: connectionConfig)
      })
  }

  /// `config` on `choice`. On the same engine a port of the user's own stays (the same endpoint
  /// is the same saved row); only the previous choice's default port moves to the new one's.
  nonisolated static func applying(
    _ choice: EnginePickerChoice, to config: ConnectionConfig
  ) -> ConnectionConfig {
    let previous = EnginePickerChoice(config)
    var config = config
    if choice.databaseType != previous.databaseType || config.port == previous.defaultPort {
      config.port = choice.defaultPort
    }
    config.databaseType = choice.databaseType
    config.flavor = choice.flavor
    return config
  }

  /// Read in `body`, so the picker and the missing-plugin row follow install and remove. While
  /// the launch check hashes the file, a present file counts as installed.
  private var isEngineInstalled: Bool {
    PluginRegistry.shared.isEngineInstalledOrPending(connectionConfig.databaseType)
  }

  private var missingPluginRow: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text(Self.missingPluginText(connectionConfig.databaseType))
        .foregroundColor(.warning)
      Spacer(minLength: Spacing.sm)
      Button("Install…", action: onOpenPluginSettings)
        .buttonStyle(.link)
        .linkPointer()
    }
    .font(.caption)
    .padding(Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.warning.opacity(0.1))
    )
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.sm)
  }

  /// "<plugin> plugin not installed", for the connection form and the workspace info.
  nonisolated static func missingPluginText(_ type: DatabaseType) -> String {
    "\(PluginDisplayInfo.forType(type).name) plugin not installed"
  }

  /// Picker engines. The engine of the connection being edited stays listed even when its
  /// plugin is missing, so the picker never shows an empty selection.
  nonisolated static func pickerTypes(
    current: DatabaseType,
    isPluginInstalled: (DatabaseType) -> Bool
  ) -> [DatabaseType] {
    DatabaseType.connectionPickerTypes(
      isPluginInstalled: { $0 == current || isPluginInstalled($0) })
  }
}

// MARK: - Connect Error Action

/// The button a connect error offers next to its message.
nonisolated enum ConnectionErrorAction: Equatable, Sendable {
  /// The engine's plugin is not installed: open Settings > Plugins.
  case openPluginSettings

  /// The button title for a connection to `type`.
  func title(for type: DatabaseType) -> String {
    switch self {
    case .openPluginSettings: "Install \(PluginDisplayInfo.forType(type).name) Plugin"
    }
  }

  /// `DatabaseError.engineUnavailable`, directly or wrapped in another error's message (catalog
  /// fetches wrap it in `queryFailed`).
  static func action(for error: any Error) -> ConnectionErrorAction? {
    if case DatabaseError.engineUnavailable(let type) = error {
      return type.capabilities.requiresPlugin ? .openPluginSettings : nil
    }
    return action(forMessage: error.localizedDescription)
  }

  /// Same check on an error message already shown as text (the form keeps only the message).
  static func action(forMessage message: String) -> ConnectionErrorAction? {
    let missing = DatabaseType.allCases.filter(\.capabilities.requiresPlugin)
    let hit = missing.contains { type in
      DatabaseError.engineUnavailable(type).errorDescription.map(message.contains) ?? false
    }
    return hit ? .openPluginSettings : nil
  }

  /// Asks the key workspace window to open Settings > Plugins.
  @MainActor
  static func postOpenPluginSettings() {
    NotificationCenter.default.post(
      name: .openSettings,
      object: nil,
      userInfo: [SettingsPage.userInfoKey: SettingsPage.plugins.rawValue]
    )
  }
}

// MARK: - View Extension for Connection Form Modal

extension View {
  /// Shows the connection form in a right sidebar that slides in from the trailing edge
  func connectionFormModal(
    isPresented: Binding<Bool>,
    connectionConfig: Binding<ConnectionConfig>,
    title: String = "Connect to Database",
    submitTitle: String = "Connect",
    showsRecentHistory: Bool = true,
    onTestConnection: ((ConnectionConfig) async throws -> Bool)? = nil,
    onConnect: (
      (ConnectionConfig, _ aiFieldsEdited: Bool, _ maskRulesEdited: Bool) async throws -> Void
    )? = nil,
    unrememberedCertificate: (() -> ClientCertificateStoreFactory.ConnectionMaterial?)? = nil,
    unrememberedSSHCredential: (() -> SSHCredentialStoreFactory.ConnectionCredential?)? = nil,
    unlockConnectError: Binding<String?>? = nil,
    onOpenPluginSettings: @escaping @MainActor () -> Void = ConnectionErrorAction
      .postOpenPluginSettings,
    draftGeneration: Int = 0,
    opensOnDraft: Bool = false
  ) -> some View {
    sidePanelOverlay(isPresented: isPresented, width: ConnectionFormModal.panelWidth) {
      ConnectionFormModal(
        isPresented: isPresented,
        connectionConfig: connectionConfig,
        title: title,
        submitTitle: submitTitle,
        showsRecentHistory: showsRecentHistory,
        onTestConnection: onTestConnection,
        onConnect: onConnect,
        unrememberedCertificate: unrememberedCertificate,
        unrememberedSSHCredential: unrememberedSSHCredential,
        unlockConnectError: unlockConnectError,
        onOpenPluginSettings: onOpenPluginSettings,
        draftGeneration: draftGeneration,
        opensOnDraft: opensOnDraft
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
      onTestConnection: { config in
        try await workspaceManager.testConnection(config: config)
      },
      onConnect: { config, aiFieldsEdited, maskRulesEdited in
        try await workspaceManager.connect(
          config: config, aiFieldsEdited: aiFieldsEdited, maskRulesEdited: maskRulesEdited,
          fromForm: true, picksEngine: true)
      },
      unrememberedCertificate: { workspaceManager.activeUnrememberedCertificate },
      unrememberedSSHCredential: { workspaceManager.activeUnrememberedSSHCredential },
      unlockConnectError: Binding(
        get: { workspaceManager.lastUnlockConnectError },
        set: { workspaceManager.lastUnlockConnectError = $0 }
      ),
      draftGeneration: workspaceManager.connectionFormDraftGeneration,
      opensOnDraft: workspaceManager.connectionFormOpensOnDraft
    )
    .sheet(
      isPresented: Binding(
        get: { workspaceManager.pendingWeakeningConnect != nil },
        set: { if !$0 { workspaceManager.cancelPendingWeakeningConnect() } }
      )
    ) {
      WorkspaceConnectUnlockSheet(
        workspaceManager: workspaceManager,
        onConnected: { workspaceManager.isConnectionFormModalVisible = false })
    }
  }
}

/// Safe Mode unlock before connecting to the same database with weaker safety settings.
/// Cancel: nothing connects, the form keeps its values. Unlock: connect, then close the form.
struct WorkspaceConnectUnlockSheet: View {
  let workspaceManager: WorkspaceManager
  /// Runs after the held connect succeeds (closes the form that started it).
  var onConnected: () -> Void

  @State private var isConnecting = false

  private let message =
    "Safe Mode requires verification to reconnect to this database with weaker protection or Safe Mode settings."

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
    Task { @MainActor in
      // A failure closes this sheet; the form shows it inline (plus the changed-key alert)
      if await workspaceManager.completePendingWeakeningConnectReportingFailure() {
        onConnected()
      }
      isConnecting = false
    }
  }
}

// MARK: - Preview

#Preview("Connection Form Modal") {
  @Previewable @State var isPresented = true
  @Previewable @State var config = ConnectionFormContent.newFormDraft()

  Color.appBackground
    .frame(width: 800, height: 700)
    .sidePanelOverlay(isPresented: $isPresented, width: ConnectionFormModal.panelWidth) {
      ConnectionFormModal(
        isPresented: $isPresented,
        connectionConfig: $config,
        onTestConnection: { _ in true },
        onConnect: { _, _, _ in }
      )
    }
}
