//
//  SettingsModal.swift
//  SQLNotebook
//
//  Settings modal at workspace level - accessible via Cmd+,
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Modal

/// Main settings modal for workspace level
/// Shows all settings in a scrollable modal with organized sections
struct SettingsModal: View {
  @Binding var isPresented: Bool
  let viewMode: ViewMode?

  @Bindable var appSettings = AppSettings.shared
  @State private var isExportingLogs = false

  /// Effective view mode - defaults to notebook if no active tab
  private var effectiveViewMode: ViewMode {
    viewMode ?? .notebook
  }

  var body: some View {
    GenericModal(
      title: "Settings",
      titleIcon: "gear",
      width: 480,
      height: 600,
      isPresented: $isPresented
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          // Appearance Settings
          AppearanceSettingsSection(appSettings: appSettings)

          Divider()

          // Editor Settings
          SettingsModalEditorSection(
            appSettings: appSettings,
            viewMode: effectiveViewMode
          )

          Divider()

          // Result Table Settings
          SettingsModalResultTableSection(
            appSettings: appSettings,
            viewMode: effectiveViewMode
          )

          Divider()

          // Save Options (Notebook Mode Only)
          SettingsModalSaveOptionsSection(appSettings: appSettings)

          Divider()

          // Security Settings
          SettingsModalSecuritySection(appSettings: appSettings)

          Divider()

          // Developer Settings
          SettingsModalDeveloperSection(isExportingLogs: $isExportingLogs)

          Divider()

          // Keyboard Shortcuts
          SettingsModalKeyboardShortcutsSection(viewMode: effectiveViewMode)
        }
        .padding(Spacing.md)
      }
    }
    .fileExporter(
      isPresented: $isExportingLogs,
      document: LogDocument(),
      contentType: .plainText,
      defaultFilename: "sqlnotebook-logs-\(formattedDate).txt"
    ) { _ in
      // Export completed, no action needed
    }
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    return formatter.string(from: Date())
  }
}

// MARK: - Editor Settings Section

struct SettingsModalEditorSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    SettingsSection(title: "Editor", icon: "text.cursor") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        SettingsToggle(
          title: "Enable Syntax Highlighting",
          description:
            "Colorize SQL keywords, functions, strings, and comments. Disable to improve performance with large files.",
          isOn: $appSettings.syntaxHighlightingEnabled
        )

        SettingsToggle(
          title: "Enable Autocomplete",
          description:
            "When enabled, SQL keywords, table names, and column names will be suggested as you type.",
          isOn: $appSettings.isAutoCompleteEnabled
        )

        // Show Line Numbers toggle (Editor mode only)
        SettingsToggle(
          title: "Show Line Numbers",
          description:
            "Display line numbers in the gutter. Helps with navigation and debugging queries. (Editor only)",
          isOn: $appSettings.showLineNumbers
        )

        // Word Wrap toggle (both modes)
        SettingsToggle(
          title: "Word Wrap",
          description:
            "Wrap long lines to fit the editor width. Use Option+Z to toggle quickly.",
          isOn: $appSettings.wordWrapEnabled
        )

        // Simple Mode toggle (Editor mode only)
        SettingsToggle(
          title: "Simple Mode",
          description:
            "When enabled, Run executes the selection or the current line. Otherwise, Run executes the selection or the entire file. (Editor only)",
          isOn: $appSettings.editorSimpleMode
        )
      }
    }
  }
}

// MARK: - Result Table Settings Section

struct SettingsModalResultTableSection: View {
  @Bindable var appSettings: AppSettings
  let viewMode: ViewMode

