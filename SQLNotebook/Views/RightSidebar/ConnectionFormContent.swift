//
//  ConnectionFormContent.swift
//  SQLNotebook
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

  @State private var isTesting = false
  @State private var testResult: TestResult?
  @State private var isConnecting = false
  @State private var inputMode: ConnectionInputMode = .form
  @State private var connectionString: String = ""
  @State private var parseError: String?
  @State private var isPasswordVisible = false
  @State private var connectionStringSSLMode: SSLMode = .prefer

  // Connection history
  @State private var connectionHistory: [ConnectionHistoryEntry] = []
  @State private var selectedHistoryId: UUID?
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
    onConnectionSuccess: (() -> Void)? = nil
  ) {
    self._connectionConfig = connectionConfig
    self.onTestConnection = onTestConnection
    self.onConnect = onConnect
    self.onConnectionSuccess = onConnectionSuccess
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Main scrollable content
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          // Connection History Dropdown (if available)
          if !connectionHistory.isEmpty {
            connectionHistorySection()
          }

          // Input Mode Picker with Sliding Animation
          customTabPicker()
            .onChange(of: inputMode) { _, newMode in
              parseError = nil
              testResult = nil
              if newMode == .connectionString {
                // Generate connection string from current config only if we have valid data
                let config = connectionConfig
                if !config.username.isEmpty && !config.database.isEmpty {
                  connectionString = generateConnectionString()
                } else {
                  // Keep empty to show placeholder
                  connectionString = ""
                }
                // Sync SSL mode state with current config
                connectionStringSSLMode = connectionConfig.sslMode
              }
            }

          if inputMode == .form {
            formFields()
          } else {
            connectionStringFields()
          }
        }
        .padding(Spacing.lg)
      }
      .onAppear {
        loadConnectionHistory()
      }

      // Fixed Footer at bottom
      footerView()
    }
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

  func getIsPasswordVisible() -> Bool {
    _isPasswordVisible.wrappedValue
  }

  func getConnectionHistory() -> [ConnectionHistoryEntry] {
    connectionHistory
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

  func togglePasswordVisibility() {
    _isPasswordVisible.wrappedValue.toggle()
  }

  // MARK: - Footer

  @ViewBuilder
  private func footerView() -> some View {
    VStack(spacing: 0) {
      // Status messages below buttons
      if let error = parseError {
        errorView(error)
      }

      if let result = testResult {
        testResultView(result)
      }

      // Action Buttons
      HStack(spacing: Spacing.md) {
        Button(action: testConnection) {
          HStack(spacing: Spacing.sm) {
            if isTesting {
              ProgressView()
                .controlSize(.mini)
                .tint(.accent)
                .frame(width: 14, height: 14)
            }
            Text("Test Connection")
              .frame(maxWidth: .infinity)
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
            Text("Connect")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isConnecting || !isFormValid)
      }.padding(.top, Spacing.md)
    }.padding(Spacing.md)
  }

  // MARK: - Validation

  private var isFormValid: Bool {
    if inputMode == .connectionString {
      return !connectionString.isEmpty
    }
    return !connectionConfig.host.isEmpty
      && !connectionConfig.database.isEmpty
      && !connectionConfig.username.isEmpty
  }

  // MARK: - Tab Picker

  @ViewBuilder
  private func customTabPicker() -> some View {
    let selectedIndex = ConnectionInputMode.allCases.firstIndex(of: inputMode) ?? 0

    ZStack {
      // Background
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.inputBackground)
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(Color.border, lineWidth: 1)
        )

      // Content with padding
      GeometryReader { geometry in
        let inset: CGFloat = 3
        let availableWidth = geometry.size.width - (inset * 2)
        let tabWidth = availableWidth / CGFloat(ConnectionInputMode.allCases.count)

        ZStack(alignment: .leading) {
          // Sliding indicator
          RoundedRectangle(cornerRadius: CornerRadius.md - 2)
            .fill(Color.accent)
            .frame(width: tabWidth, height: geometry.size.height - (inset * 2))
            .offset(x: inset + CGFloat(selectedIndex) * tabWidth)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: inputMode)

          // Tab buttons
          HStack(spacing: 0) {
            ForEach(ConnectionInputMode.allCases, id: \.self) { mode in
              Button(action: {
                withAnimation {
                  inputMode = mode
                }
              }) {
                Text(mode.rawValue)
                  .font(.body)
                  .fontWeight(inputMode == mode ? .semibold : .regular)
                  .foregroundColor(inputMode == mode ? .white : .foreground)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .contentShape(Rectangle())
              }
              .buttonStyle(PlainButtonStyle())
              .onHover { hovering in
                if hovering {
                  NSCursor.pointingHand.push()
                } else {
                  NSCursor.pop()
                }
              }
            }
          }
        }
      }
    }
    .frame(height: 32)
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

    Task { @MainActor in
      do {
        let success = try await onTest(connectionConfig)
        isTesting = false
        testResult = success ? .success : .failure("Connection failed unexpectedly")
      } catch {
        isTesting = false
        testResult = .failure(error.localizedDescription)
      }
    }
  }

  private func connect() {
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

    Task { @MainActor in
      do {
        try await onConnectCallback(connectionConfig)
        isConnecting = false
        onConnectionSuccess?()
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
