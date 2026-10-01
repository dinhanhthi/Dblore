//
//  ConnectionFormContent+FormFields.swift
//  Dblore
//
//  Form fields for connection configuration
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Form Fields Extension

extension ConnectionFormContent {

  @ViewBuilder
  func formFields() -> some View {
    let capabilities = connectionConfig.databaseType.capabilities

    VStack(alignment: .leading, spacing: Spacing.sm) {
      FormField(label: "Connection Name") {
        TextField(
          "e.g., Production DB, Development Server", text: $connectionConfig.name
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
      }

      if capabilities.usesNetwork {
        HStack(spacing: Spacing.md) {
          FormField(label: "Host") {
            TextField("localhost", text: $connectionConfig.host)
              .textFieldStyle(.plain)
              .inputCapsuleStyle()
          }

          FormField(label: "Port") {
            TextField(
              "5432", value: $connectionConfig.port, format: .number.grouping(.never)
            )
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
            .frame(width: 80)
          }
        }
      }

      if connectionConfig.databaseType == .sqlite {
        sqliteFileSection()
      } else {
        FormField(label: "Database") {
          TextField("database_name", text: $connectionConfig.database)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
        }
      }

      FormField(label: "Username") {
        TextField("username", text: $connectionConfig.username)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }

      if capabilities.usesPassword {
        FormField(label: "Password") {
          PasswordInputField(password: $connectionConfig.password)
        }
      }

      if capabilities.supportsSSL {
        sslModeMenu(selection: $connectionConfig.sslMode) {
          connectionConfig.sslMode = $0
        }
      }

      FormField(label: "Timeout (seconds)") {
        TextField(
          "30", value: $connectionConfig.timeoutSeconds,
          format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .frame(width: 80)
      }
    }
  }

  @ViewBuilder
  func connectionStringFields() -> some View {
    let capabilities = connectionConfig.databaseType.capabilities

    VStack(alignment: .leading, spacing: Spacing.sm) {
      FormField(label: "Connection Name") {
        TextField(
          "e.g., Production DB, Development Server", text: $connectionConfig.name
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
      }

      FormField(label: "Connection String") {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          TextField(
            "postgresql://username:password@localhost:5432/database", text: connectionStringBinding,
            axis: .vertical
          )
          .textFieldStyle(.plain)
          .font(.system(.body, design: .monospaced))
          .lineLimit(3...6)
          .textAreaCapsuleStyle()
          .onChange(of: connectionStringBinding.wrappedValue) { _, newValue in
            clearParseErrorAndTestResult()
            if !newValue.isEmpty {
              parseConnectionString(newValue)
            }
          }

          Text("Example: postgresql://username:password@localhost:5432/database?sslmode=require")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
      }

      if capabilities.supportsSSL {
        sslModeMenu(selection: connectionStringSSLModeBinding) { mode in
          connectionConfig.sslMode = mode
          clearTestResult()
        }
      }
    }
  }

  private func sslModeMenu(
    selection: Binding<SSLMode>, onSelect: ((SSLMode) -> Void)? = nil
  ) -> some View {
    FormField(label: "SSL Mode") {
      Menu {
        ForEach(SSLMode.allCases, id: \.self) { mode in
          Button(mode.displayName) {
            selection.wrappedValue = mode
            onSelect?(mode)
          }
        }
      } label: {
        HStack {
          Text(selection.wrappedValue.displayName)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .linkPointer()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Name plus Browse. The chosen path is shown under the button.
  @ViewBuilder
  func sqliteSimpleFields() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      FormField(label: "Name") {
        TextField("e.g. Notes", text: $connectionConfig.name)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Button("Browse…", action: chooseSQLiteFile)
          .buttonStyle(SecondaryButtonStyle())
        if !connectionConfig.database.isEmpty {
          Text(connectionConfig.database)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .lineLimit(2)
            .textSelection(.enabled)
        }
      }
    }
  }

  /// File path (`database`), bookmark, and the open-read-only flag. No file password.
  @ViewBuilder
  func sqliteFileSection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      FormField(label: "Database file") {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          TextField("/path/to/database.sqlite", text: sqliteFilePath)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()

          HStack(spacing: Spacing.sm) {
            Button("Choose…", action: chooseSQLiteFile)
              .buttonStyle(SecondaryButtonStyle())
            Button("Create new file…", action: createSQLiteFile)
              .buttonStyle(SecondaryButtonStyle())
          }
        }
      }

      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Read-only")
            .font(.body)
          Text("Open this file without writing to it")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }

        Spacer()

        Toggle("", isOn: $connectionConfig.readOnlyFile)
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(.accent)
          .scaleEffect(0.8)
      }
    }
  }

