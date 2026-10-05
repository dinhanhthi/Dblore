//
//  ConnectionFormContent+FormFields.swift
//  Dblore
//
//  Form fields for connection configuration
//

import AppKit
import NIOSSL
import Security
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
            .numberInputCapsuleStyle()
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
        if usesClientCertificate(connectionConfig.sslMode) {
          clientCertificateSection()
        } else {
          removeClientCertificateButton()
        }
      }

      FormField(label: "Timeout (seconds)") {
        TextField(
          "30", value: $connectionConfig.timeoutSeconds,
          format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .numberInputCapsuleStyle()
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
        if usesClientCertificate(connectionStringSSLModeBinding.wrappedValue) {
          clientCertificateSection()
        } else {
          removeClientCertificateButton()
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

  private func usesClientCertificate(_ mode: SSLMode) -> Bool {
    mode == .require || mode == .verifyCa || mode == .verifyFull
  }

  @ViewBuilder
  private func clientCertificateSection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      FormField(label: "Client certificate (PEM)") {
        HStack(spacing: Spacing.sm) {
          Button(certificatePEM == nil ? "Choose certificate" : "Replace certificate") {
            chooseCertificateFile(.certificate)
          }
          .buttonStyle(SecondaryButtonStyle())
          if certificatePEM != nil {
            Text("Selected").font(.caption).foregroundColor(.foregroundMuted)
          }
        }
      }

      FormField(label: "Private key (PEM)") {
        HStack(spacing: Spacing.sm) {
          Button(privateKeyPEM == nil ? "Choose key" : "Replace key") {
            chooseCertificateFile(.privateKey)
          }
          .buttonStyle(SecondaryButtonStyle())
          if privateKeyPEM != nil {
            Text("Selected").font(.caption).foregroundColor(.foregroundMuted)
          }
        }
      }

      FormField(label: "Key passphrase (if encrypted)") {
        SecureField("Optional passphrase", text: certificatePassphraseBinding)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }

      FormField(label: "Custom CA (PEM, optional)") {
        HStack(spacing: Spacing.sm) {
          Button(caPEM == nil ? "Choose CA" : "Replace CA") {
            chooseCertificateFile(.ca)
          }
          .buttonStyle(SecondaryButtonStyle())
          if caPEM != nil {
            Button("Remove CA") {
              caPEM = nil
              certificateDraftChanged = true
              certificateError = nil
            }
            .buttonStyle(SecondaryButtonStyle())
          }
        }
      }

      if let info = certificateInfo {
        Text(info.subject)
          .font(.caption)
          .foregroundColor(.foregroundMuted)
        if let expiry = info.expiry {
          Text("Expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
      }

      removeClientCertificateButton()
      if let certificateError {
        Text(certificateError)
          .font(.caption)
          .foregroundColor(.destructive)
      }
    }
  }

  /// Also shown outside require/verify-ca/verify-full: a certificate blocks those modes, so
  /// this is how the user clears it after switching to Prefer, Allow, or Disable.
  @ViewBuilder
  private func removeClientCertificateButton() -> some View {
    if certificatePEM != nil || privateKeyPEM != nil || connectionConfig.clientCertificate != nil {
      Button("Remove client certificate", role: .destructive) {
        removeClientCertificate()
      }
      .buttonStyle(SecondaryButtonStyle())
    }
  }

  private enum CertificateFileKind: Sendable {
    case certificate, privateKey, ca
  }

  private var certificatePassphraseBinding: Binding<String> {
    Binding(
      get: { certificatePassphrase },
      set: {
        certificatePassphrase = $0
        passphraseEdited = true
        certificateDraftChanged = true
      })
  }

  private func chooseCertificateFile(_ kind: CertificateFileKind) {
    guard !SessionManager.isRunningAsTestHost else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = ["pem", "crt", "cer", "key"].compactMap {
      UTType(filenameExtension: $0)
    }
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        do {
          let pem = try readPEM(at: url)
          switch kind {
          case .certificate:
            certificateInfo = try Self.certificateInfo(from: pem, hasCA: caPEM != nil)
            certificatePEM = pem
            certificateFilePicked = true
          case .privateKey:
            guard
              pem.contains("-----BEGIN PRIVATE KEY-----")
                || pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
                || pem.contains("-----BEGIN RSA PRIVATE KEY-----")
                || pem.contains("-----BEGIN EC PRIVATE KEY-----")
            else { throw CertificateFormError.invalidPEM }
            privateKeyPEM = pem
            privateKeyFilePicked = true
          case .ca:
            guard !(try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8))).isEmpty else {
              throw CertificateFormError.invalidPEM
            }
            caPEM = pem
            caFilePicked = true
          }
          certificateDraftChanged = true
          certificateError = nil
        } catch {
          certificateError = "Choose a valid PEM file smaller than 1 MB."
        }
      }
    }
  }

  private func readPEM(at url: URL) throws -> String {
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: 1_048_577) ?? Data()
    guard data.count <= 1_048_576, let pem = String(data: data, encoding: .utf8) else {
      throw CertificateFormError.invalidPEM
    }
    return pem
  }

  static func certificateInfo(from pem: String, hasCA: Bool) throws -> ClientCertificateInfo {
    guard let certificate = try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8)).first,
      let securityCertificate = SecCertificateCreateWithData(
        nil, Data(try certificate.toDERBytes()) as CFData)
    else { throw CertificateFormError.invalidPEM }
    let subject =
      SecCertificateCopySubjectSummary(securityCertificate) as String? ?? "Unknown subject"
    return ClientCertificateInfo(
      subject: subject,
      expiry: Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter)),
      hasCA: hasCA)
  }

  func restoreCertificateDraft(keepingPendingDraft: Bool = false) {
    let account = ClientCertificateStoreFactory.account(for: connectionConfig)
    if connectionConfig.clientCertificate != nil { certificateRemovalAccount = nil }
    if certificateRemovalAccount != nil && certificateRemovalAccount != account {
      certificateRemovalAccount = nil
    }
    if certificateRemovalAccount == account && connectionConfig.clientCertificate == nil { return }
    if keepingPendingDraft {
      (caPEM, certificatePassphrase) = Self.keptCertificateExtras(
        caPEM: caPEM, caPicked: caFilePicked, passphrase: certificatePassphrase,
        passphraseEdited: passphraseEdited)
      return
    }
    certificatePEM = nil
    privateKeyPEM = nil
    caPEM = nil
    certificatePassphrase = ""
    certificateInfo = connectionConfig.clientCertificate
    certificateDraftChanged = false
    certificateFilePicked = false
    privateKeyFilePicked = false
    caFilePicked = false
    passphraseEdited = false
    certificateError = nil
    guard connectionConfig.clientCertificate != nil else { return }
    // Not in the keychain: held as a draft so Connect uses it instead of the store.
    if let material = Self.unrememberedMaterial(unrememberedCertificate?(), for: connectionConfig) {
      certificatePEM = material.certificatePEM
      privateKeyPEM = material.privateKeyPEM
      caPEM = material.caPEM
      certificatePassphrase = material.passphrase ?? ""
      certificateDraftChanged = true
      return
    }
    guard let material = ClientCertificateStoreFactory.load(for: connectionConfig) else {
      certificateError = "Saved client certificate is missing. Choose the PEM files again."
      return
    }
    certificatePEM = material.certificatePEM
    privateKeyPEM = material.privateKeyPEM
    caPEM = material.caPEM
    certificatePassphrase = material.passphrase ?? ""
  }

  /// A different connection was loaded or the form was blanked: drop any draft, picked or not.
  func resetCertificateDraft() {
    certificateFilePicked = false
    privateKeyFilePicked = false
    caFilePicked = false
    passphraseEdited = false
    certificateRemovalAccount = nil
    restoreCertificateDraft()
  }

  /// PEM bytes leave form state after a successful Connect or Save and when the form closes.
  func clearCertificateDraft() {
    certificatePEM = nil
    privateKeyPEM = nil
    caPEM = nil
    certificatePassphrase = ""
    certificateDraftChanged = false
    certificateFilePicked = false
    privateKeyFilePicked = false
    caFilePicked = false
    passphraseEdited = false
  }

  private func removeClientCertificate() {
    if connectionConfig.clientCertificate != nil {
      certificateRemovalAccount = ClientCertificateStoreFactory.account(for: connectionConfig)
    }
    certificatePEM = nil
    privateKeyPEM = nil
    caPEM = nil
    certificatePassphrase = ""
    certificateInfo = nil
    certificateError = nil
    certificateDraftChanged = true
    certificateFilePicked = false
    privateKeyFilePicked = false
    caFilePicked = false
    passphraseEdited = false
    connectionConfig.clientCertificate = nil
  }

  func preparedCertificateConfig() throws -> ConnectionConfig {
    var config = connectionConfig

    if config.clientCertificate != nil && !usesClientCertificate(config.sslMode) {
      throw CertificateFormError.tlsMode
    }

    if !certificateDraftChanged {
      if config.clientCertificate != nil && ClientCertificateStoreFactory.load(for: config) == nil {
        throw CertificateFormError.missingMaterial
      }
      return config
    }

    if certificatePEM == nil && privateKeyPEM == nil {
      config.clientCertificate = nil
      return config
    }

    guard usesClientCertificate(config.sslMode) else {
      throw CertificateFormError.tlsMode
    }
    guard let certificatePEM, let privateKeyPEM else {
      throw CertificateFormError.incompleteMaterial
    }
    let material = ClientCertificateMaterial(
      certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM,
      caPEM: caPEM, passphrase: certificatePassphrase.isEmpty ? nil : certificatePassphrase)
    do {
      _ = try PostgresSession.tlsConfiguration(sslMode: config.sslMode, material: material)
    } catch {
      throw CertificateFormError.invalidPEM
    }
    let info = try Self.certificateInfo(from: certificatePEM, hasCA: caPEM != nil)
    config.clientCertificate = info
    return config
  }

  func certificateMaterialForOperation(_ config: ConnectionConfig) -> ClientCertificateMaterial? {
    guard config.clientCertificate != nil else { return nil }
    if certificateDraftChanged, let certificatePEM, let privateKeyPEM {
      return ClientCertificateMaterial(
        certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM,
        caPEM: caPEM, passphrase: certificatePassphrase.isEmpty ? nil : certificatePassphrase)
    }
    return ClientCertificateStoreFactory.load(for: config)
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
        Button("Browse", action: chooseSQLiteFile)
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
            Button("Choose", action: chooseSQLiteFile)
              .buttonStyle(SecondaryButtonStyle())
            Button("Create new file", action: createSQLiteFile)
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
    let applied = Self.applyingSQLiteFile(
      path: path,
      bookmark: bookmark,
      to: connectionConfig,
      selected: selectedHistoryEntry
    )
    connectionConfig = applied.config
    setSelectedHistoryId(applied.selectedHistoryId)
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
        .numberInputCapsuleStyle()
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
          .numberInputCapsuleStyle()
          .frame(width: 80)
        Stepper("", value: value, in: range)
          .compactStepperStyle()
      }
      .onChange(of: value.wrappedValue) { _, newValue in
        let clamped = clamp(newValue)
        if clamped != newValue { value.wrappedValue = clamped }
      }
    }
  }
}

enum CertificateFormError: LocalizedError {
  case invalidPEM
  case missingMaterial
  case incompleteMaterial
  case tlsMode
  case keychainSave

  var errorDescription: String? {
    switch self {
    case .invalidPEM: "The certificate, private key, CA, or passphrase is invalid."
    case .missingMaterial: "Saved client certificate is missing. Choose the PEM files again."
    case .incompleteMaterial: "Choose both a client certificate and private key."
    case .tlsMode: "Client certificates require Require, Verify CA, or Verify Full TLS mode."
    case .keychainSave: "Could not save the client certificate to Keychain."
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
