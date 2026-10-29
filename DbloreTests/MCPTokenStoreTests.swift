// MCPTokenStoreTests.swift
// The MCP bearer token: 32 random bytes as unpadded base64url, created once, replaced on
// regenerate. Paired command-line tools: revoke, session-only pairings and the inventory. The
// test host gets the in-memory store, never the Keychain.

import Foundation
import LocalAuthentication
import Security
import Testing

@testable import Dblore

@Suite("MCP token store")
struct MCPTokenStoreTests {
  private static func isToken(_ token: String) -> Bool {
    token.count == 43
      && token.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
      }
  }

  @Test("loadOrCreate makes a 43-character base64url token once, then returns it")
  func loadOrCreate() {
    let store = InMemoryMCPTokenStore()
    let token = store.loadOrCreate()
    #expect(Self.isToken(token))
    #expect(store.loadOrCreate() == token)
  }

  @Test("regenerate replaces the token")
  func regenerate() {
    let store = InMemoryMCPTokenStore()
    let first = store.loadOrCreate()
    let second = store.regenerate()
    #expect(Self.isToken(second))
    #expect(second != first)
    #expect(store.loadOrCreate() == second)
  }

  @Test("The test host uses the in-memory store")
  func testHostDouble() {
    #expect(MCPTokenStoreFactory.shared is InMemoryMCPTokenStore)
    #expect(MCPTokenStoreFactory.sharedCLI is InMemoryMCPCLITokenStore)
  }

  private static func credential(_ name: String) -> MCPCLICredential {
    MCPCLICredential(
      id: UUID().uuidString, token: MCPTokenStoreFactory.generate(),
      proofKey: MCPTokenStoreFactory.generate(), name: name, date: Date())
  }

  private static func cliStore(_ keychain: CLIKeychain) -> KeychainMCPCLITokenStore {
    KeychainMCPCLITokenStore(
      vault: KeychainVault(
        service: KeychainMCPCLITokenStore.serviceName,
        accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, modern: keychain,
        legacy: CLIKeychain()))
  }

  @Test("A revoked CLI token no longer validates; revoke all removes every pairing")
  func revokedCLITokenStopsValidating() {
    let keychain = CLIKeychain()
    let store = Self.cliStore(keychain)
    let first = store.save(Self.credential("first"))
    let second = store.save(Self.credential("second"))
    #expect(!first.isSessionOnly)
    let registry = MCPCLITokenRegistry()
    registry.replaceAll(with: store.list())
    #expect(registry.pairedID(for: first.token) == first.id)

    #expect(store.revoke(id: first.id))
    registry.replaceAll(with: store.list())
    #expect(registry.pairedID(for: first.token) == nil)
    #expect(registry.pairedID(for: second.token) == second.id)

    #expect(store.revokeAll())
    #expect(store.list().isEmpty)
    #expect(keychain.isEmpty)
  }

  @Test("A CLI pairing is saved as JSON token, proofKey, name and date under its id")
  func cliValueFormat() throws {
    let keychain = CLIKeychain()
    let saved = Self.cliStore(keychain).save(Self.credential("laptop"))
    let data = try #require(keychain.data(account: saved.id))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(Set(object.keys) == ["token", "proofKey", "name", "date"])
    #expect(object["token"] == saved.token && Self.isToken(saved.token))
    #expect(object["proofKey"] == saved.proofKey && Self.isToken(saved.proofKey))
    #expect(ISO8601DateFormatter().date(from: object["date"] ?? "") != nil)
    #expect(Self.cliStore(keychain).list().map(\.id) == [saved.id])
  }

  @Test("When the Keychain refuses the write, the pairing lasts this session only")
  func cliSessionOnly() {
    let keychain = CLIKeychain(writeStatus: errSecMissingEntitlement)
    let store = Self.cliStore(keychain)
    let saved = store.save(Self.credential("ad hoc"))
    #expect(saved.isSessionOnly)
    #expect(store.list() == [saved])
    #expect(keychain.isEmpty)
    store.revoke(id: saved.id)
    #expect(store.list().isEmpty)
  }

  @Test("The inventory lists the CLI token service as an MCP server token")
  func inventoryListsCLIService() {
    #expect(KeychainMCPCLITokenStore.serviceName == "ace.thi.dblore.mcp-cli")
    #expect(KeychainSecretInventory.services.contains(KeychainMCPCLITokenStore.serviceName))
    let item = SecretItem.listed(
      service: KeychainMCPCLITokenStore.serviceName, account: UUID().uuidString)
    #expect(item.kind == .mcpServerToken)
  }
}

/// One in-memory Keychain domain that lists accounts; writes can be refused with a status.
private final class CLIKeychain: KeychainBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]
  private let writeStatus: OSStatus

  init(writeStatus: OSStatus = errSecSuccess) {
    self.writeStatus = writeStatus
  }

  var isEmpty: Bool { lock.withLock { items.isEmpty } }

  func data(account: String) -> Data? { lock.withLock { items[account] } }

  func copy(service: String, account: String, context: LAContext?) -> KeychainRead {
    lock.withLock { items[account].map { .found($0) } ?? .notFound }
  }

  func add(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    upsert(
      service: service, account: account, data: data, accessible: accessible,
      accessControl: accessControl)
  }

  func upsert(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    lock.withLock {
      guard writeStatus == errSecSuccess else { return writeStatus }
      items[account] = data
      return errSecSuccess
    }
  }

  func delete(service: String, account: String) -> OSStatus {
    lock.withLock { items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess }
  }

  func accounts(service: String) -> [String] { lock.withLock { items.keys.sorted() } }
}
