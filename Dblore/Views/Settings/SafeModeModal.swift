//
//  SafeModeModal.swift
//  Dblore
//
//  Modal for Safe Mode settings - accessible from footer indicator
//

import SwiftUI

// MARK: - Safe Mode Modal

/// Modal for configuring Safe Mode settings
/// Compact design without scrollbar - all elements visible
struct SafeModeModal: View {
  @Binding var isPresented: Bool
  @Bindable var appSettings = AppSettings.shared

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
  @State private var usePasswordForAuth: Bool = false

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Database Protection",
        titleIcon: "shield.lefthalf.filled",
        titleIconColor: .accent,
        onClose: { isPresented = false }
      )

      // Content
      VStack(alignment: .leading, spacing: 0) {
        // Mode selector with descriptions
        ForEach(SafeMode.allCases, id: \.self) { mode in
          VStack(alignment: .leading, spacing: 0) {
            // Mode row
            modeRow(for: mode)

            // Password panel - indented under selected Safe modes
            if mode.requiresPassword && appSettings.safeMode == mode {
              passwordPanel
                .padding(.leading, 32)
                .padding(.trailing, Spacing.sm)
                .padding(.bottom, Spacing.xs)
            }
          }
        }
      }
      .padding(Spacing.lg)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 380)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
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
          usePasswordForAuth = !appSettings.canUseTouchID
        }
    }
  }

  // MARK: - Mode Row

  private func modeRow(for mode: SafeMode) -> some View {
    ModeRowView(
      mode: mode,
      isSelected: appSettings.safeMode == mode,
      onTap: { handleSafeModeChange(to: mode) }
    )
  }

  // MARK: - Mode Row View

  private struct ModeRowView: View {
    let mode: SafeMode
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
      Button(action: onTap) {
        HStack(spacing: Spacing.md) {
          // Selection indicator (at the beginning)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 14))
              .foregroundColor(.accent)
          } else {
            Circle()
              .stroke(Color.border, lineWidth: 1.5)
              .frame(width: 14, height: 14)
          }

          // Icon
          Image(systemName: modeIcon(for: mode))
            .font(.system(size: 15))
            .foregroundColor(modeColor(for: mode))
            .frame(width: 18)

          // Text content
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
              Text(mode.displayName)
                .font(.bodyText)
                .fontWeight(.medium)
                .foregroundColor(modeColor(for: mode))

              if mode.requiresPassword {
                Image(systemName: "lock.fill")
                  .font(.system(size: 12))
                  .foregroundColor(.foregroundMuted)
              }
            }

            Text(mode.shortDescription)
              .font(.labelText)
              .foregroundColor(.foregroundMuted)
              .lineLimit(1)
          }

          Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .linkPointer()
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }

    private func modeIcon(for mode: SafeMode) -> String {
      SafetyOptionStyle.iconName(for: mode)
    }

    private func modeColor(for mode: SafeMode) -> Color {
      SafetyOptionStyle.color(for: mode)
    }
  }

  // MARK: - Password Panel (Inline)

  private var passwordPanel: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      // Status text
      HStack(alignment: .center, spacing: Spacing.sm) {
        Image(
          systemName: appSettings.isSafeModePasswordSet
            ? (appSettings.isBiometricEnabled ? "touchid" : "lock.fill")
            : "lock.open.fill"
        )
        .font(.system(size: 12))
        .foregroundColor(appSettings.isSafeModePasswordSet ? .accent : .warning)

        Text(
          appSettings.isSafeModePasswordSet
            ? (appSettings.isBiometricEnabled ? "Touch ID Enabled" : "Password Protected")
            : "Not Protected"
        )
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
      }

      // Action buttons
      HStack(spacing: Spacing.sm) {
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
          HStack(spacing: 4) {
            Image(systemName: "key.fill")
              .font(.system(size: 10))
            Text(appSettings.hasCustomPasswordSet ? "Change" : "Set Password")
          }
          .font(.small)
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        .controlSize(.small)

        if !appSettings.isBiometricEnabled {
          Button(action: {
            if appSettings.isSafeModePasswordSet && !appSettings.isBiometricEnabled {
              pendingAction = .switchToBiometric
              showAuthSheet = true
            } else {
              enableBiometricDirectly()
            }
          }) {
            HStack(spacing: 4) {
              Image(systemName: "touchid")
                .font(.system(size: 10))
              Text("Touch ID")
            }
            .font(.small)
          }
          .buttonStyle(FilledSecondaryButtonStyle())
          .controlSize(.small)
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
          }
          .buttonStyle(DangerButtonStyle())
          .controlSize(.small)
        }
      }
    }
    .padding(Spacing.sm)
    .background(Color.inputBackground.opacity(0.3))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  // MARK: - Password Setup Sheet

  private var passwordSetupSheet: some View {
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
    .padding(Spacing.xl)
    .frame(width: 350)
    .background(Color.appBackground)
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

      if appSettings.isBiometricEnabled && !usePasswordForAuth {
        Button("Use Touch ID") {
          authenticateWithBiometric()
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isAuthenticating)

        Button("Use password instead") {
          usePasswordForAuth = true
        }
        .disabled(!appSettings.hasCustomPasswordSet)
        .font(.small)
        .foregroundColor(.accent)
        .buttonStyle(.plain)
        .linkPointer()
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

  // MARK: - Safe Mode Change Handler

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

// MARK: - View Extension

extension View {
  /// Shows a Safe Mode settings modal
  func safeModeModal(isPresented: Binding<Bool>) -> some View {
    modalOverlay(isPresented: isPresented) {
      SafeModeModal(isPresented: isPresented)
    }
  }
}

// MARK: - Preview

#Preview("Safe Mode Modal") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 600, height: 600)
    .safeModeModal(isPresented: $isPresented)
}
