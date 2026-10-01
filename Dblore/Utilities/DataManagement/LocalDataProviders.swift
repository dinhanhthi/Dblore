// LocalDataProviders.swift
// One provider per local-data category. Exports omit passwords, API keys, and tokens.

import Foundation

/// `UserDefaults` is thread-safe. This box lets a `Sendable` provider hold one.
nonisolated struct LocalDefaultsClient: @unchecked Sendable {
  var defaults: UserDefaults
  var domainName: String

  func domain() -> [String: Any] {
    defaults.persistentDomain(forName: domainName) ?? [:]
  }

  func setDomain(_ domain: [String: Any]) {
    defaults.setPersistentDomain(domain, forName: domainName)
  }
}

nonisolated enum LocalDataNotifications {
  static func post(_ category: LocalDataCategory) {
    NotificationCenter.default.post(
      name: .localDataChanged,
      object: nil,
      userInfo: [LocalDataCategory.userInfoKey: category.rawValue]
    )
  }
}

nonisolated enum LocalDataFiles {
  static func create(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  static func write(_ data: Data?, named name: String, to folder: URL) throws {
    try create(folder)
    guard let data else { return }
    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
  }

  static func read(named name: String, from folder: URL) -> Data? {
    let url = folder.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? Data(contentsOf: url)
  }

  static func children(of root: URL) -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return
      (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []
  }

  static func exportChildren(
    of root: URL, to folder: URL, matching: (URL) -> Bool = { _ in true }
  ) throws {
    try create(folder)
    for child in children(of: root) where matching(child) {
      let destination = folder.appendingPathComponent(child.lastPathComponent)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: child, to: destination)
    }
  }

  static func replaceChildren(
    of root: URL, with folder: URL, matching: (URL) -> Bool = { _ in true }
  ) throws {
    try create(root)
    for child in children(of: root) where matching(child) {
      try FileManager.default.removeItem(at: child)
    }
    for child in children(of: folder) where matching(child) {
      let destination = root.appendingPathComponent(child.lastPathComponent)
      try FileManager.default.copyItem(at: child, to: destination)
    }
  }

  static func byteCount(of url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey, .isDirectoryKey, .fileSizeKey,
    ])
    if values?.isDirectory == true {
      return children(of: url).reduce(0) { $0 + byteCount(of: $1) }
    }
    guard values?.isRegularFile == true else { return 0 }
    return Int64(values?.fileSize ?? 0)
  }
}

nonisolated enum LocalDataJSON {
  static func arrayCount(_ data: Data?) -> Int {
    guard let data, let array = try? JSONSerialization.jsonObject(with: data) as? NSArray else {
      return 0
    }
    return array.count
  }

  static func keyedArrayCount(_ data: Data?) -> Int {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
    else { return 0 }
    var count = 0
    for key in object.allKeys {
      if let values = object[key] as? NSArray {
        count += values.count
      }
    }
    return count
  }

  static func tabCount(_ data: Data?) -> Int {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
      let tabs = object["tabs"] as? NSArray
    else { return 0 }
    return tabs.count
  }

  static func positionCount(_ value: Any?) -> Int {
    guard let connections = value as? NSDictionary else { return 0 }
    var count = 0
    for key in connections.allKeys {
      if let positions = connections[key] as? NSArray {
        count += positions.count
      }
    }
    return count
  }

  static func isPasswordKey(_ key: String) -> Bool {
    key.range(of: "password", options: .caseInsensitive) != nil
  }

  static func isCredentialKey(_ key: String) -> Bool {
    let lower = key.lowercased()
    if lower.contains("password") || lower.contains("secret") || lower.contains("token") {
      return true
    }
    return lower.contains("apikey") || lower.contains("api_key") || lower.contains("api-key")
  }

  static func managesAppSetting(_ key: String) -> Bool {
    guard key.hasPrefix("app.settings.") else { return false }
    let lower = key.lowercased()
    return !lower.contains("password") && !lower.contains("secret")
  }

  /// JSON with matching keys removed. `nil` input stays `nil`. Unreadable JSON is dropped.
  static func omitting(_ data: Data?, keysSatisfying predicate: (String) -> Bool) -> Data? {
    guard let data else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let stripped = propertyList(object, omitting: predicate)
    guard JSONSerialization.isValidJSONObject(stripped),
      let encoded = try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
    else { return nil }
    return encoded
  }

  static func jsonData(from value: Any) -> Data? {
    let normalized = propertyList(value, omitting: { _ in false })
    guard JSONSerialization.isValidJSONObject(normalized) else { return nil }
    return try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
  }

  static func propertyList(_ value: Any, omitting predicate: (String) -> Bool) -> Any {
    if let dictionary = value as? NSDictionary {
      var copy: [String: Any] = [:]
      for (key, nested) in dictionary {
        guard let key = key as? String, !predicate(key) else { continue }
        copy[key] = propertyList(nested, omitting: predicate)
      }
      return copy
    }
    if let array = value as? NSArray {
      return array.map { propertyList($0, omitting: predicate) }
    }
    return value
  }
}

