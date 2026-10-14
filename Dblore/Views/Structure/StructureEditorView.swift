// StructureEditorView.swift
// The structure editor panel: one table's columns, indexes and constraints with staged changes,
// the exact DDL Apply sends (previewed with `SQLCodeWell`), and the Safe Mode step before it is
// sent. A view-only table (DuckDB, protected or paused connection) shows everything read-only.
// Apply results and new preview errors show as toasts, drawn over the panel (its backdrop covers
// the window's toast overlay); an Apply error also keeps its full text in a banner.

import SwiftUI

extension View {
  /// Presents `workspaceManager.structureEditor` in a right sidebar that slides in from the
  /// trailing edge, wider than Settings but at most 80% of the window
  func structureEditorPanel(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.structureEditor != nil },
      set: { if !$0 { workspaceManager.closeStructureEditor() } }
    )
    return sidePanelOverlay(
      isPresented: isPresented, width: StructureEditorView.panelWidth, maxWidthFraction: 0.8
    ) {
      if let model = workspaceManager.structureEditor {
        StructureEditorView(
          model: model,
          databaseType: workspaceManager.workspace.connectionConfig?.databaseType ?? .postgresql,
          engineName: StructureEditorView.engineName(
            workspaceManager.workspace.connectionConfig?.databaseType,
            server: workspaceManager.mysqlServerInfo),
          databasePassword: workspaceManager.workspace.connectionConfig?.password,
          isConnected: workspaceManager.connectionState == .connected,
          isShown: StructureEditorView.isShown(model, in: workspaceManager),
          isPresented: isPresented
        )
        .id(ObjectIdentifier(model))
      }
    }
  }
}

struct StructureEditorView: View {
  @Bindable var model: StructureEditorModel
  let databaseType: DatabaseType
  let engineName: String
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  /// False once the editor was closed or replaced (a late Touch ID answer then sends nothing)
  let isShown: () -> Bool
  @Binding var isPresented: Bool

  /// Width of the right sidebar the editor opens in (the columns table needs room)
  static let panelWidth: CGFloat = 960

  /// The catalog read wraps its error twice; the editor shows the server's text only
  private static let loadErrorPrefix = "Query failed: Failed to fetch table structure: "

  static func engineName(_ type: DatabaseType?, server: MySQLServerInfo?) -> String {
    guard let type else { return "" }
    if type == .mysql, server?.flavor == .mariadb { return "MariaDB" }
    return type.rawValue
  }

