//
//  ConnectionFormContent.swift
//  Dblore
//
//  Connection form for database configuration
//

import SwiftUI

// MARK: - Connection Form Content

struct ConnectionFormContent: View {
  /// Connection configuration binding - the single source of truth
  @Binding var connectionConfig: ConnectionConfig

  /// Callback to test connection - returns true if successful
  var onTestConnection: ((ConnectionConfig) async throws -> Bool)?

  /// Callback to connect - called when user clicks Connect button
  var onConnect: ((ConnectionConfig) async throws -> Void)?

  /// Callback when connection is successful (optional, for closing sidebar etc.)
  var onConnectionSuccess: (() -> Void)?

  /// Primary footer button. "Connect" opens a workspace. "Save" updates a recent card.
  var submitTitle: String = "Connect"

  /// Recent-connections picker. Hidden while editing one card so Save stays on that card.
  var showsRecentHistory: Bool = true

  @State private var isTesting = false
  @State private var testResult: TestResult?
  @State private var isConnecting = false
  @State private var inputMode: ConnectionInputMode = .form
  @State private var connectionString: String = ""
  @State private var parseError: String?
  @State private var connectionStringSSLMode: SSLMode = .prefer

  // Connection history
  @State private var connectionHistory: [ConnectionHistoryEntry] = []
  @State private var selectedHistoryId: UUID?
  /// Engine the current field values belong to. The header picker changes
  /// `databaseType` without clearing those fields; loading a history row sets both.
  @State private var fieldsEngine: DatabaseType?
  @State private var showDeleteConfirmation = false
  @State private var entryToDelete: UUID?

  // MARK: - Types

  enum TestResult {
    case success
    case failure(String)
  }

  enum ConnectionInputMode: String, CaseIterable {
    case form = "Form"
    case connectionString = "Connection String"
  }

  // MARK: - Initializer

