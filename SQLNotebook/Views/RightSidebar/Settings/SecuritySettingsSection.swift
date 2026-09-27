//
//  SecuritySettingsSection.swift
//  SQLNotebook
//
//  Security settings: Safe Mode, Connection History, Read-only Mode
//

import SwiftUI

struct SecuritySettingsSection: View {
  @Bindable var appSettings: AppSettings
  @Bindable var viewModel: NotebookViewModel
  @Binding var showDisableReadOnlyConfirmation: Bool

  private var currentProtectionLevel: ConnectionProtectionLevel {
    viewModel.notebook.connectionConfig?.protectionLevel ?? .none
  }

  var body: some View {
    SettingsSection(title: "Security", icon: "lock.shield.fill") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Protection Level Warning (at top for visibility)
        if currentProtectionLevel != .none {
          protectionWarning
        }

        // Combined Safe Mode Section
        SafeModeSection(appSettings: appSettings, viewModel: viewModel)
          .id("safeModeSection")
      }
    }
    // Lowering goes through the Safe Mode unlock (see ProtectionLevelDialogModifier)
    .protectionLevelDialog(isPresented: $showDisableReadOnlyConfirmation, viewModel: viewModel)
  }

  private var protectionWarning: some View {
    let level = currentProtectionLevel
    return HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: level.iconName)
        .foregroundColor(level == .readOnly ? .warning : .secondary)
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(level == .readOnly ? "Read-Only Mode Active" : "Schema Protection Active")
          .font(.subheading)
          .foregroundColor(level == .readOnly ? .warning : .secondary)
        Text(
          level == .readOnly
            ? "Modification queries are blocked regardless of Safe Mode level."
            : "Schema changes (CREATE/DROP/ALTER/TRUNCATE) are blocked."
        )
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        Button(action: {
          showDisableReadOnlyConfirmation = true
        }) {
          Text("Change Protection")
            .font(.small)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(level == .readOnly ? Color.warning : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((level == .readOnly ? Color.warning : Color.secondary).opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}

// MARK: - Safe Mode Section (Combined Layout)

/// Combined Safe Mode section with current connection and global settings
struct SafeModeSection: View {
  var appSettings: AppSettings
  var viewModel: NotebookViewModel
  @State private var selectedConnectionMode: SafeMode?

  // Password management states
  @State private var showPasswordSetup: Bool = false
  @State private var currentPassword: String = ""
  @State private var newPassword: String = ""
  @State private var confirmPassword: String = ""
  @State private var passwordError: String?
  @State private var refreshTrigger: UUID = UUID()
  @State private var isChangingPassword: Bool = false
  @State private var useDbPasswordForChange: Bool = false

  // Authentication states
  @State private var showAuthSheet: Bool = false
  @State private var pendingAction: ProtectedAction?
  @State private var authPassword: String = ""
  @State private var authError: String?
  @State private var isAuthenticating: Bool = false
  @State private var useDbPasswordForAuth: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Section Header
      Text("Safe Mode")
        .font(.subheading)
        .foregroundColor(.foreground)

      // Current Connection Row (only when connected)
      if viewModel.connectionState.isConnected {
        currentConnectionRow
      }

      // Global Row
      globalRow
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
    .onAppear {
      selectedConnectionMode = viewModel.notebook.connectionConfig?.safeMode
    }
  }

  // MARK: - Current Connection Row

  private var currentConnectionRow: some View {
    HStack(alignment: .center) {
      // Label
      VStack(alignment: .leading, spacing: 2) {
        Text("Current connection")
          .font(.bodyText)
          .foregroundColor(.foreground)
        if let config = viewModel.notebook.connectionConfig {
          Text(config.name.isEmpty ? config.displayString : config.name)
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }
      }

      Spacer()

      // Dropdown
      Picker("", selection: $selectedConnectionMode) {
        Text("Use Global").tag(SafeMode?.none)
        ForEach(SafeMode.allCases, id: \.self) { mode in
          safeModeLabel(mode)
            .tag(Optional(mode))
        }
      }
      .pickerStyle(.menu)
      .frame(width: 140)
      .onChange(of: selectedConnectionMode) { _, newValue in
        handleConnectionSafeModeChange(to: newValue)
      }
    }
  }

  /// Picker label: mode name, plus a lock icon when the mode requires a password.
  private func safeModeLabel(_ mode: SafeMode) -> Text {
    mode.requiresPassword
      ? Text("\(mode.displayName) \(Image(systemName: "lock.fill"))")
      : Text(mode.displayName)
  }

  // MARK: - Global Row

  private var globalRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center) {
        // Label
        Text(viewModel.connectionState.isConnected ? "Global" : "Default")
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
            safeModeLabel(mode)
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

  /// "Use database password" is offered only while no Safe Mode password exists
  private var showsDatabasePasswordFallback: Bool {
    NotebookViewModel.showsDatabasePasswordFallback(
      hasSafeModePassword: appSettings.hasCustomPasswordSet)
  }

  // MARK: - Safe Mode Change Handler

  /// Per-connection Safe Mode: a weakening under a password Safe Mode is applied only after the
  /// unlock (the picker snaps back until then); anything else applies now.
  private func handleConnectionSafeModeChange(to newMode: SafeMode?) {
    let current = viewModel.notebook.connectionConfig?.safeMode
    guard newMode != current, !viewModel.requestConnectionSafeModeChange(to: newMode) else {
      return
    }
    selectedConnectionMode = current
    pendingAction = .changeConnectionSafeMode(newMode)
    showAuthSheet = true
  }

  private func handleSafeModeChange(to newMode: SafeMode) {
    if NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
      from: appSettings.safeMode, to: newMode, hasPassword: appSettings.hasCustomPasswordSet,
      hasTouchID: appSettings.isBiometricEnabled)
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
        Text("Set a password to enable protection (then Touch ID if you like).")
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
            useDbPasswordForChange = false
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
          // Touch ID needs a Safe Mode password as its fallback
          .disabled(!appSettings.hasCustomPasswordSet)
          .help(
            appSettings.hasCustomPasswordSet
              ? "Unlock Safe Mode with Touch ID" : "Set a Safe Mode password first")
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
          if useDbPasswordForChange {
            SecureField("Database Password", text: $currentPassword)
              .textFieldStyle(.plain)
              .inputStyle()
            Text("Using database password as fallback")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          } else {
            SecureField("Current Password", text: $currentPassword)
              .textFieldStyle(.plain)
              .inputStyle()
            if showsDatabasePasswordFallback {
              Button("Forgot password? Use database password") {
                useDbPasswordForChange = true
                currentPassword = ""
              }
              .font(.small)
              .foregroundColor(.accent)
              .buttonStyle(.plain)
            }
          }
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

      if appSettings.isBiometricEnabled && !useDbPasswordForAuth {
        Button("Use Touch ID") {
          authenticateWithBiometric()
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isAuthenticating)

        Button("Use password instead") {
          useDbPasswordForAuth = true
        }
        .font(.small)
        .foregroundColor(.accent)
        .buttonStyle(.plain)
      } else {
        VStack(spacing: Spacing.sm) {
          if useDbPasswordForAuth && !appSettings.hasCustomPasswordSet {
            SecureField("Database Password", text: $authPassword)
              .textFieldStyle(.plain)
              .inputStyle()
            Text("Using database password as fallback")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          } else {
            SecureField("Password", text: $authPassword)
              .textFieldStyle(.plain)
              .inputStyle()
            if !appSettings.isBiometricEnabled && showsDatabasePasswordFallback {
              Button("Forgot password? Use database password") {
                useDbPasswordForAuth = true
                authPassword = ""
              }
              .font(.small)
              .foregroundColor(.accent)
              .buttonStyle(.plain)
            }
          }
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
    case .changeConnectionSafeMode:
      return "Verify your identity to lower this connection's Safe Mode"
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

  /// Enable Touch ID directly without requiring a backup password
  /// The system password is used as the backup (handled by deviceOwnerAuthentication)
  private func enableBiometricDirectly() {
    Task {
      do {
        try await appSettings.enableBiometricAuth()
        await MainActor.run {
          refreshTrigger = UUID()
        }
      } catch {
        // Show error in a toast or alert if needed
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
      guard credentialAccepted(currentPassword, usingDatabasePassword: useDbPasswordForChange)
      else {
        passwordError =
          useDbPasswordForChange ? "Invalid database password" : "Current password is incorrect"
        return
      }
    }

    // Store the password (Keychain, salted hash); switches the unlock to password
    guard appSettings.setSafeModePassword(newPassword) else {
      passwordError = "Could not store the password"
      return
    }

    refreshTrigger = UUID()
    showPasswordSetup = false
    currentPassword = ""
    newPassword = ""
    confirmPassword = ""
    passwordError = nil
    isChangingPassword = false
    useDbPasswordForChange = false
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

  /// Database password only via `acceptsDatabasePasswordFallback` (never with a Safe Mode
  /// password set, never empty, constant time); otherwise the Safe Mode password.
  private func credentialAccepted(_ entry: String, usingDatabasePassword: Bool) -> Bool {
    NotebookViewModel.settingsAcceptsCredential(
      entry: entry, usingDatabasePassword: usingDatabasePassword,
      storedDatabasePassword: viewModel.notebook.connectionConfig?.password,
      hasSafeModePassword: appSettings.hasCustomPasswordSet,
      verifySafeModePassword: { appSettings.verifySafeModePassword($0) })
  }

  private func verifyPassword() {
    // The database password field is shown only when no Safe Mode password exists
    let isValid = credentialAccepted(
      authPassword,
      usingDatabasePassword: useDbPasswordForAuth && !appSettings.hasCustomPasswordSet)

    if isValid {
      executePendingAction()
    } else {
      authError =
        useDbPasswordForAuth && !appSettings.hasCustomPasswordSet
        ? "Invalid database password" : "Invalid password"
    }
  }

  private func executePendingAction() {
    func cleanup() {
      showAuthSheet = false
      authPassword = ""
      authError = nil
      useDbPasswordForAuth = false
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

    case .changeConnectionSafeMode(let newMode):
      viewModel.applyConnectionSafeMode(newMode)
      selectedConnectionMode = newMode
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
      useDbPasswordForChange = false
      showPasswordSetup = true

    case .switchToBiometric:
      cleanup()
      // Enable biometric directly - system password is the backup
      enableBiometricDirectly()
    }
  }
}

// MARK: - Dialog Enums

/// Action that requires authentication
private enum ProtectedAction {
  case changeSafeMode(SafeMode)
  case changeConnectionSafeMode(SafeMode?)  // Per-connection weakening (nil = use global)
  case removeProtection
  case switchToPassword  // Switch from Touch ID to password
  case switchToBiometric  // Switch from password to Touch ID
}
