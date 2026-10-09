//
//  ConnectionFormContent.swift
//  Dblore
//
//  Connection form for database configuration
//

import SwiftUI

// MARK: - Connection Form Content

struct ConnectionFormContent: View {
  /// Connection configuration binding - the single source of truth
  @Binding var connectionConfig: ConnectionConfig

  /// Callback to test connection - returns true if successful
  var onTestConnection: ((ConnectionConfig) async throws -> Bool)?

  /// Callback to connect - called when user clicks Connect button
  var onConnect: ((ConnectionConfig) async throws -> Void)?

  /// Callback when connection is successful (optional, for closing sidebar etc.)
  var onConnectionSuccess: (() -> Void)?

  /// Primary footer button. "Connect" opens a workspace. "Save" updates a recent card.
  var submitTitle: String = "Connect"

  /// Recent-connections picker. Hidden while editing one card so Save stays on that card.
  var showsRecentHistory: Bool = true

  /// Certificate held by the workspace for its unremembered connection (not in the keychain).
  var unrememberedCertificate: (() -> ClientCertificateStoreFactory.ConnectionMaterial?)?

  /// SSH secret held by the workspace for its unremembered connection (not in the store).
  var unrememberedSSHCredential: (() -> SSHCredentialStoreFactory.ConnectionCredential?)?

  /// Config already applied to a live connection. The submit button stays disabled until the
  /// form differs from it (nil = always enabled).
  var unchangedFrom: ConnectionConfig?

  /// Extra footer button at the leading edge (e.g. Disconnect).
  var footerLeading: AnyView?

  /// Failure of the connect run after the Safe Mode unlock sheet (which closes on failure), so
  /// it shows here. Cleared by Connect, Test Connection and when the form goes away.
  var unlockConnectError: Binding<String?>?

  @State private var isTesting = false
  @State private var testResult: TestResult?
  @State private var isConnecting = false
  @State private var inputMode: ConnectionInputMode = .form
  @State private var connectionString: String = ""
  @State private var parseError: String?
  @State private var connectionStringSSLMode: SSLMode = .prefer

  // PEM bytes are transient form state; ConnectionConfig contains display metadata only.
  @State var certificatePEM: String?
  @State var privateKeyPEM: String?
  @State var caPEM: String?
  @State var certificatePassphrase = ""
  @State var certificateInfo: ClientCertificateInfo?
  @State var certificateError: String?
  @State var certificateDraftChanged = false
  /// Certificate or key came from a file picked in this form, not from the keychain.
  @State var certificateFilePicked = false
  @State var privateKeyFilePicked = false
  /// CA picked or passphrase typed in this form, not loaded from the keychain.
  @State var caFilePicked = false
  @State var passphraseEdited = false
  @State var certificateRemovalAccount: String?

  // SSH tunnel draft. The password and imported key stay in memory until Connect or Save.
  @State var sshDraft = SSHFormDraft()
  /// Config the SSH draft was loaded from. Its account holds the stored SSH credential.
  @State var sshOriginalConfig: ConnectionConfig?
  /// Auth method of the credential stored under `sshOriginalConfig`'s account (nil = none).
  @State var sshStoredMethod: SSHTunnelConfig.AuthMethod?

  // Connection history
  @State private var connectionHistory: [ConnectionHistoryEntry] = []
  @State private var selectedHistoryId: UUID?
  /// Engine the current field values belong to. The header picker changes
  /// `databaseType` without clearing those fields; loading a history row sets both.
  @State private var fieldsEngine: DatabaseType?
  @State private var showDeleteConfirmation = false
  @State private var showClearAllConfirmation = false
  @State private var entryToDelete: UUID?

  // MARK: - Types

  enum TestResult {
    case success
    case failure(String)
  }

  /// Everything the user can edit. A change clears the shown Test/Connect status.
  struct FormInputs: Equatable {
    var config: ConnectionConfig
    var sshDraft: SSHFormDraft
    var certificatePEM: String?
    var privateKeyPEM: String?
    var caPEM: String?
    var certificatePassphrase: String
  }

  var formInputs: FormInputs {
    FormInputs(
      config: connectionConfig, sshDraft: sshDraft, certificatePEM: certificatePEM,
      privateKeyPEM: privateKeyPEM, caPEM: caPEM, certificatePassphrase: certificatePassphrase)
  }

  enum ConnectionInputMode: String, CaseIterable {
    case form = "Form"
    case connectionString = "Connection String"
  }

  // MARK: - Initializer