  /// Initialize with binding and callbacks
  init(
    connectionConfig: Binding<ConnectionConfig>,
    onTestConnection: ((ConnectionConfig) async throws -> Bool)? = nil,
    onConnect: ((ConnectionConfig) async throws -> Void)? = nil,
    onConnectionSuccess: (() -> Void)? = nil,
    submitTitle: String = "Connect",
    showsRecentHistory: Bool = true
  ) {
    self._connectionConfig = connectionConfig
    self.onTestConnection = onTestConnection
    self.onConnect = onConnect
    self.onConnectionSuccess = onConnectionSuccess
    self.submitTitle = submitTitle
    self.showsRecentHistory = showsRecentHistory
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if showsRecentHistory && !historyForSelectedType().isEmpty {
            sectionCard {
              sectionTitle("Recent connections")
              connectionHistorySection()
            }
          }

          if connectionConfig.databaseType == .sqlite {
            sectionCard {
              sectionTitle("Connection")
              sqliteSimpleFields()
            }
          } else {
            sectionCard {
              sectionTitle("Connection")
              if connectionConfig.databaseType.capabilities.usesNetwork {
                customTabPicker()
                  .onChange(of: inputMode) { _, newMode in
                    parseError = nil
                    testResult = nil
                    if newMode == .connectionString {
                      let config = connectionConfig
                      if !config.username.isEmpty && !config.database.isEmpty {
                        connectionString = generateConnectionString()
                      } else {
                        connectionString = ""
                      }
                      connectionStringSSLMode = connectionConfig.sslMode
                    }
                  }
              }
              if inputMode == .form || !connectionConfig.databaseType.capabilities.usesNetwork {
                formFields()
              } else {
                connectionStringFields()
              }
            }

            sectionCard {
              sectionTitle("Options")
              connectionTogglesAndPickers()
            }

            sectionCard {
              sectionTitle("Safety")
              safetySection()
            }
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.appBackground)
      .onAppear {
        if fieldsEngine == nil {
          fieldsEngine = connectionConfig.databaseType
        }
        loadConnectionHistory()
        refreshSQLiteFileBookmark()
      }
      .onChange(of: connectionConfig.databaseType) { _, newType in
        clearParseErrorAndTestResult()
        if !newType.capabilities.usesNetwork {
          inputMode = .form
        }
        // Loading a history row sets `fieldsEngine` before `databaseType`, so this
        // only runs for the header picker. A PostgreSQL database name would otherwise
        // stay in `database` and show up under Browse.
        guard
          let replacement = Self.formAfterEngineChange(fieldsEngine: fieldsEngine, newType: newType)
        else { return }
        fieldsEngine = newType
        selectedHistoryId = nil
        connectionConfig = replacement
      }
      .onChange(of: Self.connectionTargetKey(connectionConfig)) { _, _ in
        // SQLite Browse clears the row itself. Resolving a bookmark can change the
        // path string without the user picking a different connection.
        guard connectionConfig.databaseType.capabilities.usesNetwork else { return }
        // A loaded recent row stays selected only while host, port, database, and user match.
        let retained = Self.retainedHistoryId(
          selectedId: selectedHistoryId,
          history: connectionHistory,
          config: connectionConfig
        )
        if selectedHistoryId != retained {
          selectedHistoryId = retained
        }
      }

      footerView()
    }
  }

  func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.subheading.weight(.semibold))
      .foregroundColor(.foreground)
  }

  /// Bordered group, same chrome as the export sheet sections.
  func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm, content: content)
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.cardHeaderBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
          .stroke(Color.border, lineWidth: 1)
      )
  }

  // MARK: - State Accessors (for extensions)

  var connectionStringBinding: Binding<String> {
    $connectionString
  }

  var connectionStringSSLModeBinding: Binding<SSLMode> {
    $connectionStringSSLMode
  }

  var showDeleteConfirmationBinding: Binding<Bool> {
    $showDeleteConfirmation
  }

  func getConnectionHistory() -> [ConnectionHistoryEntry] {
    connectionHistory
  }

  /// Recent rows for the engine selected in the header.
  func historyForSelectedType() -> [ConnectionHistoryEntry] {
    Self.history(matching: connectionConfig.databaseType, in: connectionHistory)
  }

  /// History rows for one engine.
  static func history(
    matching type: DatabaseType, in history: [ConnectionHistoryEntry]
  ) -> [ConnectionHistoryEntry] {
    history.filter { $0.config.databaseType == type }
  }

  /// Nil when the field values already belong to `newType` (a history row just loaded).
  /// Otherwise a blank config, so the previous engine's database name is dropped.
  static func formAfterEngineChange(
    fieldsEngine: DatabaseType?, newType: DatabaseType
  ) -> ConnectionConfig? {
    guard fieldsEngine != newType else { return nil }
    return ConnectionConfig(databaseType: newType)
  }

  /// Host, port, database, and username. Recent connections compares this, not the display name.
  static func connectionTargetKey(_ config: ConnectionConfig) -> String {
    [
      config.databaseType.rawValue,
      config.host,
      String(config.port),
      config.database,
      config.username,
    ].joined(separator: "\u{1e}")
  }

  /// Keeps the Recent connections row only while host, port, database, and username match.
  static func retainedHistoryId(
    selectedId: UUID?,
    history: [ConnectionHistoryEntry],
    config: ConnectionConfig
  ) -> UUID? {
    guard let selectedId,
      let entry = history.first(where: { $0.id == selectedId }),
      entry.config.databaseType == config.databaseType
    else { return nil }

    let sameTarget =
      entry.config.host == config.host && entry.config.port == config.port
      && entry.config.database == config.database && entry.config.username == config.username
    return sameTarget ? selectedId : nil
  }

  /// Choosing a SQLite file. A different path drops the loaded recent row.
  /// Name becomes the file name when it is blank or still that row's name.
  static func applyingSQLiteFile(
    path: String,
    bookmark: Data?,
    to config: ConnectionConfig,
    selected: ConnectionHistoryEntry?
  ) -> (config: ConnectionConfig, selectedHistoryId: UUID?) {
    var updated = config
    updated.database = path
    updated.fileBookmark = bookmark

    let sameFile = selected?.config.database == path
    let loadedName = sameFile ? nil : selected?.config.name
    updated.name = sqliteDisplayName(current: updated.name, path: path, loadedName: loadedName)
    return (updated, sameFile ? selected?.id : nil)
  }

  /// File name without its extension. A name the user typed is left as they typed it.
  static func sqliteDisplayName(current: String, path: String, loadedName: String?) -> String {
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    let derived = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    if trimmed.isEmpty { return derived }
    if let loadedName, trimmed == loadedName.trimmingCharacters(in: .whitespacesAndNewlines) {
      return derived
    }
    return current
  }

  func setFieldsEngine(_ type: DatabaseType) {
    fieldsEngine = type
  }

  func setConnectionHistory(_ history: [ConnectionHistoryEntry]) {
    connectionHistory = history
  }

  func getSelectedHistoryId() -> UUID? {
    selectedHistoryId
  }

  func setSelectedHistoryId(_ id: UUID?) {
    selectedHistoryId = id
  }

  func getEntryToDelete() -> UUID? {
    entryToDelete
  }

  func prepareDeleteConnection(_ id: UUID) {
    entryToDelete = id
    showDeleteConfirmation = true
  }

  func getInputMode() -> ConnectionInputMode {
    inputMode
  }

  func setConnectionString(_ value: String) {
    connectionString = value
  }

  func updateConnectionStringSSLMode(_ mode: SSLMode) {
    connectionStringSSLMode = mode
  }

  func setParseError(_ error: String?) {
    parseError = error
  }

  func clearParseError() {
    parseError = nil
  }

  func clearTestResult() {
    testResult = nil
  }

  func clearParseErrorAndTestResult() {
    parseError = nil
    testResult = nil
  }

  // MARK: - Footer

  @ViewBuilder
  private func footerView() -> some View {
    VStack(spacing: 0) {
      Divider()
      if parseError != nil || testResult != nil {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          if let error = parseError {
            errorView(error)
          }
          if let result = testResult {
            testResultView(result)
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
      }

      HStack(spacing: Spacing.sm) {
        Spacer(minLength: Spacing.sm)
        Button(action: testConnection) {
          HStack(spacing: Spacing.sm) {
            if isTesting {
              ProgressView()
                .controlSize(.mini)
                .tint(.accent)
                .frame(width: 14, height: 14)
            }
            Text("Test Connection")
          }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(isTesting || !isFormValid)

        Button(action: connect) {
          HStack(spacing: Spacing.sm) {
            if isConnecting {
              ProgressView()
                .controlSize(.mini)
                .tint(.accent)
                .frame(width: 14, height: 14)
            }
            Text(submitTitle)
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isConnecting || !isFormValid)
      }
      .modalBarPadding()
    }
    .background(Color.appBackground)
  }

  // MARK: - Validation

  /// Form fields are complete enough to test or connect.
  /// A file engine only needs the file path. Password stays optional.
  static func isFormInputValid(_ config: ConnectionConfig) -> Bool {
    let capabilities = config.databaseType.capabilities
    if !capabilities.usesNetwork {
      return !config.database.isEmpty
    }
    return !config.host.isEmpty && !config.database.isEmpty && !config.username.isEmpty
  }

  private var isFormValid: Bool {
    if inputMode == .connectionString && connectionConfig.databaseType.capabilities.usesNetwork {
      return !connectionString.isEmpty && parseError == nil
    }
    return Self.isFormInputValid(connectionConfig)
  }

  // MARK: - Tab Picker

  @ViewBuilder
  private func customTabPicker() -> some View {
    CapsuleTabPicker(
      selection: $inputMode,
      tabs: ConnectionInputMode.allCases,
      height: 32
    )
  }

  // MARK: - Status Views

  @ViewBuilder
  private func errorView(_ message: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text(message)
        .foregroundColor(.warning)
        .textSelection(.enabled)
    }
    .font(.caption)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.warning.opacity(0.1))
    )
  }

  @ViewBuilder
  private func testResultView(_ result: TestResult) -> some View {
    HStack(spacing: Spacing.sm) {
      switch result {
      case .success:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.success)
        Text("Connection successful!")
          .foregroundColor(.success)
          .textSelection(.enabled)
      case .failure(let message):
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.destructive)
        Text(message)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
    .font(.caption)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(result.isSuccess ? Color.success.opacity(0.1) : Color.destructive.opacity(0.1))
    )
  }

  // MARK: - Actions

  private func testConnection() {
    // Use the active tab: an unparsable connection string would leave stale form values
    guard inputMode == .form || parseError == nil else { return }

    // Validate connection name is not empty
    guard !connectionConfig.name.trimmingCharacters(in: .whitespaces).isEmpty
    else {
      testResult = .failure("Connection name is required")
      return
    }

    guard let onTest = onTestConnection else {
      testResult = .failure("Test connection not available")
      return
    }

    isTesting = true
    testResult = nil
    let config = connectionConfig

    Task { @MainActor in
      do {
        let success = try await onTest(config)
        isTesting = false
        testResult = success ? .success : .failure("Connection failed unexpectedly")
      } catch {
        isTesting = false
        testResult = .failure(error.localizedDescription)
      }
    }
  }

  private func connect() {
    // Use the active tab: an unparsable connection string would leave stale form values
    guard inputMode == .form || parseError == nil else { return }

    // Validate connection name is not empty
    guard !connectionConfig.name.trimmingCharacters(in: .whitespaces).isEmpty
    else {
      testResult = .failure("Connection name is required")
      return
    }

    guard let onConnectCallback = onConnect else {
      testResult = .failure("Connect not available")
      return
    }

    isConnecting = true
    let config = connectionConfig

    Task { @MainActor in
      do {
        try await onConnectCallback(config)
        isConnecting = false
        onConnectionSuccess?()
      } catch WorkspaceConnectError.unlockRequired {
        // Held for the Safe Mode unlock sheet; the form keeps its values
        isConnecting = false
      } catch WorkspaceConnectError.pendingTransactionKept {
        // The user kept the pending transaction: still connected, the form keeps its values
        isConnecting = false
      } catch {
        isConnecting = false
        testResult = .failure(error.localizedDescription)
      }
    }
  }
}

// MARK: - TestResult Extension

extension ConnectionFormContent.TestResult {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}

// MARK: - Form Field

struct FormField<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      content
    }
  }
}
