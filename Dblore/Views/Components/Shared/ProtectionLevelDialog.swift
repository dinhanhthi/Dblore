//
//  ProtectionLevelDialog.swift
//  Dblore
//
//  Reusable confirmation dialog for changing connection protection level. Lowering the level
//  while the effective Safe Mode requires a password needs the Safe Mode unlock first
//  (`NotebookViewModel.requestProtectionLevelChange`); nothing changes until it succeeds.
//

import SwiftUI

/// View modifier that adds a protection level change dialog and the unlock sheet it may need
struct ProtectionLevelDialogModifier: ViewModifier {
  @Binding var isPresented: Bool
  let viewModel: NotebookViewModel

  /// Level held until the Safe Mode unlock succeeds (sheet shown while non-nil)
  @State private var pendingLevel: ConnectionProtectionLevel?

  private var currentLevel: ConnectionProtectionLevel {
    viewModel.notebook.connectionConfig?.protectionLevel ?? .none
  }

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Change Protection Level?",
        isPresented: $isPresented,
        titleVisibility: .visible
      ) {
        Button("Disable Protection", role: .destructive) {
          request(.none)
        }
        if currentLevel == .readOnly {
          Button("Schema Protection Only") {
            request(.schemaOnly)
          }
        }
        if currentLevel == .schemaOnly {
          Button("Enable Read-Only Mode") {
            request(.readOnly)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Choose a new protection level for this connection.")
      }
      .sheet(
        isPresented: Binding(
          get: { pendingLevel != nil },
          set: { if !$0 { pendingLevel = nil } }
        )
      ) {
        SafeModeUnlockSheet(
          message:
            "Safe Mode requires verification to lower this connection's protection to \"\(pendingLevel?.displayName ?? "")\".",
          biometricReason: "Lower the connection protection level",
          storedDatabasePassword: viewModel.notebook.connectionConfig?.password,
          onUnlock: completeUnlock,
          onCancel: { pendingLevel = nil })
      }
  }

  /// Apply now, or hold the level and ask for the Safe Mode unlock
  private func request(_ level: ConnectionProtectionLevel) {
    guard !viewModel.requestProtectionLevelChange(to: level) else { return }
    pendingLevel = level
  }

  private func completeUnlock() {
    // The sheet may have been cancelled while the Touch ID prompt was up
    guard let level = pendingLevel else { return }
    viewModel.applyProtectionLevel(level)
    pendingLevel = nil
  }
}

/// Safe Mode unlock sheet: Touch ID (when enabled), the Safe Mode password, or the database
/// password via `acceptsDatabasePasswordFallback` only while no Safe Mode password exists.
/// `storedDatabasePassword` must be the password of the connection being protected (never a
/// password the user just typed into a form). `onUnlock` runs once on success.
struct SafeModeUnlockSheet: View {
  let message: String
  let biometricReason: String
  let storedDatabasePassword: String?
  let onUnlock: () -> Void
  let onCancel: () -> Void

  @State private var password: String = ""
  @State private var useDatabasePassword: Bool = false
  @State private var errorMessage: String?
  @State private var isAuthenticating: Bool = false
  @State private var showsSafeModeSettings: Bool = false

  private var showsTouchID: Bool {
    AppSettings.shared.isBiometricEnabled && AppSettings.shared.canUseTouchID
  }

  /// The database password is offered only while no Safe Mode password exists and the
  /// connection has a stored database password to compare against
  private var offersDatabasePassword: Bool {
    NotebookViewModel.showsDatabasePasswordFallback(
      hasSafeModePassword: AppSettings.shared.hasCustomPasswordSet)
      && !(storedDatabasePassword ?? "").isEmpty
  }

  /// Neither a Safe Mode password nor Touch ID exists: offer to set one up (never unlocks)
  private var offersUnlockSetup: Bool {
    !AppSettings.shared.hasCustomPasswordSet && !AppSettings.shared.isBiometricEnabled
  }

