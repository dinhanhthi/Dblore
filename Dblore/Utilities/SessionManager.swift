//
//  SessionManager.swift
//  Dblore
//

import Foundation
import Security

/// Manages saving and loading database connection sessions
/// Stores connection config in UserDefaults and passwords in Keychain
@MainActor
class SessionManager {
  // Legacy key for migration
  private nonisolated static let legacySessionKey = "ace.thi.dblore.savedSession"
  // New key for connection history
  private nonisolated static let historyKey = "ace.thi.dblore.connectionHistory"
  nonisolated static let keychainService = "ace.thi.dblore.database"

  // MARK: - Launch Restore

  /// Whether the app should restore the previous session (and read the Keychain) at launch.
  /// Returns false when running as an XCTest host to avoid blocking Keychain prompts.
  nonisolated static func shouldRestoreSession(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] == nil
  }

  /// True when the process is an XCTest host (computed once from the process environment)
  nonisolated static let isRunningAsTestHost = !shouldRestoreSession()

  // MARK: - Migration Support

  /// Migrate from single session to history array (one-time operation)
  static func migrateIfNeeded() {
    // Check if already migrated
    if UserDefaults.standard.object(forKey: historyKey) != nil {
      return  // Already migrated
    }

    // Load old session
    guard let data = UserDefaults.standard.data(forKey: legacySessionKey),
      var config = try? JSONDecoder().decode(ConnectionConfig.self, from: data)
    else {
      // No legacy session, just initialize empty history
      saveHistory([])
      return
    }

    // Engines without passwords never touch the Keychain
    if config.databaseType.capabilities.usesPassword {
      let keychainKey = keychainKey(for: config)
      do {
        if let password = try KeychainConnectionPasswordStore().readPassword(forKey: keychainKey) {
          config.password = password
        }
      } catch {
        // Not readable now: the legacy session stays, and the next launch retries
        return
      }
    }

    // Create history entry
    let entry = ConnectionHistoryEntry(config: config)
    saveHistory([entry])

    // Delete old key
    UserDefaults.standard.removeObject(forKey: legacySessionKey)
  }

  // MARK: - History Management

  /// Load connection history (sorted by most recent first)
  static func loadHistory(
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore(),
    registry: LockRegistry = .shared
  ) -> [ConnectionHistoryEntry] {
    historyWithUnreadablePasswords(defaults: defaults, passwords: passwords, registry: registry)
      .entries
  }

  /// `loadHistory`, plus the ids of the rows whose saved password could not be read (they load
  /// without it). Save and replace never delete those passwords.
  static func historyWithUnreadablePasswords(
    defaults: UserDefaults, passwords: any ConnectionPasswordStore, registry: LockRegistry
  ) -> (entries: [ConnectionHistoryEntry], unreadableIDs: Set<UUID>) {
    var entries = storedEntries(defaults: defaults).known
    var unreadableIDs: Set<UUID> = []
    publishLocks(entries, defaults: defaults, registry: registry)

    // Load passwords for engines that store one. Others are not queried, nor is a Vault row
    // (it leases its password), nor a row whose lock is not unlocked in this session: it loads
    // without its password until then.
    for i in 0..<entries.count
    where entries[i].config.databaseType.capabilities.usesPassword
      && entries[i].config.vault == nil
      && registry.refusal(for: entries[i].config) == nil
    {
      let key = entries[i].keychainKey
      do {
        if let password = try passwords.readPassword(forKey: key) {
          entries[i].config.password = password
        }
      } catch {
        unreadableIDs.insert(entries[i].id)
      }
    }

    // Sort by most recent first
    return (entries.sorted { $0.lastUsedAt > $1.lastUsedAt }, unreadableIDs)
  }

  /// Keychain keys of the given rows' passwords that could not be read.
  private static func unreadableKeys(
    of history: [ConnectionHistoryEntry], ids: Set<UUID>
  ) -> Set<String> {
    Set(history.filter { ids.contains($0.id) }.map(\.keychainKey))
  }

  /// Decodes saved entries one by one. Entries this build cannot decode (for example an
  /// engine added by a newer build) come back as raw JSON objects in `unknown`.
  private static func storedEntries(
    defaults: UserDefaults
  ) -> (known: [ConnectionHistoryEntry], unknown: [Any]) {
    guard let data = defaults.data(forKey: historyKey),
      let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else { return ([], []) }
    var known: [ConnectionHistoryEntry] = []
    var unknown: [Any] = []
    for object in array {
      if let entryData = try? JSONSerialization.data(
        withJSONObject: object, options: .fragmentsAllowed),
        let entry = try? JSONDecoder().decode(ConnectionHistoryEntry.self, from: entryData)
      {
        known.append(entry)
      } else {
        unknown.append(object)
      }
    }
    return (known, unknown)
  }

  /// Save connection history (private helper)
  private static func saveHistory(
    _ entries: [ConnectionHistoryEntry], defaults: UserDefaults = .standard
  ) {
    if let encoded = encodedHistory(entries, defaults: defaults) {
      defaults.set(encoded, forKey: historyKey)
    }
  }

  /// Encodes `entries` without passwords. Entries this build cannot decode are read from
  /// `defaults` before the write and appended unchanged, so a downgrade never drops them.
  /// They do not count toward the size limit. Load sorts by date, so their position is free.
  private static func encodedHistory(
    _ entries: [ConnectionHistoryEntry], defaults: UserDefaults
  ) -> Data? {
    // Remove passwords before saving
    var cleanEntries = entries
    for i in 0..<cleanEntries.count {
      cleanEntries[i].config.password = ""
    }

    guard let encoded = try? JSONEncoder().encode(cleanEntries) else { return nil }
    let unknown = storedEntries(defaults: defaults).unknown
    guard !unknown.isEmpty else { return encoded }
    guard let known = try? JSONSerialization.jsonObject(with: encoded) as? [Any] else {
      return nil
    }
    return try? JSONSerialization.data(withJSONObject: known + unknown)
  }

  /// Maximum number of connection history entries to store
  static let maxConnectionHistorySize = 50

  /// Add or update connection in history. Only this connection's own row (`isSavedRow(of:)`) is
  /// replaced. Refused (false, nothing changed) when another saved connection uses its Keychain
  /// key (`keyUsedByAnotherIdentity`): that row and its password are never touched.
  @discardableResult
  static func saveConnection(
    _ config: ConnectionConfig,
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore(),
    certificates: any ClientCertificateStore = ClientCertificateStoreFactory.shared,
    sshCredentials: any SSHCredentialStore = SSHCredentialStoreFactory.shared,
    sshCredential: SSHStoredCredential? = nil,
    vaultSecrets: any VaultSecretStore = VaultCredentialStore.shared,
    registry: LockRegistry = .shared
  ) -> Bool {
    var config = singleLineName(config)
    guard config.rememberConnection else {
      // If remember is disabled, don't add to history
      return true
    }

    guard !keyUsedByAnotherIdentity(config, defaults: defaults) else { return false }
    let loaded = historyWithUnreadablePasswords(
      defaults: defaults, passwords: passwords, registry: registry)
    var history = loaded.entries
    let previous = history
    // Passwords that could not be read are never deleted: they may still be there
    let unreadable = unreadableKeys(of: previous, ids: loaded.unreadableIDs)
    // Locked by the form's toggle before the first save (nothing else sets a draft's lock)
    let locksNewRow = config.isLocked
    // This connection's own row (same engine, host, port, home database and username)
    let index = history.firstIndex(where: { $0.isSavedRow(of: config) })
    // A replaced row keeps its id: the MCP allowlist and write scopes are keyed by it
    let keptID = index.map { history[$0].id }
    // It keeps the row's lock too: a form draft never changes it (only the lock toggle does)
    if let index { config.isLocked = history[index].config.isLocked }
    // Every saved row of a locked identity carries the lock (another database of the login)
    let inheritsLock = hasLockedRow(of: config, in: history)
    if inheritsLock { config.isLocked = true }
    // A new row the form locked creates its lock here: this session keeps using it, as the
    // toggle on a saved row does. A lock taken from another row is never granted.
    let grantsNewLock = locksNewRow && index == nil && !inheritsLock
    let lockedBefore = registry.lockedIdentities
    let generation = registry.generation
    let newEntry = ConnectionHistoryEntry(id: keptID ?? UUID(), config: config)

    if let index {
      // Update existing entry (refresh timestamp)
      history[index] = newEntry
    } else {
      // Add new entry at the beginning
      history.insert(newEntry, at: 0)
    }

    // Trim to max size: the oldest unlocked rows go, never a locked row (its lock would be lost
    // without asking) nor the row just saved; locked rows alone may stay over the cap
    while history.count > maxConnectionHistorySize,
      let oldest = history.lastIndex(where: { !$0.config.isLocked && $0.id != newEntry.id })
    {
      history.remove(at: oldest)
    }

    guard let encoded = encodedHistory(history, defaults: defaults),
      ClientCertificateStoreFactory.persistOperationMaterial(for: config, to: certificates),
      saveSSHCredential(sshCredential, for: config, to: sshCredentials)
    else { return false }
    // The form's typed or moved Vault secret, only on this accepted, remembered save
    VaultCredentialStore.persistOperationSecret(for: config, to: vaultSecrets)
    if config.databaseType.capabilities.usesPassword {
      if config.vault != nil {
        // A Vault row's password is a lease's: none is kept under its key, unless another
        // row on that key still uses a saved password
        if !history.contains(where: {
          $0.id != newEntry.id && $0.keychainKey == newEntry.keychainKey && $0.config.vault == nil
        }), !unreadable.contains(newEntry.keychainKey) {
          passwords.deletePassword(forKey: newEntry.keychainKey)
        }
      } else if !config.password.isEmpty {
        passwords.savePassword(config.password, forKey: newEntry.keychainKey)
      }
    }
    defaults.set(encoded, forKey: historyKey)
    publishLocks(history, defaults: defaults, registry: registry)
    if grantsNewLock {
      grantNewLocks(
        of: [config], lockedBefore: lockedBefore, generation: generation, registry: registry)
    }
    let rawKeys = undecodableRowKeys(defaults: defaults)
    for entry in previous
    where !keyStillUsed(entry.keychainKey, in: history, rawKeys: rawKeys)
      && !unreadable.contains(entry.keychainKey)
    {
      deleteStoredPassword(for: entry, passwords: passwords)
    }
    pruneCertificates(previous: previous, current: history, certificates: certificates)
    pruneSSHCredentials(previous: previous, current: history, sshCredentials: sshCredentials)
    pruneVaultSecrets(
      previous: previous, current: history, rawKeys: rawKeys, vaultSecrets: vaultSecrets)
    return true
  }

  /// Saves imported connections with one history load and one history write.
  /// Remember is forced on. A connection whose Keychain key is already saved, or earlier in
  /// the batch, is skipped and none of its secrets are written. A rejected SSH credential
  /// leaves the entry out. Imports fill only the free history slots: saved rows are never
  /// evicted, and extra imports are dropped unsaved.
  @discardableResult
  static func saveConnections(
    _ imported: [ImportedConnection],
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore(),
    sshCredentials: any SSHCredentialStore = SSHCredentialStoreFactory.shared,
    registry: LockRegistry = .shared
  ) -> BulkSaveReport {
    let history = loadHistory(defaults: defaults, passwords: passwords, registry: registry)
    let freeSlots = max(0, maxConnectionHistorySize - history.count)
    var report = BulkSaveReport()
    var seen = savedConnectionKeys(defaults: defaults)
    var kept: [ConnectionHistoryEntry] = []
    var savedSSHAccounts: [String] = []
    var pendingPasswords: [(key: String, password: String)] = []

    for item in imported {
      var saved = singleLineName(item.config)
      saved.rememberConnection = true
      saved.password = item.password ?? ""
      if hasLockedRow(of: saved, in: history) { saved.isLocked = true }
      let name = reportName(saved.name.isEmpty ? saved.displayString : saved.name)
      let entry = ConnectionHistoryEntry(config: saved)
      guard !seen.contains(entry.keychainKey) else {
        report.skippedDuplicates.append(name)
        continue
      }
      guard kept.count < freeSlots else {
        report.droppedByLimit += 1
        continue
      }
      if let credential = item.sshCredential,
        let account = SSHCredentialStoreFactory.account(for: saved)
      {
        guard sshCredentials.save(credential, account: account) else {
          report.failed.append(.init(name: name, reason: "The SSH credential could not be saved."))
          continue
        }
        savedSSHAccounts.append(account)
      }
      seen.insert(entry.keychainKey)
      kept.append(entry)
      if saved.databaseType.capabilities.usesPassword, !saved.password.isEmpty {
        pendingPasswords.append((entry.keychainKey, saved.password))
      }
    }

    guard !kept.isEmpty else { return report }
    guard let encoded = encodedHistory(kept + history, defaults: defaults) else {
      // Each kept key is new, so these accounts belong to no saved row.
      for account in savedSSHAccounts { sshCredentials.delete(account: account) }
      report.failed += kept.map {
        .init(
          name: reportName($0.shortDisplayName),
          reason: "The connection history could not be saved.")
      }
      return report
    }
    for pending in pendingPasswords {
      passwords.savePassword(pending.password, forKey: pending.key)
    }
    defaults.set(encoded, forKey: historyKey)
    publishLocks(kept + history, defaults: defaults, registry: registry)
    report.added = kept.count
    return report
  }

  /// Keychain keys of every saved row. Rows this build cannot decode keep their saved password
  /// under the same key, so they count too. Reads no Keychain item.
  static func savedConnectionKeys(defaults: UserDefaults = .standard) -> Set<String> {
    let stored = storedEntries(defaults: defaults)
    return Set(stored.known.map(\.keychainKey) + stored.unknown.compactMap(rawKeychainKey))
  }

  /// Whether a saved row of another connection (`isSavedRow(of:)` false), or a row this build
  /// cannot decode, uses the Keychain key `config` saves its password under. A save onto it would
  /// replace that row's password, so saves and edits are refused. `rowID` is the edited row,
  /// which may move onto its own key. Reads no Keychain item.
  static func keyUsedByAnotherIdentity(
    _ config: ConnectionConfig, excluding rowID: UUID? = nil, defaults: UserDefaults = .standard
  ) -> Bool {
    let key = keychainKey(for: config)
    let stored = storedEntries(defaults: defaults)
    let usedByRow = stored.known.contains {
      $0.id != rowID && $0.keychainKey == key && !$0.isSavedRow(of: config)
    }
    return usedByRow || stored.unknown.contains { rawKeychainKey($0) == key }
  }

  /// Keychain key of a raw history row, read from its `config` like `keychainKey(for:)`.
  /// Nil when host, port, database, or username is missing or has the wrong type.
  private static func rawKeychainKey(_ object: Any) -> String? {
    guard let config = (object as? [String: Any])?["config"] as? [String: Any],
      let host = config["host"] as? String,
      let port = config["port"] as? Int,
      let database = config["database"] as? String,
      let username = config["username"] as? String
    else { return nil }
    // A missing or unknown engine keeps the legacy (unscoped) key
    let scope = (config["databaseType"] as? String).flatMap(DatabaseType.init)?.keychainScope
    return ConnectionKeychainKey.password(
      scope: scope, host: host, port: port, database: database, username: username)
  }

  /// One line of at most 80 characters, for names shown in a bulk save report.
  private static func reportName(_ name: String) -> String {
    let line = DropdownTitle.singleLine(name).trimmingCharacters(in: .whitespaces)
    return line.count <= 80 ? line : String(line.prefix(79)) + "\u{2026}"
  }

  /// A single-line text field still accepts pasted line breaks, which it does not show.
  /// Saved names keep one line so menus and cards do not grow.
  private static func singleLineName(_ config: ConnectionConfig) -> ConnectionConfig {
    var config = config
    config.name = DropdownTitle.singleLine(config.name).trimmingCharacters(in: .whitespaces)
    return config
  }

  /// Replace one history row in place. The id, position, and last-used date stay.
  /// A changed host, port, database, or username takes the password with it, and the stored SSH
  /// secret too while the bastion is unchanged (`movedSSHCredential`).
  /// An empty password deletes the stored one. Remember off removes the row. The row's lock stays:
  /// a form draft never removes it, and adds one only when the form's toggle locked the draft.
  /// Another row of the edited target's identity is merged into it. Refused (false, nothing
  /// changed) while the row, the edited target or a merged row reaches a lock not unlocked in
  /// this session, and when another saved connection uses the target's Keychain key
  /// (`keyUsedByAnotherIdentity`).
  @discardableResult
  static func replaceConnection(
    id: UUID,
    with config: ConnectionConfig,
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore(),
    certificates: any ClientCertificateStore = ClientCertificateStoreFactory.shared,
    sshCredentials: any SSHCredentialStore = SSHCredentialStoreFactory.shared,
    sshCredential: SSHStoredCredential? = nil,
    vaultSecrets: any VaultSecretStore = VaultCredentialStore.shared,
    registry: LockRegistry = .shared
  ) -> Bool {
    var config = singleLineName(config)
    let loaded = historyWithUnreadablePasswords(
      defaults: defaults, passwords: passwords, registry: registry)
    var history = loaded.entries
    let oldHistory = history
    guard let index = history.firstIndex(where: { $0.id == id }) else {
      return saveConnection(
        config, defaults: defaults, passwords: passwords, certificates: certificates,
        sshCredentials: sshCredentials, sshCredential: sshCredential,
        vaultSecrets: vaultSecrets, registry: registry)
    }

    let previous = history[index]
    guard registry.refusal(for: previous.config) == nil, registry.refusal(for: config) == nil
    else { return false }
    // Passwords that could not be read are never deleted: they may still be there
    let unreadable = unreadableKeys(of: oldHistory, ids: loaded.unreadableIDs)
    let rawKeys = undecodableRowKeys(defaults: defaults)
    if !config.rememberConnection {
      if !keyStillUsed(previous.keychainKey, in: history, excluding: id, rawKeys: rawKeys),
        !unreadable.contains(previous.keychainKey)
      {
        deleteStoredPassword(for: previous, passwords: passwords)
      }
      history.remove(at: index)
      saveHistory(history, defaults: defaults)
      publishLocks(history, defaults: defaults, registry: registry)
      pruneCertificates(previous: oldHistory, current: history, certificates: certificates)
      pruneSSHCredentials(previous: oldHistory, current: history, sshCredentials: sshCredentials)
      pruneVaultSecrets(
        previous: oldHistory, current: history, rawKeys: rawKeys, vaultSecrets: vaultSecrets)
      return true
    }

    // The form's toggle locked a retargeted draft no saved row matched: the lock is born here
    let locksDraft = config.isLocked
    config.isLocked = previous.config.isLocked || config.isLocked
    // Counted before the rows on the new key are removed: retargeting an unlocked row onto a
    // locked login keeps that login locked
    let inheritsLock = hasLockedRow(of: config, in: history)
    if inheritsLock { config.isLocked = true }
    // A lock the draft added is granted for this session, as a first locked save is; a lock
    // taken from another row is never granted
    let grantsNewLock = locksDraft && !previous.config.isLocked && !inheritsLock
    let lockedBefore = registry.lockedIdentities
    let generation = registry.generation
    var updated = previous
    updated.config = config
    let newKey = updated.keychainKey
    // Another connection on the new key keeps its row and password
    guard !keyUsedByAnotherIdentity(config, excluding: id, defaults: defaults) else {
      return false
    }
    // Another row of this identity is merged: refused while its lock is blocked
    guard
      !history.contains(where: {
        $0.id != id && $0.isSavedRow(of: config) && registry.refusal(for: $0.config) != nil
      })
    else { return false }
    history.removeAll { $0.id != id && $0.isSavedRow(of: config) }
    guard let kept = history.firstIndex(where: { $0.id == id }) else {
      return saveConnection(
        config, defaults: defaults, passwords: passwords, certificates: certificates,
        sshCredentials: sshCredentials, sshCredential: sshCredential,
        vaultSecrets: vaultSecrets, registry: registry)
    }
    history[kept] = updated
    guard let encoded = encodedHistory(history, defaults: defaults),
      ClientCertificateStoreFactory.persistOperationMaterial(for: config, to: certificates),
      saveSSHCredential(
        sshCredential
          ?? movedSSHCredential(from: previous.config, to: config, sshCredentials: sshCredentials),
        for: config, to: sshCredentials)
    else { return false }
    // A Vault secret that could not be read is never deleted: it may still be there
    var unreadableVaultAccounts: Set<String> = []
    if VaultCredentialStore.persistOperationSecret(for: config, to: vaultSecrets) == nil {
      do {
        if let moved = try movedVaultSecret(
          from: previous.config, to: config, vaultSecrets: vaultSecrets)
        {
          VaultCredentialStore.save(moved, for: config, to: vaultSecrets)
        }
      } catch {
        if let account = VaultCredentialStore.account(for: previous.config) {
          unreadableVaultAccounts.insert(account)
        }
      }
    }
    if previous.keychainKey != newKey,
      !keyStillUsed(previous.keychainKey, in: history, excluding: id, rawKeys: rawKeys),
      !unreadable.contains(previous.keychainKey)
    {
      deleteStoredPassword(for: previous, passwords: passwords)
    }
    if config.databaseType.capabilities.usesPassword {
      // A Vault row keeps no saved password: its password is a lease's
      if config.password.isEmpty || config.vault != nil {
        if !unreadable.contains(newKey) { passwords.deletePassword(forKey: newKey) }
      } else {
        passwords.savePassword(config.password, forKey: newKey)
      }
    }
    defaults.set(encoded, forKey: historyKey)
    publishLocks(history, defaults: defaults, registry: registry)
    if grantsNewLock {
      grantNewLocks(
        of: [config], lockedBefore: lockedBefore, generation: generation, registry: registry)
    }
    pruneCertificates(previous: oldHistory, current: history, certificates: certificates)
    pruneSSHCredentials(previous: oldHistory, current: history, sshCredentials: sshCredentials)
    pruneVaultSecrets(
      previous: oldHistory, current: history, rawKeys: rawKeys, vaultSecrets: vaultSecrets,
      keeping: unreadableVaultAccounts)
    return true
  }

  /// Get most recent connection
  static func loadMostRecentConnection() -> ConnectionConfig? {
    return loadHistory().first?.config
  }

  /// Clear all connection history. Refused (false, nothing changed) while a row reaches a lock
  /// not unlocked in this session.
  @discardableResult
  static func clearAllHistory(
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore(),
    certificates: any ClientCertificateStore = ClientCertificateStoreFactory.shared,
    sshCredentials: any SSHCredentialStore = SSHCredentialStoreFactory.shared,
    vaultSecrets: any VaultSecretStore = VaultCredentialStore.shared,
    registry: LockRegistry = .shared
  ) -> Bool {
    let history = loadHistory(defaults: defaults, passwords: passwords, registry: registry)
    guard !history.contains(where: { registry.refusal(for: $0.config) != nil }) else {
      return false
    }

    for entry in history {
      deleteStoredPassword(for: entry, passwords: passwords)
    }
    pruneCertificates(previous: history, current: [], certificates: certificates)
    pruneSSHCredentials(previous: history, current: [], sshCredentials: sshCredentials)
    // The undecodable rows go too: none keeps a secret
    pruneVaultSecrets(previous: history, current: [], rawKeys: [], vaultSecrets: vaultSecrets)

    defaults.removeObject(forKey: historyKey)
    publishLocks([], defaults: defaults, registry: registry)
    return true
  }

  /// Remove specific connection from history. Refused (false, nothing changed) while the row
  /// reaches a lock not unlocked in this session: deleting its last row would drop the lock.
  @discardableResult
  static func removeConnection(
    id: UUID,
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore(),
    certificates: any ClientCertificateStore = ClientCertificateStoreFactory.shared,
    sshCredentials: any SSHCredentialStore = SSHCredentialStoreFactory.shared,
    vaultSecrets: any VaultSecretStore = VaultCredentialStore.shared,
    registry: LockRegistry = .shared
  ) -> Bool {
    var history = loadHistory(defaults: defaults, passwords: passwords, registry: registry)

    if let index = history.firstIndex(where: { $0.id == id }) {
      guard registry.refusal(for: history[index].config) == nil else { return false }
      let previous = history
      let rawKeys = undecodableRowKeys(defaults: defaults)
      if !keyStillUsed(history[index].keychainKey, in: history, excluding: id, rawKeys: rawKeys) {
        deleteStoredPassword(for: history[index], passwords: passwords)
      }

      // Remove from array
      history.remove(at: index)
      saveHistory(history, defaults: defaults)
      publishLocks(history, defaults: defaults, registry: registry)
      pruneCertificates(previous: previous, current: history, certificates: certificates)
      pruneSSHCredentials(previous: previous, current: history, sshCredentials: sshCredentials)
      pruneVaultSecrets(
        previous: previous, current: history, rawKeys: rawKeys, vaultSecrets: vaultSecrets)
    }
    return true
  }

  // MARK: - Legacy Methods (Backward Compatibility)

  /// Save a connection session
  /// - Parameter config: The connection configuration to save
  @available(*, deprecated, message: "Use saveConnection() instead")
  static func saveSession(_ config: ConnectionConfig) {
    saveConnection(config)
  }

  /// Load a saved connection session
  /// - Returns: The saved connection config, or nil if none exists
  @available(*, deprecated, message: "Use loadMostRecentConnection() instead")
  static func loadSession() -> ConnectionConfig? {
    return loadMostRecentConnection()
  }

  /// Clear the saved session
  @available(*, deprecated, message: "Use clearAllHistory() instead")
  static func clearSession() {
    clearAllHistory()
  }

  /// Check if a session exists
  @available(*, deprecated, message: "Use !loadHistory().isEmpty instead")
  static func hasSession() -> Bool {
    return !loadHistory().isEmpty
  }

  // MARK: - Lock State

  /// Republishes the identities of `history`'s locked rows. The shared registry takes only the
  /// app's own history: never an isolated suite's, and nothing under the test host.
  private static func publishLocks(
    _ history: [ConnectionHistoryEntry], defaults: UserDefaults, registry: LockRegistry
  ) {
    guard
      registry !== LockRegistry.shared
        || (defaults === UserDefaults.standard && !isRunningAsTestHost)
    else { return }
    registry.setLockedConnections(
      Set(history.filter(\.config.isLocked).flatMap { LockIdentity.all($0.config) }))
  }

  /// The lock toggle: sets `isLocked` on every saved row that reaches `identity`
  /// (`LockIdentity.all`) and republishes the registry. Locking grants the identities it adds
  /// for this session (after the republish, which drops grants outside the locked set), so an
  /// open window keeps working until the next relock. Unlocking is refused (false, nothing
  /// changed) while such a row reaches a lock not unlocked in this session. Reads no Keychain
  /// item.
  @discardableResult
  static func setLocked(
    _ locked: Bool, for identity: LockIdentity, defaults: UserDefaults = .standard,
    registry: LockRegistry = .shared
  ) -> Bool {
    var history = storedEntries(defaults: defaults).known
    publishLocks(history, defaults: defaults, registry: registry)
    let matched = history.indices.filter { LockIdentity.all(history[$0].config).contains(identity) }
    guard locked || !matched.contains(where: { registry.refusal(for: history[$0].config) != nil })
    else { return false }
    for index in matched { history[index].config.isLocked = locked }
    guard let encoded = encodedHistory(history, defaults: defaults) else { return false }
    let lockedBefore = registry.lockedIdentities
    let generation = registry.generation
    defaults.set(encoded, forKey: historyKey)
    publishLocks(history, defaults: defaults, registry: registry)
    if locked {
      grantNewLocks(
        of: matched.map { history[$0].config }, lockedBefore: lockedBefore,
        generation: generation, registry: registry)
    }
    return true
  }

  /// Grants the identities of `configs` that were not locked before this change, never one
  /// locked earlier (that would unlock it without asking), and none when a relock landed since
  /// `generation` was read
  private static func grantNewLocks(
    of configs: [ConnectionConfig], lockedBefore: Set<LockIdentity>, generation: Int,
    registry: LockRegistry
  ) {
    let reached = Set(configs.flatMap { LockIdentity.all($0) })
    let added = registry.lockedIdentities.subtracting(lockedBefore).intersection(reached)
    _ = registry.grant(added, ifGeneration: generation)
  }

  /// Whether a row of `history` locks an identity `config` reaches (`LockIdentity.all`)
  private static func hasLockedRow(
    of config: ConnectionConfig, in history: [ConnectionHistoryEntry]
  ) -> Bool {
    // No locked row: no `stat` or URI parsing on a save
    guard history.contains(where: \.config.isLocked) else { return false }
    let identities = LockIdentity.all(config)
    return history.contains {
      $0.config.isLocked && !identities.isDisjoint(with: LockIdentity.all($0.config))
    }
  }

  // MARK: - Keychain Helpers

  private static func keychainKey(for config: ConnectionConfig) -> String {
    ConnectionKeychainKey.password(for: config)
  }

  /// Deletes a stored password only when this engine uses one.
  private static func deleteStoredPassword(
    for entry: ConnectionHistoryEntry, passwords: any ConnectionPasswordStore
  ) {
    guard entry.config.databaseType.capabilities.usesPassword else { return }
    passwords.deletePassword(forKey: entry.keychainKey)
  }

  /// Whether a row other than `rowID` still uses Keychain key `key`: a row of `history`, or a
  /// saved row this build cannot decode (`rawKeys`, from `undecodableRowKeys`). Its password and
  /// Vault secret are then kept.
  private static func keyStillUsed(
    _ key: String, in history: [ConnectionHistoryEntry], excluding rowID: UUID? = nil,
    rawKeys: Set<String>
  ) -> Bool {
    rawKeys.contains(key) || history.contains { $0.id != rowID && $0.keychainKey == key }
  }

  /// Keychain keys of the saved rows this build cannot decode. Reads no Keychain item.
  private static func undecodableRowKeys(defaults: UserDefaults) -> Set<String> {
    Set(storedEntries(defaults: defaults).unknown.compactMap(rawKeychainKey))
  }

  private static func pruneCertificates(
    previous: [ConnectionHistoryEntry], current: [ConnectionHistoryEntry],
    certificates: any ClientCertificateStore
  ) {
    let retained = Set(
      current.compactMap { entry in
        entry.config.clientCertificate == nil
          ? nil : ClientCertificateStoreFactory.account(for: entry.config)
      })
    for entry in previous where entry.config.clientCertificate != nil {
      let account = ClientCertificateStoreFactory.account(for: entry.config)
      if !retained.contains(account) {
        ClientCertificateStoreFactory.delete(for: entry.config, from: certificates)
      }
    }
  }

  /// Saves a credential supplied with this save, else the operation's scoped one (the form's
  /// secret). Without a tunnel there is nothing to key it by.
  private static func saveSSHCredential(
    _ credential: SSHStoredCredential?, for config: ConnectionConfig,
    to sshCredentials: any SSHCredentialStore
  ) -> Bool {
    guard let credential else {
      return SSHCredentialStoreFactory.persistOperationCredential(for: config, to: sshCredentials)
    }
    guard let account = SSHCredentialStoreFactory.account(for: config) else { return true }
    return sshCredentials.save(credential, account: account)
  }

  /// The credential stored under `previous`'s account, to save under the edited `config`'s
  /// account, when the operation brings none (the form reads no stored secret while the row is
  /// blocked, and the unlock comes after the click). Only while the bastion is unchanged and the
  /// stored secret serves the edited auth method; nil otherwise. Called only after the row's
  /// unlock.
  private static func movedSSHCredential(
    from previous: ConnectionConfig, to config: ConnectionConfig,
    sshCredentials: any SSHCredentialStore
  ) -> SSHStoredCredential? {
    guard SSHCredentialStoreFactory.currentCredential(for: config) == nil,
      let old = previous.sshTunnel, let new = config.sshTunnel,
      old.host == new.host, old.port == new.port, old.username == new.username,
      let oldAccount = SSHCredentialStoreFactory.account(for: previous),
      oldAccount != SSHCredentialStoreFactory.account(for: config),
      let stored = sshCredentials.load(account: oldAccount),
      SSHFormDraft.method(of: stored) == new.authMethod,
      new.authMethod == .password || new.keyFingerprint != nil
    else { return nil }
    return stored
  }

  /// Deletes SSH credentials no remaining entry uses. Host key pins are kept: they belong
  /// to the bastion, not the connection, and are removed only in Settings > Data.
  private static func pruneSSHCredentials(
    previous: [ConnectionHistoryEntry], current: [ConnectionHistoryEntry],
    sshCredentials: any SSHCredentialStore
  ) {
    let retained = Set(current.compactMap { SSHCredentialStoreFactory.account(for: $0.config) })
    for entry in previous {
      guard let account = SSHCredentialStoreFactory.account(for: entry.config),
        !retained.contains(account)
      else { continue }
      sshCredentials.delete(account: account)
    }
  }

  /// The Vault secret stored for `previous`, to save under the edited `config`'s account when
  /// the operation brings none (the form had not read it). Only while the destination is
  /// unchanged: a secret is never re-bound to other Vault settings without the user's draft.
  /// Called only after the row's unlock. Throws `ConnectionPasswordError.unreadable` when the
  /// old account's secret could not be read.
  private static func movedVaultSecret(
    from previous: ConnectionConfig, to config: ConnectionConfig,
    vaultSecrets: any VaultSecretStore
  ) throws -> VaultSecret? {
    guard let oldAccount = VaultCredentialStore.account(for: previous),
      let newAccount = VaultCredentialStore.account(for: config), oldAccount != newAccount,
      let destination = VaultCredentialStore.destination(for: config),
      let stored = try vaultSecrets.readSecret(account: oldAccount),
      stored.destination == destination
    else { return nil }
    return stored.secret
  }

  /// Deletes Vault secrets no remaining entry uses: a row switched away from Vault, retargeted
  /// or removed. A secret another Vault row on the same Keychain key still uses is kept, and so is
  /// one on the key of a row this build cannot decode (`rawKeys`), and the accounts in
  /// `keeping` (a secret that could not be read).
  private static func pruneVaultSecrets(
    previous: [ConnectionHistoryEntry], current: [ConnectionHistoryEntry], rawKeys: Set<String>,
    vaultSecrets: any VaultSecretStore, keeping: Set<String> = []
  ) {
    let vaultRows = current.filter { $0.config.vault != nil }
    for entry in previous {
      guard let account = VaultCredentialStore.account(for: entry.config),
        !keeping.contains(account),
        !keyStillUsed(entry.keychainKey, in: vaultRows, rawKeys: rawKeys)
      else { continue }
      vaultSecrets.delete(account: account)
    }
  }

  // MARK: - Local data (UserDefaults only)

  /// History blobs in `domainName`, still containing whatever was stored.
  nonisolated static func storedHistory(
    defaults: UserDefaults, domainName: String
  ) -> (
    history: Data?, legacy: Data?
  ) {
    let domain = defaults.persistentDomain(forName: domainName) ?? [:]
    return (domain[historyKey] as? Data, domain[legacySessionKey] as? Data)
  }

  /// Same blobs with password fields removed, for export.
  nonisolated static func exportSnapshot(
    defaults: UserDefaults, domainName: String
  ) -> (
    history: Data?, legacy: Data?
  ) {
    let stored = storedHistory(defaults: defaults, domainName: domainName)
    return (
      LocalDataJSON.omitting(stored.history, keysSatisfying: LocalDataJSON.isPasswordKey),
      LocalDataJSON.omitting(stored.legacy, keysSatisfying: LocalDataJSON.isPasswordKey)
    )
  }

  /// Replaces the history blobs. Does not read or write the Keychain. Refused (false, nothing
  /// changed) while a stored row reaches a lock not unlocked in this session.
  @discardableResult
  nonisolated static func replace(
    history: Data?, legacySession: Data?, defaults: UserDefaults, domainName: String,
    registry: LockRegistry = .shared
  ) -> Bool {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    guard !hasBlockedRow(domain[historyKey] as? Data, registry) else {
      return false
    }
    if let history {
      domain[historyKey] = history
    } else {
      domain.removeValue(forKey: historyKey)
    }
    if let legacySession {
      domain[legacySessionKey] = legacySession
    } else {
      domain.removeValue(forKey: legacySessionKey)
    }
    defaults.setPersistentDomain(domain, forName: domainName)
    return true
  }

  /// Removes connection-history entries from `domainName` only. Refused (false, nothing
  /// changed) while a stored row reaches a lock not unlocked in this session.
  @discardableResult
  nonisolated static func clearAll(
    defaults: UserDefaults, domainName: String, registry: LockRegistry = .shared
  ) -> Bool {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    guard !hasBlockedRow(domain[historyKey] as? Data, registry) else {
      return false
    }
    domain.removeValue(forKey: historyKey)
    domain.removeValue(forKey: legacySessionKey)
    defaults.setPersistentDomain(domain, forName: domainName)
    return true
  }

  /// Whether a row of a stored history blob reaches an identity `registry` blocks. Only each
  /// row's `config` is decoded; a row this build cannot decode reaches none.
  private nonisolated static func hasBlockedRow(_ blob: Data?, _ registry: LockRegistry) -> Bool {
    guard !registry.lockedIdentities.isEmpty, let blob,
      let rows = try? JSONSerialization.jsonObject(with: blob) as? [Any]
    else { return false }
    return rows.contains { row in
      guard let object = (row as? [String: Any])?["config"],
        let data = try? JSONSerialization.data(withJSONObject: object),
        let config = try? JSONDecoder().decode(ConnectionConfig.self, from: data)
      else { return false }
      return registry.refusal(for: config) != nil
    }
  }
}

