import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing

@testable import Dblore

/// Test-only in-memory keychain domain. Records each item with its accessibility, access
/// control and seeded modification date, counts `copy`, no-UI `copy`, date reads, writes and
/// deletes, and can be told to fail every `copy`, no-UI `copy`, `delete` or write (protected
/// and plain writes separately), or to answer every `copy` after a successful `add` with a set
/// result. A protected item read without an authentication context fails
/// closed (the real Keychain would prompt; no caller does that).
private final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
  struct Item: Equatable {
    var data: Data
    var accessible: String
    var accessControl: KeychainAccessControl? = nil
    /// Set only by `seed`; writes leave it nil (a date the fake cannot read).
    var modificationDate: Date? = nil
  }

  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var items: [Key: Item] = [:]
  private var copies = 0
  private var noUICopies = 0
  private var dateReads = 0
  private var writes = 0
  private var deletes = 0
  private var noUIDeletes = 0
  private var copyFailure: OSStatus?
  private var noUICopyFailure: OSStatus?
  private var deleteFailure: OSStatus?
  private var protectedWriteFailure: OSStatus?
  private var plainWriteFailure: OSStatus?
  private var copyAfterAdd: KeychainRead?
  private var added = false

  var copyCount: Int { lock.withLock { copies } }
  var noUICopyCount: Int { lock.withLock { noUICopies } }
  var dateReadCount: Int { lock.withLock { dateReads } }
  var writeCount: Int { lock.withLock { writes } }
  var deleteCount: Int { lock.withLock { deletes } }
  /// Deletes made with a context that disallows interaction.
  var noUIDeleteCount: Int { lock.withLock { noUIDeletes } }

  func failCopy(with status: OSStatus) { lock.withLock { copyFailure = status } }

  func failNoUICopy(with status: OSStatus) { lock.withLock { noUICopyFailure = status } }

  func failDelete(with status: OSStatus) { lock.withLock { deleteFailure = status } }

  func failProtectedWrites(with status: OSStatus) {
    lock.withLock { protectedWriteFailure = status }
  }

  func failPlainWrites(with status: OSStatus) { lock.withLock { plainWriteFailure = status } }

  func answerCopiesAfterAdd(with read: KeychainRead) { lock.withLock { copyAfterAdd = read } }

  func seed(
    service: String, account: String, data: Data, accessible: CFString,
    accessControl: KeychainAccessControl? = nil, modified: Date? = nil
  ) {
    lock.withLock {
      items[Key(service: service, account: account)] = Item(
        data: data, accessible: accessible as String, accessControl: accessControl,
        modificationDate: modified)
    }
  }

  func item(service: String, account: String) -> Item? {
    lock.withLock { items[Key(service: service, account: account)] }
  }

  func copy(service: String, account: String, context: LAContext?) -> KeychainRead {
    lock.withLock {
      copies += 1
      if let copyFailure { return .failed(copyFailure) }
      if added, let copyAfterAdd { return copyAfterAdd }
      guard let item = items[Key(service: service, account: account)] else { return .notFound }
      if item.accessControl != nil, context == nil { return .failed(errSecInteractionNotAllowed) }
      return .found(item.data)
    }
  }

  func copyWithoutUI(service: String, account: String) -> KeychainRead {
    lock.withLock {
      noUICopies += 1
      if let failure = noUICopyFailure ?? copyFailure { return .failed(failure) }
      guard let item = items[Key(service: service, account: account)] else { return .notFound }
      if item.accessControl != nil { return .failed(errSecInteractionNotAllowed) }
      return .found(item.data)
    }
  }

  func modificationDate(service: String, account: String) -> Date? {
    lock.withLock {
      dateReads += 1
      return items[Key(service: service, account: account)]?.modificationDate
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
      added = true
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

  func delete(service: String, account: String, context: LAContext?) -> OSStatus {
    if context?.interactionNotAllowed == true { lock.withLock { noUIDeletes += 1 } }
    return delete(service: service, account: account)
  }

  func delete(service: String, account: String) -> OSStatus {
    lock.withLock {
      deletes += 1
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

  private let sweeps = KeychainSweepTracker()

  /// Never sweeps, so the read-through tests see the legacy keychain as it was.
  private var vault: KeychainVault {
    KeychainVault(
      service: service, accessible: accessible, modern: modern, legacy: legacy,
      sweepTracker: sweeps, sweepPolicy: .noKey)
  }

  /// Sweeps with this test's own tracker; the shared tracker and launch policy stay untouched.
  private func sweepingVault(_ policy: KeychainSweepPolicy = .everyKey) -> KeychainVault {
    KeychainVault(
      service: service, accessible: accessible, modern: modern, legacy: legacy,
      sweepTracker: sweeps, sweepPolicy: policy)
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

  // MARK: Legacy sweep

  private let now = Date()

  @Test("A modern hit deletes an equal legacy copy without UI")
  func sweepDeletesEqualLegacy() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)

    #expect(sweepingVault().read(account: "a") == .found(Data("s".utf8)))
    #expect(legacy.item(service: service, account: "a") == nil)
    #expect(legacy.noUIDeleteCount == 1)
    #expect(legacy.copyCount == 0)
  }

  @Test("A modern hit deletes an older differing legacy copy")
  func sweepDeletesOlderDifferingLegacy() {
    modern.seed(
      service: service, account: "a", data: Data("new".utf8), accessible: accessible,
      modified: now)
    legacy.seed(
      service: service, account: "a", data: Data("old".utf8), accessible: accessible,
      modified: now.addingTimeInterval(-60))

    #expect(sweepingVault().read(account: "a") == .found(Data("new".utf8)))
    #expect(legacy.item(service: service, account: "a") == nil)
  }

  /// Offsets from `now` of the legacy and modern modification dates; nil is an unreadable date.
  private static let keptDifferingDates: [(TimeInterval?, TimeInterval?)] = [
    (60, 0), (nil, 0), (-60, nil),
  ]

  @Test(
    "A modern hit keeps a differing legacy copy that is newer or has an unreadable date, once",
    arguments: keptDifferingDates)
  func sweepKeepsDifferingLegacy(legacyOffset: TimeInterval?, modernOffset: TimeInterval?) {
    modern.seed(
      service: service, account: "a", data: Data("new".utf8), accessible: accessible,
      modified: modernOffset.map { now.addingTimeInterval($0) })
    legacy.seed(
      service: service, account: "a", data: Data("other".utf8), accessible: accessible,
      modified: legacyOffset.map { now.addingTimeInterval($0) })

    #expect(sweepingVault().read(account: "a") == .found(Data("new".utf8)))
    #expect(legacy.dateReadCount == 1)
    let dateReads = legacy.dateReadCount + modern.dateReadCount
    // The kept-copy branch (and its log) runs once per launch: a second read checks nothing
    #expect(sweepingVault().read(account: "a") == .found(Data("new".utf8)))
    #expect(legacy.item(service: service, account: "a")?.data == Data("other".utf8))
    #expect(legacy.deleteCount == 0)
    #expect(legacy.noUICopyCount == 1)
    #expect(legacy.dateReadCount + modern.dateReadCount == dateReads)
  }

  @Test("A failed no-UI legacy read keeps the legacy copy, with no date check")
  func sweepKeepsLegacyWhenNoUIReadFails() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.failNoUICopy(with: errSecInteractionNotAllowed)

    #expect(sweepingVault().read(account: "a") == .found(Data("s".utf8)))
    #expect(legacy.item(service: service, account: "a")?.data == Data("s".utf8))
    #expect(legacy.deleteCount == 0)
    #expect(legacy.dateReadCount == 0)
    #expect(modern.dateReadCount == 0)
  }

  @Test("A legacy-only hit is copied, verified by a re-read and then deleted without UI")
  func sweepMigratesThenDeletesLegacy() {
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)

    #expect(sweepingVault().read(account: "a") == .found(Data("s".utf8)))
    #expect(modern.item(service: service, account: "a")?.data == Data("s".utf8))
    #expect(modern.copyCount == 2)
    #expect(legacy.item(service: service, account: "a") == nil)
    #expect(legacy.noUIDeleteCount == 1)
  }

  /// What the data protection re-read answers after a legacy-only hit was copied over.
  private static let unverifiedRereads: [KeychainRead] = [
    .found(Data("other".utf8)), .failed(errSecInteractionNotAllowed),
  ]

  @Test(
    "A legacy-only hit whose re-read does not match keeps the legacy copy",
    arguments: unverifiedRereads)
  func sweepKeepsLegacyWhenRereadMismatches(reread: KeychainRead) {
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    modern.answerCopiesAfterAdd(with: reread)

    #expect(sweepingVault().read(account: "a") == .found(Data("s".utf8)))
    #expect(modern.copyCount == 2)
    #expect(legacy.item(service: service, account: "a")?.data == Data("s".utf8))
    #expect(legacy.deleteCount == 0)
  }

  @Test("A modern read error never touches the legacy keychain, even when sweeping every key")
  func modernReadErrorSkipsLegacy() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    modern.failCopy(with: errSecInteractionNotAllowed)

    #expect(sweepingVault().read(account: "a") == .failed(errSecInteractionNotAllowed))
    #expect(legacy.copyCount == 0)
    #expect(legacy.noUICopyCount == 0)
    #expect(legacy.deleteCount == 0)
    #expect(legacy.item(service: service, account: "a") != nil)
  }

  @Test("A failed legacy delete is not retried in the same launch and keeps the read result")
  func sweepFailedDeleteNotRetried() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "b", data: Data("t".utf8), accessible: accessible)
    legacy.failDelete(with: errSecAuthFailed)
    let vault = sweepingVault()

    for _ in 0..<2 {
      #expect(vault.read(account: "a") == .found(Data("s".utf8)))
      #expect(vault.read(account: "b") == .found(Data("t".utf8)))
    }
    #expect(legacy.deleteCount == 2)
    #expect(legacy.noUICopyCount == 1)
    #expect(legacy.item(service: service, account: "a") != nil)
    #expect(legacy.item(service: service, account: "b") != nil)
  }

  @Test("The no-key policy never reads without UI or deletes in the legacy keychain")
  func noKeyPolicyNeverSweeps() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "b", data: Data("t".utf8), accessible: accessible)

    #expect(vault.read(account: "a") == .found(Data("s".utf8)))
    #expect(vault.read(account: "b") == .found(Data("t".utf8)))
    #expect(legacy.noUICopyCount == 0)
    #expect(legacy.deleteCount == 0)
    #expect(legacy.item(service: service, account: "a") != nil)
    #expect(legacy.item(service: service, account: "b") != nil)
  }

  @Test("A failed copy into the modern keychain keeps the legacy copy")
  func sweepKeepsLegacyWhenAddFails() {
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    modern.failPlainWrites(with: errSecMissingEntitlement)

    #expect(sweepingVault().read(account: "a") == .found(Data("s".utf8)))
    #expect(legacy.item(service: service, account: "a")?.data == Data("s".utf8))
    #expect(legacy.deleteCount == 0)
  }

  @Test("A key is swept at most once per launch")
  func sweepRunsOncePerKey() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    _ = sweepingVault().read(account: "a")
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)

    #expect(sweepingVault().read(account: "a") == .found(Data("s".utf8)))
    #expect(legacy.deleteCount == 1)
    #expect(legacy.noUICopyCount == 1)
    #expect(legacy.item(service: service, account: "a") != nil)
  }

  @Test("A policy naming one key sweeps only that key")
  func sweepPolicyNamesOneKey() {
    for account in ["a", "b"] {
      modern.seed(service: service, account: account, data: Data("s".utf8), accessible: accessible)
      legacy.seed(service: service, account: account, data: Data("s".utf8), accessible: accessible)
    }
    let vault = sweepingVault(.onlyKey(service: service, account: "a"))

    _ = vault.read(account: "a")
    _ = vault.read(account: "b")
    #expect(legacy.item(service: service, account: "a") == nil)
    #expect(legacy.item(service: service, account: "b") != nil)
    #expect(legacy.noUICopyCount == 1)
  }

  @Test("The Debug fence names one key from the launch arguments, otherwise none")
  func debugPolicyParsesArguments() {
    #expect(
      KeychainSweepPolicy.debug(arguments: ["app", "-keychainSweepOnly", "svc|acc|x"])
        == .onlyKey(service: "svc", account: "acc|x"))
    #expect(KeychainSweepPolicy.debug(arguments: ["app"]) == .noKey)
    #expect(KeychainSweepPolicy.debug(arguments: ["app", "-keychainSweepOnly"]) == .noKey)
    #expect(KeychainSweepPolicy.debug(arguments: ["app", "-keychainSweepOnly", "svc"]) == .noKey)
    #expect(KeychainSweepPolicy.debug(arguments: ["app", "-keychainSweepOnly", "|acc"]) == .noKey)
  }

  @Test("Each SecItem backend's query is scoped to its own keychain")
  func backendQueriesAreScopedToTheirKeychain() {
    let key = kSecUseDataProtectionKeychain as String
    let legacyQuery = SecItemKeychainBackend(dataProtection: false).query(service: "svc")
    let modernQuery = SecItemKeychainBackend(dataProtection: true).query(
      service: "svc", account: "a")
    #expect(legacyQuery[key] as? Bool == false)
    #expect(modernQuery[key] as? Bool == true)
  }

  /// Process state only: no keychain item is read or written, and the off window lasts one state
  /// read.
  @Test(
    "The file-keychain interaction switch runs its body once with interaction off, then restores")
  func fileKeychainInteractionSwitchRestoresState() throws {
    let before = try #require(FileKeychainInteraction.isAllowed() as Bool?)
    var runs = 0
    var inside: Bool?

    let result = FileKeychainInteraction.withInteractionDisabled {
      runs += 1
      inside = FileKeychainInteraction.isAllowed()
      return 7
    }

    #expect(result == 7)
    #expect(runs == 1)
    #expect(inside == false)
    #expect(FileKeychainInteraction.isAllowed() == before)
  }

  @Test("A protected read never sweeps")
  func protectedReadNeverSweeps() {
    modern.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)
    legacy.seed(service: service, account: "a", data: Data("s".utf8), accessible: accessible)

    #expect(
      sweepingVault().readProtected(account: "a", context: LAContext()) == .found(Data("s".utf8)))
    #expect(legacy.noUICopyCount == 0)
    #expect(legacy.copyCount == 0)
    #expect(legacy.deleteCount == 0)
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
