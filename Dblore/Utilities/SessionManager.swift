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
      if let password = KeychainConnectionPasswordStore().loadPassword(forKey: keychainKey) {
        config.password = password
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
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) -> [ConnectionHistoryEntry] {
    guard let data = defaults.data(forKey: historyKey),
      var entries = try? JSONDecoder().decode([ConnectionHistoryEntry].self, from: data)
    else {
      return []
    }

    // Load passwords for engines that store one. Others are not queried.
    for i in 0..<entries.count where entries[i].config.databaseType.capabilities.usesPassword {
      let key = entries[i].keychainKey
      if let password = passwords.loadPassword(forKey: key) {
        entries[i].config.password = password
      }
    }

    // Sort by most recent first
    return entries.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  /// Save connection history (private helper)
  private static func saveHistory(
    _ entries: [ConnectionHistoryEntry], defaults: UserDefaults = .standard
  ) {
    // Remove passwords before saving
    var cleanEntries = entries
    for i in 0..<cleanEntries.count {
      cleanEntries[i].config.password = ""
    }

    if let encoded = try? JSONEncoder().encode(cleanEntries) {
      defaults.set(encoded, forKey: historyKey)
    }
  }

  /// Maximum number of connection history entries to store
  private static let maxConnectionHistorySize = 6

  /// Add or update connection in history
  static func saveConnection(
    _ config: ConnectionConfig,
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) {
    guard config.rememberConnection else {
      // If remember is disabled, don't add to history
      return
    }

    var history = loadHistory(defaults: defaults, passwords: passwords)
    let newEntry = ConnectionHistoryEntry(config: config)

    // Save password BEFORE adding to history
    // (because ConnectionHistoryEntry.init strips password from config).
    // Engines without passwords are not written.
    if config.databaseType.capabilities.usesPassword, !config.password.isEmpty {
      passwords.savePassword(config.password, forKey: newEntry.keychainKey)
    }

    // Check if connection already exists (same host+port+db+user)
    if let index = history.firstIndex(where: { $0.keychainKey == newEntry.keychainKey }) {
      // Update existing entry (refresh timestamp)
      history[index] = newEntry
    } else {
      // Add new entry at the beginning
      history.insert(newEntry, at: 0)
    }

    // Trim to max size
    if history.count > maxConnectionHistorySize {
      // Remove oldest entries and their passwords
      let entriesToRemove = history.suffix(history.count - maxConnectionHistorySize)
      for entry in entriesToRemove {
        deleteStoredPassword(for: entry, passwords: passwords)
      }
      history = Array(history.prefix(maxConnectionHistorySize))
    }

    saveHistory(history, defaults: defaults)
  }

  /// Replace one history row in place. The id, position, and last-used date stay.
  /// A changed host, port, database, or username takes the password with it.
  /// An empty password deletes the stored one. Remember off removes the row.
  static func replaceConnection(
    id: UUID,
    with config: ConnectionConfig,
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) {
    var history = loadHistory(defaults: defaults, passwords: passwords)
    guard let index = history.firstIndex(where: { $0.id == id }) else {
      saveConnection(config, defaults: defaults, passwords: passwords)
      return
    }

    let previous = history[index]
    if !config.rememberConnection {
      if !history.contains(where: { $0.id != id && $0.keychainKey == previous.keychainKey }) {
        deleteStoredPassword(for: previous, passwords: passwords)
      }
      history.remove(at: index)
      saveHistory(history, defaults: defaults)
      return
    }

    var updated = previous
    updated.config = config
    let newKey = updated.keychainKey
    if previous.keychainKey != newKey,
      !history.contains(where: { $0.id != id && $0.keychainKey == previous.keychainKey })
    {
      deleteStoredPassword(for: previous, passwords: passwords)
    }
    history.removeAll { $0.id != id && $0.keychainKey == newKey }
    guard let kept = history.firstIndex(where: { $0.id == id }) else {
      saveConnection(config, defaults: defaults, passwords: passwords)
      return
    }
    history[kept] = updated
    if config.databaseType.capabilities.usesPassword {
      if config.password.isEmpty {
        passwords.deletePassword(forKey: newKey)
      } else {
        passwords.savePassword(config.password, forKey: newKey)
      }
    }
    saveHistory(history, defaults: defaults)
  }

  /// Get most recent connection
  static func loadMostRecentConnection() -> ConnectionConfig? {
    return loadHistory().first?.config
  }

  /// Clear all connection history
  static func clearAllHistory(
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) {
    let history = loadHistory(defaults: defaults, passwords: passwords)

    for entry in history {
      deleteStoredPassword(for: entry, passwords: passwords)
    }

    defaults.removeObject(forKey: historyKey)
  }

  /// Remove specific connection from history
  static func removeConnection(
    id: UUID,
    defaults: UserDefaults = .standard,
    passwords: any ConnectionPasswordStore = KeychainConnectionPasswordStore()
  ) {
    var history = loadHistory(defaults: defaults, passwords: passwords)

    if let index = history.firstIndex(where: { $0.id == id }) {
      deleteStoredPassword(for: history[index], passwords: passwords)

      // Remove from array
      history.remove(at: index)
      saveHistory(history, defaults: defaults)
    }
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

  // MARK: - Keychain Helpers

  /// Get password from keychain for a specific key
  /// - Parameter key: The keychain key (format: host:port:database:username)
  /// - Returns: The password if found, nil otherwise
  static func getPasswordFromKeychain(for key: String) -> String? {
    return KeychainConnectionPasswordStore().loadPassword(forKey: key)
  }

  private static func keychainKey(for config: ConnectionConfig) -> String {
    // Create a unique key based on host, port, database, and username
    return "\(config.host):\(config.port):\(config.database):\(config.username)"
  }

  /// Deletes a stored password only when this engine uses one.
  private static func deleteStoredPassword(
    for entry: ConnectionHistoryEntry, passwords: any ConnectionPasswordStore
  ) {
    guard entry.config.databaseType.capabilities.usesPassword else { return }
    passwords.deletePassword(forKey: entry.keychainKey)
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

  /// Replaces the history blobs. Does not read or write the Keychain.
  nonisolated static func replace(
    history: Data?, legacySession: Data?, defaults: UserDefaults, domainName: String
  ) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
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
  }

  /// Removes connection-history entries from `domainName` only.
  nonisolated static func clearAll(defaults: UserDefaults, domainName: String) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    domain.removeValue(forKey: historyKey)
    domain.removeValue(forKey: legacySessionKey)
    defaults.setPersistentDomain(domain, forName: domainName)
  }
}

/// Saves, loads, and deletes one connection password.
/// The app uses `KeychainConnectionPasswordStore`.
protocol ConnectionPasswordStore {
  func savePassword(_ password: String, forKey key: String)
  func loadPassword(forKey key: String) -> String?
  func deletePassword(forKey key: String)
}

/// Keychain implementation of `ConnectionPasswordStore`.
struct KeychainConnectionPasswordStore: ConnectionPasswordStore {
  func savePassword(_ password: String, forKey key: String) {
    guard let passwordData = password.data(using: .utf8) else { return }

    // Delete existing item first
    deletePassword(forKey: key)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SessionManager.keychainService,
      kSecAttrAccount as String: key,
      kSecValueData as String: passwordData,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    SecItemAdd(query as CFDictionary, nil)
  }

  func loadPassword(forKey key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SessionManager.keychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess,
      let passwordData = result as? Data,
      let password = String(data: passwordData, encoding: .utf8)
    else {
      return nil
    }

    return password
  }

  func deletePassword(forKey key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SessionManager.keychainService,
      kSecAttrAccount as String: key,
    ]

    SecItemDelete(query as CFDictionary)
  }
}
