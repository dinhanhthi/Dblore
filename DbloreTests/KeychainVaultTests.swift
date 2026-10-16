import Foundation
import Security
import Testing

@testable import Dblore

/// Test-only in-memory keychain domain. Records each item with its accessibility,
/// counts `copy` calls, and can be told to fail every `copy` or `delete`.
private final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
  struct Item: Equatable {
    var data: Data
    var accessible: String
  }

  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var items: [Key: Item] = [:]
  private var copies = 0
  private var copyFailure: OSStatus?
  private var deleteFailure: OSStatus?

  var copyCount: Int { lock.withLock { copies } }

  func failCopy(with status: OSStatus) { lock.withLock { copyFailure = status } }

  func failDelete(with status: OSStatus) { lock.withLock { deleteFailure = status } }

  func seed(service: String, account: String, data: Data, accessible: CFString) {
    lock.withLock {
      items[Key(service: service, account: account)] = Item(
        data: data, accessible: accessible as String)
    }
  }

  func item(service: String, account: String) -> Item? {
    lock.withLock { items[Key(service: service, account: account)] }
  }

  func copy(service: String, account: String) -> KeychainRead {
    lock.withLock {
      copies += 1
      if let copyFailure { return .failed(copyFailure) }
      guard let item = items[Key(service: service, account: account)] else { return .notFound }
      return .found(item.data)
    }
  }

  func add(service: String, account: String, data: Data, accessible: CFString) -> OSStatus {
    lock.withLock {
      let key = Key(service: service, account: account)
      guard items[key] == nil else { return errSecDuplicateItem }
      items[key] = Item(data: data, accessible: accessible as String)
      return errSecSuccess
    }
  }

  func upsert(service: String, account: String, data: Data, accessible: CFString) -> OSStatus {
    lock.withLock {
      items[Key(service: service, account: account)] = Item(
        data: data, accessible: accessible as String)
      return errSecSuccess
    }
  }

  func delete(service: String, account: String) -> OSStatus {
    lock.withLock {
      if let deleteFailure { return deleteFailure }
      return items.removeValue(forKey: Key(service: service, account: account)) == nil
        ? errSecItemNotFound : errSecSuccess
    }
  }

  func accounts(service: String) -> [String] {
    lock.withLock { items.keys.filter { $0.service == service }.map(\.account) }
  }
}

@Suite("Keychain vault")
struct KeychainVaultTests {
  private let service = "ace.thi.dblore.test"
  private let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  private let modern = InMemoryKeychainBackend()
  private let legacy = InMemoryKeychainBackend()

  private var vault: KeychainVault {
    KeychainVault(service: service, accessible: accessible, modern: modern, legacy: legacy)
  }

  @Test("A legacy-only value is returned and copied into the modern keychain")
  func migratesLegacyValue() {
    let secret = Data("legacy".utf8)
    legacy.seed(
      service: service, account: "a", data: secret, accessible: kSecAttrAccessibleAfterFirstUnlock)

    #expect(vault.read(account: "a") == .found(secret))
    #expect(
      modern.item(service: service, account: "a")
        == .init(data: secret, accessible: accessible as String))
    #expect(legacy.item(service: service, account: "a")?.data == secret)
  }

  @Test("A modern value wins and the legacy keychain is never read")
  func modernValueSkipsLegacy() {
    modern.seed(service: service, account: "a", data: Data("new".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("old".utf8), accessible: accessible)

    #expect(vault.read(account: "a") == .found(Data("new".utf8)))
    #expect(legacy.copyCount == 0)
  }

  @Test("A failed legacy read is reported as failed and nothing is copied")
  func legacyFailureFailsClosed() {
    legacy.seed(service: service, account: "a", data: Data("old".utf8), accessible: accessible)
    legacy.failCopy(with: errSecUserCanceled)

    #expect(vault.read(account: "a") == .failed(errSecUserCanceled))
    #expect(modern.item(service: service, account: "a") == nil)
  }

  @Test("Write targets modern only, delete clears both, accounts are a deduplicated union")
  func writeDeleteAccounts() {
    legacy.seed(service: service, account: "a", data: Data("1".utf8), accessible: accessible)
    legacy.seed(service: service, account: "shared", data: Data("2".utf8), accessible: accessible)

    vault.write(account: "shared", data: Data("3".utf8))
    vault.write(account: "b", data: Data("4".utf8))
    #expect(modern.item(service: service, account: "shared")?.data == Data("3".utf8))
    #expect(legacy.item(service: service, account: "shared")?.data == Data("2".utf8))
    #expect(legacy.item(service: service, account: "b") == nil)

    #expect(vault.accounts().sorted() == ["a", "b", "shared"])

    #expect(vault.delete(account: "shared") == errSecSuccess)
    #expect(modern.item(service: service, account: "shared") == nil)
    #expect(legacy.item(service: service, account: "shared") == nil)
  }

  @Test("A failed legacy delete keeps the modern copy, so the secret cannot come back stale")
  func failedLegacyDeleteKeepsModern() {
    modern.seed(service: service, account: "a", data: Data("new".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("old".utf8), accessible: accessible)
    legacy.failDelete(with: errSecAuthFailed)

    #expect(vault.delete(account: "a") == errSecAuthFailed)
    #expect(vault.read(account: "a") == .found(Data("new".utf8)))
  }
}