  /// Built outside the panel content closure, which already holds `workspaceManager` strongly
  static func isShown(
    _ model: StructureEditorModel, in workspaceManager: WorkspaceManager
  )
    -> () -> Bool
  {
    { [weak workspaceManager, weak model] in
      guard let workspaceManager, let model else { return false }
      return workspaceManager.structureEditor === model
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "\(model.schema).\(model.table)", titleIcon: "tablecells",
        titleIconColor: .accent, titleBadge: engineName, onClose: { isPresented = false })
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          banners
          content
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      .overlay { ToastOverlay() }
      if let statements = model.pendingConfirmation {
        StructureConfirmationPanel(
          model: model, statements: statements, databasePassword: databasePassword,
          isConnected: isConnected, isShown: isShown)
      }
      footer
    }
    .background(Color.cardBackground)
  }

  // MARK: - Sections

  @ViewBuilder
  private var banners: some View {
    if let reason = model.disabledReason {
      StructureBanner(text: reason, systemImage: "lock", color: .warning)
    }
    if let error = model.applyError {
      StructureBanner(
        text: error, systemImage: "exclamationmark.triangle",
        color: model.applyPartiallyFailed ? .warning : .destructive)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.loadState {
    case .idle, .loading:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Loading structure...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      .frame(maxWidth: .infinity, minHeight: 200)
    case .failed(let message):
      StructureBanner(
        text: Self.displayedLoadError(message), systemImage: "exclamationmark.triangle",
        color: .destructive)
    case .loaded:
      Group {
        StructureColumnsSection(model: model, databaseType: databaseType)
        StructureIndexesSection(model: model, databaseType: databaseType)
        StructureConstraintsSection(model: model, databaseType: databaseType)
      }
      .disabled(model.isApplying)
      if !model.isReadOnly { previewSection }
    }
  }

  private var previewSection: some View {
    SettingsGroupCard(title: "SQL Preview") {
      Text("Apply sends exactly this SQL")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      // A builder error leaves no statements: it takes the placeholder's place in the well
      SQLCodeWell(
        sql: model.previewStatements.map { $0 + ";" }.joined(separator: "\n"),
        placeholder: model.previewError == nil ? "No changes" : nil, dialect: databaseType.dialect
      )
      .overlay(alignment: .topLeading) {
        if let error = model.previewError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .padding(Spacing.md)
        }
      }
      .frame(height: 160)
    }
  }

  private var footer: some View {
    GenericModalFooter {
      if model.isReadOnly {
        Text("View only")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else if !model.changes.isEmpty {
        Text(model.changes.count == 1 ? "1 change" : "\(model.changes.count) changes")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      Spacer()
      Button {
        Task { await model.reload() }
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(model.isApplying || model.loadState == .loading)
      .help(model.changes.isEmpty ? "Read the table again" : "Discard the changes and read again")
      if !model.isReadOnly {
        Button("Discard") { model.discardChanges() }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(model.changes.isEmpty || model.isApplying)
      }
      Button("Close") { isPresented = false }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.isApplying)
      if !model.isReadOnly {
        Button(model.isApplying ? "Applying..." : "Apply") {
          Task { await model.apply() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canApply || model.pendingConfirmation != nil)
      }
    }
  }

  static func displayedLoadError(_ message: String) -> String {
    message.hasPrefix(loadErrorPrefix)
      ? String(message.dropFirst(loadErrorPrefix.count)) : message
  }
}

// MARK: - Shared pieces

/// Inline message with a tinted background (results, warnings, errors)
struct StructureBanner: View {
  let text: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.small)
      .foregroundColor(color)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.md)
      .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: CornerRadius.lg))
      .overlay(
        HairlineBorder(
          shape: RoundedRectangle(cornerRadius: CornerRadius.lg), color: color.opacity(0.4))
      )
  }
}

/// Added / edited / dropped marker in front of a row
struct StructureStateMarker: View {
  let state: StructureEditorModel.StagedState

  var body: some View {
    Circle()
      .fill(Self.color(state) ?? .clear)
      .frame(width: 6, height: 6)
      .help(Self.label(state))
      .accessibilityLabel(Self.label(state))
      .accessibilityHidden(state == .unchanged)
  }

  static func color(_ state: StructureEditorModel.StagedState) -> Color? {
    switch state {
    case .unchanged: nil
    case .added: .success
    case .edited: .warning
    case .dropped: .destructive
    }
  }

  static func label(_ state: StructureEditorModel.StagedState) -> String {
    switch state {
    case .unchanged: ""
    case .added: "Added"
    case .edited: "Edited"
    case .dropped: "Dropped"
    }
  }
}

