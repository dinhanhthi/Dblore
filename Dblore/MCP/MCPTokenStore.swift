// MCPTokenStore.swift
// The MCP bearer token: 32 random bytes (SecRandomCopyBytes) as unpadded base64url, one
// generic-password Keychain item (this device only), created on first use and replaced by
// regenerate. Paired command-line tools keep their own tokens, one item each under
// ace.thi.dblore.mcp-cli (session only when the Keychain refuses the write). The test host gets
// the in-memory stores. Tokens are never logged.

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

  static let sharedCLI: any MCPCLITokenStore =
    SessionManager.isRunningAsTestHost ? InMemoryMCPCLITokenStore() : KeychainMCPCLITokenStore()

  /// 32 random bytes, base64url without padding (43 characters).
  static func generate() -> String {
    base64URL(randomBytes(count: 32))
  }

  /// Bytes from the system CSPRNG (SecRandomCopyBytes).
  static func randomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return bytes
  }

  /// RFC 4648 base64url without padding.
  static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The bytes of an unpadded base64url string, nil when it is not one.
  static func data(base64URL text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
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

// MARK: - Paired command-line tools

/// One paired command-line tool. Saved in the Keychain (service `ace.thi.dblore.mcp-cli`,
/// account = `id`, a UUID string) as the JSON object `{"token", "proofKey", "name", "date"}`:
/// `token` and `proofKey` are 32 random bytes each as unpadded base64url (43 characters, the MCP
/// token's format), `name` is display text, `date` (pairing time) is ISO 8601. This format is
/// permanent. The hello HMAC key is the 32 bytes `proofKey` decodes to, not its UTF-8 text.
nonisolated struct MCPCLICredential: Equatable, Sendable {
  let id: String
  let token: String
  let proofKey: String
  let name: String
  let date: Date
  /// Not saved: the Keychain refused the write (an ad hoc build), so it lasts this session only
  var isSessionOnly = false
}

/// Paired command-line tools. Every call may read or write the Keychain: call it off the main
/// actor. Tokens are never logged.
nonisolated protocol MCPCLITokenStore: AnyObject, Sendable {
  /// Every paired tool: the saved ones, then the session-only ones.
  func list() -> [MCPCLICredential]
  /// Saves a new pairing; the result is session only when the Keychain refused it.
  func save(_ credential: MCPCLICredential) -> MCPCLICredential
  /// False when a saved item could not be deleted: it comes back at the next load.
  @discardableResult func revoke(id: String) -> Bool
  @discardableResult func revokeAll() -> Bool
}

nonisolated final class KeychainMCPCLITokenStore: MCPCLITokenStore, @unchecked Sendable {
  static let serviceName = "ace.thi.dblore.mcp-cli"

  private struct Stored: Codable {
    var token: String
    var proofKey: String
    var name: String
    var date: Date
  }

  private let vault: KeychainVault
  private let lock = NSLock()
  /// Pairings the Keychain refused (no data protection keychain in ad hoc builds), by id
  private var session: [String: MCPCLICredential] = [:]

  init(
    vault: KeychainVault = KeychainVault(
      service: KeychainMCPCLITokenStore.serviceName,
      accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
  ) {
    self.vault = vault
  }

  func list() -> [MCPCLICredential] {
    lock.withLock {
      let saved = vault.accounts().compactMap { id -> MCPCLICredential? in
        guard case .found(let data) = vault.read(account: id),
          let stored = try? Self.decoder.decode(Stored.self, from: data)
        else { return nil }
        return MCPCLICredential(
          id: id, token: stored.token, proofKey: stored.proofKey, name: stored.name,
          date: stored.date)
      }
      return saved + session.values.sorted { $0.date < $1.date }
    }
  }

  func save(_ credential: MCPCLICredential) -> MCPCLICredential {
    lock.withLock {
      let stored = Stored(
        token: credential.token, proofKey: credential.proofKey, name: credential.name,
        date: credential.date)
      var result = credential
      if let data = try? Self.encoder.encode(stored),
        vault.write(account: credential.id, data: data) == errSecSuccess
      {
        result.isSessionOnly = false
      } else {
        result.isSessionOnly = true
        session[credential.id] = result
      }
      return result
    }
  }

  @discardableResult func revoke(id: String) -> Bool {
    lock.withLock {
      session[id] = nil
      return Self.deleted(vault.delete(account: id))
    }
  }

  @discardableResult func revokeAll() -> Bool {
    lock.withLock {
      session.removeAll()
      return vault.accounts().map { Self.deleted(vault.delete(account: $0)) }.allSatisfy { $0 }
    }
  }

  /// Without the data protection keychain (ad hoc builds) nothing was saved there to delete.
  private static func deleted(_ status: OSStatus) -> Bool {
    status == errSecSuccess || status == errSecMissingEntitlement
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemoryMCPCLITokenStore: MCPCLITokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [MCPCLICredential] = []

  func list() -> [MCPCLICredential] {
    lock.withLock { stored }
  }

  func save(_ credential: MCPCLICredential) -> MCPCLICredential {
    lock.withLock {
      stored.removeAll { $0.id == credential.id }
      stored.append(credential)
      return credential
    }
  }

  @discardableResult func revoke(id: String) -> Bool {
    lock.withLock { stored.removeAll { $0.id == id } }
    return true
  }

  @discardableResult func revokeAll() -> Bool {
    lock.withLock { stored.removeAll() }
    return true
  }
}