  var body: some View {
    SettingsSection(title: "Result Table", icon: "tablecells.fill") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Hide Column Types toggle
        SettingsToggle(
          title: "Hide Column Types",
          description:
            "When enabled, column types (e.g., VARCHAR, INTEGER) will be hidden from table headers, showing only column names.",
          isOn: $appSettings.hideColumnTypes
        )

        // Hide Run with Query Section toggle
        SettingsToggle(
          title: "Hide Run with Query Section",
          description:
            "When enabled, the 'Run with query' section (with query text and download button) will be hidden from result tables.",
          isOn: $appSettings.hideRunWithQuerySection
        )

        // Max Height (Notebook only)
        SettingsSlider(
          title: "Max Height",
          valueText: "\(Int(appSettings.maxResultHeight)) pt",
          value: Binding(
            get: { Double(appSettings.maxResultHeight) },
            set: { appSettings.maxResultHeight = CGFloat($0) }
          ),
          range: 200...1000,
          step: 50,
          description:
            "Adjust the maximum height of result tables. Values between 200-1000 points. (Notebook only)"
        )

        // Max Row Limit - Notebook
        SettingsSlider(
          title: "Max Rows (Notebook)",
          valueText: "\(appSettings.maxRowLimit) rows",
          value: Binding(
            get: { Double(appSettings.maxRowLimit) },
            set: { appSettings.maxRowLimit = Int($0) }
          ),
          range: 50...100,
          step: 5,
          description: "Maximum rows to fetch in Notebook mode. Values between 50-100 rows."
        )

        // Max Row Limit - Editor
        SettingsSlider(
          title: "Max Rows (Editor)",
          valueText: "\(appSettings.editorMaxRowLimit) rows",
          value: Binding(
            get: { Double(appSettings.editorMaxRowLimit) },
            set: { appSettings.editorMaxRowLimit = Int($0) }
          ),
          range: 100...200,
          step: 10,
          description: "Maximum rows to fetch in Editor mode. Values between 100-200 rows."
        )
      }
    }
  }
}

// MARK: - Save Options Section

struct SettingsModalSaveOptionsSection: View {
  @Bindable var appSettings: AppSettings

  var body: some View {
    SettingsSection(title: "Save Options", icon: "square.and.arrow.down.fill") {
      SettingsToggle(
        title: "Include Results When Saving",
        description:
          "When enabled, query results are saved with the notebook. Disable to reduce file size. (Notebook only)",
        isOn: $appSettings.includeResultsOnSave
      )
    }
  }
}

// MARK: - Security Settings Section

struct SettingsModalSecuritySection: View {
  @Bindable var appSettings: AppSettings

  // Password management states
  @State private var showPasswordSetup: Bool = false
  @State private var currentPassword: String = ""
  @State private var newPassword: String = ""
  @State private var confirmPassword: String = ""
  @State private var passwordError: String?
  @State private var refreshTrigger: UUID = UUID()
  @State private var isChangingPassword: Bool = false

  // Authentication states
  @State private var showAuthSheet: Bool = false
  @State private var pendingAction: ProtectedAction?
  @State private var authPassword: String = ""
  @State private var authError: String?
  @State private var isAuthenticating: Bool = false