// Columns, indexes and constraints render as tables on a white card: a tinted header row ruled
// off from the data, data rows split by light rules, and the add form below a rule.
// The header fill names `Rectangle()`: a bare color background inside the card's rounded clip
// comes out with rounded, inset corners.
extension View {
  /// Header row of a structure table
  func structureTableHeader() -> some View {
    font(.small)
      .fontWeight(.medium)
      .foregroundColor(.gridForeground)
      .lineLimit(1)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.tableHeaderBackground, in: Rectangle())
      .overlay(alignment: .bottom) {
        Rectangle().fill(Color.borderStrong).frame(height: 1)
      }
  }

  /// Vertical rule on the leading edge of a header cell, centered in the `Spacing.sm` gap and
  /// spanning the header row
  func structureColumnDivider() -> some View {
    overlay(alignment: .leading) {
      Rectangle()
        .fill(Color.border)
        .frame(width: 1)
        .padding(.vertical, -Spacing.sm)
        .offset(x: -Spacing.sm / 2)
    }
  }

  /// Data row of a structure table; every row but the first is ruled off from the one above
  func structureTableRow(isFirst: Bool) -> some View {
    padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .frame(maxWidth: .infinity, minHeight: ButtonMetrics.regularHeight, alignment: .leading)
      .overlay(alignment: .top) {
        if !isFirst {
          Rectangle().fill(Color.border).frame(height: 1)
        }
      }
  }

  /// Input capsule of the structure editor, smaller than `inputCapsuleStyle`: as tall as a
  /// regular button, so fields, menus and the Add buttons line up
  func structureInputStyle() -> some View {
    padding(.horizontal, Spacing.sm + 2)
      .frame(height: ButtonMetrics.regularHeight)
      .background(Color.controlBackground)
      .clipShape(Capsule())
      .overlay(HairlineBorder(shape: Capsule()))
  }

  /// Add form under the rows of a structure table
  func structureTableFooter() -> some View {
    padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .top) {
        Rectangle().fill(Color.border).frame(height: 1)
      }
  }
}

extension Font {
  /// Field and cell text of the structure editor, one step under `monoMedium` (11pt)
  static let structureField = Font.system(.subheadline, design: .monospaced)
}

/// Text field that stages its value on Return or when it loses focus (not on every keystroke,
/// so a half-typed type or default does not flash a preview error)
struct StructureCommitField: View {
  let value: String
  var placeholder = ""
  var isEdited = false
  let onCommit: (String) -> Void

  @State private var draft = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $draft)
      .textFieldStyle(.plain)
      .font(.structureField)
      .foregroundColor(isEdited ? .warning : .structureCellForeground)
      .structureInputStyle()
      .focused($isFocused)
      .onSubmit(commit)
      .onChange(of: isFocused) { _, focused in
        if !focused { commit() }
      }
      .onChange(of: value, initial: true) { _, newValue in
        if !isFocused { draft = newValue }
      }
  }

  private func commit() {
    if draft != value { onCommit(draft) }
  }
}

// MARK: - Safe Mode

/// Safe Mode step inside the panel (a sheet cannot sit on the panel overlay): lists the
/// statements and their reasons, then asks for Touch ID or the Safe Mode password when the
/// commit style requires it, the same checks as the query confirmation sheet.
private struct StructureConfirmationPanel: View {
  let model: StructureEditorModel
  let statements: [StatementConfirmation]
  let databasePassword: String?
  let isConnected: Bool
  let isShown: () -> Bool

  @State private var passwordEntry = ""
  @State private var passwordError: String?
  @State private var isBiometricAuthenticating = false
  @State private var useDatabasePassword = false

  private var requiresPassword: Bool { model.confirmationRequiresPassword }

  private var showsTouchID: Bool {
    AppSettings.shared.isBiometricEnabled && AppSettings.shared.canUseTouchID
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Divider()
      HStack(spacing: Spacing.sm) {
        Image(systemName: "lock.shield.fill")
          .foregroundColor(.accent)
        Text(requiresPassword ? "Safe Mode - Authorization Required" : "Confirm the changes")
          .font(.subheading)
          .foregroundColor(.foreground)
      }
      .padding(.horizontal, Spacing.md)

      statementList
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
        .padding(.horizontal, Spacing.md)

      if requiresPassword {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          if showsTouchID { biometricButton }
          passwordEntrySection
        }
        .padding(.horizontal, Spacing.md)
      }

