//
//  SharedViewModifiers.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Search Notification Handler

/// Handles search-related notifications
/// Used by both Notebook and Editor modes
struct SearchNotificationHandler: ViewModifier {
  let viewModel: NotebookViewModel

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
        viewModel.openSearch()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
        viewModel.navigateToNextMatch()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
        viewModel.navigateToPreviousMatch()
      }
  }
}

// MARK: - Focused Scene Actions

/// Handles focused scene values for sidebar and search actions
/// Used by both Notebook and Editor modes
struct FocusedSceneActions: ViewModifier {
  let viewModel: NotebookViewModel
  let documentMode: DocumentMode

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.documentMode, documentMode)
      .focusedSceneValue(\.toggleLeftSidebarAction) { [viewModel] in
        viewModel.toggleLeftSidebar()
      }
      .focusedSceneValue(\.toggleRightSidebarAction) { [viewModel] in
        viewModel.toggleSidebar()
      }
      .focusedSceneValue(\.openSearchAction) { [viewModel] in
        viewModel.openSearch()
      }
      .focusedSceneValue(\.findNextAction) { [viewModel] in
        viewModel.navigateToNextMatch()
      }
      .focusedSceneValue(\.findPreviousAction) { [viewModel] in
        viewModel.navigateToPreviousMatch()
      }
  }
}

// MARK: - Query Confirmation Dialog

/// Adds query confirmation dialog with Safe Mode support
/// Uses sheet for password entry (Safe Mode levels 3-4), confirmationDialog otherwise
/// Used by both Notebook and Editor modes
extension View {
  func queryConfirmationDialog(
    viewModel: NotebookViewModel,
    syncDocument: @escaping () -> Void
  ) -> some View {
    self.modifier(QueryConfirmationModifier(viewModel: viewModel, syncDocument: syncDocument))
  }

  // Keep old name for backward compatibility
  func destructiveQueryDialog(
    viewModel: NotebookViewModel,
    syncDocument: @escaping () -> Void
  ) -> some View {
    queryConfirmationDialog(viewModel: viewModel, syncDocument: syncDocument)
  }
}

/// View modifier that handles both confirmation dialog and password sheet
private struct QueryConfirmationModifier: ViewModifier {
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void
  @State private var passwordEntry: String = ""
  @State private var passwordError: String?
  @State private var isBiometricAuthenticating: Bool = false
  @State private var useDatabasePassword: Bool = false  // Forgot password mode

  func body(content: Content) -> some View {
    content
      // Show sheet for password-protected modes
      .sheet(
        isPresented: Binding(
          get: {
            viewModel.queryConfirmationState.showDialog
              && viewModel.queryConfirmationState.requiresPassword
          },
          set: { if !$0 { viewModel.cancelPendingQuery() } }
        )
      ) {
        passwordConfirmationSheet
      }
      // Show simple confirmation dialog for non-password modes
      .confirmationDialog(
        "Confirm Query Execution",
        isPresented: Binding(
          get: {
            viewModel.queryConfirmationState.showDialog
              && !viewModel.queryConfirmationState.requiresPassword
          },
          set: { viewModel.queryConfirmationState.showDialog = $0 }
        ),
        titleVisibility: .visible
      ) {
        Button("Execute Query", role: .destructive) {
          Task { @MainActor in
            await viewModel.executePendingQuery()
            syncDocument()
          }
        }
        Button("Cancel", role: .cancel) {
          viewModel.cancelPendingQuery()
        }
      } message: {
        VStack(alignment: .leading, spacing: 8) {
          if viewModel.queryConfirmationState.affectsAllRows {
            Text("⚠️ WARNING: This query has no WHERE clause and will affect ALL rows!")
              .font(.body.bold())
              .foregroundStyle(.red)
          } else {
            Text("This query will modify data in your database:")
              .font(.body)
          }
          Text(viewModel.queryConfirmationState.pendingQuery)
            .font(.system(.body, design: .monospaced))
            .lineLimit(5)
          Text("Are you sure you want to proceed?")
            .font(.body)
        }
      }
  }

  private var passwordConfirmationSheet: some View {
    VStack(spacing: Spacing.lg) {
      // Header
      HStack {
        Image(systemName: "lock.shield.fill")
          .font(.title)
          .foregroundColor(.accent)
        Text("Safe Mode - Authorization Required")
          .font(.heading)
          .foregroundColor(.foreground)
      }

      // Warning for dangerous queries
      if viewModel.queryConfirmationState.affectsAllRows {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.destructive)
          Text("WARNING: This query has no WHERE clause and will affect ALL rows!")
            .font(.bodyText)
            .foregroundColor(.destructive)
        }
        .padding(Spacing.md)
        .background(Color.destructive.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }

      // Query preview
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Query to execute:")
          .font(.subheading)
          .foregroundColor(.foreground)

        Text(viewModel.queryConfirmationState.pendingQuery)
          .font(.mono)
          .foregroundColor(.foregroundMuted)
          .lineLimit(5)
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.inputBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }

