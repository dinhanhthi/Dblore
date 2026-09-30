// LocalDataBackupTests.swift
// A .dblorebackup package round-trips local data and never keeps a secret.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Local data backup", .serialized)
struct LocalDataBackupTests {
  private let created = Date(timeIntervalSince1970: 1_700_000_000)
  private let createdStamp = "2023-11-14T22:13:20Z"

  @Test("Several categories round-trip through a backup package")
  func roundTrip() async throws {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let root = try makeRoot()
    defer { remove(root) }
    let suite = makeSuite()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }

    let databaseURL = root.appendingPathComponent("History.sqlite")
    let store = try QueryHistoryStore(url: databaseURL)
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(
      QueryHistoryEntry(
        id: 0, sql: "SELECT 1", executedAt: when, durationMs: 3, rowCount: 1, status: .success,
        errorMessage: nil, connectionKey: "k", connectionLabel: "label", workspaceID: nil,
        workspaceName: nil, source: .cell))
    let original = try await store.search(text: "", scope: .all, limit: 10, offset: 0)

    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let closed = logs.appendingPathComponent("dblore-1999-01-01.log")
    try "old-line\n".write(to: closed, atomically: true, encoding: .utf8)

    setString("dark", forKey: "app.settings.themePreference", suite: suite)

    let providers: [any LocalDataProvider] = [
      QueryHistoryLocalDataProvider(store: store, fileURL: databaseURL),
      LogsLocalDataProvider(root: logs),
      AppSettingsLocalDataProvider(defaults: suite.defaults, domainName: suite.name),
    ]
    let categories: [LocalDataCategory] = [.queryHistory, .logs, .appSettings]
    let package = root.appendingPathComponent("Sample.dblorebackup", isDirectory: true)
    try await LocalDataBackup.export(
      categories: categories, providers: providers, to: package, appVersion: "9.2.0",
      created: created)

