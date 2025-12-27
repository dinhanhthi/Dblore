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
  private static let sessionKey = "com.sqlnotebook.savedSession"
  private static let keychainService = "com.sqlnotebook.database"

  /// Save a connection session
  /// - Parameter config: The connection configuration to save
  static func saveSession(_ config: ConnectionConfig) {
    guard config.rememberConnection else {
      // If remember is disabled, clear the session
      clearSession()
      return
    }

    // Save password to Keychain
    let keychainKey = keychainKey(for: config)
    savePasswordToKeychain(password: config.password, key: keychainKey)

    // Save config to UserDefaults (without password)
    var configToSave = config
    configToSave.password = "" // Don't save password in UserDefaults

    if let encoded = try? JSONEncoder().encode(configToSave) {
      UserDefaults.standard.set(encoded, forKey: sessionKey)
    }
  }

  /// Load a saved connection session
  /// - Returns: The saved connection config, or nil if none exists
  static func loadSession() -> ConnectionConfig? {
    guard let data = UserDefaults.standard.data(forKey: sessionKey),
          var config = try? JSONDecoder().decode(ConnectionConfig.self, from: data) else {
      return nil
    }

    // Load password from Keychain
    let keychainKey = keychainKey(for: config)
    if let password = loadPasswordFromKeychain(key: keychainKey) {
      config.password = password
    }

    return config
  }

  /// Clear the saved session
  static func clearSession() {
    // Load existing config to get the keychain key
    if let config = loadSession() {
      let keychainKey = keychainKey(for: config)
      deletePasswordFromKeychain(key: keychainKey)
    }

    UserDefaults.standard.removeObject(forKey: sessionKey)
  }

  /// Check if a session exists
  static func hasSession() -> Bool {
    return UserDefaults.standard.data(forKey: sessionKey) != nil
  }

  // MARK: - Keychain Helpers

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
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]

    SecItemAdd(query as CFDictionary, nil)
  }

  private static func loadPasswordFromKeychain(key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess,
          let passwordData = result as? Data,
          let password = String(data: passwordData, encoding: .utf8) else {
      return nil
    }

    return password
  }

  private static func deletePasswordFromKeychain(key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key
    ]

    SecItemDelete(query as CFDictionary)
  }
}
