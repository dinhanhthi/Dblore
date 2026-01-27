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

  var body: some View {
    SettingsSection(title: "Security", icon: "lock.shield.fill") {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Safe Mode Picker
        SafeModePicker(appSettings: appSettings, viewModel: viewModel)
          .id("safeModeSection")

        // Connection History Size Setting
        SettingsSlider(
          title: "Connection History Size",
          valueText: "\(appSettings.maxConnectionHistorySize) connections",
          value: Binding(
            get: { Double(appSettings.maxConnectionHistorySize) },
            set: { appSettings.maxConnectionHistorySize = Int($0) }
          ),
          range: 0...5,
          step: 1
        ) {
          Text(
            appSettings.maxConnectionHistorySize == 0
              ? "Connection history is disabled. Passwords will not be saved."
              : "Store up to \(appSettings.maxConnectionHistorySize) recent connection(s). Passwords are securely stored in Keychain."
          )
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        }

        // Read-only Mode Warning
        if viewModel.editingConnectionConfig.readOnly {
          readOnlyWarning
        }
      }
    }
    .confirmationDialog(
      "Disable Read-only Mode?",
      isPresented: $showDisableReadOnlyConfirmation,
      titleVisibility: .visible
    ) {
      Button("Disable Read-only Mode", role: .destructive) {
        Task {
          await viewModel.disableReadOnlyMode()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Are you sure you want to disable read-only mode? This will allow data modification queries (INSERT, UPDATE, DELETE, etc.) to execute."
      )
    }
  }

  private var readOnlyWarning: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: "lock.fill")
        .foregroundColor(.warning)
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Read-Only Mode Active")
          .font(.subheading)
          .foregroundColor(.warning)
        Text("Modification queries are blocked regardless of Safe Mode level.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        Button(action: {
          showDisableReadOnlyConfirmation = true
        }) {
          Text("Disable Read-only Mode")
            .font(.small)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.warning)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(Spacing.md)
    .background(Color.warning.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}

// MARK: - Safe Mode Picker Component

/// Dialog mode for password setup sheet
private enum PasswordDialogMode {
  case password
  case biometric
}

/// Action that requires authentication
private enum ProtectedAction {
  case changeSafeMode(SafeMode)
  case removeProtection
  case switchToPassword  // Switch from Touch ID to password
  case switchToBiometric  // Switch from password to Touch ID
}

/// A picker component for Safe Mode levels with password management
struct SafeModePicker: View {
  @Bindable var appSettings: AppSettings
  let viewModel: NotebookViewModel  // For accessing database password
  @State private var showPasswordSetup: Bool = false
  @State private var currentPassword: String = ""  // For verifying current password when changing
  @State private var newPassword: String = ""
  @State private var confirmPassword: String = ""
  @State private var passwordError: String?
  @State private var dialogMode: PasswordDialogMode = .password
  @State private var activeDialogMode: PasswordDialogMode = .password  // Captured when sheet opens
  @State private var refreshTrigger: UUID = UUID()  // Force UI refresh
  @State private var isChangingPassword: Bool = false  // Track if we're changing existing password
  @State private var useDbPasswordForChange: Bool = false  // Forgot password mode for change password

  // Authentication for protected actions
  @State private var showAuthSheet: Bool = false
  @State private var pendingAction: ProtectedAction?
  @State private var authPassword: String = ""
  @State private var authError: String?
  @State private var isAuthenticating: Bool = false
  @State private var useDbPasswordForAuth: Bool = false  // Forgot password mode for auth

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      // Safe Mode Picker Label
      Text("Safe Mode")
        .font(.subheading)
        .foregroundColor(.foreground)