    var isPackage: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: package.path, isDirectory: &isPackage))
    #expect(isPackage.boolValue)
    for category in categories {
      var isFolder: ObjCBool = false
      let folder = package.appendingPathComponent(category.rawValue, isDirectory: true)
      #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder))
      #expect(isFolder.boolValue)
    }

    var summaries: [LocalDataCategory: LocalDataSummary] = [:]
    for provider in providers {
      summaries[provider.category] = await provider.summary()
    }
    let manifest = try LocalDataBackup.inspect(package)
    #expect(manifest.formatVersion == 1)
    #expect(manifest.appVersion == "9.2.0")
    #expect(manifest.created == createdStamp)
    #expect(manifest.categories.map(\.id) == categories.map(\.rawValue))
    for entry in manifest.categories {
      let category = try #require(LocalDataCategory(rawValue: entry.id))
      let summary = try #require(summaries[category])
      #expect(entry.itemCount == summary.itemCount)
      #expect(entry.byteSize == summary.bytes)
    }

    for provider in providers {
      try await provider.clear()
    }
    #expect(try await store.count() == 0)
    #expect(FileManager.default.fileExists(atPath: closed.path) == false)
    #expect(string(forKey: "app.settings.themePreference", suite: suite) == nil)

    try await LocalDataBackup.import(package, categories: categories, providers: providers)
    let restored = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(restored == original)
    #expect(try String(contentsOf: closed, encoding: .utf8) == "old-line\n")
    #expect(string(forKey: "app.settings.themePreference", suite: suite) == "dark")
  }

  @Test("Export all omits local models unless that category is requested")
  func modelsExcludedUnlessRequested() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let suite = makeSuite()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let fixtures = try StorageFixtures(root: root, suite: suite)
    try Data("model-weights".utf8).write(to: fixtures.models.appendingPathComponent("weights.bin"))
    try "log-line\n".write(
      to: fixtures.logs.appendingPathComponent("dblore-1999-01-01.log"), atomically: true,
      encoding: .utf8)
    let providers = try fixtures.providers()

    let exportAll = LocalDataBackup.exportAllCategories()
    #expect(exportAll == LocalDataCategory.allCases.filter { !$0.isLarge })
    #expect(!exportAll.contains(.localModels))
    #expect(
      LocalDataBackup.exportAllCategories(including: [.localModels]) == LocalDataCategory.allCases)

    let without = root.appendingPathComponent("WithoutModels.dblorebackup", isDirectory: true)
    try await LocalDataBackup.export(
      categories: exportAll, providers: providers, to: without, appVersion: "9.2.0",
      created: created)
    #expect(FileManager.default.fileExists(atPath: without.appendingPathComponent("logs").path))
    #expect(
      FileManager.default.fileExists(atPath: without.appendingPathComponent("queryHistory").path))
    #expect(
      FileManager.default.fileExists(atPath: without.appendingPathComponent("localModels").path)
        == false)
    let withoutManifest = try LocalDataBackup.inspect(without)
    #expect(withoutManifest.categories.map(\.id).contains("localModels") == false)

    let withModels = root.appendingPathComponent("WithModels.dblorebackup", isDirectory: true)
    try await LocalDataBackup.export(
      categories: LocalDataBackup.exportAllCategories(including: [.localModels]),
      providers: providers, to: withModels, appVersion: "9.2.0", created: created)
    let copied = withModels.appendingPathComponent("localModels/weights.bin")
    #expect(try Data(contentsOf: copied) == Data("model-weights".utf8))
    let withManifest = try LocalDataBackup.inspect(withModels)
    #expect(withManifest.categories.map(\.id).contains("localModels"))
  }

  @Test("formatVersion 2 is rejected and provider data stays unchanged")
  func unsupportedVersionLeavesData() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let memory = TextMemory("keep")
    let provider = TextProvider(category: .logs, memory: memory, contents: "keep")
    let package = root.appendingPathComponent("Future.dblorebackup", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let manifest = """
      {
        "appVersion": "9.0.0",
        "categories": [{"byteSize": 4, "id": "logs", "itemCount": 1}],
        "created": "\(createdStamp)",
        "formatVersion": 2
      }
      """
    try manifest.write(
      to: package.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    await #expect(throws: LocalDataBackupError.unsupportedVersion(2)) {
      try await LocalDataBackup.import(package, categories: [.logs], providers: [provider])
    }
    #expect(memory.importCount == 0)
    #expect(memory.text == "keep")
  }

  @Test("A missing or corrupt category folder aborts before any import")
  func invalidFolderAbortsBeforeImport() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let logs = TextMemory("logs")
    let settings = TextMemory("settings")
    let providers: [any LocalDataProvider] = [
      TextProvider(category: .logs, memory: logs, contents: "logs"),
      TextProvider(category: .appSettings, memory: settings, contents: "settings"),
    ]
    let categories: [LocalDataCategory] = [.logs, .appSettings]
    let package = root.appendingPathComponent("Partial.dblorebackup", isDirectory: true)
    try await LocalDataBackup.export(
      categories: categories, providers: providers, to: package, appVersion: "9.2.0",
      created: created)
    #expect(try LocalDataBackup.inspect(package).formatVersion == 1)

    let missing = root.appendingPathComponent("Missing.dblorebackup", isDirectory: true)
    try FileManager.default.copyItem(at: package, to: missing)
    try FileManager.default.removeItem(at: missing.appendingPathComponent("appSettings"))
    await #expect(throws: LocalDataBackupError.missingCategory(.appSettings)) {
      try await LocalDataBackup.import(missing, categories: categories, providers: providers)
    }
    #expect(logs.importCount == 0)
    #expect(settings.importCount == 0)
    #expect(logs.text == "logs")
    #expect(settings.text == "settings")

    let corrupt = root.appendingPathComponent("Corrupt.dblorebackup", isDirectory: true)
    try FileManager.default.copyItem(at: package, to: corrupt)
    let settingsFolder = corrupt.appendingPathComponent("appSettings")
    for file in try FileManager.default.contentsOfDirectory(
      at: settingsFolder, includingPropertiesForKeys: nil)
    {
      try FileManager.default.removeItem(at: file)
    }
    await #expect(throws: LocalDataBackupError.corruptCategory(.appSettings)) {
      try await LocalDataBackup.import(corrupt, categories: categories, providers: providers)
    }
    #expect(logs.importCount == 0)
    #expect(settings.importCount == 0)
    #expect(logs.text == "logs")
    #expect(settings.text == "settings")
  }

  @Test(
    "A planted secret aborts export and the package is not left behind",
    arguments: [
      "sk-ant-secret",
      "prefix sk-live-value",
      "aaaaaaaa.bbbbbbbb.cccccccc",
      #"{"password":"hunter2"}"#,
      #"{"apiKey":"k"}"#,
      #"{"api_key":"k"}"#,
      #"{"token":"k"}"#,
      #"{"config":{"password":"nested"}}"#,
    ])
  func plantedSecretIsDeleted(payload: String) async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let provider = TextProvider(category: .logs, memory: TextMemory(payload), contents: payload)
    let package = root.appendingPathComponent("Secret.dblorebackup", isDirectory: true)
    await #expect(throws: LocalDataBackupError.secretDetected) {
      try await LocalDataBackup.export(
        categories: [.logs], providers: [provider], to: package, appVersion: "9.2.0",
        created: created)
    }
    #expect(FileManager.default.fileExists(atPath: package.path) == false)
    let leftover = try FileManager.default.subpathsOfDirectory(atPath: root.path)
    for relative in leftover {
      let url = root.appendingPathComponent(relative)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      #expect(!text.contains(payload))
    }
  }

  @Test("Empty credential values and prose stay in the package")
  func benignContentRemains() async throws {
    let payloads = [
      #"{"password":""}"#,
      #"{"token":1}"#,
      "the password field is omitted",
    ]
    for payload in payloads {
      let root = try makeRoot()
      defer { remove(root) }
      let provider = TextProvider(category: .logs, memory: TextMemory(payload), contents: payload)
      let package = root.appendingPathComponent("Benign.dblorebackup", isDirectory: true)
      try await LocalDataBackup.export(
        categories: [.logs], providers: [provider], to: package, appVersion: "9.2.0",
        created: created)
      #expect(FileManager.default.fileExists(atPath: package.path))
      let note = package.appendingPathComponent("logs/item.txt")
      #expect(try String(contentsOf: note, encoding: .utf8) == payload)
    }
  }

  @Test("The backup package is an exported directory UTI")
  func exportedType() throws {
    let plist = try source("Dblore/Info.plist")
    #expect(plist.contains("ace.thi.dblore.workspace"))
    #expect(plist.contains("ace.thi.dblore.document"))
    #expect(plist.contains("public.sql"))
    #expect(plist.contains("ace.thi.dblore.backup"))
    #expect(plist.contains("dblorebackup"))
    #expect(plist.contains("com.apple.package"))
  }

  // MARK: - Fixtures

  private struct Suite {
    var name: String
    var defaults: UserDefaults
  }

  private func makeSuite() -> Suite {
    let name = "ace.thi.Dblore.tests.backup.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return Suite(name: name, defaults: defaults)
  }

  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-backup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func setString(_ value: String, forKey key: String, suite: Suite) {
    var domain = suite.defaults.persistentDomain(forName: suite.name) ?? [:]
    domain[key] = value
    suite.defaults.setPersistentDomain(domain, forName: suite.name)
  }

  private func string(forKey key: String, suite: Suite) -> String? {
    suite.defaults.persistentDomain(forName: suite.name)?[key] as? String
  }

  private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
  }

  /// Temp files and a private defaults domain. Nothing here reads the user's library.
  private struct StorageFixtures {
    var root: URL
    var suite: Suite
    var history: URL
    var chats: URL
    var logs: URL
    var models: URL

    init(root: URL, suite: Suite) throws {
      self.root = root
      self.suite = suite
      history = root.appendingPathComponent("History.sqlite")
      chats = root.appendingPathComponent("Chats", isDirectory: true)
      logs = root.appendingPathComponent("Logs", isDirectory: true)
      models = root.appendingPathComponent("Models", isDirectory: true)
      for folder in [chats, logs, models] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      }
    }

    func providers() throws -> [any LocalDataProvider] {
      let store = try QueryHistoryStore(url: history)
      let defaults = suite.defaults
      let name = suite.name
      return [
        QueryHistoryLocalDataProvider(store: store, fileURL: history),
        ConnectionHistoryLocalDataProvider(defaults: defaults, domainName: name),
        RecentItemsLocalDataProvider(defaults: defaults, domainName: name),
        OpenTabsLocalDataProvider(defaults: defaults, domainName: name),
        SavedFiltersLocalDataProvider(defaults: defaults, domainName: name),
        SchemaLayoutLocalDataProvider(defaults: defaults, domainName: name),
        AIChatsLocalDataProvider(root: chats),
        AISettingsLocalDataProvider(defaults: defaults, domainName: name),
        LocalModelsLocalDataProvider(root: models),
        LogsLocalDataProvider(root: logs),
        AppSettingsLocalDataProvider(defaults: defaults, domainName: name),
      ]
    }
  }
}

