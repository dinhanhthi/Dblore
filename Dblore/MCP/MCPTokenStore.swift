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

  private static let vault = KeychainVault(
    service: serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

  func loadOrCreate() -> String {
    lock.withLock {
      let read = Self.vault.read(account: Self.account)
      if let token = Self.token(from: read) { return token }
      let token = MCPTokenStoreFactory.generate()
      // A failed read (for example a denied prompt) leaves the saved token for the next launch.
      if case .failed = read { return token }
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

  /// A legacy-keychain token is migrated on read, so agents keep working.
  private static func token(from read: KeychainRead) -> String? {
    guard case .found(let data) = read,
      let token = String(data: data, encoding: .utf8), !token.isEmpty
    else { return nil }
    return token
  }

  /// A failed save keeps the token in use for this run only; the next launch makes a new one.
  private func save(_ token: String) {
    Self.vault.write(account: Self.account, data: Data(token.utf8))
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
