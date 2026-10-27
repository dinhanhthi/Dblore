// DataSettingsModelTests.swift
// Data settings loads summaries and refuses destructive actions without confirmation. While
// anything is locked, actions that would drop a lock or a key ask LockCenter first (an injected
// center with a counting owner: no prompt, no Keychain).

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Data settings model")
struct DataSettingsModelTests {
  @Test("Refresh fills summaries and total size", .timeLimit(.minutes(1)))
  func refreshFillsSummariesAndTotalSize() async {
    let latch = SummaryLatch(expected: 2)
    let logs = Store(text: "alpha", bytes: 11, itemCount: 2, latch: latch)
    let settings = Store(text: "beta", bytes: 7, itemCount: 1, latch: latch)
    let item = SecretItem(service: "svc", account: "ada", label: "ada", kind: .dbPassword)
    let inventory = InMemorySecretInventory(items: [item])
    let model = DataSettingsModel(
      providers: [
        FakeProvider(category: .logs, store: logs),
        FakeProvider(category: .appSettings, store: settings),
      ],
      inventory: inventory)

    #expect(model.totalBytes == 0)
    await model.refresh()

    #expect(model.rows.map(\.category) == [.logs, .appSettings])
    #expect(
      model.rows.map(\.summary) == [
        LocalDataSummary(bytes: 11, itemCount: 2, location: nil),
        LocalDataSummary(bytes: 7, itemCount: 1, location: nil),
      ])
    #expect(model.rows.allSatisfy { $0.loading == false && $0.error == nil })
    #expect(model.totalBytes == 18)
    #expect(model.secrets == [item])
  }

  @Test("Clear without a matching token does not call the provider")
  func clearRequiresMatchingToken() async {
    let logs = Store(text: "alpha", bytes: 4, itemCount: 1)
    let history = Store(text: "beta", bytes: 4, itemCount: 1)
    let model = DataSettingsModel(
      providers: [
        FakeProvider(category: .logs, store: logs),
        FakeProvider(category: .queryHistory, store: history),
      ],
      inventory: InMemorySecretInventory())

    let fromOtherCategory = model.prepareClear(.queryHistory)
    await model.clear(.logs, confirmed: fromOtherCategory)
    #expect(logs.clearCount == 0)
    #expect(history.clearCount == 0)

    let fromOtherAction = model.prepareClearAll(includeSecrets: false)
    await model.clear(.logs, confirmed: fromOtherAction)
    #expect(logs.clearCount == 0)

    let token = model.prepareClear(.logs)
    await model.clear(.logs, confirmed: token)
    #expect(logs.clearCount == 1)
    #expect(history.clearCount == 0)

    await model.clear(.logs, confirmed: token)
    #expect(logs.clearCount == 1)
  }

  @Test(
    "Clear all removes secrets, outside MCP servers and the MCP server token only when that flag is confirmed"
  )
  func clearAllRespectsSecretsFlag() async throws {
    let logs = Store(text: "alpha", bytes: 4, itemCount: 1)
    let database = SecretItem(service: "db", account: "ada", label: "ada", kind: .dbPassword)
    let key = SecretItem(service: "ai", account: "openai", label: "openai", kind: .aiKey)
    let certificate = SecretItem.listed(
      service: KeychainClientCertificateStore.serviceName,
      account: "db.example:5432:app:ada")
    let ssh = SecretItem.listed(
      service: KeychainSSHCredentialStore.serviceName, account: "v2|9:bastion")
    let hostKey = SecretItem.listed(
      service: KeychainSSHKnownHostStore.serviceName, account: "v2|9:bastion|2:22")
    let mcpToken = SecretItem.listed(
      service: KeychainMCPTokenStore.serviceName, account: "bearer-token")
    let inventory = InMemorySecretInventory(
      items: [database, key, certificate, ssh, hostKey, mcpToken])
    let suite = "ace.thi.Dblore.tests.dataSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tokens = InMemoryOutsideMCPTokenStore()
    let servers = OutsideMCPServerStore(defaults: defaults, tokens: tokens)
    let server = try await servers.add(
      name: "Tools", url: "http://127.0.0.1:7777/mcp", token: "tok-1")
    let forgotten = HookCount()
    let lock = try LockFixture()
    defer { lock.cleanUp() }
    let model = DataSettingsModel(
      providers: [FakeProvider(category: .logs, store: logs)],
      inventory: inventory, outsideServers: servers,
      mcpServerTokenDeleted: { forgotten.count += 1 }, lockCenter: lock.center,
      recentWorkspaces: { [] })

    let mismatched = model.prepareClearAll(includeSecrets: false)
    await model.clearAll(includeSecrets: true, confirmed: mismatched)
    #expect(logs.clearCount == 0)
    #expect(await inventory.items() == [database, key, certificate, ssh, hostKey, mcpToken])

    let keepSecrets = model.prepareClearAll(includeSecrets: false)
    await model.clearAll(includeSecrets: false, confirmed: keepSecrets)
    #expect(logs.clearCount == 1)
    #expect(await inventory.items() == [database, key, certificate, ssh, hostKey, mcpToken])
    // A server and its token are a pair: kept together with the credentials.
    #expect(servers.servers.map(\.id) == [server.id])
    #expect(tokens.load(serverID: server.id) == "tok-1")
    #expect(forgotten.count == 0)

    let removeSecrets = model.prepareClearAll(includeSecrets: true)
    await model.clearAll(includeSecrets: true, confirmed: removeSecrets)
    #expect(logs.clearCount == 2)
    #expect(await inventory.items().isEmpty)
    #expect(servers.servers.isEmpty)
    #expect(defaults.data(forKey: OutsideMCPServerStore.defaultsKey) == nil)
    #expect(tokens.load(serverID: server.id) == nil)
    #expect(OutsideMCPServerStore(defaults: defaults, tokens: tokens).servers.isEmpty)
    #expect(forgotten.count == 1)
    // Nothing locked: nothing asked
    #expect(lock.owner.prompts == 0)
  }

  @Test("Delete ignores a token from another action")
  func deleteRequiresMatchingToken() async {
    let item = SecretItem.listed(
      service: KeychainClientCertificateStore.serviceName,
      account: "db.example:5432:app:ada")
    let inventory = InMemorySecretInventory(items: [item])
    let logs = Store(text: "alpha", bytes: 4, itemCount: 1)
    let model = DataSettingsModel(
      providers: [FakeProvider(category: .logs, store: logs)],
      inventory: inventory)
    await model.refresh()
    #expect(model.secrets == [item])

    let other = model.prepareClear(.logs)
    await model.deleteSecret(item, confirmed: other)
    #expect(await inventory.items() == [item])
    #expect(model.secrets == [item])
    #expect(logs.clearCount == 0)

    let token = model.prepareDeleteSecret(item)
    await model.deleteSecret(item, confirmed: token)
    #expect(await inventory.items().isEmpty)
    #expect(model.secrets.isEmpty)
  }

  @Test("Deleting SSH items removes only the confirmed one")
  func deletesSSHItems() async {
    let ssh = SecretItem.listed(
      service: KeychainSSHCredentialStore.serviceName, account: "v2|9:bastion")
    let hostKey = SecretItem.listed(
      service: KeychainSSHKnownHostStore.serviceName, account: "v2|9:bastion|2:22")
    let inventory = InMemorySecretInventory(items: [ssh, hostKey])
    let logs = Store(text: "alpha", bytes: 4, itemCount: 1)
    let model = DataSettingsModel(
      providers: [FakeProvider(category: .logs, store: logs)],
      inventory: inventory)
    await model.refresh()
    #expect(model.secrets.map(\.kind) == [.sshCredential, .sshHostKey])

    await model.deleteSecret(ssh, confirmed: model.prepareDeleteSecret(ssh))
    #expect(await inventory.items() == [hostKey])
    await model.deleteSecret(hostKey, confirmed: model.prepareDeleteSecret(hostKey))
    #expect(await inventory.items().isEmpty)
    #expect(model.secrets.isEmpty)
  }

  @Test("Deleting one outside MCP token turns only its server off")
  func deletingOutsideTokenTurnsServerOff() async throws {
    let suite = "ace.thi.Dblore.tests.dataSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let servers = OutsideMCPServerStore(defaults: defaults, tokens: InMemoryOutsideMCPTokenStore())
    let first = try await servers.add(name: "One", url: "http://127.0.0.1:7777/mcp", token: "t1")
    let second = try await servers.add(name: "Two", url: "http://127.0.0.1:7778/mcp", token: "t2")
    servers.setEnabled(true, for: first.id)
    servers.setEnabled(true, for: second.id)
    let item = SecretItem.listed(
      service: KeychainOutsideMCPTokenStore.serviceName, account: first.id.uuidString)
    #expect(item.kind == .outsideMCPToken)
    let model = DataSettingsModel(
      providers: [], inventory: InMemorySecretInventory(items: [item]), outsideServers: servers)

    await model.deleteSecret(item, confirmed: model.prepareDeleteSecret(item))
    #expect(servers.servers.map(\.isEnabled) == [false, true])
  }

  @Test("Deleting the MCP server token makes the server forget it; other kinds do not")
  func deletingMCPServerTokenForgetsIt() async {
    let mcpToken = SecretItem.listed(
      service: KeychainMCPTokenStore.serviceName, account: "bearer-token")
    let key = SecretItem(service: "ai", account: "openai", label: "openai", kind: .aiKey)
    let inventory = InMemorySecretInventory(items: [key, mcpToken])
    let forgotten = HookCount()
    let model = DataSettingsModel(
      providers: [], inventory: inventory, mcpServerTokenDeleted: { forgotten.count += 1 })
    await model.refresh()
    #expect(model.secrets.map(\.kind) == [.aiKey, .mcpServerToken])

    await model.deleteSecret(key, confirmed: model.prepareDeleteSecret(key))
    #expect(forgotten.count == 0)
    await model.deleteSecret(mcpToken, confirmed: model.prepareDeleteSecret(mcpToken))
    #expect(await inventory.items().isEmpty)
    #expect(model.secrets.isEmpty)
    #expect(forgotten.count == 1)
  }

  @Test("Import reports per-category success")
  func importReportsPerCategorySuccess() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = Store(text: "alpha", bytes: 5, itemCount: 1)
    let settings = Store(text: "beta", bytes: 4, itemCount: 1)
    let providers: [any LocalDataProvider] = [
      FakeProvider(category: .logs, store: logs),
      FakeProvider(category: .appSettings, store: settings),
    ]
    let package = root.appendingPathComponent("Sample.dblorebackup", isDirectory: true)
    try await LocalDataBackup.export(
      categories: [.logs, .appSettings], providers: providers, to: package, appVersion: "9.2.0")
    logs.replace("changed")
    settings.replace("changed")

    let lock = try LockFixture()
    defer { lock.cleanUp() }
    let model = lock.model(providers: providers, inventory: InMemorySecretInventory())
    let selected: [LocalDataCategory] = [.logs, .appSettings]
    let foreign = model.prepareClear(.logs)
    let blocked = await model.importBackup(url: package, selected: selected, confirmed: foreign)
    #expect(blocked.isEmpty)
    #expect(logs.importCount == 0)
    #expect(settings.importCount == 0)
    #expect(logs.text == "changed")

    let token = model.prepareImport(url: package, selected: selected)
    let results = await model.importBackup(url: package, selected: selected, confirmed: token)
    #expect(
      results == [
        DataImportResult(category: .logs, succeeded: true),
        DataImportResult(category: .appSettings, succeeded: true),
      ])
    #expect(logs.importCount == 1)
    #expect(settings.importCount == 1)
    #expect(logs.text == "alpha")
    #expect(settings.text == "beta")
  }

  @Test("Import, clear and Clear all over a lock ask first; a cancel changes nothing")
  func lockedDataAsksFirst() async throws {
    let lock = try LockFixture()
    defer { lock.cleanUp() }
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = Store(text: "backup rows", bytes: 4, itemCount: 1)
    let providers: [any LocalDataProvider] = [
      FakeProvider(category: .connectionHistory, store: history)
    ]
    let package = root.appendingPathComponent("Old.dblorebackup", isDirectory: true)
    try await LocalDataBackup.export(
      categories: [.connectionHistory], providers: providers, to: package, appVersion: "9.2.0")
    history.replace("current rows")
    let database = SecretItem(service: "db", account: "ada", label: "ada", kind: .dbPassword)
    let key = SecretItem.listed(
      service: LockKeyStore.serviceName, account: LockKeyStore.account(for: UUID()))
    let inventory = InMemorySecretInventory(items: [database, key])
    let locked: Set<LockIdentity> = [
      .server(engine: .postgresql, host: "db.example", port: 5432, username: "ada")
    ]
    lock.registry.setLockedConnections(locked)
    let model = lock.model(providers: providers, inventory: inventory)
    let selected: [LocalDataCategory] = [.connectionHistory]

    await model.clear(.connectionHistory, confirmed: model.prepareClear(.connectionHistory))
    let refused = await model.importBackup(
      url: package, selected: selected,
      confirmed: model.prepareImport(url: package, selected: selected))
    await model.clearAll(
      includeSecrets: true, confirmed: model.prepareClearAll(includeSecrets: true))

    #expect(lock.owner.prompts == 3)
    #expect(history.clearCount == 0)
    #expect(history.importCount == 0)
    #expect(history.text == "current rows")
    #expect(refused == [DataImportResult(category: .connectionHistory, succeeded: false)])
    #expect(await inventory.items() == [database, key])
    #expect(lock.registry.lockedIdentities == locked)

    lock.owner.grants = true
    let imported = await model.importBackup(
      url: package, selected: selected,
      confirmed: model.prepareImport(url: package, selected: selected))
    #expect(imported == [DataImportResult(category: .connectionHistory, succeeded: true)])
    #expect(history.text == "backup rows")
    await model.clear(.connectionHistory, confirmed: model.prepareClear(.connectionHistory))
    #expect(history.clearCount == 1)
    #expect(lock.owner.prompts == 5)
  }

  @Test("Clear all with credentials keeps what a lock still needs")
  func clearAllKeepsLockedCredentials() async throws {
    let lock = try LockFixture()
    defer { lock.cleanUp() }
    #expect(lock.vault.setPassword(Self.lockPassword))
    lock.registry.registerWorkspace(UUID())
    lock.owner.grants = true
    let history = Store(text: "rows", bytes: 4, itemCount: 1)
    // A saved row still locked: the history clear is refused
    history.failsClear = true
    let database = SecretItem(service: "db", account: "ada", label: "ada", kind: .dbPassword)
    let certificate = SecretItem.listed(
      service: KeychainClientCertificateStore.serviceName, account: "db.example:5432:app:ada")
    let ssh = SecretItem.listed(
      service: KeychainSSHCredentialStore.serviceName, account: "v2|9:bastion")
    let apiKey = SecretItem(service: "ai", account: "openai", label: "openai", kind: .aiKey)
    let password = SecretItem.listed(
      service: LockPasswordStore.serviceName, account: LockPasswordStore.accountName)
    let key = SecretItem.listed(
      service: LockKeyStore.serviceName, account: LockKeyStore.account(for: UUID()))
    let inventory = InMemorySecretInventory(
      items: [database, certificate, ssh, apiKey, password, key])
    let model = lock.model(
      providers: [FakeProvider(category: .connectionHistory, store: history)],
      inventory: inventory)

    await model.clearAll(
      includeSecrets: true, confirmed: model.prepareClearAll(includeSecrets: true))

    // Asked once; the Lock password is refused before a second ask (a workspace uses it)
    #expect(lock.owner.prompts == 1)
    #expect(await inventory.items() == [database, certificate, ssh, password])
    #expect(lock.vault.hasPassword)
    #expect(model.error != nil)
  }

  @Test("Deleting the Lock password goes through LockCenter: refused while a workspace uses it")
  func deletingLockPasswordAsksLockCenter() async throws {
    let lock = try LockFixture()
    defer { lock.cleanUp() }
    #expect(lock.vault.setPassword(Self.lockPassword))
    let password = SecretItem.listed(
      service: LockPasswordStore.serviceName, account: LockPasswordStore.accountName)
    let inventory = InMemorySecretInventory(items: [password])
    let model = lock.model(providers: [], inventory: inventory)
    let workspace = UUID()
    lock.registry.registerWorkspace(workspace)
    lock.owner.grants = true

    await model.deleteSecret(password, confirmed: model.prepareDeleteSecret(password))
    #expect(lock.owner.prompts == 0)
    #expect(model.error == LockPasswordChangeResult.workspacesDepend.message)
    #expect(await inventory.items() == [password])
    #expect(lock.vault.hasPassword)

    lock.registry.unregisterWorkspace(workspace)
    lock.owner.grants = false
    await model.deleteSecret(password, confirmed: model.prepareDeleteSecret(password))
    #expect(lock.owner.prompts == 1)
    #expect(await inventory.items() == [password])
    #expect(lock.vault.hasPassword)

    lock.owner.grants = true
    await model.deleteSecret(password, confirmed: model.prepareDeleteSecret(password))
    #expect(lock.owner.prompts == 2)
    #expect(await inventory.items().isEmpty)
    #expect(!lock.vault.hasPassword)
    #expect(model.error == nil)
  }

  @Test("Deleting a workspace key asks the owner first")
  func deletingWorkspaceKeyAsksFirst() async throws {
    let lock = try LockFixture()
    defer { lock.cleanUp() }
    let key = SecretItem.listed(
      service: LockKeyStore.serviceName, account: LockKeyStore.account(for: UUID()))
    let apiKey = SecretItem(service: "ai", account: "openai", label: "openai", kind: .aiKey)
    let inventory = InMemorySecretInventory(items: [apiKey, key])
    let model = lock.model(providers: [], inventory: inventory)

    await model.deleteSecret(key, confirmed: model.prepareDeleteSecret(key))
    #expect(lock.owner.prompts == 1)
    #expect(await inventory.items() == [apiKey, key])

    lock.owner.grants = true
    await model.deleteSecret(key, confirmed: model.prepareDeleteSecret(key))
    #expect(lock.owner.prompts == 2)
    #expect(await inventory.items() == [apiKey])
  }

  private static let lockPassword = "the lock password"

  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-data-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