/// Outcome of `SessionManager.saveConnections`. Holds names only, never secrets.
struct BulkSaveReport: Equatable, Sendable {
  struct Failure: Equatable, Sendable {
    let name: String
    let reason: String
  }

  var added = 0
  var skippedDuplicates: [String] = []
  var failed: [Failure] = []
  /// Imports left out because history had no free slot.
  var droppedByLimit = 0
}

/// A saved connection password exists but could not be read. Never a missing password.
nonisolated enum ConnectionPasswordError: Error, Equatable, Sendable {
  /// The Keychain lookup failed with this status (for example a denied prompt or a locked
  /// keychain), or the item held data that is not UTF-8 text (`errSecDecode`).
  case unreadable(OSStatus)
}

/// Saves, reads, and deletes one connection password.
/// The app uses `KeychainConnectionPasswordStore`.
protocol ConnectionPasswordStore {
  func savePassword(_ password: String, forKey key: String)
  /// nil when no password is saved under `key`; throws `ConnectionPasswordError.unreadable`
  /// when one may exist but could not be read.
  func readPassword(forKey key: String) throws -> String?
  func deletePassword(forKey key: String)
}

extension ConnectionPasswordStore {
  /// `readPassword(forKey:)` with an unreadable password flattened to nil.
  func loadPassword(forKey key: String) -> String? {
    (try? readPassword(forKey: key)) ?? nil
  }
}