  /// Typing a path drops the bookmark; choosing a file sets both together.
  private var sqliteFilePath: Binding<String> {
    Binding(
      get: { connectionConfig.database },
      set: { newValue in
        var updated = connectionConfig
        if newValue != updated.database {
          updated.fileBookmark = nil
        }
        updated.database = newValue
        connectionConfig = updated
      }
    )
  }

  private func chooseSQLiteFile() {
    presentSQLitePanel(SQLiteFilePicker.openPanel())
  }

  private func createSQLiteFile() {
    presentSQLitePanel(SQLiteFilePicker.savePanel())
  }

  private func presentSQLitePanel(_ panel: NSSavePanel) {
    guard !SessionManager.isRunningAsTestHost else { return }
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let bookmark = try? SecurityScopedAccess.makeBookmark(for: url)
        storeSQLiteFile(path: url.path, bookmark: bookmark)
      }
    }
  }

  private func storeSQLiteFile(path: String, bookmark: Data?) {
    var updated = connectionConfig
    updated.database = path
    updated.fileBookmark = bookmark
    if updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      updated.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
    connectionConfig = updated
  }

  /// Refresh the stored path from the security-scoped bookmark, and replace a stale bookmark.
  func refreshSQLiteFileBookmark() {
    guard connectionConfig.databaseType == .sqlite, let bookmark = connectionConfig.fileBookmark
    else { return }
    do {
      let resolved = try SecurityScopedAccess.resolve(bookmark)
      var updated = connectionConfig
      updated.database = resolved.url.path
      if resolved.isStale {
        let token = SecurityScopedAccessToken(url: resolved.url)
        defer { token.release() }
        if token.isGranted {
          updated.fileBookmark = try SecurityScopedAccess.makeBookmark(for: resolved.url)
        }
      }
      connectionConfig = updated
    } catch {
      // Keep the stored path. The user can pick the file again.
    }
  }

  /// Common toggles and pickers used in both form and connection string modes
  @ViewBuilder
  func connectionTogglesAndPickers() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Remember connection")
            .font(.body)
          Text("Automatically reconnect when you reopen the app")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }

        Spacer()

        Toggle("", isOn: $connectionConfig.rememberConnection)
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(.accent)
          .scaleEffect(0.8)
      }

      // Protection Level Picker
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Protection level")
            .font(.body)
          Text(connectionConfig.protectionLevel.description)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }

        Spacer()

        Menu {
          ForEach(ConnectionProtectionLevel.allCases, id: \.self) { level in
            Button {
              connectionConfig.protectionLevel = level
            } label: {
              Label(level.displayName, systemImage: level.iconName)
            }
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: connectionConfig.protectionLevel.iconName)
              .font(.caption)
            Text(connectionConfig.protectionLevel.displayName)
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption)
              .foregroundColor(.foregroundMuted)
          }
          .dropdownCapsuleStyle()
        }
        .buttonStyle(.plain)
        .linkPointer()
      }

      // Security Level (Safe Mode) Picker
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Security level")
            .font(.body)
          if let mode = connectionConfig.safeMode {
            Text(mode.shortDescription)
              .font(.caption)
              .foregroundColor(.foregroundMuted)
          } else {
            Text("Use global setting (\(AppSettings.shared.safeMode.displayName))")
              .font(.caption)
              .foregroundColor(.foregroundMuted)
          }
        }

        Spacer()

        Menu {
          Button("Use Global") {
            connectionConfig.safeMode = nil
          }
          ForEach(SafeMode.allCases, id: \.self) { mode in
            Button(mode.displayName) {
              connectionConfig.safeMode = mode
            }
          }
        } label: {
          HStack(spacing: Spacing.xs) {
            Text(connectionConfig.safeMode?.displayName ?? "Use Global")
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption)
              .foregroundColor(.foregroundMuted)
          }
          .dropdownCapsuleStyle()
        }
        .buttonStyle(.plain)
        .linkPointer()
      }
    }
  }

  // MARK: - Safety

  /// Protected mode, server-side session brakes and row cap override.
  /// The section card supplies the "Safety" title.
  @ViewBuilder
  func safetySection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Protected mode")
            .font(.body)
          Text("Review data changes before they are committed")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }

        Spacer()

        Toggle("", isOn: $connectionConfig.protectedMode)
          .labelsHidden()
          .toggleStyle(.switch)
          .tint(.accent)
          .scaleEffect(0.8)
      }

      brakeField(
        "Statement timeout (seconds)", placeholder: "60",
        value: $connectionConfig.statementTimeoutSeconds,
        range: SessionBrakeLimits.statementTimeoutRange,
        clamp: SessionBrakeLimits.clampStatementTimeout)

      brakeField(
        "Lock timeout (seconds)", placeholder: "5", value: $connectionConfig.lockTimeoutSeconds,
        range: SessionBrakeLimits.lockTimeoutRange, clamp: SessionBrakeLimits.clampLockTimeout)

      brakeField(
        "Idle in transaction timeout (seconds)", placeholder: "600",
        value: $connectionConfig.idleInTransactionTimeoutSeconds,
        range: SessionBrakeLimits.idleTimeoutRange, clamp: SessionBrakeLimits.clampIdleTimeout)

      FormField(label: "Row cap override (empty = global setting)") {
        TextField(
          "Global", value: $connectionConfig.rowCapOverride, format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .frame(width: 120)
        .onChange(of: connectionConfig.rowCapOverride) { _, newValue in
          let clamped = SessionBrakeLimits.clampRowCap(newValue)
          if clamped != newValue { connectionConfig.rowCapOverride = clamped }
        }
      }
    }
  }

  /// Number field + stepper for a session brake, clamped to `range` (non-positive → default)
  private func brakeField(
    _ label: String, placeholder: String, value: Binding<Int>, range: ClosedRange<Int>,
    clamp: @escaping (Int) -> Int
  ) -> some View {
    FormField(label: label) {
      HStack(spacing: Spacing.sm) {
        TextField(placeholder, value: value, format: .number.grouping(.never))
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
          .frame(width: 80)
        Stepper("", value: value, in: range)
          .labelsHidden()
      }
      .onChange(of: value.wrappedValue) { _, newValue in
        let clamped = clamp(newValue)
        if clamped != newValue { value.wrappedValue = clamped }
      }
    }
  }
}

