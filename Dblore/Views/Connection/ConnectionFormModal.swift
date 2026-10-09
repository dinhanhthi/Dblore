//
//  ConnectionFormModal.swift
//  Dblore
//

import SwiftUI

/// Modal wrapper for ConnectionFormContent
/// Used consistently across the app for showing connection forms
struct ConnectionFormModal: View {
  @Binding var isPresented: Bool
  @Binding var connectionConfig: ConnectionConfig

  var title: String = "Connect to Database"
  var submitTitle: String = "Connect"
  var showsRecentHistory: Bool = true
  var onTestConnection: ((ConnectionConfig) async throws -> Bool)?
  var onConnect: ((ConnectionConfig) async throws -> Void)?
  var unrememberedCertificate: (() -> ClientCertificateStoreFactory.ConnectionMaterial?)?
  var unrememberedSSHCredential: (() -> SSHCredentialStoreFactory.ConnectionCredential?)?
  var unlockConnectError: Binding<String?>?
  /// Opens Settings > Plugins (the missing-plugin row and connect errors offer it).
  var onOpenPluginSettings: @MainActor () -> Void = ConnectionErrorAction.postOpenPluginSettings
  /// See `ConnectionFormContent.draftGeneration`.
  var draftGeneration: Int = 0

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(title: title, onClose: { isPresented = false }) {
        databaseTypeMenu
      }
      if connectionConfig.databaseType.capabilities.requiresPlugin && !isDuckDBInstalled {
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
        draftGeneration: draftGeneration
      )
    }
    .modalFrame(
      width: 440, height: connectionConfig.databaseType.capabilities.isFileBased ? 420 : 640
    )
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
  }

  /// Engine picker, sitting on the right of the title and before the close button.
  private var databaseTypeMenu: some View {
    let installed = isDuckDBInstalled
    let types = Self.pickerTypes(
      showExperimental: AppSettings.shared.showExperimentalEngines,
      current: connectionConfig.databaseType,
      isPluginInstalled: { $0 == .duckdb ? installed : true })
    return Picker("Database", selection: $connectionConfig.databaseType) {
      ForEach(types, id: \.self) { type in
        Text(type.displayName).tag(type)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
  }

  /// Read in `body`, so the picker and the missing-plugin row follow install and remove. While
  /// the launch check hashes the file, a present file counts as installed.
  private var isDuckDBInstalled: Bool { DuckDBPluginManager.shared.isInstalledOrPending }

  private var missingPluginRow: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text("DuckDB plugin not installed")
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

  /// Picker engines. The engine of the connection being edited stays listed even when its
  /// plugin is missing, so the picker never shows an empty selection.
  nonisolated static func pickerTypes(
    showExperimental: Bool,
    current: DatabaseType,
    isPluginInstalled: (DatabaseType) -> Bool
  ) -> [DatabaseType] {
    DatabaseType.connectionPickerTypes(
      showExperimental: showExperimental,
      isPluginInstalled: { $0 == current || isPluginInstalled($0) })
  }
}

// MARK: - Connect Error Action

/// The button a connect error offers next to its message.
nonisolated enum ConnectionErrorAction: Equatable, Sendable {
  /// The engine's plugin is not installed: open Settings > Plugins.
  case openPluginSettings

  var title: String {
    switch self {
    case .openPluginSettings: "Install DuckDB Plugin"
    }
  }

  /// `DatabaseError.engineUnavailable`, directly or wrapped in another error's message (catalog
  /// fetches wrap it in `queryFailed`).
  static func action(for error: any Error) -> ConnectionErrorAction? {
    if case DatabaseError.engineUnavailable = error { return .openPluginSettings }
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
  /// Shows a connection form modal with zoom animation from center
  func connectionFormModal(
    isPresented: Binding<Bool>,
    connectionConfig: Binding<ConnectionConfig>,
    title: String = "Connect to Database",
    submitTitle: String = "Connect",
    showsRecentHistory: Bool = true,
    onTestConnection: ((ConnectionConfig) async throws -> Bool)? = nil,
    onConnect: ((ConnectionConfig) async throws -> Void)? = nil,
    unrememberedCertificate: (() -> ClientCertificateStoreFactory.ConnectionMaterial?)? = nil,
    unrememberedSSHCredential: (() -> SSHCredentialStoreFactory.ConnectionCredential?)? = nil,
    unlockConnectError: Binding<String?>? = nil,
    onOpenPluginSettings: @escaping @MainActor () -> Void = ConnectionErrorAction
      .postOpenPluginSettings,
    draftGeneration: Int = 0
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
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
        draftGeneration: draftGeneration
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
        try await workspaceManager.connectionManager.testConnection(config: config)
      },
      onConnect: { config in
        try await workspaceManager.connect(config: config)
      },
      unrememberedCertificate: { workspaceManager.activeUnrememberedCertificate },
      unrememberedSSHCredential: { workspaceManager.activeUnrememberedSSHCredential },
      unlockConnectError: Binding(
        get: { workspaceManager.lastUnlockConnectError },
        set: { workspaceManager.lastUnlockConnectError = $0 }
      ),
      draftGeneration: workspaceManager.connectionFormDraftGeneration
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