nonisolated struct QueryHistoryLocalDataProvider: LocalDataProvider {
  var store: QueryHistoryStore
  var fileURL: URL
  var category: LocalDataCategory { .queryHistory }

  func summary() async -> LocalDataSummary {
    let count = (try? await store.count()) ?? 0
    let bytes = (try? await store.fileSize()) ?? 0
    return LocalDataSummary(bytes: bytes, itemCount: count, location: fileURL)
  }

  func export(to folder: URL) async throws {
    try LocalDataFiles.create(folder)
    try await store.exportJSON(to: folder.appendingPathComponent("history.json"))
  }

  func importData(from folder: URL) async throws {
    try await store.importJSON(from: folder.appendingPathComponent("history.json"), replace: true)
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    try await store.clear()
    LocalDataNotifications.post(category)
  }
}

nonisolated struct ConnectionHistoryLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .connectionHistory }

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let stored = SessionManager.storedHistory(
      defaults: client.defaults, domainName: client.domainName)
    let bytes = Int64((stored.history?.count ?? 0) + (stored.legacy?.count ?? 0))
    let count = LocalDataJSON.arrayCount(stored.history) + (stored.legacy == nil ? 0 : 1)
    return LocalDataSummary(bytes: bytes, itemCount: count, location: nil)
  }

  func export(to folder: URL) async throws {
    let snapshot = SessionManager.exportSnapshot(
      defaults: client.defaults, domainName: client.domainName)
    try LocalDataFiles.write(snapshot.history, named: "connectionHistory.json", to: folder)
    try LocalDataFiles.write(snapshot.legacy, named: "savedSession.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    SessionManager.replace(
      history: LocalDataFiles.read(named: "connectionHistory.json", from: folder),
      legacySession: LocalDataFiles.read(named: "savedSession.json", from: folder),
      defaults: client.defaults,
      domainName: client.domainName
    )
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    SessionManager.clearAll(defaults: client.defaults, domainName: client.domainName)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct RecentItemsLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .recentItems }

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let stored = RecentManager.storedRecents(
      defaults: client.defaults, domainName: client.domainName)
    let bytes = Int64((stored.workspaces?.count ?? 0) + (stored.bookmarks?.count ?? 0))
    let count =
      LocalDataJSON.arrayCount(stored.workspaces) + LocalDataJSON.arrayCount(stored.bookmarks)
    return LocalDataSummary(bytes: bytes, itemCount: count, location: nil)
  }

  func export(to folder: URL) async throws {
    let stored = RecentManager.exportSnapshot(
      defaults: client.defaults, domainName: client.domainName)
    try LocalDataFiles.write(stored.workspaces, named: "recentWorkspaces.json", to: folder)
    try LocalDataFiles.write(stored.bookmarks, named: "recentDocumentBookmarks.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    RecentManager.replace(
      workspaces: LocalDataFiles.read(named: "recentWorkspaces.json", from: folder),
      bookmarks: LocalDataFiles.read(named: "recentDocumentBookmarks.json", from: folder),
      defaults: client.defaults,
      domainName: client.domainName
    )
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    RecentManager.clearStoredData(defaults: client.defaults, domainName: client.domainName)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct OpenTabsLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .openTabs }

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let data = TabStateManager.storedSession(
      defaults: client.defaults, domainName: client.domainName)
    return LocalDataSummary(
      bytes: Int64(data?.count ?? 0), itemCount: LocalDataJSON.tabCount(data), location: nil)
  }

  func export(to folder: URL) async throws {
    let data = TabStateManager.exportSnapshot(
      defaults: client.defaults, domainName: client.domainName)
    try LocalDataFiles.write(data, named: "tabSession.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    TabStateManager.replace(
      LocalDataFiles.read(named: "tabSession.json", from: folder),
      defaults: client.defaults,
      domainName: client.domainName
    )
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    TabStateManager.clearAll(defaults: client.defaults, domainName: client.domainName)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct SavedFiltersLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .savedFilters }

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let stored = SavedFilterStore.storedData(
      defaults: client.defaults, domainName: client.domainName)
    let bytes = Int64((stored.filters?.count ?? 0) + (stored.highlights?.count ?? 0))
    let count =
      LocalDataJSON.keyedArrayCount(stored.filters)
      + LocalDataJSON.keyedArrayCount(stored.highlights)
    return LocalDataSummary(bytes: bytes, itemCount: count, location: nil)
  }

  func export(to folder: URL) async throws {
    let stored = SavedFilterStore.exportSnapshot(
      defaults: client.defaults, domainName: client.domainName)
    try LocalDataFiles.write(stored.filters, named: "savedFilters.json", to: folder)
    try LocalDataFiles.write(stored.highlights, named: "savedHighlights.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    SavedFilterStore.replace(
      filters: LocalDataFiles.read(named: "savedFilters.json", from: folder),
      highlights: LocalDataFiles.read(named: "savedHighlights.json", from: folder),
      defaults: client.defaults,
      domainName: client.domainName
    )
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    SavedFilterStore.clearAll(defaults: client.defaults, domainName: client.domainName)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct SchemaLayoutLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .schemaLayout }

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let positions = SchemaPositionsStore.storedPositions(
      defaults: client.defaults, domainName: client.domainName)
    let bytes = positions.flatMap { LocalDataJSON.jsonData(from: $0)?.count } ?? 0
    return LocalDataSummary(
      bytes: Int64(bytes), itemCount: LocalDataJSON.positionCount(positions), location: nil)
  }

  func export(to folder: URL) async throws {
    let positions = SchemaPositionsStore.exportSnapshot(
      defaults: client.defaults, domainName: client.domainName)
    let data = positions.flatMap { LocalDataJSON.jsonData(from: $0) }
    try LocalDataFiles.write(data, named: "nodePositions.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    let data = LocalDataFiles.read(named: "nodePositions.json", from: folder)
    let positions = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
      .map { LocalDataJSON.propertyList($0, omitting: { _ in false }) }
    SchemaPositionsStore.replace(
      positions, defaults: client.defaults, domainName: client.domainName)
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    SchemaPositionsStore.clearAll(defaults: client.defaults, domainName: client.domainName)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct AIChatsLocalDataProvider: LocalDataProvider {
  var root: URL
  var category: LocalDataCategory { .aiChats }

  func summary() async -> LocalDataSummary {
    let files = AIConversationStore.conversationFiles(in: root)
    let bytes = files.reduce(Int64(0)) { $0 + LocalDataFiles.byteCount(of: $1) }
    let count = files.reduce(0) { partial, url in
      partial + LocalDataJSON.arrayCount(try? Data(contentsOf: url))
    }
    return LocalDataSummary(bytes: bytes, itemCount: count, location: root)
  }

  func export(to folder: URL) async throws {
    try AIConversationStore.export(from: root, to: folder)
  }

  func importData(from folder: URL) async throws {
    try AIConversationStore.replace(root: root, with: folder)
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    try AIConversationStore.clear(root: root)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct AISettingsLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .aiSettings }

  private static let key = "app.settings.aiConfiguration"

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let data = stored()
    return LocalDataSummary(
      bytes: Int64(data?.count ?? 0), itemCount: data == nil ? 0 : 1, location: nil)
  }

  func export(to folder: URL) async throws {
    let stripped = LocalDataJSON.omitting(stored(), keysSatisfying: LocalDataJSON.isCredentialKey)
    try LocalDataFiles.write(stripped, named: "aiConfiguration.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    let data = LocalDataFiles.read(named: "aiConfiguration.json", from: folder)
    let stripped = LocalDataJSON.omitting(data, keysSatisfying: LocalDataJSON.isCredentialKey)
    write(stripped)
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    write(nil)
    LocalDataNotifications.post(category)
  }

  private func stored() -> Data? {
    client.domain()[Self.key] as? Data
  }

  private func write(_ data: Data?) {
    var domain = client.domain()
    if let data {
      domain[Self.key] = data
    } else {
      domain.removeValue(forKey: Self.key)
    }
    client.setDomain(domain)
  }
}

nonisolated struct LocalModelsLocalDataProvider: LocalDataProvider {
  var root: URL
  var category: LocalDataCategory { .localModels }

  func summary() async -> LocalDataSummary {
    let items = LocalDataFiles.children(of: root)
    let bytes = items.reduce(Int64(0)) { $0 + LocalDataFiles.byteCount(of: $1) }
    return LocalDataSummary(bytes: bytes, itemCount: items.count, location: root)
  }

  func export(to folder: URL) async throws {
    try LocalDataFiles.exportChildren(of: root, to: folder)
  }

  func importData(from folder: URL) async throws {
    try LocalDataFiles.replaceChildren(of: root, with: folder)
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    for child in LocalDataFiles.children(of: root) {
      try FileManager.default.removeItem(at: child)
    }
    LocalDataNotifications.post(category)
  }
}

nonisolated struct LogsLocalDataProvider: LocalDataProvider {
  var root: URL
  var category: LocalDataCategory { .logs }

  func summary() async -> LocalDataSummary {
    let files = AppLogger.logFiles(in: root)
    let bytes = files.reduce(Int64(0)) { $0 + LocalDataFiles.byteCount(of: $1) }
    return LocalDataSummary(bytes: bytes, itemCount: files.count, location: root)
  }

  func export(to folder: URL) async throws {
    try LocalDataFiles.exportChildren(of: root, to: folder) {
      $0.pathExtension.lowercased() == "log"
    }
  }

  func importData(from folder: URL) async throws {
    try LocalDataFiles.replaceChildren(of: root, with: folder) {
      $0.pathExtension.lowercased() == "log"
    }
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    try AppLogger.clearLogFiles(in: root)
    LocalDataNotifications.post(category)
  }
}

nonisolated struct AppSettingsLocalDataProvider: LocalDataProvider {
  var client: LocalDefaultsClient
  var category: LocalDataCategory { .appSettings }

  init(defaults: UserDefaults, domainName: String) {
    client = LocalDefaultsClient(defaults: defaults, domainName: domainName)
  }

  func summary() async -> LocalDataSummary {
    let managed = managedSettings()
    let bytes = LocalDataJSON.jsonData(from: managed)?.count ?? 0
    return LocalDataSummary(bytes: Int64(bytes), itemCount: managed.count, location: nil)
  }

  func export(to folder: URL) async throws {
    try LocalDataFiles.write(
      LocalDataJSON.jsonData(from: managedSettings()), named: "appSettings.json", to: folder)
  }

  func importData(from folder: URL) async throws {
    let data = LocalDataFiles.read(named: "appSettings.json", from: folder)
    let imported =
      data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    var domain = client.domain()
    for key in domain.keys where LocalDataJSON.managesAppSetting(key) {
      domain.removeValue(forKey: key)
    }
    for (key, value) in imported where LocalDataJSON.managesAppSetting(key) {
      domain[key] = value
    }
    client.setDomain(domain)
    LocalDataNotifications.post(category)
  }

  func clear() async throws {
    var domain = client.domain()
    for key in domain.keys where LocalDataJSON.managesAppSetting(key) {
      domain.removeValue(forKey: key)
    }
    client.setDomain(domain)
    LocalDataNotifications.post(category)
  }

  private func managedSettings() -> [String: Any] {
    client.domain().filter { LocalDataJSON.managesAppSetting($0.key) }
  }
}
