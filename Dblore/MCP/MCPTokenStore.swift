// MCPTokenStore.swift
// The MCP bearer token: 32 random bytes (SecRandomCopyBytes) as unpadded base64url, one
// generic-password Keychain item (this device only), created on first use and replaced by
// regenerate. The test host gets the in-memory store. The token is never logged.

import Foundation
import Security

nonisolated protocol MCPTokenStore: AnyObject, Sendable {
  /// The saved token, or a new one saved now.
  func loadOrCreate() -> String
  /// Replaces the token and returns the new one.
  @discardableResult func regenerate() -> String
}

nonisolated enum MCPTokenStoreFactory {
  static let shared: any MCPTokenStore =
    SessionManager.isRunningAsTestHost ? InMemoryMCPTokenStore() : KeychainMCPTokenStore()

  /// 32 random bytes, base64url without padding (43 characters).
  static func generate() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

nonisolated final class KeychainMCPTokenStore: MCPTokenStore {
  static let serviceName = "ace.thi.dblore.mcp"
  private static let account = "bearer-token"

  /// Serializes load-then-create so two callers never save two tokens.
  private let lock = NSLock()

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecAttrAccount as String: Self.account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func loadOrCreate() -> String {
    lock.withLock {
      if let token = load() { return token }
      let token = MCPTokenStoreFactory.generate()
      save(token)
      return token
    }
  }

  func regenerate() -> String {
    lock.withLock {
      let token = MCPTokenStoreFactory.generate()
      save(token)
      return token
    }
  }

  private func load() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, let token = String(data: data, encoding: .utf8),
      !token.isEmpty
    else { return nil }
    return token
  }

  /// A failed save keeps the token in use for this run only; the next launch makes a new one.
  private func save(_ token: String) {
    let data = Data(token.utf8)
    let status = SecItemUpdate(
      baseQuery as CFDictionary,
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as CFDictionary)
    guard status == errSecItemNotFound else { return }
    var attributes = baseQuery
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    SecItemAdd(attributes as CFDictionary, nil)
  }
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemoryMCPTokenStore: MCPTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?

  func loadOrCreate() -> String {
    lock.withLock {
      if let token { return token }
      let created = MCPTokenStoreFactory.generate()
      token = created
      return created
    }
  }

  func regenerate() -> String {
    lock.withLock {
      let created = MCPTokenStoreFactory.generate()
      token = created
      return created
    }
  }
}