  var body: some View {
    SettingsSection(title: "Security", icon: "lock.shield.fill") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Safe Mode Section
        safeModeSection
      }
    }
    .id(refreshTrigger)
    .sheet(isPresented: $showPasswordSetup) {
      passwordSetupSheet
    }
    .sheet(isPresented: $showAuthSheet) {
      authenticationSheet
        .onAppear {
          authPassword = ""
          authError = nil
          isAuthenticating = false
        }
    }
  }

  // MARK: - Safe Mode Section

  private var safeModeSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Section Header
      Text("Safe Mode")
        .font(.subheading)
        .foregroundColor(.foreground)

      // Global Row
      globalRow
    }
  }

  // MARK: - Global Row

  private var globalRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center) {
        // Label
        Text("Default Level")
          .font(.bodyText)
          .foregroundColor(.foreground)

        Spacer()

        // Dropdown
        Picker(
          "",
          selection: Binding(
            get: { appSettings.safeMode },
            set: { newMode in
              handleSafeModeChange(to: newMode)
            }
          )
        ) {
          ForEach(SafeMode.allCases, id: \.self) { mode in
            (Text(mode.displayName)
              + Text(mode.requiresPassword ? " \(Image(systemName: "lock.fill"))" : ""))
              .tag(mode)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 140)
      }

      // Description of selected global mode
      Text(appSettings.safeMode.shortDescription)
        .font(.small)
        .foregroundColor(.foregroundSubtle)

      // Password panel - shown when Safe mode (requires password) is selected
      if appSettings.safeMode.requiresPassword {
        passwordManagementPanel
      }
    }
  }

  // MARK: - Safe Mode Change Handler

  private func handleSafeModeChange(to newMode: SafeMode) {
    if appSettings.safeMode.requiresPassword && appSettings.isSafeModePasswordSet
      && newMode != appSettings.safeMode
    {
      pendingAction = .changeSafeMode(newMode)
      showAuthSheet = true
    } else {
      withAnimation(.snappy(duration: 0.2)) {
        appSettings.safeMode = newMode
      }
    }
  }

  // MARK: - Password Management Panel

  private var passwordManagementPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: appSettings.isSafeModePasswordSet ? "lock.fill" : "lock.open.fill")
          .font(.system(size: 12))
          .foregroundColor(appSettings.isSafeModePasswordSet ? .accent : .warning)
        Text(appSettings.isSafeModePasswordSet ? "Password Protected" : "No Password Set")
          .font(.small)
          .fontWeight(.medium)
          .foregroundColor(appSettings.isSafeModePasswordSet ? .foreground : .warning)
      }

      if !appSettings.isSafeModePasswordSet {
        Text("Set a password or use Touch ID to enable protection.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      }

      HStack(spacing: Spacing.md) {
        Button(action: {
          if appSettings.isBiometricEnabled {
            pendingAction = .switchToPassword
            showAuthSheet = true
          } else {
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            passwordError = nil
            isChangingPassword = appSettings.hasCustomPasswordSet
            showPasswordSetup = true
          }
        }) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "key.fill")
              .font(.system(size: 10))
            Text(appSettings.hasCustomPasswordSet ? "Change" : "Set Password")
          }
          .font(.small)
          .foregroundColor(.accent)
        }
        .buttonStyle(.plain)

        if !appSettings.isBiometricEnabled {
          Button(action: {
            if appSettings.isSafeModePasswordSet && !appSettings.isBiometricEnabled {
              pendingAction = .switchToBiometric
              showAuthSheet = true
            } else {
              // Directly enable biometric - system password is the backup
              enableBiometricDirectly()
            }
          }) {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "touchid")
                .font(.system(size: 10))
              Text("Use Touch ID")
            }
            .font(.small)
            .foregroundColor(.accent)
          }
          .buttonStyle(.plain)
        }

        if appSettings.isSafeModePasswordSet {
          Button(action: {
            pendingAction = .removeProtection
            showAuthSheet = true
          }) {
            Text("Remove")
              .font(.small)
              .foregroundColor(.destructive)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(Spacing.sm)
    .background(Color.inputBackground.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
  }

  // MARK: - Password Setup Sheet

  private var passwordSetupSheet: some View {
    VStack(spacing: Spacing.lg) {
      passwordSetupContent
    }
    .padding(Spacing.xl)
    .frame(width: 350)
    .background(Color.appBackground)
  }

  private var passwordSetupContent: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "key.fill")
        .font(.system(size: 48))
        .foregroundColor(.accent)

      VStack(spacing: Spacing.xs) {
        Text(isChangingPassword ? "Change Password" : "Set Password")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(
          isChangingPassword
            ? "Enter your current password and choose a new one"
            : "Choose a password to protect Safe Mode"
        )
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
      }

      VStack(spacing: Spacing.sm) {
        if isChangingPassword {
          SecureField("Current Password", text: $currentPassword)
            .textFieldStyle(.plain)
            .inputStyle()
        }

        SecureField("New Password", text: $newPassword)
          .textFieldStyle(.plain)
          .inputStyle()

        SecureField("Confirm Password", text: $confirmPassword)
          .textFieldStyle(.plain)
          .inputStyle()
      }

      if let error = passwordError {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
      }

      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showPasswordSetup = false
        }
        .buttonStyle(SecondaryButtonStyle())

        Button(isChangingPassword ? "Change" : "Set Password") {
          setPassword()
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(newPassword.isEmpty || confirmPassword.isEmpty)
      }
    }
  }

  // MARK: - Authentication Sheet

  private var authenticationSheet: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: appSettings.isBiometricEnabled ? "touchid" : "lock.fill")
        .font(.system(size: 48))
        .foregroundColor(.accent)

      VStack(spacing: Spacing.xs) {
        Text("Authentication Required")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(authenticationMessage)
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
          .multilineTextAlignment(.center)
      }

      if appSettings.isBiometricEnabled {
        Button("Use Touch ID") {
          authenticateWithBiometric()
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isAuthenticating)

        Button("Use password instead") {
          // Will need password fallback
        }
        .font(.small)
        .foregroundColor(.accent)
        .buttonStyle(.plain)
      } else {
        VStack(spacing: Spacing.sm) {
          SecureField("Password", text: $authPassword)
            .textFieldStyle(.plain)
            .inputStyle()
        }

        if let error = authError {
          Text(error)
            .font(.small)
            .foregroundColor(.destructive)
        }

        HStack(spacing: Spacing.md) {
          Button("Cancel") {
            showAuthSheet = false
            pendingAction = nil
          }
          .buttonStyle(SecondaryButtonStyle())

          Button("Verify") {
            verifyPassword()
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(authPassword.isEmpty || isAuthenticating)
        }
      }
    }
    .padding(Spacing.xl)
    .frame(width: 350)
    .background(Color.appBackground)
  }

  private var authenticationMessage: String {
    switch pendingAction {
    case .changeSafeMode:
      return "Verify your identity to change Safe Mode level"
    case .removeProtection:
      return "Verify your identity to remove password protection"
    case .switchToPassword:
      return "Verify your identity to switch to password authentication"
    case .switchToBiometric:
      return "Verify your identity to enable Touch ID"
    case .none:
      return "Verify your identity to continue"
    }
  }

  // MARK: - Authentication Methods

  private func enableBiometricDirectly() {
    Task {
      do {
        try await appSettings.enableBiometricAuth()
        await MainActor.run {
          refreshTrigger = UUID()
        }
      } catch {
        print("Failed to enable Touch ID: \(error.localizedDescription)")
      }
    }
  }

  private func setPassword() {
    guard newPassword == confirmPassword else {
      passwordError = "Passwords don't match"
      return
    }
    guard newPassword.count >= 4 else {
      passwordError = "Password must be at least 4 characters"
      return
    }

    if isChangingPassword {
      let isValid = appSettings.verifySafeModePassword(currentPassword)

      guard isValid else {
        passwordError = "Current password is incorrect"
        return
      }
    }

    // Set password (this also clears biometric if it was enabled)
    appSettings.safeModePassword = newPassword
    appSettings.clearSafeModePassword()
    appSettings.safeModePassword = newPassword

    refreshTrigger = UUID()
    showPasswordSetup = false
    currentPassword = ""
    newPassword = ""
    confirmPassword = ""
    passwordError = nil
    isChangingPassword = false
  }

  private func authenticateWithBiometric() {
    isAuthenticating = true
    Task {
      do {
        let success = try await appSettings.verifyBiometric()
        await MainActor.run {
          isAuthenticating = false
          if success {
            executePendingAction()
          } else {
            authError = "Touch ID authentication failed"
          }
        }
      } catch {
        await MainActor.run {
          isAuthenticating = false
          authError = "Touch ID error: \(error.localizedDescription)"
        }
      }
    }
  }

  private func verifyPassword() {
    let isValid = appSettings.verifySafeModePassword(authPassword)

    if isValid {
      executePendingAction()
    } else {
      authError = "Invalid password"
    }
  }

  private func executePendingAction() {
    func cleanup() {
      showAuthSheet = false
      authPassword = ""
      authError = nil
      pendingAction = nil
    }

    guard let action = pendingAction else {
      cleanup()
      return
    }

    switch action {
    case .changeSafeMode(let newMode):
      withAnimation(.snappy(duration: 0.2)) {
        appSettings.safeMode = newMode
      }
      cleanup()

    case .removeProtection:
      appSettings.clearSafeModePassword()
      refreshTrigger = UUID()
      cleanup()

    case .switchToPassword:
      cleanup()
      currentPassword = ""
      newPassword = ""
      confirmPassword = ""
      passwordError = nil
      isChangingPassword = false
      showPasswordSetup = true

    case .switchToBiometric:
      cleanup()
      enableBiometricDirectly()
    }
  }

  // MARK: - Protected Action Enum

  private enum ProtectedAction {
    case changeSafeMode(SafeMode)
    case removeProtection
    case switchToPassword
    case switchToBiometric
  }
}

