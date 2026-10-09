// DataSettingsModelTests.swift
// Data settings loads summaries and refuses destructive actions without confirmation.

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

  @Test("Clear all removes secrets only when that flag is confirmed")
  func clearAllRespectsSecretsFlag() async {
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
    let inventory = InMemorySecretInventory(items: [database, key, certificate, ssh, hostKey])
    let model = DataSettingsModel(
      providers: [FakeProvider(category: .logs, store: logs)],
      inventory: inventory)

    let mismatched = model.prepareClearAll(includeSecrets: false)
    await model.clearAll(includeSecrets: true, confirmed: mismatched)
    #expect(logs.clearCount == 0)
    #expect(await inventory.items() == [database, key, certificate, ssh, hostKey])

    let keepSecrets = model.prepareClearAll(includeSecrets: false)
    await model.clearAll(includeSecrets: false, confirmed: keepSecrets)
    #expect(logs.clearCount == 1)
    #expect(await inventory.items() == [database, key, certificate, ssh, hostKey])

    let removeSecrets = model.prepareClearAll(includeSecrets: true)
    await model.clearAll(includeSecrets: true, confirmed: removeSecrets)
    #expect(logs.clearCount == 2)
    #expect(await inventory.items().isEmpty)
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

    let model = DataSettingsModel(providers: providers, inventory: InMemorySecretInventory())
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

  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-data-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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

  func clear() {
    lock.withLock {
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
    store.clear()
  }
}