/// Keychain implementation of `ConnectionPasswordStore`.
struct KeychainConnectionPasswordStore: ConnectionPasswordStore {
  nonisolated static let vault = KeychainVault(
    service: SessionManager.keychainService, accessible: kSecAttrAccessibleAfterFirstUnlock)

  private let keychain: KeychainVault

  /// `vault` is the connection password service; tests pass one over an in-memory backend.
  init(vault: KeychainVault = KeychainConnectionPasswordStore.vault) {
    keychain = vault
  }

  func savePassword(_ password: String, forKey key: String) {
    guard let passwordData = password.data(using: .utf8) else { return }
    keychain.write(account: key, data: passwordData)
  }

  func readPassword(forKey key: String) throws -> String? {
    try Self.password(from: keychain.read(account: key))
  }

  /// `readPassword(forKey:)` callable off the main actor (the MCP pool).
  nonisolated static func readPassword(forKey key: String) throws -> String? {
    try password(from: vault.read(account: key))
  }

  /// `loadPassword(forKey:)` callable off the main actor: an unreadable password is nil.
  nonisolated static func loadPassword(forKey key: String) -> String? {
    (try? readPassword(forKey: key)) ?? nil
  }

  /// A miss is nil; a failed lookup or non-UTF-8 data (`errSecDecode`) throws.
  private nonisolated static func password(from read: KeychainRead) throws -> String? {
    switch read {
    case .notFound:
      return nil
    case .failed(let status):
      throw ConnectionPasswordError.unreadable(status)
    case .found(let passwordData):
      guard let password = String(data: passwordData, encoding: .utf8) else {
        throw ConnectionPasswordError.unreadable(errSecDecode)
      }
      return password
    }
  }

  func deletePassword(forKey key: String) {
    keychain.delete(account: key)
  }
}

/// Why a connection was not saved
enum SessionManagerError: LocalizedError, Equatable {
  /// Another saved connection's password is stored under the same Keychain key
  case keychainKeyInUse
  /// The history, client certificate or SSH secret could not be written
  case saveFailed

  var errorDescription: String? {
    switch self {
    case .keychainKeyInUse: "Another saved connection uses the same Keychain entry."
    case .saveFailed: "Could not save the connection."
    }
  }
}