// MARK: - Developer Settings Section

struct SettingsModalDeveloperSection: View {
  @Binding var isExportingLogs: Bool

  var body: some View {
    SettingsSection(title: "Developer", icon: "hammer.fill") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Export logs button
        Button(action: {
          isExportingLogs = true
        }) {
          HStack {
            Image(systemName: "square.and.arrow.up")
            Text("Export Application Logs")
          }
          .font(.bodyText)
          .foregroundColor(.accent)
          .frame(maxWidth: .infinity)
          .padding(.vertical, Spacing.sm)
          .background(Color.accent.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)

        Text(
          "Export diagnostic logs to share with developers for troubleshooting. Logs include app activity and error messages."
        )
        .font(.small)
        .foregroundColor(.foregroundSubtle)
      }
    }
  }
}

// MARK: - Keyboard Shortcuts Section

struct SettingsModalKeyboardShortcutsSection: View {
  let viewMode: ViewMode

  var body: some View {
    SettingsSection(title: "Keyboard Shortcuts", icon: "command") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        Text("Custom keyboard shortcuts will be available in a future update.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)

        // General shortcuts (both modes)
        generalShortcutsList

        Divider()
          .padding(.vertical, Spacing.xs)

        // Mode-specific shortcuts
        Text(viewMode == .notebook ? "Notebook Shortcuts" : "Editor Shortcuts")
          .font(.small)
          .fontWeight(.medium)
          .foregroundColor(.foregroundMuted)

        if viewMode == .notebook {
          notebookShortcutsList
        } else {
          editorShortcutsList
        }
      }
    }
  }

  private var generalShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "New Notebook", shortcut: "Cmd+Shift+N")
      ShortcutRow(action: "New SQL File", shortcut: "Cmd+Shift+J")
      ShortcutRow(action: "Save As", shortcut: "Cmd+Shift+S")
      ShortcutRow(action: "Toggle Comment", shortcut: "Cmd+/")
      ShortcutRow(action: "Toggle Word Wrap", shortcut: "Option+Z")
      ShortcutRow(action: "Toggle Left Sidebar", shortcut: "Cmd+B")
      ShortcutRow(action: "Toggle Right Sidebar", shortcut: "Cmd+Shift+B")
    }
  }

  private var notebookShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "Add New Cell", shortcut: "Cmd+Option+N")
      ShortcutRow(action: "Run Cell", shortcut: "Ctrl+Enter")
      ShortcutRow(action: "Run Cell and Select Next", shortcut: "Shift+Enter")
      ShortcutRow(action: "Run Cell and Insert Below", shortcut: "Option+Enter")
      ShortcutRow(action: "Run All Cells", shortcut: "Cmd+Shift+Enter")
      ShortcutRow(action: "Delete Cell", shortcut: "Cmd+Delete")
      ShortcutRow(action: "Duplicate Cell", shortcut: "Cmd+D")
    }
  }

  private var editorShortcutsList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ShortcutRow(action: "Run Query", shortcut: "Cmd+R / Cmd+Enter")
      ShortcutRow(action: "Find", shortcut: "Cmd+F")
      ShortcutRow(action: "Find Next", shortcut: "Cmd+G")
      ShortcutRow(action: "Find Previous", shortcut: "Cmd+Shift+G")
    }
  }
}

// MARK: - View Extension for Settings Modal

extension View {
  /// Shows a settings modal with zoom animation from center
  func settingsModal(
    isPresented: Binding<Bool>,
    viewMode: ViewMode?
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
      SettingsModal(
        isPresented: isPresented,
        viewMode: viewMode
      )
    }
  }
}

// MARK: - WorkspaceManager Settings Modal Extension

extension View {
  /// Shows a settings modal bound to a WorkspaceManager
  func settingsModal(workspaceManager: WorkspaceManager) -> some View {
    self.settingsModal(
      isPresented: Binding(
        get: { workspaceManager.isSettingsModalVisible },
        set: { workspaceManager.isSettingsModalVisible = $0 }
      ),
      viewMode: workspaceManager.activeViewModel?.viewMode
    )
  }
}

// MARK: - Preview

#Preview("Settings Modal") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .settingsModal(isPresented: $isPresented, viewMode: .notebook)
}

#Preview("Settings Modal - Editor Mode") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .settingsModal(isPresented: $isPresented, viewMode: .editor)
}