      HStack(spacing: Spacing.md) {
        Spacer()
        Button("Cancel") { model.cancelConfirmation() }
          .buttonStyle(FilledSecondaryButtonStyle())
        Button("Apply Changes", action: confirm)
          .buttonStyle(DangerButtonStyle())
          .disabled(
            requiresPassword && !AppSettings.shared.hasCustomPasswordSet && !useDatabasePassword)
      }
      .padding(.horizontal, Spacing.md)
      .padding(.bottom, Spacing.md)
    }
    .background(Color.cardHeaderBackground)
    .task {
      if requiresPassword && showsTouchID { authenticateWithBiometric() }
    }
  }

  private var statementList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(statements) { statement in
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
      }
    }
    .frame(maxHeight: 140)
  }

  private var biometricButton: some View {
    Button(action: authenticateWithBiometric) {
      HStack(spacing: Spacing.sm) {
        if isBiometricAuthenticating {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "touchid")
        }
        Text(isBiometricAuthenticating ? "Authenticating..." : "Use Touch ID")
          .font(.bodyText)
      }
      .foregroundColor(.accent)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.sm)
      .background(Color.accent.opacity(0.1))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .disabled(isBiometricAuthenticating)
  }

  private var passwordEntrySection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.md) {
        Text(
          useDatabasePassword
            ? "Enter database password:"
            : (showsTouchID ? "Or enter Safe Mode password:" : "Enter Safe Mode password:")
        )
        .font(.labelText)
        .foregroundColor(.foreground)
        .fixedSize()
        SecureField("Password", text: $passwordEntry)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .onSubmit(confirm)
        if isConnected
          && (useDatabasePassword
            || NotebookViewModel.showsDatabasePasswordFallback(
              hasSafeModePassword: AppSettings.shared.hasCustomPasswordSet))
        {
          Button(useDatabasePassword ? "Use Safe Mode Password" : "Forgot Password?") {
            useDatabasePassword.toggle()
            passwordEntry = ""
            passwordError = nil
          }
          .font(.small)
          .foregroundColor(.accent)
          .buttonStyle(.plain)
          .linkPointer()
          .fixedSize()
        }
      }
      if let passwordError {
        Text(passwordError)
          .font(.small)
          .foregroundColor(.destructive)
      }
      if useDatabasePassword {
        Text("Using the database connection password to authorize these changes.")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
      } else if !AppSettings.shared.hasCustomPasswordSet {
        Text("No password has been set. Set a password in Settings first.")
          .font(.small)
          .foregroundColor(.warning)
      }
    }
  }

  private func confirm() {
    if requiresPassword {
      if useDatabasePassword {
        let hasSafeModePassword = AppSettings.shared.hasCustomPasswordSet
        guard
          NotebookViewModel.acceptsDatabasePasswordFallback(
            entry: passwordEntry, storedPassword: databasePassword,
            hasSafeModePassword: hasSafeModePassword)
        else {
          passwordError =
            hasSafeModePassword
            ? "A Safe Mode password is set: use it or Touch ID"
            : "Incorrect database password"
          return
        }
      } else {
        guard AppSettings.shared.verifySafeModePassword(passwordEntry) else {
          passwordError = "Incorrect password"
          return
        }
      }
    }
    passwordEntry = ""
    passwordError = nil
    Task { await model.confirmApply() }
  }

  private func authenticateWithBiometric() {
    guard !isBiometricAuthenticating else { return }
    isBiometricAuthenticating = true
    passwordError = nil
    Task { @MainActor in
      let success = await SafeModeAuthenticator.shared.authenticate(
        reason: "Authorize the structure change in Safe Mode")
      isBiometricAuthenticating = false
      guard success else {
        passwordError = "Touch ID did not unlock. Enter your password instead."
        return
      }
      // The step may have been cancelled, or the editor closed, while Touch ID was up
      guard model.pendingConfirmation != nil, isShown() else { return }
      passwordEntry = ""
      await model.confirmApply()
    }
  }
}