/// Keeps `localDataChanged` observers from seeing posts made by another suite.
final class LocalDataNotificationGate: @unchecked Sendable {
  static let shared = LocalDataNotificationGate()
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let state = NSLock()

  func acquire() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      state.lock()
      if !held {
        held = true
        state.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        state.unlock()
      }
    }
  }

  func release() {
    state.lock()
    if waiters.isEmpty {
      held = false
      state.unlock()
    } else {
      let next = waiters.removeFirst()
      state.unlock()
      next.resume()
    }
  }
}

private final class TextMemory: @unchecked Sendable {
  var text: String
  var importCount = 0

  init(_ text: String) {
    self.text = text
  }
}

private struct TextProvider: LocalDataProvider {
  var category: LocalDataCategory
  var memory: TextMemory
  var contents: String

  func summary() async -> LocalDataSummary {
    LocalDataSummary(
      bytes: Int64(contents.utf8.count), itemCount: contents.isEmpty ? 0 : 1, location: nil)
  }

  func export(to folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: folder.appendingPathComponent("item.txt"))
  }

  func importData(from folder: URL) async throws {
    memory.importCount += 1
    memory.text = try String(contentsOf: folder.appendingPathComponent("item.txt"), encoding: .utf8)
  }

  func clear() async throws {
    memory.text = ""
  }
}
