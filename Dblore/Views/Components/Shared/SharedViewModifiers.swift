//
//  SharedViewModifiers.swift
//  Dblore
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
            Text("These statements need confirmation:")
              .font(.body)
          }
          Text(statementSummary)
            .font(.system(.body, design: .monospaced))
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

      // Statements that need confirmation
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Statements to confirm:")
          .font(.subheading)
          .foregroundColor(.foreground)

        statementList
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.inputBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      }

      // Authorization: Touch ID first (prompted on appear), Safe Mode password as fallback
      if showsTouchID {
        biometricAuthSection
      }
      passwordEntrySection

      // Buttons
      HStack(spacing: Spacing.md) {
        Button("Cancel") {
          passwordEntry = ""
          passwordError = nil
          useDatabasePassword = false
          viewModel.cancelPendingQuery()
        }
        .buttonStyle(SecondaryButtonStyle())

        Button(viewModel.queryConfirmationState.runAllAwaitingUnlock ? "Run All" : "Execute Query")
        {
          verifyAndExecute()
        }
        .buttonStyle(DangerButtonStyle())
        // Enable button if a Safe Mode password is set OR using database password mode
        .disabled(!AppSettings.shared.hasCustomPasswordSet && !useDatabasePassword)
      }
    }
    .padding(Spacing.xl)
    .frame(width: 450)
    .background(Color.appBackground)
    .task {
      if showsTouchID { authenticateWithBiometric() }
    }
  }

  /// Touch ID is enabled for Safe Mode and usable now
  private var showsTouchID: Bool {
    AppSettings.shared.isBiometricEnabled && AppSettings.shared.canUseTouchID
  }

  /// Plain-text list for the confirmation dialog message (text only on macOS), capped so a
  /// huge cell under alertAll stays readable
  private var statementSummary: String {
    let statements = viewModel.queryConfirmationState.statements
    guard !statements.isEmpty else { return viewModel.queryConfirmationState.pendingQuery }
    return NotebookViewModel.confirmationSummary(statements)
  }

  /// Each statement needing confirmation with its reason badges (password sheet)
  private var statementList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(viewModel.queryConfirmationState.statements) { statement in
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(statement.index + 1). \(statement.preview)")
              .font(.mono)
              .foregroundColor(.foregroundMuted)
              .lineLimit(2)
            Text(statement.kindLabel)
              .font(.small)
              .foregroundColor(.foregroundSubtle)
            ForEach(statement.reasons, id: \.self) { reason in
              Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.small)
                .foregroundColor(.destructive)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Color.destructive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if viewModel.queryConfirmationState.statements.isEmpty {
          Text(viewModel.queryConfirmationState.pendingQuery)
            .font(.mono)
            .foregroundColor(.foregroundMuted)
            .lineLimit(5)
        }
      }
    }
    .frame(maxHeight: 200)
  }

  private var biometricAuthSection: some View {
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
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .disabled(isBiometricAuthenticating)
  }

  private var passwordEntrySection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text(
          useDatabasePassword
            ? "Enter database password:"
            : (showsTouchID ? "Or enter Safe Mode password:" : "Enter Safe Mode password:")
        )
        .font(.subheading)
        .foregroundColor(.foreground)

        Spacer()

        // Forgot password / Back button (database password only while no Safe Mode password)
        if viewModel.connectionState == .connected
          && (useDatabasePassword
            || NotebookViewModel.showsDatabasePasswordFallback(
              hasSafeModePassword: AppSettings.shared.hasCustomPasswordSet))
        {
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
          .linkPointer()
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
      } else if !AppSettings.shared.hasCustomPasswordSet {
        Text("⚠️ No password has been set. Please set a password in Settings first.")
          .font(.small)
          .foregroundColor(.warning)
      }
    }
  }

  private func verifyAndExecute() {
    if useDatabasePassword {
      // Database password: only when no Safe Mode password exists, never empty
      let hasSafeModePassword = AppSettings.shared.hasCustomPasswordSet
      guard
        NotebookViewModel.acceptsDatabasePasswordFallback(
          entry: passwordEntry, storedPassword: viewModel.notebook.connectionConfig?.password,
          hasSafeModePassword: hasSafeModePassword)
      else {
        passwordError =
          hasSafeModePassword
          ? "A Safe Mode password is set: use it or Touch ID"
          : "Incorrect database password"
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
    guard !isBiometricAuthenticating else { return }
    isBiometricAuthenticating = true
    passwordError = nil

    Task { @MainActor in
      let success = await SafeModeAuthenticator.shared.authenticate(
        reason: "Authorize query execution in Safe Mode")
      isBiometricAuthenticating = false
      guard success else {
        passwordError = "Touch ID did not unlock. Enter your password instead."
        return
      }
      // The sheet may have been cancelled while the Touch ID prompt was up
      guard viewModel.queryConfirmationState.showDialog else { return }
      passwordEntry = ""
      useDatabasePassword = false
      await viewModel.executePendingQuery()
      syncDocument()
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