      // Mode Selection with descriptions
      VStack(alignment: .leading, spacing: 0) {
        ForEach(SafeMode.allCases, id: \.self) { mode in
          safeModeOption(mode)
        }
      }
    }
    .id(refreshTrigger)  // Force refresh when trigger changes
    .sheet(isPresented: $showPasswordSetup) {
      passwordSetupSheet
        .onAppear {
          // Capture the dialog mode when sheet opens - this prevents mode switching during editing
          activeDialogMode = dialogMode
        }
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

  @ViewBuilder
  private func safeModeOption(_ mode: SafeMode) -> some View {
    let isSelected = appSettings.safeMode == mode

    VStack(alignment: .leading, spacing: 0) {
      // Mode selection button
      Button(action: {
        // Check if current mode is protected and user is trying to change it
        if appSettings.safeMode.requiresPassword && appSettings.isSafeModePasswordSet
          && mode != appSettings.safeMode
        {
          // Require authentication before changing mode
          pendingAction = .changeSafeMode(mode)
          showAuthSheet = true
        } else {
          withAnimation(.snappy(duration: 0.2)) {
            appSettings.safeMode = mode
          }
        }
      }) {
        HStack(alignment: .top, spacing: Spacing.sm) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundColor(isSelected ? .accent : .foregroundMuted)
            .font(.system(size: 16))

          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
              Text(mode.displayName)
                .font(.bodyText)
                .foregroundColor(isSelected ? .foreground : .foregroundMuted)

              if mode.requiresPassword {
                Image(systemName: "lock.fill")
                  .font(.system(size: 10))
                  .foregroundColor(.foregroundSubtle)
              }
            }

            // Short description for each mode
            Text(mode.shortDescription)
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          }

          Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Password panel - shown indented under selected Safe mode options
      if isSelected && mode.requiresPassword {
        passwordManagementPanel
          .padding(.leading, Spacing.lg + Spacing.sm)
          .padding(.bottom, Spacing.sm)
      }
    }
  }

  private var passwordManagementPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Status header
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

      // Action buttons
      HStack(spacing: Spacing.md) {
        // Set Password button
        // - If Touch ID is enabled: require Touch ID auth first, then show password setup
        // - If password is enabled: show password setup directly (to change)
        // - If nothing is set: show password setup directly
        Button(action: {
          if appSettings.isBiometricEnabled {
            // Touch ID is enabled - require auth first before switching to password
            pendingAction = .switchToPassword
            showAuthSheet = true
          } else {
            // No protection or password mode - show password setup directly
            dialogMode = .password
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            passwordError = nil
            // Track if we're changing an existing password
            isChangingPassword = appSettings.hasCustomPasswordSet
            showPasswordSetup = true
          }
        }) {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "key.fill")
              .font(.system(size: 10))
            // Show "Change" if custom password is set (not biometric), otherwise "Set Password"
            Text(appSettings.hasCustomPasswordSet ? "Change" : "Set Password")
          }
          .font(.small)
          .foregroundColor(.accent)
        }
        .buttonStyle(.plain)

        // Touch ID button
        // - If password is enabled: require password auth first, then enable Touch ID
        // - If Touch ID is already enabled: do nothing (already active)
        // - If nothing is set: show Touch ID setup directly
        if !appSettings.isBiometricEnabled {
          Button(action: {
            if appSettings.isSafeModePasswordSet && !appSettings.isBiometricEnabled {
              // Password is enabled - require auth first before switching to Touch ID
              pendingAction = .switchToBiometric
              showAuthSheet = true
            } else {
              // No protection - show Touch ID setup directly
              dialogMode = .biometric
              newPassword = ""
              confirmPassword = ""
              passwordError = nil
              showPasswordSetup = true
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

        // Remove button (only if protection is set)
        if appSettings.isSafeModePasswordSet {
          Button(action: {
            // Require authentication before removing protection
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

  private var passwordSetupSheet: some View {
    VStack(spacing: Spacing.lg) {
      // Use activeDialogMode which is captured when sheet opens
      // This prevents the view from switching while user is interacting
      switch activeDialogMode {
      case .biometric:
        // Touch ID / Biometric setup
        biometricSetupContent
      case .password:
        // Password setup
        passwordSetupContent
      }
    }
    .padding(Spacing.xl)
    .frame(width: 350)
    .background(Color.appBackground)
  }

  private var passwordSetupContent: some View {
    VStack(spacing: Spacing.lg) {
      Text(isChangingPassword ? "Change Safe Mode Password" : "Set Safe Mode Password")
        .font(.heading)
        .foregroundColor(.foreground)

      VStack(alignment: .leading, spacing: Spacing.md) {
        // Current password field - only shown when changing existing password
        if isChangingPassword {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
              Text(
                useDbPasswordForChange ? "Database Password" : "Current Password"
              )
              .font(.bodyText)
              .foregroundColor(.foreground)

              Spacer()

              // Forgot password option - only show when connected
              if viewModel.connectionState == .connected {
                Button(action: {
                  useDbPasswordForChange.toggle()
                  currentPassword = ""
                  passwordError = nil
                }) {
                  Text(useDbPasswordForChange ? "Use Safe Mode Password" : "Forgot Password?")
                    .font(.small)
                    .foregroundColor(.accent)
                }
                .buttonStyle(.plain)
              }
            }
            SecureField(
              useDbPasswordForChange ? "Enter database password" : "Enter current password",
              text: $currentPassword
            )
            .textFieldStyle(.roundedBorder)

            if useDbPasswordForChange {
              Text("Using database connection password to verify your identity.")
                .font(.small)
                .foregroundColor(.foregroundSubtle)
            }
          }
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("New Password")
            .font(.bodyText)
            .foregroundColor(.foreground)
          SecureField("Enter password", text: $newPassword)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Confirm Password")
            .font(.bodyText)
            .foregroundColor(.foreground)
          SecureField("Confirm password", text: $confirmPassword)
            .textFieldStyle(.roundedBorder)
        }

        if let error = passwordError {
          Text(error)
            .font(.small)
            .foregroundColor(.destructive)
        }
      }

      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showPasswordSetup = false
          useDbPasswordForChange = false
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        Button("Save Password") {
          savePassword()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          newPassword.isEmpty || confirmPassword.isEmpty
            || (isChangingPassword && currentPassword.isEmpty))
      }
    }
  }

  private var biometricSetupContent: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "touchid")
        .font(.system(size: 48))
        .foregroundColor(.accent)

      Text("Enable Touch ID")
        .font(.heading)
        .foregroundColor(.foreground)

      Text("Use Touch ID or your macOS password to authorize queries in Safe Mode.")
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)

      if let error = passwordError {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
      }

      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showPasswordSetup = false
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        Button("Enable Touch ID") {
          enableBiometric()
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func savePassword() {
    // Verify current password if changing existing password
    if isChangingPassword {
      if useDbPasswordForChange {
        // Verify using database password
        guard currentPassword == viewModel.editingConnectionConfig.password else {
          passwordError = "Incorrect database password"
          return
        }
      } else {
        // Verify using Safe Mode password
        guard appSettings.verifySafeModePassword(currentPassword) else {
          passwordError = "Current password is incorrect"
          return
        }
      }
    }

    guard !newPassword.isEmpty else {
      passwordError = "Password cannot be empty"
      return
    }

    guard newPassword == confirmPassword else {
      passwordError = "Passwords do not match"
      return
    }

    guard newPassword.count >= 4 else {
      passwordError = "Password must be at least 4 characters"
      return
    }

    appSettings.safeModePassword = newPassword
    showPasswordSetup = false
    isChangingPassword = false
    useDbPasswordForChange = false
    // Force UI refresh to show updated password status
    refreshTrigger = UUID()
  }

  private func enableBiometric() {
    Task {
      do {
        try await appSettings.enableBiometricAuth()
        await MainActor.run {
          showPasswordSetup = false
          // Force UI refresh to show updated password status
          refreshTrigger = UUID()
        }
      } catch {
        await MainActor.run {
          // Check if user cancelled authentication
          // LAError codes: userCancel = -2, systemCancel = -4, appCancel = -9
          let nsError = error as NSError
          let isCancelled =
            nsError.code == -2 || nsError.code == -4 || nsError.code == -9
            || nsError.localizedDescription.lowercased().contains("cancel")

          if isCancelled {
            // User cancelled - show message prompting to try again (don't close dialog)
            passwordError = "Authentication cancelled. Tap 'Enable Touch ID' to try again."
            return
          }
          // Show other errors
          passwordError = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Authentication Sheet for Protected Actions

  private var authenticationSheet: some View {
    VStack(spacing: Spacing.lg) {
      // Header with action-specific message
      HStack {
        Image(systemName: "lock.shield.fill")
          .font(.title)
          .foregroundColor(.accent)
        Text(authenticationTitle)
          .font(.heading)
          .foregroundColor(.foreground)
      }

      // Authentication options
      if appSettings.isBiometricEnabled && !useDbPasswordForAuth {
        // Touch ID / Biometric option
        VStack(spacing: Spacing.md) {
          Button(action: {
            authenticateForAction()
          }) {
            HStack(spacing: Spacing.sm) {
              if isAuthenticating {
                ProgressView()
                  .scaleEffect(0.8)
              } else {
                Image(systemName: "touchid")
                  .font(.title)
              }
              Text(isAuthenticating ? "Authenticating..." : "Use Touch ID")
                .font(.bodyText)
            }
            .foregroundColor(.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(Color.accent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          }
          .buttonStyle(.plain)
          .disabled(isAuthenticating)

          // Forgot password option for biometric - switch to database password
          if viewModel.connectionState == .connected {
            Button(action: {
              useDbPasswordForAuth = true
              authError = nil
            }) {
              Text("Use Database Password Instead")
                .font(.small)
                .foregroundColor(.accent)
            }
            .buttonStyle(.plain)
          }

          if let error = authError {
            Text(error)
              .font(.small)
              .foregroundColor(.destructive)
          }
        }
      } else {
        // Password entry (Safe Mode password or database password)
        VStack(alignment: .leading, spacing: Spacing.sm) {
          HStack {
            Text(
              useDbPasswordForAuth
                ? "Enter database password:" : "Enter Safe Mode password:"
            )
            .font(.bodyText)
            .foregroundColor(.foreground)

            Spacer()

            // Forgot password option - only show when connected and not already using db password
            if viewModel.connectionState == .connected && !appSettings.isBiometricEnabled {
              Button(action: {
                useDbPasswordForAuth.toggle()
                authPassword = ""
                authError = nil
              }) {
                Text(useDbPasswordForAuth ? "Use Safe Mode Password" : "Forgot Password?")
                  .font(.small)
                  .foregroundColor(.accent)
              }
              .buttonStyle(.plain)
            }
          }

          SecureField("Password", text: $authPassword)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              verifyPasswordForAction()
            }

          if useDbPasswordForAuth {
            Text("Using database connection password to verify your identity.")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
          }

          if let error = authError {
            Text(error)
              .font(.small)
              .foregroundColor(.destructive)
          }
        }
      }

      // Buttons
      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          showAuthSheet = false
          pendingAction = nil
          authPassword = ""
          authError = nil
          useDbPasswordForAuth = false
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        // Show Confirm button when not using biometric OR using database password fallback
        if !appSettings.isBiometricEnabled || useDbPasswordForAuth {
          Button("Confirm") {
            verifyPasswordForAction()
          }
          .buttonStyle(.borderedProminent)
          .tint(.destructive)
          .disabled(authPassword.isEmpty)
        }
      }
    }
    .padding(Spacing.xl)
    .frame(width: 400)
    .background(Color.appBackground)
  }

  private var authenticationTitle: String {
    switch pendingAction {
    case .changeSafeMode:
      return "Change Safe Mode"
    case .removeProtection:
      return "Remove Protection"
    case .switchToPassword:
      return "Switch to Password"
    case .switchToBiometric:
      return "Switch to Touch ID"
    case .none:
      return "Authentication Required"
    }
  }

  private func verifyPasswordForAction() {
    if useDbPasswordForAuth {
      // Verify using database password
      guard authPassword == viewModel.editingConnectionConfig.password else {
        authError = "Incorrect database password"
        return
      }
    } else {
      // Verify using Safe Mode password
      guard appSettings.verifySafeModePassword(authPassword) else {
        authError = "Incorrect password"
        return
      }
    }

    executeProtectedAction()
  }

  private func authenticateForAction() {
    isAuthenticating = true
    authError = nil

    Task {
      do {
        let success = try await appSettings.verifyBiometric()
        await MainActor.run {
          isAuthenticating = false
          if success {
            executeProtectedAction()
          } else {
            authError = "Authentication failed"
          }
        }
      } catch {
        await MainActor.run {
          isAuthenticating = false
          // Check if user cancelled
          let nsError = error as NSError
          let isCancelled =
            nsError.code == -2 || nsError.code == -4 || nsError.code == -9
            || nsError.localizedDescription.lowercased().contains("cancel")

          if isCancelled {
            authError = "Authentication cancelled. Try again."
          } else {
            authError = error.localizedDescription
          }
        }
      }
    }
  }

  private func executeProtectedAction() {
    guard let action = pendingAction else { return }

    // Common cleanup for all actions
    let cleanup = {
      showAuthSheet = false
      pendingAction = nil
      authPassword = ""
      authError = nil
      useDbPasswordForAuth = false
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
      // Open password setup
      dialogMode = .password
      currentPassword = ""
      newPassword = ""
      confirmPassword = ""
      passwordError = nil
      isChangingPassword = false  // Switching from Touch ID, not changing password
      useDbPasswordForChange = false
      showPasswordSetup = true

    case .switchToBiometric:
      cleanup()
      // Open biometric setup
      dialogMode = .biometric
      newPassword = ""
      confirmPassword = ""
      passwordError = nil
      showPasswordSetup = true
    }
  }
}