  /// Initialize with binding and callbacks
  init(
    connectionConfig: Binding<ConnectionConfig>,
    onTestConnection: ((ConnectionConfig) async throws -> Bool)? = nil,
    onConnect: ((ConnectionConfig) async throws -> Void)? = nil,
    onConnectionSuccess: (() -> Void)? = nil,
    submitTitle: String = "Connect",
    showsRecentHistory: Bool = true,
    unrememberedCertificate: (() -> ClientCertificateStoreFactory.ConnectionMaterial?)? = nil,
    unrememberedSSHCredential: (() -> SSHCredentialStoreFactory.ConnectionCredential?)? = nil,
    unchangedFrom: ConnectionConfig? = nil,
    footerLeading: AnyView? = nil,
    unlockConnectError: Binding<String?>? = nil
  ) {
    self._connectionConfig = connectionConfig
    self.onTestConnection = onTestConnection
    self.onConnect = onConnect
    self.onConnectionSuccess = onConnectionSuccess
    self.submitTitle = submitTitle
    self.showsRecentHistory = showsRecentHistory
    self.unrememberedCertificate = unrememberedCertificate
    self.unrememberedSSHCredential = unrememberedSSHCredential
    self.unchangedFrom = unchangedFrom
    self.footerLeading = footerLeading
    self.unlockConnectError = unlockConnectError
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          if showsRecentHistory && !historyForSelectedType().isEmpty {
            sectionCard {
              sectionTitle("Recent connections")
              connectionHistorySection()
            }
          }

          if connectionConfig.databaseType == .sqlite {
            sectionCard {
              sectionTitle("Connection")
              sqliteSimpleFields()
            }
          } else {
            sectionCard {
              sectionTitle("Connection")
              if connectionConfig.databaseType.capabilities.usesNetwork {
                customTabPicker()
                  .onChange(of: inputMode) { _, newMode in
                    parseError = nil
                    testResult = nil
                    if newMode == .connectionString {
                      let config = connectionConfig
                      if !config.username.isEmpty && !config.database.isEmpty {
                        connectionString = generateConnectionString()
                      } else {
                        connectionString = ""
                      }
                      connectionStringSSLMode = connectionConfig.sslMode
                    }
                  }
              }
              if inputMode == .form || !connectionConfig.databaseType.capabilities.usesNetwork {
                formFields()
              } else {
                connectionStringFields()
              }
            }

            if SSHFormDraft.supportsSSH(connectionConfig.databaseType) {
              sectionCard {
                sectionTitle("SSH Tunnel")
                sshTunnelSection()
              }
            }

            sectionCard {
              sectionTitle("Options")
              connectionTogglesAndPickers()
            }

            sectionCard {
              sectionTitle("Safety")
              safetySection()
            }
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.appBackground)
      .onAppear {
        if fieldsEngine == nil {
          fieldsEngine = connectionConfig.databaseType
        }
        loadConnectionHistory()
        restoreCertificateDraft()
        restoreSSHDraft()
        refreshSQLiteFileBookmark()
      }
      .onChange(of: connectionConfig.databaseType) { _, newType in
        clearParseErrorAndTestResult()
        if !newType.capabilities.usesNetwork {
          inputMode = .form
        }
        // Loading a history row sets `fieldsEngine` before `databaseType`, so this
        // only runs for the header picker. A PostgreSQL database name would otherwise
        // stay in `database` and show up under Browse.
        guard
          let replacement = Self.formAfterEngineChange(fieldsEngine: fieldsEngine, newType: newType)
        else { return }
        fieldsEngine = newType
        selectedHistoryId = nil
        connectionConfig = replacement
      }
      .onChange(of: Self.connectionTargetKey(connectionConfig)) { oldKey, newKey in
        // A loaded recent row stays selected only while host, port, database, and user match.
        let retained = Self.retainedHistoryId(
          selectedId: selectedHistoryId,
          history: connectionHistory,
          config: connectionConfig
        )
        // A matching row means it was just loaded, not edited.
        restoreCertificateDraft(
          keepingPendingDraft: Self.keepsCertificateDraft(
            filesPicked: Self.draftCameFromFiles(
              hasCertificate: certificatePEM != nil, certificatePicked: certificateFilePicked,
              hasKey: privateKeyPEM != nil, keyPicked: privateKeyFilePicked),
            isHistoryLoad: retained != nil,
            engineChanged: Self.engineChanged(oldKey: oldKey, newKey: newKey),
            isBlankForm: Self.isBlankForm(connectionConfig)))
        if Self.resetsSSHDraft(
          isHistoryLoad: retained != nil,
          engineChanged: Self.engineChanged(oldKey: oldKey, newKey: newKey),
          isBlankForm: Self.isBlankForm(connectionConfig))
        {
          restoreSSHDraft()
        }
        // SQLite Browse clears the row itself. Resolving a bookmark can change the
        // path string without the user picking a different connection.
        guard connectionConfig.databaseType.capabilities.usesNetwork else { return }
        if selectedHistoryId != retained {
          selectedHistoryId = retained
        }
      }
      .onChange(of: connectionConfig.clientCertificate) { _, _ in
        restoreCertificateDraft()
      }
      // A Recent row, an engine change or a successful submit replaced the tunnel config.
      .onChange(of: connectionConfig.sshTunnel) { _, _ in
        restoreSSHDraft()
      }
      // A status describes the values it ran with: any edit makes it stale.
      // `unlockConnectError` stays: its owner sets it together with a replaced draft.
      .onChange(of: formInputs) { _, _ in
        testResult = nil
      }

      footerView()
    }
    .onDisappear {
      clearCertificateDraft()
      sshDraft.clearSecrets()
      unlockConnectError?.wrappedValue = nil
    }
  }

  func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.subheading.weight(.semibold))
      .foregroundColor(.foreground)
  }

  /// Bordered group, same chrome as the export sheet sections.
  func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm, content: content)
      .padding(Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.cardHeaderBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
          .stroke(Color.border, lineWidth: 1)
      )
  }

  // MARK: - State Accessors (for extensions)

  var connectionStringBinding: Binding<String> {
    $connectionString
  }

  var connectionStringSSLModeBinding: Binding<SSLMode> {
    $connectionStringSSLMode
  }

  var showDeleteConfirmationBinding: Binding<Bool> {
    $showDeleteConfirmation
  }

  var showClearAllConfirmationBinding: Binding<Bool> {
    $showClearAllConfirmation
  }

  func getConnectionHistory() -> [ConnectionHistoryEntry] {
    connectionHistory
  }

  /// Recent rows for the engine selected in the header.
  func historyForSelectedType() -> [ConnectionHistoryEntry] {
    Self.history(matching: connectionConfig.databaseType, in: connectionHistory)
  }

  /// History rows for one engine.
  static func history(
    matching type: DatabaseType, in history: [ConnectionHistoryEntry]
  ) -> [ConnectionHistoryEntry] {
    history.filter { $0.config.databaseType == type }
  }

  /// Nil when the field values already belong to `newType` (a history row just loaded).
  /// Otherwise a blank config, so the previous engine's database name is dropped.
  static func formAfterEngineChange(
    fieldsEngine: DatabaseType?, newType: DatabaseType
  ) -> ConnectionConfig? {
    guard fieldsEngine != newType else { return nil }
    return newFormDraft(databaseType: newType)
  }

  /// Blank connection form. Stores the Default commit style explicitly.
  /// `ConnectionConfig()` stays the unstyled default tests use.
  static func newFormDraft(databaseType: DatabaseType = .postgresql) -> ConnectionConfig {
    var config = ConnectionConfig(databaseType: databaseType)
    config.applyCommitStyle(AppSettings.shared.commitStyle)
    return config
  }

  /// A form the user has not filled in. Includes the unstyled `ConnectionConfig()` and a draft
  /// that already copied the Default commit style.
  static func isBlankForm(_ config: ConnectionConfig) -> Bool {
    config == ConnectionConfig() || config == newFormDraft()
  }

  /// Host, port, database, and username. Recent connections compares this, not the display name.
  static func connectionTargetKey(_ config: ConnectionConfig) -> String {
    [
      config.databaseType.rawValue,
      config.host,
      String(config.port),
      config.database,
      config.username,
    ].joined(separator: "\u{1e}")
  }

  /// The engine is the first part of `connectionTargetKey`.
  static func engineChanged(oldKey: String, newKey: String) -> Bool {
    let separator: Character = "\u{1e}"
    return oldKey.split(separator: separator).first != newKey.split(separator: separator).first
  }

  /// Every half in the draft was picked from a file in this form. Replacing only one half of a
  /// keychain-loaded pair still holds the old target's material, so it does not count.
  static func draftCameFromFiles(
    hasCertificate: Bool, certificatePicked: Bool, hasKey: Bool, keyPicked: Bool
  ) -> Bool {
    (certificatePicked || keyPicked) && (!hasCertificate || certificatePicked)
      && (!hasKey || keyPicked)
  }

  /// A kept draft keeps only the CA and passphrase picked or typed in this form. Values loaded
  /// with the old pair belong to the old target's account and are dropped.
  static func keptCertificateExtras(
    caPEM: String?, caPicked: Bool, passphrase: String, passphraseEdited: Bool
  ) -> (caPEM: String?, passphrase: String) {
    (caPicked ? caPEM : nil, passphraseEdited ? passphrase : "")
  }

  /// Session material for an unremembered connection to this target. Nothing is in the keychain.
  static func unrememberedMaterial(
    _ active: ClientCertificateStoreFactory.ConnectionMaterial?, for config: ConnectionConfig
  ) -> ClientCertificateMaterial? {
    guard !config.rememberConnection, let active,
      active.account == ClientCertificateStoreFactory.account(for: config)
    else { return nil }
    return active.material
  }

  /// Freshly picked PEM files are not bound to an account until saved, so editing the target
  /// keeps them. Material loaded from the keychain belongs to the old target and is reloaded.
  /// Loading a Recent row, changing the engine, or blanking the form always resets.
  static func keepsCertificateDraft(
    filesPicked: Bool, isHistoryLoad: Bool, engineChanged: Bool, isBlankForm: Bool
  ) -> Bool {
    filesPicked && !isHistoryLoad && !engineChanged && !isBlankForm
  }

  /// A Recent row, an engine change or a blank form is another connection: its SSH draft and
  /// stored-credential account are reloaded. A plain target edit keeps them, so the stored
  /// credential can move to the edited identity on save.
  static func resetsSSHDraft(isHistoryLoad: Bool, engineChanged: Bool, isBlankForm: Bool) -> Bool {
    isHistoryLoad || engineChanged || isBlankForm
  }

  /// Keeps the Recent connections row only while host, port, database, and username match.
  static func retainedHistoryId(
    selectedId: UUID?,
    history: [ConnectionHistoryEntry],
    config: ConnectionConfig
  ) -> UUID? {
    guard let selectedId,
      let entry = history.first(where: { $0.id == selectedId }),
      entry.config.databaseType == config.databaseType
    else { return nil }

    let sameTarget =
      entry.config.host == config.host && entry.config.port == config.port
      && entry.config.database == config.database && entry.config.username == config.username
    return sameTarget ? selectedId : nil
  }

  /// Choosing a SQLite file. A different path drops the loaded recent row.
  /// Name becomes the file name when it is blank or still that row's name.
  static func applyingSQLiteFile(
    path: String,
    bookmark: Data?,
    to config: ConnectionConfig,
    selected: ConnectionHistoryEntry?
  ) -> (config: ConnectionConfig, selectedHistoryId: UUID?) {
    var updated = config
    updated.database = path
    updated.fileBookmark = bookmark

    let sameFile = selected?.config.database == path
    let loadedName = sameFile ? nil : selected?.config.name
    updated.name = sqliteDisplayName(current: updated.name, path: path, loadedName: loadedName)
    return (updated, sameFile ? selected?.id : nil)
  }

  /// File name without its extension. A name the user typed is left as they typed it.
  static func sqliteDisplayName(current: String, path: String, loadedName: String?) -> String {
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    let derived = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    if trimmed.isEmpty { return derived }
    if let loadedName, trimmed == loadedName.trimmingCharacters(in: .whitespacesAndNewlines) {
      return derived
    }
    return current
  }

  func setFieldsEngine(_ type: DatabaseType) {
    fieldsEngine = type
  }

  func setConnectionHistory(_ history: [ConnectionHistoryEntry]) {
    connectionHistory = history
  }

  func getSelectedHistoryId() -> UUID? {
    selectedHistoryId
  }

  func setSelectedHistoryId(_ id: UUID?) {
    selectedHistoryId = id
  }

  func getEntryToDelete() -> UUID? {
    entryToDelete
  }

  func prepareDeleteConnection(_ id: UUID) {
    entryToDelete = id
    showDeleteConfirmation = true
  }

  func prepareClearAllHistory() {
    showClearAllConfirmation = true
  }

  func getInputMode() -> ConnectionInputMode {
    inputMode
  }

  func setConnectionString(_ value: String) {
    connectionString = value
  }

  func updateConnectionStringSSLMode(_ mode: SSLMode) {
    connectionStringSSLMode = mode
  }

  func setParseError(_ error: String?) {
    parseError = error
  }

  func clearParseError() {
    parseError = nil
  }

  func clearTestResult() {
    testResult = nil
  }

  func clearParseErrorAndTestResult() {
    parseError = nil
    testResult = nil
  }

  // MARK: - Footer

  @ViewBuilder
  private func footerView() -> some View {
    VStack(spacing: 0) {
      Divider()
      if parseError != nil || testResult != nil || unlockConnectError?.wrappedValue != nil {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          if let error = parseError {
            errorView(error)
          }
          if let result = testResult {
            testResultView(result)
          }
          if let message = unlockConnectError?.wrappedValue {
            testResultView(.failure(message))
          }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
      }

      HStack(spacing: Spacing.sm) {
        if let footerLeading { footerLeading }
        Spacer(minLength: Spacing.sm)
        Button(action: testConnection) {
          HStack(spacing: Spacing.sm) {
            if isTesting {
              ProgressView()
                .controlSize(.mini)
                .tint(.accent)
                .frame(width: 14, height: 14)
            }
            Text("Test Connection")
          }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(isTesting || !isFormValid)

        Button(action: connect) {
          HStack(spacing: Spacing.sm) {
            if isConnecting {
              ProgressView()
                .controlSize(.mini)
                .tint(.accent)
                .frame(width: 14, height: 14)
            }
            Text(submitTitle)
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isConnecting || !isFormValid || isUnchanged)
      }
      .modalBarPadding()
    }
    .background(Color.appBackground)
  }

  // MARK: - Validation

  /// Form fields are complete enough to test or connect.
  /// A file engine only needs the file path. Password stays optional.
  static func isFormInputValid(_ config: ConnectionConfig) -> Bool {
    let capabilities = config.databaseType.capabilities
    if !capabilities.usesNetwork {
      return !config.database.isEmpty
    }
    return !config.host.isEmpty && !config.database.isEmpty && !config.username.isEmpty
  }

  private var isUnchanged: Bool {
    guard let unchangedFrom else { return false }
    return withSSHConfig(connectionConfig) == unchangedFrom && !certificateDraftChanged
      && sshDraft.enteredCredential == nil
  }

  private var isFormValid: Bool {
    guard sshDraftIsValid else { return false }
    if inputMode == .connectionString && connectionConfig.databaseType.capabilities.usesNetwork {
      return !connectionString.isEmpty && parseError == nil
    }
    return Self.isFormInputValid(connectionConfig)
  }

  /// SSH on requires host, user and a usable secret. Engines without SSH ignore the draft.
  private var sshDraftIsValid: Bool {
    !SSHFormDraft.supportsSSH(connectionConfig.databaseType)
      || sshDraft.isValid(storedMethod: usableSSHStoredMethod)
  }

  // MARK: - SSH Draft

  /// The config with the draft's tunnel applied (nil for engines without SSH).
  func withSSHConfig(_ config: ConnectionConfig) -> ConnectionConfig {
    var config = config
    config.sshTunnel =
      SSHFormDraft.supportsSSH(config.databaseType) ? sshDraft.preparedConfig : nil
    return config
  }

  /// Tunnel config for Connect, Test and Save. Key fingerprint and algorithm come from the
  /// imported (or still stored) key; no secret is in it.
  var preparedSSHConfig: SSHTunnelConfig? {
    withSSHConfig(connectionConfig).sshTunnel
  }

  /// The SSH secret for this submit: the session reads it, and a remembered save persists it
  /// (`SessionManager`). Nil keeps the stored credential (same account). A secret never follows
  /// a changed bastion (`SSHFormDraft.preparedCredential`).
  var preparedSSHCredential: SSHStoredCredential? {
    sshDraft.preparedCredential(
      original: sshOriginalConfig, new: withSSHConfig(connectionConfig),
      store: SSHCredentialStoreFactory.shared, held: unrememberedSSHCredential?())
  }

  /// The stored or held secret's method while it still serves the bastion in the form.
  var usableSSHStoredMethod: SSHTunnelConfig.AuthMethod? {
    sshDraft.usableStoredMethod(sshStoredMethod, original: sshOriginalConfig)
  }

  /// The workspace's in-memory SSH secret when it belongs to `original`'s account.
  func heldSSHCredential(for original: ConnectionConfig?) -> SSHStoredCredential? {
    guard let original, let held = unrememberedSSHCredential?(),
      held.account == SSHCredentialStoreFactory.account(for: original)
    else { return nil }
    return held.credential
  }

  /// Reloads the draft from `connectionConfig.sshTunnel` and snapshots the identity the stored
  /// credential belongs to. Drops any typed password or imported key.
  func restoreSSHDraft() {
    sshDraft = SSHFormDraft(from: connectionConfig)
    let original = connectionConfig.sshTunnel == nil ? nil : connectionConfig
    sshOriginalConfig = original
    sshStoredMethod =
      heldSSHCredential(for: original).map(SSHFormDraft.method(of:))
      ?? SSHFormDraft.storedMethod(for: original, store: SSHCredentialStoreFactory.shared)
  }

  /// Parses the key off the main actor, keeps only the decrypted key for the store, and
  /// clears the passphrase. A newer import or Remove supersedes a slower one.
  func importSSHKey(data: Data, passphrase: String?) async {
    let token = sshDraft.beginKeyImport()
    let result = await SSHFormDraft.parseKey(data: data, passphrase: passphrase)
    sshDraft.finishKeyImport(result, data: data, token: token)
  }

  /// Retries an encrypted key with the passphrase now typed in the form.
  func retrySSHKeyImport() async {
    guard let data = sshDraft.pendingKeyData else { return }
    await importSSHKey(data: data, passphrase: sshDraft.passphrase)
  }

  func removeSSHKey() {
    sshDraft.removeKey()
  }

  // MARK: - Tab Picker

  @ViewBuilder
  private func customTabPicker() -> some View {
    CapsuleTabPicker(
      selection: $inputMode,
      tabs: ConnectionInputMode.allCases,
      height: 32
    )
  }

  // MARK: - Status Views

  @ViewBuilder
  private func errorView(_ message: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text(message)
        .foregroundColor(.warning)
        .textSelection(.enabled)
    }
    .font(.caption)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.warning.opacity(0.1))
    )
  }

  @ViewBuilder
  private func testResultView(_ result: TestResult) -> some View {
    HStack(spacing: Spacing.sm) {
      switch result {
      case .success:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.success)
        Text("Connection successful!")
          .foregroundColor(.success)
          .textSelection(.enabled)
      case .failure(let message):
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.destructive)
        Text(message)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
    .font(.caption)
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(result.isSuccess ? Color.success.opacity(0.1) : Color.destructive.opacity(0.1))
    )
  }

  // MARK: - Actions

  private func testConnection() {
    unlockConnectError?.wrappedValue = nil
    // Use the active tab: an unparsable connection string would leave stale form values
    guard inputMode == .form || parseError == nil else { return }

    // A pasted name can carry line breaks the one-line field does not show
    connectionConfig.name = DropdownTitle.singleLine(connectionConfig.name)
    // Validate connection name is not empty
    guard !connectionConfig.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      testResult = .failure("Connection name is required")
      return
    }

    guard let onTest = onTestConnection else {
      testResult = .failure("Test connection not available")
      return
    }

    let config: ConnectionConfig
    do {
      config = withSSHConfig(try preparedCertificateConfig())
    } catch {
      testResult = .failure(error.localizedDescription)
      return
    }

    isTesting = true
    testResult = nil
    let testedInputs = formInputs
    let scopedMaterial = certificateMaterialForOperation(config).map {
      ClientCertificateStoreFactory.ScopedMaterial(
        account: ClientCertificateStoreFactory.account(for: config), material: $0)
    }
    let scopedSSH = SSHCredentialStoreFactory.scoped(preparedSSHCredential, for: config)

    Task { @MainActor in
      defer {
        scopedMaterial?.clear()
        scopedSSH?.clear()
      }
      do {
        let success = try await ClientCertificateStoreFactory.$operationMaterial.withValue(
          scopedMaterial
        ) {
          try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
            try await onTest(config)
          }
        }
        isTesting = false
        // Edited while the test ran: the result is for values no longer in the form.
        guard formInputs == testedInputs else { return }
        testResult = success ? .success : .failure("Connection failed unexpectedly")
      } catch {
        isTesting = false
        let message = SSHHostKeyTrustCoordinator.shared.report(error)
        guard formInputs == testedInputs else { return }
        testResult = .failure(message)
      }
    }
  }

  private func connect() {
    unlockConnectError?.wrappedValue = nil
    // Use the active tab: an unparsable connection string would leave stale form values
    guard inputMode == .form || parseError == nil else { return }

    // A pasted name can carry line breaks the one-line field does not show
    connectionConfig.name = DropdownTitle.singleLine(connectionConfig.name)
    // Validate connection name is not empty
    guard !connectionConfig.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      testResult = .failure("Connection name is required")
      return
    }

    guard let onConnectCallback = onConnect else {
      testResult = .failure("Connect not available")
      return
    }

    let config: ConnectionConfig
    do {
      config = withSSHConfig(try preparedCertificateConfig())
    } catch {
      testResult = .failure(error.localizedDescription)
      return
    }

    isConnecting = true
    let scopedMaterial = certificateMaterialForOperation(config).map {
      ClientCertificateStoreFactory.ScopedMaterial(
        account: ClientCertificateStoreFactory.account(for: config), material: $0)
    }
    // The typed, imported or moved SSH secret: the session reads it before the store, and a
    // remembered save persists it (`SessionManager`). Remember off keeps it only here.
    let scopedSSH = SSHCredentialStoreFactory.scoped(preparedSSHCredential, for: config)

    Task { @MainActor in
      defer {
        scopedMaterial?.clear()
        scopedSSH?.clear()
      }
      do {
        try await ClientCertificateStoreFactory.$operationMaterial.withValue(scopedMaterial) {
          try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
            try await onConnectCallback(config)
          }
        }
        connectionConfig.clientCertificate = config.clientCertificate
        clearCertificateDraft()
        // Restores the draft from the submitted tunnel (and drops the typed secret).
        connectionConfig.sshTunnel = config.sshTunnel
        restoreSSHDraft()
        isConnecting = false
        onConnectionSuccess?()
      } catch WorkspaceConnectError.unlockRequired {
        // Held for the Safe Mode unlock sheet; the form keeps its values
        isConnecting = false
      } catch WorkspaceConnectError.pendingTransactionKept {
        // The user kept the pending transaction: still connected, the form keeps its values
        isConnecting = false
      } catch {
        isConnecting = false
        testResult = .failure(SSHHostKeyTrustCoordinator.shared.report(error))
      }
    }
  }
}