@MainActor
private final class HookCount {
  var count = 0
}

/// Owner authentication without a prompt: refuses until `grants`, and counts the asks
@MainActor
private final class CountingOwner: BiometricAuthenticator {
  var grants = false
  private(set) var prompts = 0

  var canUseBiometrics: Bool { false }

  func authenticate(reason: String) async -> Bool { false }

  func authenticateOwner(reason: String) async -> OwnerAuthentication? {
    prompts += 1
    guard grants else { return nil }
    return await GrantingOwnerTestAuthenticator().authenticateOwner(reason: reason)
  }
}

/// A LockCenter of the test's own: a fresh registry, an in-memory Lock password vault, a
/// counting owner and a durable list on a throwaway suite. Never the shared ones.
@MainActor
private final class LockFixture {
  let registry = LockRegistry()
  let vault = UnlockPasswordVault(
    store: InMemoryPasswordStore(), minimumLength: UnlockPasswordVault.lockMinimumLength,
    iterations: 1_000)
  let owner = CountingOwner()
  let suiteName = "ace.thi.Dblore.tests.dataSettingsLock.\(UUID().uuidString)"
  let defaults: UserDefaults
  let center: LockCenter

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suiteName))
    center = LockCenter(
      registry: registry, lockVault: vault, prompter: RefusingUnlockPrompter(),
      ownerAuthenticator: owner, sessions: WorkspaceLockSessions(),
      lockedWorkspaces: LockedWorkspaceList(defaults: defaults))
  }

  func model(
    providers: [any LocalDataProvider], inventory: any SecretInventory
  ) -> DataSettingsModel {
    DataSettingsModel(
      providers: providers, inventory: inventory,
      outsideServers: OutsideMCPServerStore(
        defaults: defaults, tokens: InMemoryOutsideMCPTokenStore()),
      mcpServerTokenDeleted: {}, lockCenter: center, recentWorkspaces: { [] })
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

/// Both summaries must enter `arrive` before either returns, so a sequential refresh stalls.
private final class SummaryLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var arrived = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let expected: Int

  init(expected: Int) {
    self.expected = expected
  }

  func arrive() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      arrived += 1
      if arrived >= expected {
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        continuation.resume()
        for waiter in pending {
          waiter.resume()
        }
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

private final class Store: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String
  private var clears = 0
  private var imports = 0
  private var failing = false
  let bytes: Int64
  let itemCount: Int
  let latch: SummaryLatch?

  init(text: String, bytes: Int64, itemCount: Int, latch: SummaryLatch? = nil) {
    stored = text
    self.bytes = bytes
    self.itemCount = itemCount
    self.latch = latch
  }

  var text: String {
    lock.withLock { stored }
  }

  var clearCount: Int {
    lock.withLock { clears }
  }

  var importCount: Int {
    lock.withLock { imports }
  }

  /// `clear()` throws without clearing (a provider that refuses)
  var failsClear: Bool {
    get { lock.withLock { failing } }
    set { lock.withLock { failing = newValue } }
  }

  func replace(_ text: String) {
    lock.withLock { stored = text }
  }

  func summary() async -> LocalDataSummary {
    if let latch {
      await latch.arrive()
    }
    return LocalDataSummary(bytes: bytes, itemCount: itemCount, location: nil)
  }

  func export(to folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let body = lock.withLock { stored }
    try Data(body.utf8).write(to: folder.appendingPathComponent("item.txt"), options: .atomic)
  }

  func importData(from folder: URL) async throws {
    let body = try String(contentsOf: folder.appendingPathComponent("item.txt"), encoding: .utf8)
    lock.withLock {
      stored = body
      imports += 1
    }
  }

  func clear() throws {
    try lock.withLock {
      if failing { throw DatabaseError.connectionLocked }
      stored = ""
      clears += 1
    }
  }
}

private struct FakeProvider: LocalDataProvider {
  var category: LocalDataCategory
  var store: Store

  func summary() async -> LocalDataSummary {
    await store.summary()
  }

  func export(to folder: URL) async throws {
    try await store.export(to: folder)
  }

  func importData(from folder: URL) async throws {
    try await store.importData(from: folder)
  }

  func clear() async throws {
    try store.clear()
  }
}