      // Authorization options
      if AppSettings.shared.isBiometricEnabled {
        // Touch ID option
        biometricAuthSection
      } else {
        // Password entry
        passwordEntrySection
      }

      // Buttons
      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          passwordEntry = ""
          passwordError = nil
          useDatabasePassword = false
          viewModel.cancelPendingQuery()
        }
        .buttonStyle(.plain)
        .foregroundColor(.foregroundMuted)

        if !AppSettings.shared.isBiometricEnabled {
          Button("Execute Query") {
            verifyAndExecute()
          }
          .buttonStyle(.borderedProminent)
          .tint(.destructive)
          // Enable button if Safe Mode password is set OR using database password mode
          .disabled(!AppSettings.shared.isSafeModePasswordSet && !useDatabasePassword)
        }
      }
    }
    .padding(Spacing.xl)
    .frame(width: 450)
    .background(Color.appBackground)
  }

  private var biometricAuthSection: some View {
    VStack(spacing: Spacing.md) {
      Button(action: {
        authenticateWithBiometric()
      }) {
        HStack(spacing: Spacing.sm) {
          if isBiometricAuthenticating {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Image(systemName: "touchid")
              .font(.title)
          }
          Text(isBiometricAuthenticating ? "Authenticating..." : "Use Touch ID")
            .font(.bodyText)
        }
        .foregroundColor(.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .background(Color.accent.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }
      .buttonStyle(.plain)
      .disabled(isBiometricAuthenticating)

      if let error = passwordError {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
      }
    }
  }

  private var passwordEntrySection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text(useDatabasePassword ? "Enter database password:" : "Enter Safe Mode password:")
          .font(.subheading)
          .foregroundColor(.foreground)

        Spacer()

        // Forgot password / Back button
        if viewModel.connectionState == .connected {
          Button(action: {
            useDatabasePassword.toggle()
            passwordEntry = ""
            passwordError = nil
          }) {
            Text(useDatabasePassword ? "Use Safe Mode Password" : "Forgot Password?")
              .font(.small)
              .foregroundColor(.accent)
          }
          .buttonStyle(.plain)
        }
      }

      SecureField("Password", text: $passwordEntry)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          verifyAndExecute()
        }

      if let error = passwordError {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
      }

      if useDatabasePassword {
        Text("Using database connection password to authorize this query.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      } else if !AppSettings.shared.isSafeModePasswordSet {
        Text("⚠️ No password has been set. Please set a password in Settings first.")
          .font(.small)
          .foregroundColor(.warning)
      }
    }
  }

  private func verifyAndExecute() {
    if useDatabasePassword {
      // Verify using database connection password
      guard passwordEntry == viewModel.notebook.connectionConfig?.password else {
        passwordError = "Incorrect database password"
        return
      }
    } else {
      // Verify using Safe Mode password
      guard AppSettings.shared.verifySafeModePassword(passwordEntry) else {
        passwordError = "Incorrect password"
        return
      }
    }

    passwordEntry = ""
    passwordError = nil
    useDatabasePassword = false

    Task { @MainActor in
      await viewModel.executePendingQuery()
      syncDocument()
    }
  }

  private func authenticateWithBiometric() {
    isBiometricAuthenticating = true
    passwordError = nil

    Task {
      do {
        let success = try await AppSettings.shared.verifyBiometric()
        await MainActor.run {
          isBiometricAuthenticating = false
          if success {
            Task {
              await viewModel.executePendingQuery()
              syncDocument()
            }
          } else {
            passwordError = "Authentication failed"
          }
        }
      } catch {
        await MainActor.run {
          isBiometricAuthenticating = false
          passwordError = error.localizedDescription
        }
      }
    }
  }
}

// MARK: - Search and Scene Actions

extension View {
  func searchNotifications(viewModel: NotebookViewModel) -> some View {
    modifier(SearchNotificationHandler(viewModel: viewModel))
  }

  func focusedSceneActions(viewModel: NotebookViewModel, mode: DocumentMode) -> some View {
    modifier(FocusedSceneActions(viewModel: viewModel, documentMode: mode))
  }
}