/// Open and save panels for a SQLite file. Suggested extensions, plus any other file.
enum SQLiteFilePicker {
  static let extensions = ["sqlite", "sqlite3", "db", "db3"]

  static var contentTypes: [UTType] {
    extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
  }

  static func openPanel() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = contentTypes
    panel.allowsOtherFileTypes = true
    panel.prompt = "Choose"
    panel.message = "Choose a SQLite database file"
    return panel
  }

  static func savePanel() -> NSSavePanel {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = contentTypes
    panel.allowsOtherFileTypes = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = "database.sqlite"
    panel.prompt = "Create"
    panel.message = "Create a new SQLite database file"
    return panel
  }
}

/// Password input with its own visibility state so the eye toggle re-renders reliably.
private struct PasswordInputField: View {
  @Binding var password: String
  @State private var isVisible = false

  var body: some View {
    HStack(spacing: 0) {
      if isVisible {
        TextField("password", text: $password)
          .textFieldStyle(.plain)
      } else {
        SecureField("password", text: $password)
          .textFieldStyle(.plain)
      }

      Button(action: { isVisible.toggle() }) {
        Image(systemName: isVisible ? "eye.slash.fill" : "eye.fill")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help(isVisible ? "Hide password" : "Show password")
    }
    .inputCapsuleStyle()
  }
}
