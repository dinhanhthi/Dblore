import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing

@testable import Dblore

/// Test-only in-memory keychain domain. Records each item with its accessibility and access
/// control, counts `copy` calls and writes, and can be told to fail every `copy`, `delete` or
/// write (protected and plain writes separately). A protected item read without an
/// authentication context fails closed (the real Keychain would prompt; no caller does that).
private final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
  struct Item: Equatable {
    var data: Data
    var accessible: String
    var accessControl: KeychainAccessControl? = nil
  }

  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var items: [Key: Item] = [:]
  private var copies = 0
  private var writes = 0
  private var copyFailure: OSStatus?
  private var deleteFailure: OSStatus?
  private var protectedWriteFailure: OSStatus?
  private var plainWriteFailure: OSStatus?

  var copyCount: Int { lock.withLock { copies } }
  var writeCount: Int { lock.withLock { writes } }

  func failCopy(with status: OSStatus) { lock.withLock { copyFailure = status } }

  func failDelete(with status: OSStatus) { lock.withLock { deleteFailure = status } }

  func failProtectedWrites(with status: OSStatus) {
    lock.withLock { protectedWriteFailure = status }
  }

  func failPlainWrites(with status: OSStatus) { lock.withLock { plainWriteFailure = status } }

  func seed(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl? = nil
  ) {
    lock.withLock {
      items[Key(service: service, account: account)] = Item(
        data: data, accessible: accessible as String, accessControl: accessControl)
    }
  }

  func item(service: String, account: String) -> Item? {
    lock.withLock { items[Key(service: service, account: account)] }
  }

  func copy(service: String, account: String, context: LAContext?) -> KeychainRead {
    lock.withLock {
      copies += 1
      if let copyFailure { return .failed(copyFailure) }
      guard let item = items[Key(service: service, account: account)] else { return .notFound }
      if item.accessControl != nil, context == nil { return .failed(errSecInteractionNotAllowed) }
      return .found(item.data)
    }
  }

  func add(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    lock.withLock {
      writes += 1
      if let failure = writeFailure(accessControl) { return failure }
      let key = Key(service: service, account: account)
      guard items[key] == nil else { return errSecDuplicateItem }
      items[key] = Item(
        data: data, accessible: accessible as String, accessControl: accessControl)
      return errSecSuccess
    }
  }

  func upsert(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl?
  ) -> OSStatus {
    lock.withLock {
      writes += 1
      if let failure = writeFailure(accessControl) { return failure }
      items[Key(service: service, account: account)] = Item(
        data: data, accessible: accessible as String, accessControl: accessControl)
      return errSecSuccess
    }
  }

  /// Called with the lock held.
  private func writeFailure(_ accessControl: KeychainAccessControl?) -> OSStatus? {
    accessControl == nil ? plainWriteFailure : protectedWriteFailure
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
  private var accessible: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
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

  // MARK: Protected items and the content-key store

  private let workspaceId = UUID()
  private let contentKey = SymmetricKey(size: .bits256)

  private var keyAccount: String { LockKeyStore.account(for: workspaceId) }

  private func keyStore(defaults: UserDefaults, passcodeSet: Bool = true) -> LockKeyStore {
    LockKeyStore(
      vault: KeychainVault(
        service: LockKeyStore.serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        modern: modern, legacy: legacy),
      modes: defaults, passcodeSet: { passcodeSet })
  }

  /// A proof from the non-prompting Debug double (the only way to get one without a prompt)
  @MainActor private func ownerProof() async throws -> OwnerAuthentication {
    try #require(await GrantingOwnerTestAuthenticator().authenticateOwner(reason: "test"))
  }

  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "KeychainVaultTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }

  @Test("A failed protected write stores nothing, never a plain item")
  func protectedWriteNeverStoresPlain() {
    modern.failProtectedWrites(with: errSecParam)

    #expect(vault.writeProtected(account: "a", data: Data("key".utf8)) == errSecParam)
    #expect(modern.item(service: service, account: "a") == nil)
  }

  @Test(
    "A protected item read without a context fails closed and never reaches the legacy keychain")
  func protectedReadWithoutContextFailsClosed() {
    modern.seed(
      service: service, account: "a", data: Data("key".utf8), accessible: accessible,
      accessControl: .userPresence)
    legacy.seed(service: service, account: "a", data: Data("old".utf8), accessible: accessible)

    #expect(vault.read(account: "a") == .failed(errSecInteractionNotAllowed))
    #expect(legacy.copyCount == 0)
    #expect(vault.readProtected(account: "a", context: LAContext()) == .found(Data("key".utf8)))
  }

  @Test("A protected read never falls back to the legacy keychain")
  func protectedReadSkipsLegacy() {
    legacy.seed(service: service, account: "a", data: Data("old".utf8), accessible: accessible)

    #expect(vault.readProtected(account: "a", context: LAContext()) == .notFound)
    #expect(legacy.copyCount == 0)
    #expect(modern.item(service: service, account: "a") == nil)
  }

  @Test("The content key is stored behind user presence first and the mode is recorded")
  @MainActor
  func contentKeyStoredBehindPresence() async throws {
    let owner = try await ownerProof()
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults)

      #expect(try store.store(contentKey, for: workspaceId) == .presence)
      #expect(store.mode(for: workspaceId) == .presence)
      let item = modern.item(service: LockKeyStore.serviceName, account: keyAccount)
      #expect(item?.accessControl == .userPresence)
      #expect(item?.data == contentKey.withUnsafeBytes { Data($0) })
      #expect(try store.read(for: workspaceId, authentication: owner) == contentKey)
    }
  }

  @Test("A failed user-presence add falls back only through the reported app-gated mode")
  @MainActor
  func failedPresenceFallsBackToReportedAppGated() async throws {
    let owner = try await ownerProof()
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults)
      modern.failProtectedWrites(with: errSecAuthFailed)

      #expect(try store.store(contentKey, for: workspaceId) == .appGated)
      #expect(store.mode(for: workspaceId) == .appGated)
      let item = modern.item(service: LockKeyStore.serviceName, account: keyAccount)
      #expect(item?.accessControl == nil)
      #expect(item?.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
      // The plain item reads back through the same owner proof as the presence item
      #expect(try store.read(for: workspaceId, authentication: owner) == contentKey)
    }
  }

  @Test("A missing entitlement is reported as unavailable, with no item written")
  @MainActor
  func missingEntitlementIsUnavailable() async throws {
    let owner = try await ownerProof()
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults)
      modern.failProtectedWrites(with: errSecMissingEntitlement)
      modern.failPlainWrites(with: errSecMissingEntitlement)

      #expect(try store.store(contentKey, for: workspaceId) == .unavailable)
      #expect(store.mode(for: workspaceId) == .unavailable)
      #expect(modern.item(service: LockKeyStore.serviceName, account: keyAccount) == nil)
      #expect(try store.read(for: workspaceId, authentication: owner) == nil)
    }
  }

  @Test("Without a login password the key store is unavailable before any Keychain write")
  func noPasscodeIsUnavailable() throws {
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults, passcodeSet: false)

      #expect(try store.store(contentKey, for: workspaceId) == .unavailable)
      #expect(store.mode(for: workspaceId) == .unavailable)
      #expect(modern.writeCount == 0)
    }
  }

  @Test("A locked keybag is a retryable error and never triggers a fallback")
  func lockedKeybagIsRetryable() throws {
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults)
      modern.failProtectedWrites(with: errSecInteractionNotAllowed)

      #expect(throws: LockKeyStoreError.retryable(errSecInteractionNotAllowed)) {
        try store.store(contentKey, for: workspaceId)
      }
      #expect(modern.writeCount == 1)
      #expect(modern.item(service: LockKeyStore.serviceName, account: keyAccount) == nil)
      #expect(store.mode(for: workspaceId) == nil)
    }
  }

  @Test("Remove deletes the key and its recorded mode")
  func removeClearsKeyAndMode() throws {
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults)
      _ = try store.store(contentKey, for: workspaceId)

      #expect(store.remove(for: workspaceId) == errSecSuccess)
      #expect(modern.item(service: LockKeyStore.serviceName, account: keyAccount) == nil)
      #expect(store.mode(for: workspaceId) == nil)
    }
  }

  @Test("Remove treats a missing entitlement as nothing to delete and always clears the mode")
  func removeWithoutKeychainClearsMode() throws {
    try withDefaults { defaults throws in
      let store = keyStore(defaults: defaults)
      _ = try store.store(contentKey, for: workspaceId)

      modern.failDelete(with: errSecMissingEntitlement)
      #expect(store.remove(for: workspaceId) == errSecSuccess)
      #expect(store.mode(for: workspaceId) == nil)

      // Any other delete failure is returned, and the recorded mode is still cleared
      #expect(try store.store(contentKey, for: workspaceId) == .unavailable)
      modern.failDelete(with: errSecInteractionNotAllowed)
      #expect(store.remove(for: workspaceId) == errSecInteractionNotAllowed)
      #expect(store.mode(for: workspaceId) == nil)
    }
  }
}
