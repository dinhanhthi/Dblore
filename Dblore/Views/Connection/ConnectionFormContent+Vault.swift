//
//  ConnectionFormContent+Vault.swift
//  Dblore
//
//  Password source of the connection form (saved password, password command, Vault) and the
//  Vault fields: address, mount, role, auth method, the token or AppRole secret, a private CA,
//  and Test Vault. The secret lives only in `VaultFormDraft` until a remembered save writes it
//  (`SessionManager`); the form never writes `VaultCredentialStore` itself.
//

import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers

/// Where a connection's password comes from.
enum PasswordSource: String, CaseIterable {
  case saved = "Saved password"
  case command = "Password command"
  case vault = "Vault"
}

/// What Test Vault shows. `running` carries the run's id: an edit made meanwhile drops it.
enum VaultTestStatus: Equatable {
  case running(UUID)
  case success(String)
  case failure(String)
}

/// What Test Vault's status depends on: the Vault settings and the typed secret.
struct VaultTestInputs: Equatable {
  let source: VaultSource?
  let typed: [String]

  init(config source: VaultSource?, draft: VaultFormDraft) {
    self.source = source
    typed = [draft.token, draft.roleID, draft.secretID]
  }
}

// MARK: - Vault draft

/// The Vault secret of the connection form: typed in this form, or read from the store for the
/// connection the draft was restored for (never while that row's lock is blocked). The stored
/// secret goes with the draft, so a save under edited Vault settings binds it to them.
nonisolated struct VaultFormDraft: Equatable, Sendable {
  var token = ""
  var roleID = ""
  var secretID = ""
  /// The saved secret of the connection the draft was restored for (nil: none, or not read)
  var storedSecret: VaultSecret?
  /// The saved secret was not read: the row's lock is not unlocked in this session
  var pending = false
  /// A saved secret exists, bound to other Vault settings
  var storedElsewhere = false
  /// A saved secret exists but the Keychain could not read it
  var storeUnreadable = false
  /// Destination (`VaultCredentialStore.destination(for:)`) of the restored connection
  var originalDestination: String?
  /// Vault address (trimmed) and CA of the restored connection: the stored secret goes only there
  var originalAddress: String?
  var originalCAPEM: String?
  /// The store read in flight; a newer restore supersedes it
  var restoreID: UUID?

  init() {}

  /// A draft for `config`, its stored secret still to be read (`apply`). `blocked`: the row's
  /// lock is not unlocked, so nothing is read.
  init(restoringFor config: ConnectionConfig, blocked: Bool) {
    originalDestination = VaultCredentialStore.destination(for: config)
    originalAddress = config.vault?.address.trimmingCharacters(in: .whitespacesAndNewlines)
    originalCAPEM = config.vault?.caPEM
    pending = blocked && config.vault != nil
  }

  /// The stored secret lookup for `config`; nil without reading the store while any lock
  /// `config` reaches is blocked. Reads the Keychain: call it off the main actor.
  static func storedLookup(
    for config: ConnectionConfig, store: any VaultSecretStore, registry: LockRegistry = .shared
  ) -> VaultCredentialStore.Lookup? {
    guard config.vault != nil, registry.refusal(for: config) == nil else { return nil }
    return VaultCredentialStore.lookup(for: config, from: store)
  }

  mutating func apply(_ lookup: VaultCredentialStore.Lookup?) {
    restoreID = nil
    switch lookup {
    case .found(let secret): storedSecret = secret
    case .destinationChanged: storedElsewhere = true
    case .missing: break
    // Not "no saved secret": the stored item is still there
    case .unreadable: storeUnreadable = true
    case nil: pending = true
    }
  }

  /// The secret typed for `method` (nil when nothing is typed)
  func enteredSecret(for method: VaultSource.AuthMethod) -> VaultSecret? {
    switch method {
    case .token:
      let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
      return typed.isEmpty ? nil : .token(typed)
    case .appRole:
      let role = roleID.trimmingCharacters(in: .whitespacesAndNewlines)
      let secret = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
      return role.isEmpty && secret.isEmpty ? nil : .appRole(roleID: role, secretID: secret)
    }
  }

  /// The secret for `config`'s submit: as `preparedSecret(for: method)`, but the stored secret
  /// never goes to an edited Vault address or CA (it is typed again there). Other edits (mount,
  /// role, auth method, SSH hop, TLS mode) re-bind it.
  func preparedSecret(for config: ConnectionConfig) -> VaultSecret? {
    guard let vault = config.vault else { return nil }
    return prepared(for: vault.authMethod, stored: storedServes(vault) ? storedSecret : nil)
  }

  /// The stored secret may go to `vault`: its address and CA are the restored connection's.
  func storedServes(_ vault: VaultSource) -> Bool {
    originalAddress == vault.address.trimmingCharacters(in: .whitespacesAndNewlines)
      && originalCAPEM == vault.caPEM
  }

  /// The typed secret, else the stored one when it serves `method`. An AppRole field left
  /// empty keeps the stored value (a new secret id alone rotates it).
  func preparedSecret(for method: VaultSource.AuthMethod?) -> VaultSecret? {
    prepared(for: method, stored: storedSecret)
  }

  private func prepared(
    for method: VaultSource.AuthMethod?, stored: VaultSecret?
  ) -> VaultSecret? {
    switch (method, stored) {
    case (nil, _):
      return nil
    case (.token, let stored):
      if let typed = enteredSecret(for: .token) { return typed }
      if case .token = stored { return stored }
      return nil
    case (.appRole, let stored):
      var role = roleID.trimmingCharacters(in: .whitespacesAndNewlines)
      var secret = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
      if case .appRole(let storedRole, let storedSecret) = stored {
        if role.isEmpty { role = storedRole }
        if secret.isEmpty { secret = storedSecret }
      }
      return role.isEmpty || secret.isEmpty ? nil : .appRole(roleID: role, secretID: secret)
    }
  }

  /// The row's lock is blocked and `config` still has the Vault settings the saved secret was
  /// entered for, its address and CA as `storedServes` reads them: the connect uses it after
  /// the unlock.
  func waitsForUnlock(_ config: ConnectionConfig) -> Bool {
    guard pending, originalDestination != nil, let vault = config.vault else { return false }
    return storedServes(vault)
      && VaultCredentialStore.destination(for: config) == originalDestination
  }

  /// No secret to submit although one was saved: it is for other Vault settings (edited here,
  /// or before) or another address or CA, so the user enters it again.
  func needsSecretAgain(for config: ConnectionConfig) -> Bool {
    guard config.vault != nil, preparedSecret(for: config) == nil else { return false }
    return storedElsewhere || storedSecret != nil || (pending && !waitsForUnlock(config))
  }

  /// Address, mount and role are filled in, and there is a secret (typed, stored, or stored
  /// and waiting for the unlock).
  func isValid(for config: ConnectionConfig) -> Bool {
    guard let vault = config.vault else { return true }
    let filled = [vault.address, vault.mount, vault.role].allSatisfy {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return filled && (preparedSecret(for: config) != nil || waitsForUnlock(config))
  }

  /// Drops typed and stored secrets, and a store read still in flight, e.g. when the form
  /// closes.
  mutating func clearSecrets() {
    token = ""
    roleID = ""
    secretID = ""
    storedSecret = nil
    restoreID = nil
  }
}

// MARK: - Test Vault

nonisolated enum VaultTestProbe {
  struct Result: Equatable, Sendable {
    let username: String
    /// Seconds (0: the lease has no TTL)
    let ttl: Int
    /// Why the lease could not be revoked, in user words (nil: revoked)
    var revokeFailure: String? = nil
  }

  /// Reads one lease with `secret` (never the stored one), then revokes it at once. Only the
  /// lease username and TTL, and a revoke failure, come back, never its password.
  static func run(
    config: ConnectionConfig, secret: VaultSecret, leasing: VaultLeasing = .app
  ) async throws -> Result {
    guard let scoped = VaultCredentialStore.scoped(secret, for: config) else {
      throw VaultLeaseError.secretMissing
    }
    defer { scoped.clear() }
    let lease = try await VaultCredentialStore.$operationSecret.withValue(scoped) {
      try await leasing.take(for: config)
    }
    let failure = await lease.revoke()
    return Result(
      username: lease.username, ttl: lease.createdDuration,
      revokeFailure: failure.map(revokeReason))
  }

  /// A 403 is the token's policy; anything else is Vault's own answer.
  static func revokeReason(_ error: any Error) -> String {
    if (error as? VaultClientError)?.isForbidden == true {
      return "the token's policy does not allow update on sys/leases/revoke"
    }
    var reason = error.localizedDescription
    if reason.hasSuffix(".") { reason.removeLast() }
    return reason
  }

  /// "Vault works: user …, lease 1 hr, revoked.", or why the lease outlives the test
  static func message(for result: Result) -> String {
    let ttl =
      result.ttl > 0
      ? Duration.seconds(result.ttl).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
      : "no TTL"
    let works = "Vault works: user \(result.username), lease \(ttl)"
    guard let failure = result.revokeFailure else { return works + ", revoked." }
    let end = result.ttl > 0 ? "it ends at its TTL." : "revoke it in Vault."
    return works + "; the lease could not be revoked: \(failure) — \(end)"
  }
}

// MARK: - CA

/// The Vault CA row's text, computed once per picked or loaded CA
struct VaultCADescription: Equatable {
  /// The first certificate's subject, and how many the PEM holds
  let summary: String
  /// SHA-256 of each certificate, as the import warning shows them (nil: none valid)
  let fingerprints: String?

  init(pem: String) {
    let certificates = URLSessionVaultClient.certificates(pem: pem)
    guard let first = certificates.first else {
      summary = "Invalid CA certificate"
      fingerprints = nil
      return
    }
    let subject = SecCertificateCopySubjectSummary(first) as String? ?? "Unknown subject"
    let extra = certificates.count > 1 ? " and \(certificates.count - 1) more" : ""
    summary = "Only \(subject)\(extra) is trusted for Vault"
    fingerprints =
      "SHA-256 "
      + certificates.map(DbloreConnectionFile.Connection.caFingerprint).joined(separator: ", ")
  }
}

// MARK: - Form section

extension ConnectionFormContent {

  /// Vault when the config has a source, the password command once one is picked or chosen
  /// here, else the saved password.
  var passwordSource: PasswordSource {
    if connectionConfig.vault != nil { return .vault }
    if connectionConfig.passwordCommandScript != nil || choosesPasswordCommand { return .command }
    return .saved
  }

  /// Saved password, Password command or Vault. `formFields()` shows the chosen source's fields.
  func passwordSourcePicker() -> some View {
    let source = passwordSource
    return FormField(label: "Password source") {
      CapsuleDropdown(
        title: source.rawValue, options: PasswordSource.allCases, optionTitle: \.rawValue,
        isSelected: { $0 == source }, onSelect: selectPasswordSource
      )
      .fixedSize()
    }
  }

  /// Switching away from Vault drops its settings and secrets (a save then deletes the stored
  /// secret) and brings back the password Vault cleared. Vault takes no password or password
  /// command and is always remembered.
  func selectPasswordSource(_ source: PasswordSource) {
    guard source != passwordSource else { return }
    choosesPasswordCommand = source == .command
    switch source {
    case .saved, .command:
      if source == .saved { connectionConfig.passwordCommandScript = nil }
      if connectionConfig.vault != nil {
        connectionConfig.vault = nil
        // Else a save or connect would delete the row's stored password
        if let password = passwordBeforeVault { connectionConfig.password = password }
        passwordBeforeVault = nil
        vaultDraft = VaultFormDraft()
        vaultTest = nil
        vaultSessionOnly = false
      }
    case .vault:
      connectionConfig.passwordCommandScript = nil
      passwordBeforeVault = connectionConfig.password
      connectionConfig.password = ""
      connectionConfig.rememberConnection = true
      connectionConfig.vault = VaultSource(
        address: "", mount: "database", role: "", authMethod: .token, caPEM: nil)
    }
  }

  /// The config Connect, Test and Save submit for a Vault source: always remembered, no saved
  /// password or password command, trimmed address, mount and role.
  static func withVaultRules(_ config: ConnectionConfig) -> ConnectionConfig {
    guard var vault = config.vault else { return config }
    var config = config
    vault.address = vault.address.trimmingCharacters(in: .whitespacesAndNewlines)
    vault.mount = vault.mount.trimmingCharacters(in: .whitespacesAndNewlines)
    vault.role = vault.role.trimmingCharacters(in: .whitespacesAndNewlines)
    config.vault = vault
    config.rememberConnection = true
    config.password = ""
    config.passwordCommandScript = nil
    return config
  }

  /// The draft's secret scoped to `config` (the submitted config: its destination binds it).
  func scopedVaultSecret(for config: ConnectionConfig) -> VaultCredentialStore.ScopedSecret? {
    VaultCredentialStore.scoped(vaultDraft.preparedSecret(for: config), for: config)
  }

  /// Rereads the stored secret for the form's connection (off the main actor; a blocked row
  /// reads nothing until its unlock) and drops typed secrets and the password kept for a
  /// switch back from Vault.
  func restoreVaultDraft() {
    if connectionConfig.vault != nil && !connectionConfig.rememberConnection {
      connectionConfig.rememberConnection = true
    }
    let config = connectionConfig
    let registry = LockCenter.shared.registry
    let blocked = registry.refusal(for: config) != nil
    var draft = VaultFormDraft(restoringFor: config, blocked: blocked)
    choosesPasswordCommand = false
    passwordBeforeVault = nil
    vaultTest = nil
    vaultSessionOnly = config.vault != nil && VaultCredentialStore.isSessionOnly(for: config)
    guard config.vault != nil, !blocked else {
      vaultDraft = draft
      return
    }
    let id = UUID()
    draft.restoreID = id
    vaultDraft = draft
    Task {
      let lookup = await Task.detached(priority: .userInitiated) {
        VaultFormDraft.storedLookup(
          for: config, store: VaultCredentialStore.shared, registry: registry)
      }.value
      guard vaultDraft.restoreID == id else { return }
      vaultDraft.apply(lookup)
    }
  }

  // MARK: Fields

  private func vaultBinding(
    _ keyPath: WritableKeyPath<VaultSource, String>
  ) -> Binding<String> {
    Binding(
      get: { connectionConfig.vault?[keyPath: keyPath] ?? "" },
      set: { connectionConfig.vault?[keyPath: keyPath] = $0 })
  }

  private var vaultAuthMethod: Binding<VaultSource.AuthMethod> {
    Binding(
      get: { connectionConfig.vault?.authMethod ?? .token },
      set: { connectionConfig.vault?.authMethod = $0 })
  }

  static func vaultAuthTitle(_ method: VaultSource.AuthMethod) -> String {
    switch method {
    case .token: "Token"
    case .appRole: "AppRole"
    }
  }

  /// Address, mount, role, auth method, secret, CA, notes and Test Vault.
  @ViewBuilder
  func vaultFields() -> some View {
    let method = connectionConfig.vault?.authMethod ?? .token
    FormField(label: "Vault address") {
      TextField("https://vault.example.com:8200", text: vaultBinding(\.address))
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .inputCapsuleStyle()
    }

    HStack(spacing: Spacing.md) {
      FormField(label: "Mount") {
        TextField("database", text: vaultBinding(\.mount))
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .inputCapsuleStyle()
      }
      FormField(label: "Role") {
        TextField("readonly", text: vaultBinding(\.role))
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .inputCapsuleStyle()
      }
    }

    FormField(label: "Sign in with") {
      CapsuleTabPicker(
        selection: vaultAuthMethod, tabs: [VaultSource.AuthMethod.token, .appRole], height: 28
      ) { option in
        CapsuleTabLabel(text: Self.vaultAuthTitle(option), isSelected: option == method)
      }
      .fitsContent()
      .fixedSize()
    }

    switch method {
    case .token:
      FormField(label: "Token") {
        SecureField(vaultPlaceholder(storedServes: isStoredToken), text: $vaultDraft.token)
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
      }
    case .appRole:
      HStack(spacing: Spacing.md) {
        FormField(label: "Role ID") {
          SecureField(vaultPlaceholder(storedServes: isStoredAppRole), text: $vaultDraft.roleID)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
        }
        FormField(label: "Secret ID") {
          SecureField(
            vaultPlaceholder(storedServes: isStoredAppRole), text: $vaultDraft.secretID
          )
          .textFieldStyle(.plain)
          .inputCapsuleStyle()
        }
      }
    }

    vaultCAField()

    Text(
      "Each connect leases a database user and password from \(Self.credentialsPath(connectionConfig.vault)). "
        + "The token or AppRole secret is kept in the Keychain once you save. Besides the "
        + "default policy (lease renew, lookup-self), its policy needs update on "
        + "sys/leases/revoke so Dblore can end leases on disconnect."
    )
    .font(.caption)
    .foregroundColor(.foregroundMuted)
    .fixedSize(horizontal: false, vertical: true)

    vaultNotes()

    vaultTestRow()
  }

  private static func credentialsPath(_ vault: VaultSource?) -> String {
    let mount = vault?.mount ?? ""
    let role = vault?.role ?? ""
    return "\(mount.isEmpty ? "<mount>" : mount)/creds/\(role.isEmpty ? "<role>" : role)"
  }

  /// The stored secret is a token and may go to the form's Vault address and CA
  private var isStoredToken: Bool {
    guard let vault = connectionConfig.vault, vaultDraft.storedServes(vault) else { return false }
    if case .token = vaultDraft.storedSecret { return true }
    return false
  }

  private var isStoredAppRole: Bool {
    guard let vault = connectionConfig.vault, vaultDraft.storedServes(vault) else { return false }
    if case .appRole = vaultDraft.storedSecret { return true }
    return false
  }

  /// A saved secret is never shown; leaving the field empty keeps it.
  private func vaultPlaceholder(storedServes: Bool) -> String {
    storedServes ? "Leave empty to keep the saved value" : "Required"
  }

  @ViewBuilder
  private func vaultNotes() -> some View {
    let submitted = Self.withVaultRules(withSSHConfig(connectionConfig))
    if vaultDraft.storeUnreadable {
      Text(Self.vaultStoreUnreadableHint)
        .font(.caption)
        .foregroundColor(.warning)
        .fixedSize(horizontal: false, vertical: true)
    }
    if vaultDraft.needsSecretAgain(for: submitted) {
      Text(Self.vaultSecretAgainHint)
        .font(.caption)
        .foregroundColor(.warning)
        .fixedSize(horizontal: false, vertical: true)
    } else if vaultDraft.waitsForUnlock(submitted)
      && vaultDraft.enteredSecret(for: submitted.vault?.authMethod ?? .token) == nil
    {
      Text("The saved Vault secret is used once the connection is unlocked.")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
    if vaultSessionOnly {
      Text(
        "The Keychain did not accept the Vault secret: it is kept until Dblore quits. Enter it again next time."
      )
      .font(.caption)
      .foregroundColor(.warning)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  static let vaultStoreUnreadableHint =
    "The Keychain could not be read, so the saved Vault secret was not loaded; it is kept. "
    + "Unlock the Keychain and open the connection again, or enter the token or AppRole "
    + "secret to replace it."

  static let vaultSecretAgainHint =
    "The saved Vault secret is for the previous Vault settings. Enter the token or AppRole "
    + "secret again."

  // MARK: CA

  @ViewBuilder
  private func vaultCAField() -> some View {
    let caPEM = connectionConfig.vault?.caPEM
    FormField(label: "Vault CA certificate") {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.sm) {
          Button(caPEM == nil ? "Choose CA File…" : "Replace CA File…", action: chooseVaultCA)
            .buttonStyle(FilledSecondaryButtonStyle())
          if caPEM != nil {
            Button("Remove") {
              connectionConfig.vault?.caPEM = nil
              vaultCAError = nil
            }
            .buttonStyle(SecondaryButtonStyle())
          }
        }
        Text(
          caPEM == nil
            ? "None: the system trust store checks Vault" : vaultCADescription?.summary ?? ""
        )
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .lineLimit(2)
        // To compare with the import warning's fingerprints
        if caPEM != nil, let fingerprints = vaultCADescription?.fingerprints {
          Text(fingerprints)
            .font(.caption.monospaced())
            .foregroundColor(.foregroundMuted)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let vaultCAError {
          Text(vaultCAError)
            .font(.caption)
            .foregroundColor(.destructive)
        }
      }
    }
    // Parsed once per picked or loaded CA, not on every render
    .onChange(of: caPEM, initial: true) { _, pem in
      vaultCADescription = pem.map(VaultCADescription.init)
    }
  }

  /// A PEM of one or more certificates, the only anchors trusted for the Vault address. At
  /// most `DbloreConnectionFile.maxCAPEMLength`, so an export of the connection imports.
  private func chooseVaultCA() {
    guard !SessionManager.isRunningAsTestHost else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = ["pem", "crt", "cer"].compactMap {
      UTType(filenameExtension: $0)
    }
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        guard let pem = try? readPEM(at: url),
          pem.utf8.count <= DbloreConnectionFile.maxCAPEMLength,
          !URLSessionVaultClient.certificates(pem: pem).isEmpty
        else {
          vaultCAError =
            "Choose a PEM file of CA certificates of at most "
            + "\(DbloreConnectionFile.maxCAPEMLength / 1024) KB."
          return
        }
        connectionConfig.vault?.caPEM = pem
        vaultCAError = nil
      }
    }
  }

  // MARK: Test Vault

  @ViewBuilder
  private func vaultTestRow() -> some View {
    let running: Bool = {
      if case .running = vaultTest { return true }
      return false
    }()
    HStack(alignment: .top, spacing: Spacing.sm) {
      Button(action: testVault) {
        HStack(spacing: Spacing.sm) {
          if running {
            ProgressView()
              .controlSize(.mini)
              .tint(.accent)
              .frame(width: 14, height: 14)
          }
          Text("Test Vault")
        }
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(running)

      switch vaultTest {
      case .success(let message):
        Text(message)
          .font(.caption)
          .foregroundColor(.success)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      case .failure(let message):
        Text(message)
          .font(.caption)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      case .running, nil:
        EmptyView()
      }
    }
  }

  /// Reads one lease with the draft's secret, shows its username and TTL, revokes it at once.
  /// Writes nothing; the saved secret of a blocked row is not used.
  private func testVault() {
    let config = Self.withVaultRules(withSSHConfig(connectionConfig))
    guard config.vault != nil else { return }
    guard let secret = vaultDraft.preparedSecret(for: config) else {
      vaultTest = .failure("Enter the Vault token or AppRole role ID and secret ID first.")
      return
    }
    let id = UUID()
    vaultTest = .running(id)
    Task {
      let status: VaultTestStatus
      do {
        // Vault I/O off the main actor
        let result = try await Task.detached(priority: .userInitiated) {
          try await VaultTestProbe.run(config: config, secret: secret)
        }.value
        status = .success(VaultTestProbe.message(for: result))
      } catch {
        status = .failure(error.localizedDescription)
      }
      // An edit made meanwhile cleared the run
      guard vaultTest == .running(id) else { return }
      vaultTest = status
    }
  }
}