  var body: some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "lock.shield.fill")
        .font(.system(size: 48))
        .foregroundColor(.accent)

      VStack(spacing: Spacing.xs) {
        Text("Authentication Required")
          .font(.heading)
          .foregroundColor(.foreground)
        Text(message)
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
          .multilineTextAlignment(.center)
      }

      if showsTouchID && !useDatabasePassword {
        Button("Use Touch ID") {
          authenticateWithBiometric()
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isAuthenticating)
      }

      VStack(spacing: Spacing.sm) {
        SecureField(
          useDatabasePassword ? "Database Password" : "Safe Mode Password", text: $password
        )
        .textFieldStyle(.plain)
        .inputStyle()
        .onSubmit { verifyPassword() }

        if offersDatabasePassword {
          Button(useDatabasePassword ? "Use Safe Mode password" : "Use database password") {
            useDatabasePassword.toggle()
            password = ""
            errorMessage = nil
          }
          .font(.small)
          .foregroundColor(.accent)
          .buttonStyle(.plain)
          .linkPointer()
        }
      }

      if offersUnlockSetup {
        unlockSetup
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.small)
          .foregroundColor(.destructive)
      }

      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          onCancel()
        }
        .buttonStyle(SecondaryButtonStyle())

        Button("Verify") {
          verifyPassword()
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(password.isEmpty || isAuthenticating)
      }
    }
    .padding(Spacing.xl)
    .frame(width: 350)
    .background(Color.appBackground)
    .sheet(isPresented: $showsSafeModeSettings) {
      SafeModeModal(isPresented: $showsSafeModeSettings)
    }
  }

  /// Lockout recovery: opens the Safe Mode settings to set a password (Touch ID needs one
  /// first). Setting it up does not unlock: the user still verifies here afterwards.
  private var unlockSetup: some View {
    VStack(spacing: Spacing.xs) {
      Text("No Safe Mode password is set.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
      HStack(spacing: Spacing.md) {
        Button("Set password...") {
          showsSafeModeSettings = true
        }
        Button("Enable Touch ID") {
          showsSafeModeSettings = true
        }
        .disabled(true)
        .foregroundColor(.foregroundMuted)
        .help("Set a Safe Mode password first")
      }
      .font(.small)
      .foregroundColor(.accent)
      .buttonStyle(.plain)
      .linkPointer()
    }
  }

  /// Safe Mode password, or the database password via `acceptsDatabasePasswordFallback` only
  /// when no Safe Mode password exists
  private func verifyPassword() {
    let hasSafeModePassword = AppSettings.shared.hasCustomPasswordSet
    let usingDatabasePassword = useDatabasePassword && !hasSafeModePassword
    let accepted = NotebookViewModel.settingsAcceptsCredential(
      entry: password, usingDatabasePassword: usingDatabasePassword,
      storedDatabasePassword: storedDatabasePassword,
      hasSafeModePassword: hasSafeModePassword,
      verifySafeModePassword: { AppSettings.shared.verifySafeModePassword($0) })
    guard accepted else {
      errorMessage = usingDatabasePassword ? "Invalid database password" : "Invalid password"
      return
    }
    password = ""
    onUnlock()
  }

  private func authenticateWithBiometric() {
    guard !isAuthenticating else { return }
    isAuthenticating = true
    errorMessage = nil
    Task { @MainActor in
      let success = await SafeModeAuthenticator.shared.authenticate(reason: biometricReason)
      isAuthenticating = false
      guard success else {
        errorMessage = "Touch ID did not unlock. Enter your password instead."
        return
      }
      onUnlock()
    }
  }
}

extension View {
  /// Adds the protection level dialog for `viewModel`'s connection. Lowering the level goes
  /// through the Safe Mode unlock when the effective Safe Mode requires a password.
  func protectionLevelDialog(
    isPresented: Binding<Bool>,
    viewModel: NotebookViewModel
  ) -> some View {
    modifier(ProtectionLevelDialogModifier(isPresented: isPresented, viewModel: viewModel))
  }
}
