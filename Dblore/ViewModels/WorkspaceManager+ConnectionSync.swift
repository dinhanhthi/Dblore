//
//  WorkspaceManager+ConnectionSync.swift
//  Dblore
//
//  The workspace connection config is the single source of protection level, commit style,
//  per-connection Safe Mode and protected mode for every tab and for the connection actor.
//  An opened file's AI policy never weakens the saved connection's, and AI features ask the
//  strictest of the live policy and of every saved row of the connection's identity. Its TLS
//  mode, SSH tunnel, client certificate and connection string are the saved row's, so it never
//  redirects a saved password, and it never weakens the saved row's protection. A save keeps
//  the saved row's AI policy and rules unless the AI fields themselves were edited, and its
//  color and group unless the save comes from the connection form. Its hidden schemas are
//  always kept: only the sidebar sets them, and saves the row when there is one.
//  Connecting to the same database with weaker settings goes through the same Safe Mode unlock
//  as a runtime change.
//

import Foundation

/// A connect held by `WorkspaceManager.connect(config:defaultCommitStyle:)`
enum WorkspaceConnectError: Error, Equatable {
  /// Same database with weaker safety settings: waiting for the Safe Mode unlock. Also thrown,
  /// with nothing held, when the unlock of a locked connection was cancelled
  case unlockRequired
  /// A Protected transaction is pending and the user cancelled its resolution: still
  /// connected, nothing changed
  case pendingTransactionKept
}

extension WorkspaceManager {
  /// Give a tab ViewModel the workspace connection config and route its runtime protection
  /// changes back to the workspace.
  func shareConnectionConfig(with viewModel: NotebookViewModel) {
    viewModel.applyWorkspaceConnectionConfig(workspace.connectionConfig)
    viewModel.onConnectionProtectionChanged = { [weak self] config in
      self?.updateConnectionProtection(from: config)
    }
    viewModel.isCommitStyleChangeBlocked = { [weak self] in
      guard let self else { return false }
      return !self.pendingTransaction.isIdle
    }
  }

  /// A tab changed the protection level, commit style, Safe Mode or protected mode of the
  /// connection: update the workspace config, every tab and the actor's connected config.
  func updateConnectionProtection(from config: ConnectionConfig) {
    guard var current = workspace.connectionConfig else { return }
    current.protectionLevel = config.protectionLevel
    current.safeMode = config.safeMode
    current.protectedMode = config.protectedMode
    current.commitStyle = config.commitStyle
    guard current != workspace.connectionConfig else { return }
    workspace.connectionConfig = current
    editingConnectionConfig.protectionLevel = current.protectionLevel
    editingConnectionConfig.safeMode = current.safeMode
    editingConnectionConfig.protectedMode = current.protectedMode
    editingConnectionConfig.commitStyle = current.commitStyle
    markDirtyAndScheduleAutoSave()
    syncConnectionStateToTabs()
    let connectionManager = connectionManager
    Task {
      await connectionManager.updateConnectedProtection(from: current)
    }
  }