// MARK: - TestResult Extension

extension ConnectionFormContent.TestResult {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}

// MARK: - Form Field

struct FormField<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      content
    }
  }
}

// MARK: - SSH Form Draft

/// SSH tunnel fields of the connection form. The password and decrypted key live only here
/// until Connect or Save hands them to `SSHCredentialStore`; key bytes and the passphrase are
/// dropped once a key is imported.
nonisolated struct SSHFormDraft: Equatable, Sendable {
  /// A key parsed in this form. `keychainRepresentation` is the decrypted secret.
  struct ImportedKey: Equatable, Sendable {
    var algorithm: String
    var fingerprint: String
    var keychainRepresentation: Data
  }

  var enabled = false
  var host = ""
  var port = 22
  var username = ""
  var authMethod: SSHTunnelConfig.AuthMethod = .password
  /// Typed in this form. Empty keeps the stored password.
  var password = ""
  /// Only for decrypting an encrypted key; cleared after every import attempt.
  var passphrase = ""
  var importedKey: ImportedKey?
  /// The key already in the store, from the saved config. Nil after Remove.
  var storedKeyAlgorithm: String?
  var storedKeyFingerprint: String?
  /// Encrypted key bytes waiting for a (correct) passphrase. Dropped on success or Remove.
  var pendingKeyData: Data?
  /// User-readable import error (plain text).
  var keyError: String?
  private(set) var importToken: UUID?

  var isImportingKey: Bool { importToken != nil }
  /// The picked key is encrypted and needs its passphrase before it can be imported.
  var needsPassphrase: Bool { pendingKeyData != nil }

  init() {}

  init(from config: ConnectionConfig) {
    guard let tunnel = config.sshTunnel else { return }
    enabled = true
    host = tunnel.host
    port = tunnel.port
    username = tunnel.username
    authMethod = tunnel.authMethod
    storedKeyAlgorithm = tunnel.keyAlgorithm
    storedKeyFingerprint = tunnel.keyFingerprint
  }

  /// SSH tunnels are PostgreSQL-only.
  static func supportsSSH(_ type: DatabaseType) -> Bool { type == .postgresql }

  /// Nil when SSH is off. The key's algorithm and fingerprint are display data only.
  var preparedConfig: SSHTunnelConfig? {
    guard enabled else { return nil }
    let usesKey = authMethod == .privateKey
    return SSHTunnelConfig(
      host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
      username: username.trimmingCharacters(in: .whitespacesAndNewlines), authMethod: authMethod,
      keyAlgorithm: usesKey ? importedKey?.algorithm ?? storedKeyAlgorithm : nil,
      keyFingerprint: usesKey ? importedKey?.fingerprint ?? storedKeyFingerprint : nil)
  }

  /// The secret typed or imported in this form for the selected auth method.
  var enteredCredential: SSHStoredCredential? {
    guard enabled else { return nil }
    switch authMethod {
    case .password:
      return password.isEmpty ? nil : .password(password)
    case .privateKey:
      return importedKey.map { .privateKey(keychainRepresentation: $0.keychainRepresentation) }
    }
  }

  /// A stored credential of `storedMethod` still serves the selected method (a removed key
  /// does not).
  func canUseStoredCredential(_ storedMethod: SSHTunnelConfig.AuthMethod?) -> Bool {
    guard let storedMethod, storedMethod == authMethod else { return false }
    return authMethod == .password || storedKeyFingerprint != nil
  }

  /// SSH on requires host, user, a valid port and a secret (typed, imported, or stored).
  func isValid(storedMethod: SSHTunnelConfig.AuthMethod?) -> Bool {
    guard enabled else { return true }
    guard let config = preparedConfig, !config.host.isEmpty, !config.username.isEmpty,
      (1...65535).contains(port), !isImportingKey
    else { return false }
    return enteredCredential != nil || canUseStoredCredential(storedMethod)
  }

  /// The bastion (host, port, SSH user) is still `original`'s. A stored or held secret belongs
  /// to that bastion and is never sent to another one.
  func bastionMatches(_ original: ConnectionConfig?) -> Bool {
    guard let tunnel = original?.sshTunnel, let config = preparedConfig else { return false }
    return config.host == tunnel.host && config.port == tunnel.port
      && config.username == tunnel.username
  }

  /// `storedMethod` while the bastion is unchanged, else nil (the old secret no longer counts).
  func usableStoredMethod(
    _ storedMethod: SSHTunnelConfig.AuthMethod?, original: ConnectionConfig?
  ) -> SSHTunnelConfig.AuthMethod? {
    bastionMatches(original) ? storedMethod : nil
  }

  /// The bastion changed and the saved secret was for the old one: ask for a new secret.
  func needsSecretForNewBastion(
    storedMethod: SSHTunnelConfig.AuthMethod?, original: ConnectionConfig?
  ) -> Bool {
    enabled && storedMethod != nil && enteredCredential == nil && !bastionMatches(original)
  }

  static let newBastionSecretHint =
    "Enter the password or choose the key again for the new SSH server."

  /// The secret to use and save with `new`. A typed or imported secret wins. Otherwise, while
  /// the bastion is unchanged: the `held` secret of a live unremembered connection (not in the
  /// store), else, when the account changed (DB fields or engine), the credential stored under
  /// the original account so it moves to the new account. Nil keeps the store as is.
  func preparedCredential(
    original: ConnectionConfig?, new: ConnectionConfig, store: any SSHCredentialStore,
    held: SSHCredentialStoreFactory.ConnectionCredential? = nil
  ) -> SSHStoredCredential? {
    guard enabled, let newAccount = SSHCredentialStoreFactory.account(for: new) else {
      return nil
    }
    if let enteredCredential { return enteredCredential }
    guard bastionMatches(original), let original,
      let oldAccount = SSHCredentialStoreFactory.account(for: original)
    else { return nil }
    if let held, held.account == oldAccount,
      canUseStoredCredential(Self.method(of: held.credential))
    {
      return held.credential
    }
    guard oldAccount != newAccount, let stored = store.load(account: oldAccount),
      canUseStoredCredential(Self.method(of: stored))
    else { return nil }
    return stored
  }

  /// Auth method of the credential stored for `config` (nil when there is none).
  static func storedMethod(
    for config: ConnectionConfig?, store: any SSHCredentialStore
  ) -> SSHTunnelConfig.AuthMethod? {
    guard let config, let account = SSHCredentialStoreFactory.account(for: config) else {
      return nil
    }
    return store.load(account: account).map(method(of:))
  }

  static func method(of credential: SSHStoredCredential) -> SSHTunnelConfig.AuthMethod {
    switch credential {
    case .password: .password
    case .privateKey: .privateKey
    }
  }

  // MARK: Key import

  /// Marks an import in flight. Pass the token to `finishKeyImport`.
  mutating func beginKeyImport() -> UUID {
    let token = UUID()
    importToken = token
    keyError = nil
    return token
  }

  /// Parses off the main actor: decrypting an OpenSSH key runs bcrypt_pbkdf (about 1 s).
  static func parseKey(data: Data, passphrase: String?) async -> Result<ParsedSSHKey, any Error> {
    let passphrase = passphrase?.isEmpty == true ? nil : passphrase
    return await Task.detached(priority: .userInitiated) {
      Result {
        try PerfSignpost.interval("ssh-key-import") {
          try SSHPrivateKeyParser.parse(data, passphrase: passphrase)
        }
      }
    }.value
  }

  /// Applies an import result unless a newer import or Remove superseded it. The passphrase
  /// is always cleared. Encrypted bytes are kept only while a passphrase is still needed.
  mutating func finishKeyImport(
    _ result: Result<ParsedSSHKey, any Error>, data: Data, token: UUID
  ) {
    guard token == importToken else { return }
    importToken = nil
    passphrase = ""
    switch result {
    case .success(let key):
      importedKey = ImportedKey(
        algorithm: key.algorithm, fingerprint: key.fingerprint,
        keychainRepresentation: key.keychainRepresentation)
      authMethod = .privateKey
      pendingKeyData = nil
      keyError = nil
    case .failure(let error):
      let keyError = error as? SSHPrivateKeyError
      pendingKeyData =
        keyError == .passphraseRequired || keyError == .wrongPassphrase ? data : nil
      self.keyError = Self.message(for: error)
    }
  }

  /// Parser messages carry static text only, never key material.
  static func message(for error: any Error) -> String {
    if let error = error as? SSHPrivateKeyError, let text = error.errorDescription {
      return text
    }
    return "The private key could not be read."
  }

  /// Drops the imported or stored key; a stored key then no longer counts for validation.
  mutating func removeKey() {
    importedKey = nil
    storedKeyAlgorithm = nil
    storedKeyFingerprint = nil
    pendingKeyData = nil
    passphrase = ""
    keyError = nil
    importToken = nil
  }

  /// Drops typed and imported secrets, e.g. when the form closes.
  mutating func clearSecrets() {
    password = ""
    passphrase = ""
    importedKey = nil
    pendingKeyData = nil
    importToken = nil
  }
}
