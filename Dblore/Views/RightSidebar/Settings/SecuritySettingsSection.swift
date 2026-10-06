//
//  SecuritySettingsSection.swift
//  Dblore
//
//  Security settings: Safe Mode, Connection History, Read-only Mode
//

import SwiftUI

struct SecuritySettingsSection: View {
  @Bindable var appSettings: AppSettings
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Protection") {
        ConnectionSafetyMenus(viewModel: viewModel, showsSecurity: false, prominent: true)
      }
      SettingsGroupCard(title: "Safe Mode") {
        SafeModeSection(appSettings: appSettings, viewModel: viewModel)
          .id("safeModeSection")
      }
    }
  }
}

// MARK: - Safe Mode Section (Combined Layout)

/// Combined Safe Mode section with current connection and global settings
struct SafeModeSection: View {
  var appSettings: AppSettings
  var viewModel: NotebookViewModel

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
  }

  // MARK: - Current Connection Row

  private var currentConnectionRow: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Spacing.xs) {
          Text("Commit style")
            .font(.bodyText)
            .foregroundColor(.foreground)
          commitStyleHelpButton
        }
        Text(resolvedConnectionStyle.summary)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      }

      Spacer()

      SafetyOptionMenu(arrowEdge: .top, rows: connectionCommitStyleRows) {
        settingsChoiceLabel(
          title: resolvedConnectionStyle.title,
          systemImage: SafetyOptionStyle.iconName(for: resolvedConnectionStyle),
          color: SafetyOptionStyle.color(for: resolvedConnectionStyle))
      }
    }
  }

  private var resolvedConnectionStyle: CommitStyle {
    let fallback = appSettings.commitStyle
    return viewModel.notebook.connectionConfig?.resolvedCommitStyle(fallback: fallback) ?? fallback
  }

  private var connectionCommitStyleRows: [SafetyOptionRow] {
    SafetyOptionRow.commitStyles(
      idPrefix: "connection", selected: resolvedConnectionStyle
    ) { style in
      handleConnectionCommitStyleChange(to: style)
    }
  }

  private var defaultCommitStyleRows: [SafetyOptionRow] {
    SafetyOptionRow.commitStyles(idPrefix: "default", selected: appSettings.commitStyle) { style in
      handleDefaultCommitStyleChange(to: style)
    }
  }

  /// Same help as the footer. Shown on the connection row and the default row,
  /// so it stays available when nothing is connected.
  private var commitStyleHelpButton: some View {
    CommitStyleSettingsHelpButton()
  }

  private func settingsChoiceLabel(title: String, systemImage: String, color: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: systemImage)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(color)
      Text(title)
        .foregroundStyle(color)
        .lineLimit(1)
      Spacer(minLength: Spacing.xs)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.foregroundMuted)
    }
    .font(.body)
    .frame(width: 140, alignment: .leading)
    .dropdownCapsuleStyle()
  }

  // MARK: - Global Row

  private var globalRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: Spacing.xs) {
            Text("Default commit style")
              .font(.bodyText)
              .foregroundColor(.foreground)
            commitStyleHelpButton
          }
          Text("Used for new connections.")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }

        Spacer()

        SafetyOptionMenu(arrowEdge: .top, rows: defaultCommitStyleRows) {
          settingsChoiceLabel(
            title: appSettings.commitStyle.title,
            systemImage: SafetyOptionStyle.iconName(for: appSettings.commitStyle),
            color: SafetyOptionStyle.color(for: appSettings.commitStyle))
        }
      }

      if appSettings.commitStyle.requiresPassword {
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

  /// A click always requests the style, including a click on the style already resolved.
  /// The default picker writes `AppSettings.commitStyle` only, never this connection.
  private func handleConnectionCommitStyleChange(to style: CommitStyle) {
    if viewModel.requestConnectionCommitStyle(style) { return }
    pendingAction = .changeConnectionCommitStyle(style)
    showAuthSheet = true
  }

  private func handleDefaultCommitStyleChange(to newStyle: CommitStyle) {
    if NotebookViewModel.requiresUnlockForGlobalSafeModeChange(
      from: appSettings.commitStyle, to: newStyle, hasPassword: appSettings.hasCustomPasswordSet,
      hasTouchID: appSettings.isBiometricEnabled)
    {
      pendingAction = .changeDefaultCommitStyle(newStyle)
      showAuthSheet = true
    } else {
      withAnimation(.snappy(duration: 0.2)) {
        appSettings.commitStyle = newStyle
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
          .font(.bodyText)
          .fontWeight(.medium)
          .foregroundColor(appSettings.isSafeModePasswordSet ? .foreground : .warning)
      }

      if !appSettings.isSafeModePasswordSet {
        Text("Set a password to enable protection (then Touch ID if you like).")
          .font(.bodyText)
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
          .font(.bodyText)
          .foregroundColor(.accent)
        }
        .buttonStyle(.plain)
        .linkPointer()

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
            .font(.bodyText)
            .foregroundColor(.accent)
          }
          .buttonStyle(.plain)
          .linkPointer()
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
              .font(.bodyText)
              .foregroundColor(.destructive)
          }
          .buttonStyle(.plain)
          .linkPointer()
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
              .linkPointer()
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
        .linkPointer()
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
              .linkPointer()
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
    case .changeDefaultCommitStyle:
      return "Verify your identity to change the default commit style"
    case .changeConnectionCommitStyle:
      return "Verify your identity to lower this connection's commit style"
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
    case .changeDefaultCommitStyle(let newStyle):
      withAnimation(.snappy(duration: 0.2)) {
        appSettings.commitStyle = newStyle
      }
      cleanup()

    case .changeConnectionCommitStyle(let style):
      viewModel.applyConnectionCommitStyle(style)
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

/// "?" next to a commit-style label. Opening help does not change the style.
private struct CommitStyleSettingsHelpButton: View {
  @State private var showsHelp = false

  var body: some View {
    Button {
      showsHelp = true
    } label: {
      Image(systemName: "questionmark.circle")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help("How writes are handled")
    .popover(isPresented: $showsHelp) {
      CommitStyleHelpView()
    }
  }
}

/// Action that requires authentication
private enum ProtectedAction {
  case changeDefaultCommitStyle(CommitStyle)
  case changeConnectionCommitStyle(CommitStyle)
  case removeProtection
  case switchToPassword  // Switch from Touch ID to password
  case switchToBiometric  // Switch from password to Touch ID
}
