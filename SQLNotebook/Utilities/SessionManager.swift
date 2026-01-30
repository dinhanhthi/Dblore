//
//  SessionManager.swift
//  SQLNotebook
//

import Foundation
import Security

/// Manages saving and loading database connection sessions
/// Stores connection config in UserDefaults and passwords in Keychain
@MainActor
class SessionManager {
  // Legacy key for migration
  private static let legacySessionKey = "com.sqlnotebook.savedSession"
  // New key for connection history
  private static let historyKey = "com.sqlnotebook.connectionHistory"
  private static let keychainService = "com.sqlnotebook.database"

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

    // Load password from keychain
    let keychainKey = keychainKey(for: config)
    if let password = loadPasswordFromKeychain(key: keychainKey) {
      config.password = password
    }

    // Create history entry
    let entry = ConnectionHistoryEntry(config: config)
    saveHistory([entry])

    // Delete old key
    UserDefaults.standard.removeObject(forKey: legacySessionKey)
  }

  // MARK: - History Management

  /// Load connection history (sorted by most recent first)
  static func loadHistory() -> [ConnectionHistoryEntry] {
    guard let data = UserDefaults.standard.data(forKey: historyKey),
      var entries = try? JSONDecoder().decode([ConnectionHistoryEntry].self, from: data)
    else {
      return []
    }

    // Load passwords from keychain for each entry
    for i in 0..<entries.count {
      let key = entries[i].keychainKey
      if let password = loadPasswordFromKeychain(key: key) {
        entries[i].config.password = password
      }
    }

    // Sort by most recent first
    return entries.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  /// Save connection history (private helper)
  private static func saveHistory(_ entries: [ConnectionHistoryEntry]) {
    // Remove passwords before saving
    var cleanEntries = entries
    for i in 0..<cleanEntries.count {
      cleanEntries[i].config.password = ""
    }

    if let encoded = try? JSONEncoder().encode(cleanEntries) {
      UserDefaults.standard.set(encoded, forKey: historyKey)
    }
  }

  /// Add or update connection in history
  static func saveConnection(_ config: ConnectionConfig) {
    guard config.rememberConnection else {
      // If remember is disabled, don't add to history
      return
    }

    let maxSize = AppSettings.shared.maxConnectionHistorySize

    // If maxSize is 0, clear history and return
    if maxSize == 0 {
      clearAllHistory()
      return
    }

    var history = loadHistory()
    let newEntry = ConnectionHistoryEntry(config: config)

    // Save password to keychain BEFORE adding to history
    // (because ConnectionHistoryEntry.init strips password from config)
    if !config.password.isEmpty {
      savePasswordToKeychain(password: config.password, key: newEntry.keychainKey)
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
    if history.count > maxSize {
      // Remove oldest entries and their passwords
      let entriesToRemove = history.suffix(history.count - maxSize)
      for entry in entriesToRemove {
        deletePasswordFromKeychain(key: entry.keychainKey)
      }
      history = Array(history.prefix(maxSize))
    }

    saveHistory(history)
  }

  /// Get most recent connection
  static func loadMostRecentConnection() -> ConnectionConfig? {
    return loadHistory().first?.config
  }

  /// Clear all connection history
  static func clearAllHistory() {
    let history = loadHistory()

    // Delete all passwords from keychain
    for entry in history {
      deletePasswordFromKeychain(key: entry.keychainKey)
    }

    UserDefaults.standard.removeObject(forKey: historyKey)
  }

  /// Remove specific connection from history
  static func removeConnection(id: UUID) {
    var history = loadHistory()

    if let index = history.firstIndex(where: { $0.id == id }) {
      // Delete password from keychain
      deletePasswordFromKeychain(key: history[index].keychainKey)

      // Remove from array
      history.remove(at: index)
      saveHistory(history)
    }
  }

  /// Trim history to specified size (used when setting changes)
  static func trimHistoryToSize(_ maxSize: Int) {
    if maxSize == 0 {
      clearAllHistory()
      return
    }

    var history = loadHistory()
    if history.count > maxSize {
      // Remove oldest entries and their passwords
      let entriesToRemove = history.suffix(history.count - maxSize)
      for entry in entriesToRemove {
        deletePasswordFromKeychain(key: entry.keychainKey)
      }
      history = Array(history.prefix(maxSize))
      saveHistory(history)
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
    return loadPasswordFromKeychain(key: key)
  }

  private static func keychainKey(for config: ConnectionConfig) -> String {
    // Create a unique key based on host, port, database, and username
    return "\(config.host):\(config.port):\(config.database):\(config.username)"
  }

  private static func savePasswordToKeychain(password: String, key: String) {
    guard let passwordData = password.data(using: .utf8) else { return }

    // Delete existing item first
    deletePasswordFromKeychain(key: key)

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
      kSecValueData as String: passwordData,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    SecItemAdd(query as CFDictionary, nil)
  }

  private static func loadPasswordFromKeychain(key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
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

  private static func deletePasswordFromKeychain(key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
    ]

    SecItemDelete(query as CFDictionary)
  }
}