  /// The saved connection with the identity of `config`: engine, host, port, home database and
  /// username, the identity the save path matches rows on, so another user's row never applies.
  /// The exact row (`keychainKey`, which a save of `config` overwrites) comes first, else the
  /// strictest row with the same `AIAccessGate.sessionKey` (host and names compared
  /// case-insensitively, file paths exactly). Without settings to resolve Use default, strictest
  /// ranks Never, Ask once per session, Use default, then Always. Nil when the list is
  /// unreadable.
  static func savedConnection(
    matching config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> ConnectionConfig? {
    savedMatches(
      for: config,
      in: SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
    ).first
  }

  /// Every saved row of the identity of `config`: the exact row first, then the rows with the
  /// same `AIAccessGate.sessionKey`, strictest first (see `savedConnection(matching:)`).
  private static func savedMatches(
    for config: ConnectionConfig, in history: [ConnectionHistoryEntry]
  ) -> [ConnectionConfig] {
    let exact = exactSavedEntry(for: config, in: history)
    let key = AIAccessGate.sessionKey(for: config)
    let strictness: [AIAccessPolicy] = [.never, .askOncePerSession, .useDefault, .always]
    let variants = history.filter {
      $0.keychainKey != exact?.keychainKey && AIAccessGate.sessionKey(for: $0.config) == key
    }
    .sorted {
      (strictness.firstIndex(of: $0.config.aiAccess) ?? 0)
        < (strictness.firstIndex(of: $1.config.aiAccess) ?? 0)
    }
    return ((exact.map { [$0] } ?? []) + variants).map(\.config)
  }

  /// `config` with the AI policy, rules and lock of the saved row a save of `config` overwrites, so
  /// a save never writes back an older copy over a stricter saved row. Unchanged without that
  /// row, and with Remember off (nothing is written, so the live policy stays).
  static func keepingSavedAIFields(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> ConnectionConfig {
    guard config.rememberConnection else { return config }
    let history = SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
    guard let saved = exactSavedEntry(for: config, in: history)?.config else { return config }
    var config = config
    config.aiAccess = saved.aiAccess
    config.aiRules = saved.aiRules
    config.isLocked = saved.isLocked
    return config
  }

  /// `config` with the color, group, hidden schemas, scripts, attached databases and lock of the
  /// saved row a save of `config` overwrites, for saves that do not come from the connection form
  /// (an opened file, a rename), so they never erase what the form or the sidebar set, and for an
  /// opened file's config, so the form opens on the saved values. Unchanged without that row,
  /// and with Remember off.
  static func keepingSavedAppearance(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> ConnectionConfig {
    guard config.rememberConnection else { return config }
    let history = SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
    guard let saved = exactSavedEntry(for: config, in: history)?.config else { return config }
    var config = config
    config.colorTag = saved.colorTag
    config.groupName = saved.groupName
    config.hiddenSchemas = saved.hiddenSchemas
    config.isLocked = saved.isLocked
    return config.withScripts(of: saved)
  }

  /// An opened file's `config` with the scripts and attached databases of its saved row
  /// (Remember on), else none: a file from elsewhere never picks which of the user's scripts
  /// run, nor against which host, nor which files are attached.
  static func keepingSavedScripts(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> ConnectionConfig {
    let saved =
      config.rememberConnection
      ? exactSavedEntry(
        for: config,
        in: SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()))?.config
      : nil
    return config.withScripts(of: saved)
  }

  /// An opened file's `config` with the TLS mode, SSH tunnel, client certificate (which also
  /// decides whether the saved custom CA is used) and connection string of its saved row
  /// (`hasSavedTransport`), even where the file's are stronger: the saved row is the user's
  /// choice, and a file never picks how a saved password travels. Remember off in the file
  /// changes nothing. Without that row they stay the file's (auto-connect then reads no
  /// password), but a connection string that reaches another host, port or TLS mode than the
  /// config is dropped (`MongoURIParser.checkedMongoURI`, the connection-file import rule).
  static func keepingSavedTransport(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> ConnectionConfig {
    var config = config
    if let saved = savedTransportRow(for: config, defaults: defaults) {
      config.sslMode = saved.sslMode
      config.sshTunnel = saved.sshTunnel
      config.clientCertificate = saved.clientCertificate
      config.mongoURI = saved.mongoURI
    } else if let uri = config.mongoURI {
      config.mongoURI = try? MongoURIParser.checkedMongoURI(
        uri, host: config.host, port: config.port, engine: config.databaseType,
        sslMode: config.sslMode
      ).get()
    }
    return config
  }

  /// True when `config` has a saved row: same Keychain key, engine, host, port, home database
  /// and username, whatever the config's Remember. Only then does auto-connect read a saved
  /// password or run a password command (over that row's transport).
  static func hasSavedTransport(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard
  ) -> Bool {
    savedTransportRow(for: config, defaults: defaults) != nil
  }

  private static func savedTransportRow(
    for config: ConnectionConfig, defaults: UserDefaults
  ) -> ConnectionConfig? {
    exactSavedEntry(
      for: config,
      in: SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()))?.config
  }

  /// An opened file's `config` with each protection part of its saved row (same key, engine,
  /// host, port, home database and username, whatever Remember) where the file's is weaker: a
  /// weaker file cannot have passed the Safe Mode unlock a weakening needs. The parts are decided
  /// on their own: the protection level, the commit style with the protected mode and Safe Mode
  /// it projects to (compared on the resolved style, as
  /// `NotebookViewModel.requiresUnlockForChange` does), and the read-only file flag. A part as
  /// strict or stricter keeps the file's: the protection pickers write only the workspace, and
  /// the next connect saves them to the row.
  static func keepingSavedProtection(
    _ config: ConnectionConfig, defaults: UserDefaults = .standard,
    defaultCommitStyle: CommitStyle = AppSettings.shared.commitStyle
  ) -> ConnectionConfig {
    guard let saved = savedTransportRow(for: config, defaults: defaults) else { return config }
    var config = config
    if config.protectionLevel.strictness < saved.protectionLevel.strictness {
      config.protectionLevel = saved.protectionLevel
    }
    if config.resolvedCommitStyle(fallback: defaultCommitStyle).strength
      < saved.resolvedCommitStyle(fallback: defaultCommitStyle).strength
    {
      config.protectedMode = saved.protectedMode
      config.safeMode = saved.safeMode
      config.commitStyle = saved.commitStyle
    }
    if saved.readOnlyFile, !config.readOnlyFile { config.readOnlyFile = true }
    return config
  }

  /// `config` with the hidden schemas of the saved row a save of `config` overwrites, for form
  /// saves: no form edits them, so a new draft of a saved connection never clears them. Without
  /// that row (or with Remember off) the draft keeps its own only while it still targets
  /// `current`, the workspace's connection they were set on (same saved-row key); a draft
  /// retargeted at another connection gets none.
  static func keepingSavedHiddenSchemas(
    _ config: ConnectionConfig, current: ConnectionConfig? = nil,
    defaults: UserDefaults = .standard
  ) -> ConnectionConfig {
    var config = config
    if config.rememberConnection,
      let saved = exactSavedEntry(
        for: config,
        in: SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore()))?.config
    {
      config.hiddenSchemas = saved.hiddenSchemas
    } else if current.map(ConnectionKeychainKey.password(for:))
      != ConnectionKeychainKey.password(for: config)
    {
      config.hiddenSchemas = []
    }
    return config
  }

  /// The row a save of `config` overwrites, when it is the same connection
  /// (`ConnectionHistoryEntry.isSavedRow(of:)`).
  private static func exactSavedEntry(
    for config: ConnectionConfig, in history: [ConnectionHistoryEntry]
  ) -> ConnectionHistoryEntry? {
    history.first { $0.isSavedRow(of: config) }
  }

  /// The AI policy and rules an opened workspace or notebook file may keep. With a saved match,
  /// the saved connection's policy and rules replace the file's. Without one, the file's policy
  /// may only tighten (Always follows the default) and its rules are dropped (untrusted).
  static func sanitizedFileAIPolicy(
    _ config: ConnectionConfig?, defaults: UserDefaults = .standard
  ) -> ConnectionConfig? {
    guard var config else { return nil }
    if let saved = savedConnection(matching: config, defaults: defaults) {
      config.aiAccess = saved.aiAccess
      config.aiRules = saved.aiRules
    } else {
      if config.aiAccess == .always { config.aiAccess = .useDefault }
      config.aiRules = ""
    }
    return config
  }

  /// What AI features read for the live `config`: the exact saved row's rules combined with the
  /// live ones (`combinedAIRules`; a variant row's rules are not sent), and the policy of every
  /// saved row of its identity (they share session approvals), so no stale or variant row
  /// loosens a stricter one.
  static func aiAccessContext(
    for config: ConnectionConfig?, defaults: UserDefaults = .standard
  ) -> AIAccessContext? {
    guard var config else { return nil }
    let history = SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
    let saved = savedMatches(for: config, in: history)
    config.aiRules = combinedAIRules(
      saved: exactSavedEntry(for: config, in: history)?.config.aiRules, live: config.aiRules)
    // Prompt builders read this copy: no secret reaches them
    config.password = ""
    config.mongoURI = nil
    return AIAccessContext(config: config, savedPolicies: saved.map(\.aiAccess), gate: .shared)
  }

  /// The rules sent once: live when it holds the saved rules (e.g. a saved row's rules extended
  /// with Remember off), saved when it holds the live ones, else both (saved first, a blank line,
  /// then live); at most `ConnectionConfig.aiRulesLimit`.
  static func combinedAIRules(saved: String?, live: String) -> String {
    let saved = saved ?? ""
    if live.isEmpty { return saved }
    if saved.isEmpty || live.contains(saved) { return ConnectionConfig.clampedAIRules(live) }
    if saved.contains(live) { return saved }
    return ConnectionConfig.clampedAIRules(saved + "\n\n" + live)
  }

  /// Rename the active connection (workspace, editing copy, tabs and the recent list).
  func renameConnection(
    to name: String, defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) {
    let trimmed = DropdownTitle.singleLine(name).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var current = workspace.connectionConfig, current.name != trimmed
    else { return }
    current = Self.keepingSavedAIFields(current, defaults: defaults)
    current = Self.keepingSavedAppearance(current, defaults: defaults)
    current.name = trimmed
    workspace.connectionConfig = current
    editingConnectionConfig.name = trimmed
    markDirtyAndScheduleAutoSave()
    syncConnectionStateToTabs()
    // A switched MongoDB connection renames its saved entry, which keeps the home database
    SessionManager.saveConnection(
      current.mongoHomeDatabase == nil
        ? current : Self.switchedMongoConfig(current, to: current.identityDatabase),
      defaults: defaults, passwords: passwords)
  }

  /// Set the schemas the sidebar hides for the active connection (workspace, editing copy and,
  /// when it has one, its saved row, saved as a rename is). Only the sidebar reads them. A
  /// connection without a saved row gets none: the save would add one to Recents and could
  /// push out the oldest row with its Keychain items.
  func setHiddenSchemas(
    _ schemas: [String], defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) {
    let normalized = ConnectionConfig.normalizedHiddenSchemas(schemas)
    guard var current = workspace.connectionConfig, current.hiddenSchemas != normalized else {
      return
    }
    current = Self.keepingSavedAIFields(current, defaults: defaults)
    current = Self.keepingSavedAppearance(current, defaults: defaults)
    current.hiddenSchemas = normalized
    workspace.connectionConfig = current
    editingConnectionConfig.hiddenSchemas = normalized
    markDirtyAndScheduleAutoSave()
    let history = SessionManager.loadHistory(defaults: defaults, passwords: NoPasswordStore())
    guard Self.exactSavedEntry(for: current, in: history) != nil else { return }
    SessionManager.saveConnection(
      current.mongoHomeDatabase == nil
        ? current : Self.switchedMongoConfig(current, to: current.identityDatabase),
      defaults: defaults, passwords: passwords)
  }

  // MARK: - Connect (weakening needs the Safe Mode unlock)

  /// True if connecting with `new` needs the Safe Mode unlock: `new` targets the same database
  /// as `current` (engine, host, port, database, username; strings trimmed and compared
  /// case-insensitively, so a case variant cannot dodge the check) and the resolved commit
  /// style weakens under the same rule as a runtime change
  /// (`NotebookViewModel.requiresUnlockForChange`). A different target is a new connection.
  /// `defaultCommitStyle` is the fallback for a legacy unprotected connection with a nil safe mode.
  nonisolated static func connectRequiresUnlock(
    current: ConnectionConfig?, new: ConnectionConfig, defaultCommitStyle: CommitStyle,
    hasPassword: Bool, hasTouchID: Bool
  ) -> Bool {
    guard let current, isSameTarget(current, new) else { return false }
    return NotebookViewModel.requiresUnlockForChange(
      from: ConnectionSafetyState(config: current, defaultCommitStyle: defaultCommitStyle),
      to: ConnectionSafetyState(config: new, defaultCommitStyle: defaultCommitStyle),
      hasPassword: hasPassword, hasTouchID: hasTouchID)
  }

  nonisolated private static func isSameTarget(
    _ lhs: ConnectionConfig, _ rhs: ConnectionConfig
  )
    -> Bool
  {
    isSameServer(lhs, rhs) && normalized(lhs.database) == normalized(rhs.database)
  }

  /// Engine, host, port and username match (strings trimmed, case-insensitive)
  nonisolated private static func isSameServer(
    _ lhs: ConnectionConfig, _ rhs: ConnectionConfig
  )
    -> Bool
  {
    lhs.databaseType == rhs.databaseType && lhs.port == rhs.port
      && normalizedHost(lhs.host) == normalizedHost(rhs.host)
      && normalized(lhs.username) == normalized(rhs.username)
  }

  /// Trimmed and lowercased, without a trailing dot
  nonisolated static func normalizedHost(_ value: String) -> String {
    let host = normalized(value)
    return host.hasSuffix(".") ? String(host.dropLast()) : host
  }

  nonisolated static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// The single connect entry point. Connecting replaces the current connection, so a pending
  /// Protected transaction is resolved first (Commit / Roll back / Cancel, like a disconnect).
  /// Compared against the workspace's current config whether or not it is connected right now:
  /// the workspace keeps the last config after a disconnect, so reconnecting to the same
  /// database with weaker settings needs the unlock too.
  /// - Throws: `WorkspaceConnectError.pendingTransactionKept` when the pending transaction was
  ///   not resolved (still connected, nothing changed); `WorkspaceConnectError.unlockRequired`
  ///   when the connect is held in `pendingWeakeningConnect` (nothing changed); connect with
  ///   `completePendingWeakeningConnect()` after the unlock. A locked connection asks first
  ///   (`LockCenter`, on this workspace's window): cancel throws `unlockRequired` with nothing
  ///   held, connected or read.
  /// - Parameter aiFieldsEdited: true only when the user edited the AI policy or rules: the save
  ///   then writes them; otherwise the saved row's AI fields are kept.
  /// - Parameter fromForm: true when `config` comes from the connection form: the save writes its
  ///   color and group (nil clears them); otherwise the saved row's are kept.
  func connect(
    config: ConnectionConfig, defaultCommitStyle: CommitStyle = AppSettings.shared.commitStyle,
    isAutoConnect: Bool = false,
    hasPassword: Bool = AppSettings.shared.hasCustomPasswordSet,
    hasTouchID: Bool = AppSettings.shared.isBiometricEnabled,
    aiFieldsEdited: Bool = false, fromForm: Bool = false
  ) async throws {
    lastUnlockConnectError = nil
    // The pin of a switched MongoDB connection holds on its own server only (Reconnect,
    // auto-connect, a new window); a form connect to another server or user is a new connection
    var config = config
    if config.mongoHomeDatabase != nil,
      workspace.connectionConfig.map({ !Self.isSameServer($0, config) }) ?? true
    {
      config.mongoHomeDatabase = nil
    }
    if !isAutoConnect { await supersedeAutoConnect() }
    // A locked connection asks on this workspace's window before anything else; auto-connect
    // never asks (the connection actor refuses it)
    if !isAutoConnect, lockCenter.registry.refusal(for: config) != nil {
      config = try await unlockedForConnect(config)
    }
    if !isAutoConnect { await unlockAttachedFiles(of: config) }
    guard
      await resolvePendingTransaction(action: .disconnect, defaultCommitStyle: defaultCommitStyle)
    else {
      throw WorkspaceConnectError.pendingTransactionKept
    }
    if Self.connectRequiresUnlock(
      current: workspace.connectionConfig, new: config, defaultCommitStyle: defaultCommitStyle,
      hasPassword: hasPassword, hasTouchID: hasTouchID)
    {
      pendingWeakeningConnect = config
      pendingWeakeningCertificate = ClientCertificateStoreFactory.operationMaterial?.material
      let pendingSSH = SSHCredentialStoreFactory.currentCredential(for: config)
      pendingWeakeningSSHCredential = pendingSSH?.credential
      pendingWeakeningAIFieldsEdited = aiFieldsEdited
      pendingWeakeningFromForm = fromForm
      throw WorkspaceConnectError.unlockRequired
    }
    pendingWeakeningConnect = nil
    pendingWeakeningCertificate = nil
    pendingWeakeningSSHCredential = nil
    pendingWeakeningAIFieldsEdited = false
    pendingWeakeningFromForm = false
    try await connectWithoutUnlockCheck(
      config: config, isAutoConnect: isAutoConnect, aiFieldsEdited: aiFieldsEdited,
      fromForm: fromForm)
    await showAttachWarnings()
  }

  /// Asks, on this workspace's window, to unlock each locked file `config` attaches. A cancel
  /// leaves that file blocked: the connection actor then skips it with a warning, and `config`
  /// (saved on connect) keeps it.
  private func unlockAttachedFiles(of config: ConnectionConfig) async {
    for attachment in config.validatedAttachedDatabases().attachments {
      let file = SQLiteFileAccess.lockConfig(
        forFile: attachment.path, engine: config.databaseType)
      guard lockCenter.registry.refusal(for: file) != nil else { continue }
      _ = await lockCenter.requestUnlock(
        for: file, reason: "Unlock \(attachment.name.prefix(80)) to attach it",
        anchor: NewWindowStore.shared.findWindow(for: id))
    }
  }

  /// The attached databases the connect left out, in one warning toast
  private func showAttachWarnings() async {
    let warnings = await connectionManager.attachWarnings
    guard !warnings.isEmpty else { return }
    WorkspaceWindowManager.shared.showToast(warnings.joined(separator: "\n"), type: .warning)
  }

  /// `config` once its blocked lock is unlocked, with its saved password when it uses one, has
  /// no password command and none typed (a locked row loads without it). Nothing is read before
  /// the grant.
  /// - Parameter action: what the prompt says the unlock is for ("connect", "test it")
  /// - Throws: `WorkspaceConnectError.unlockRequired` when the unlock was cancelled (nothing
  ///   changed, no error to show)
  func unlockedForConnect(
    _ config: ConnectionConfig, to action: String = "connect"
  ) async throws -> ConnectionConfig {
    let name = config.name.isEmpty ? config.displayString : config.name
    guard
      await lockCenter.requestUnlock(
        for: config, reason: "Unlock \(name.prefix(80)) to \(action)",
        anchor: NewWindowStore.shared.findWindow(for: id))
    else { throw WorkspaceConnectError.unlockRequired }
    guard config.databaseType.capabilities.usesPassword, config.passwordCommandScript == nil,
      config.password.isEmpty, lockCenter.registry.refusal(for: config) == nil,
      let password = passwords.loadPassword(forKey: ConnectionKeychainKey.password(for: config))
    else { return config }
    var config = config
    config.password = password
    return config
  }

  /// Connect with the held config after a successful Safe Mode unlock. No-op without one.
  /// The config stays held while connecting; it is cleared on success and on failure (a retry
  /// needs a new unlock).
  func completePendingWeakeningConnect() async throws {
    guard let config = pendingWeakeningConnect else { return }
    let scopedMaterial = pendingWeakeningCertificate.map {
      ClientCertificateStoreFactory.ScopedMaterial(
        account: ClientCertificateStoreFactory.account(for: config), material: $0)
    }
    let scopedSSH = SSHCredentialStoreFactory.scoped(pendingWeakeningSSHCredential, for: config)
    let aiFieldsEdited = pendingWeakeningAIFieldsEdited
    let fromForm = pendingWeakeningFromForm
    pendingWeakeningCertificate = nil
    pendingWeakeningSSHCredential = nil
    pendingWeakeningAIFieldsEdited = false
    pendingWeakeningFromForm = false
    defer {
      scopedMaterial?.clear()
      scopedSSH?.clear()
    }
    do {
      try await ClientCertificateStoreFactory.$operationMaterial.withValue(scopedMaterial) {
        try await SSHCredentialStoreFactory.$operationCredential.withValue(scopedSSH) {
          try await connectWithoutUnlockCheck(
            config: config, aiFieldsEdited: aiFieldsEdited, fromForm: fromForm)
        }
      }
    } catch {
      pendingWeakeningConnect = nil
      throw error
    }
    pendingWeakeningConnect = nil
    await showAttachWarnings()
  }

  /// The unlock sheet's connect. A failure closes the sheet; the form that started it stays
  /// open and shows `lastUnlockConnectError`. A changed SSH host key also shows the blocking
  /// alert. True once connected.
  func completePendingWeakeningConnectReportingFailure(
    coordinator: SSHHostKeyTrustCoordinator = .shared
  ) async -> Bool {
    lastUnlockConnectError = nil
    do {
      try await completePendingWeakeningConnect()
      return true
    } catch {
      lastUnlockConnectError = coordinator.report(error)
      return false
    }
  }

  /// Unlock cancelled: nothing connects (the form keeps its values).
  func cancelPendingWeakeningConnect() {
    pendingWeakeningConnect = nil
    pendingWeakeningCertificate = nil
    pendingWeakeningSSHCredential = nil
    pendingWeakeningAIFieldsEdited = false
    pendingWeakeningFromForm = false
  }

  /// Connect/disconnect: results shown in every tab came from the previous connection, so none
  /// of them stays editable (the actor also refuses their targets by connection epoch).
  func invalidateEditTargetsInTabs() {
    for viewModel in viewModels.values {
      viewModel.invalidateEditTargets()
    }
  }
}

extension ConnectionConfig {
  /// This config with the script names, timeout and attached databases of `other` (none when
  /// nil).
  fileprivate func withScripts(of other: ConnectionConfig?) -> ConnectionConfig {
    var config = self
    config.preConnectScript = other?.preConnectScript
    config.postDisconnectScript = other?.postDisconnectScript
    config.passwordCommandScript = other?.passwordCommandScript
    config.scriptTimeoutSeconds = other?.scriptTimeoutSeconds
    config.attachedDatabases = other?.attachedDatabases ?? []
    return config
  }
}
