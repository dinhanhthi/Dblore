// LocalDataProvidersTests.swift
// Each local-data provider reports a summary and round-trips through export, clear, and import.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Local data providers", .serialized)
struct LocalDataProvidersTests {
  @Test("Query history summary, round-trip, and an unrelated preference")
  func queryHistory() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let databaseURL = root.appendingPathComponent("History.sqlite")
    let store = try QueryHistoryStore(url: databaseURL)
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.record(
      QueryHistoryEntry(
        id: 0, sql: "SELECT 1", executedAt: when, durationMs: 3, rowCount: 1, status: .success,
        errorMessage: nil, connectionKey: "k", connectionLabel: "label", workspaceID: nil,
        workspaceName: nil, source: .cell))
    let original = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    let provider = QueryHistoryLocalDataProvider(store: store, fileURL: databaseURL)
    let suite = makeSuite()
    setUnrelated(suite)

    let summary = await provider.summary()
    #expect(summary.itemCount == 1)
    #expect(summary.bytes == (try await store.fileSize()))
    #expect(summary.location == databaseURL)

    let folder = try makeFolder(in: root)
    let notes = try await recordChanges {
      try await provider.export(to: folder)
      try await provider.clear()
      #expect(try await store.count() == 0)
      try await provider.importData(from: folder)
    }
    #expect(
      notes == [LocalDataCategory.queryHistory.rawValue, LocalDataCategory.queryHistory.rawValue])
    let restored = try await store.search(text: "", scope: .all, limit: 10, offset: 0)
    #expect(restored == original)
    expectUnrelated(suite)
  }

  @Test("Connection history omits passwords and restores the other fields")
  func connectionHistory() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let secret = "super-secret-db-password"
    let history = try historyJSON(host: "db.example", password: secret)
    let legacy = try configJSON(host: "legacy.example", password: secret)
    setData(history, forKey: "ace.thi.dblore.connectionHistory", suite: suite)
    setData(legacy, forKey: "ace.thi.dblore.savedSession", suite: suite)
    let provider = ConnectionHistoryLocalDataProvider(
      defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 2)
    #expect(summary.bytes > 0)
    #expect(summary.location == nil)

    let folder = try makeFolder()
    defer { remove(folder) }
    let notes = try await recordChanges {
      try await provider.export(to: folder)
      let exported = try textFiles(in: folder)
      #expect(!exported.contains(secret))
      #expect(!exported.contains("\"password\""))
      try await provider.clear()
      #expect(data(forKey: "ace.thi.dblore.connectionHistory", suite: suite) == nil)
      #expect(data(forKey: "ace.thi.dblore.savedSession", suite: suite) == nil)
      try await provider.importData(from: folder)
    }
    #expect(notes == [provider.category.rawValue, provider.category.rawValue])
    let restored = try textOf(data(forKey: "ace.thi.dblore.connectionHistory", suite: suite))
    let restoredLegacy = try textOf(data(forKey: "ace.thi.dblore.savedSession", suite: suite))
    #expect(restored.contains("db.example"))
    #expect(restoredLegacy.contains("legacy.example"))
    #expect(!restored.contains(secret))
    #expect(!restoredLegacy.contains(secret))
    expectUnrelated(suite)
  }

  @Test("Recent workspaces and file bookmarks round-trip")
  func recentItems() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let entry = WorkspaceHistoryEntry(
      fileURL: URL(fileURLWithPath: "/tmp/notes.sqlws"), name: "Notes", tabCount: 2)
    let workspaces = try JSONEncoder().encode([entry])
    let bookmarks = Data(#"[{"path":"/tmp/a.sql"},{"path":"/tmp/b.sql"}]"#.utf8)
    setData(workspaces, forKey: "ace.thi.dblore.recentWorkspaces", suite: suite)
    setData(bookmarks, forKey: "ace.thi.dblore.recentDocumentBookmarks", suite: suite)
    let provider = RecentItemsLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 3)
    #expect(summary.bytes == Int64(workspaces.count + bookmarks.count))
    #expect(summary.location == nil)

    try await expectRoundTrip(provider, category: .recentItems) {
      #expect(data(forKey: "ace.thi.dblore.recentWorkspaces", suite: suite) == nil)
      #expect(data(forKey: "ace.thi.dblore.recentDocumentBookmarks", suite: suite) == nil)
    } afterImport: {
      #expect(data(forKey: "ace.thi.dblore.recentWorkspaces", suite: suite) == workspaces)
      #expect(data(forKey: "ace.thi.dblore.recentDocumentBookmarks", suite: suite) == bookmarks)
    }
    expectUnrelated(suite)
  }

  @Test("Open tab session round-trips")
  func openTabs() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let tab = TabItem(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      fileURL: URL(fileURLWithPath: "/tmp/query.sql"), documentType: .sqlFile, title: "query.sql")
    let state = TabSessionState(tabs: [tab], activeTabId: tab.id)
    let encoded = try JSONEncoder().encode(state)
    setData(encoded, forKey: "Dblore.TabSession", suite: suite)
    let provider = OpenTabsLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 1)
    #expect(summary.bytes == Int64(encoded.count))
    #expect(summary.location == nil)

    try await expectRoundTrip(provider, category: .openTabs) {
      #expect(data(forKey: "Dblore.TabSession", suite: suite) == nil)
    } afterImport: {
      #expect(data(forKey: "Dblore.TabSession", suite: suite) == encoded)
    }
    expectUnrelated(suite)
  }

  @Test("Saved filters, highlights, Mongo queries, pipelines and view preferences round-trip")
  func savedFilters() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let store = SavedFilterStore(defaults: suite.defaults)
    let key = SavedFilterStore.key(
      for: ConnectionConfig(host: "h", port: 5432, database: "app"), schema: "public", name: "users"
    )
    let filter = TableFilter(conditions: [
      FilterCondition(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, column: "id", op: .equals,
        value: "1")
    ])
    store.save(filter, named: "open", for: key)
    store.saveHighlight(
      TableHighlight(filter: filter, color: .yellow, style: .cell), named: "paint", for: key)
    store.saveMongoQuery(filter: "{a: 1}", options: .init(), named: "q", for: key)
    store.saveMongoPipeline(
      stages: [SavedMongoPipeline.Stage(operator: "$match", body: "{}", isEnabled: true)],
      options: .init(), named: "p", for: key)
    store.saveMongoViewPreference(MongoViewPreference(mode: .json, pageSize: 250), for: key)
    let keys = [
      "ace.thi.dblore.savedFilters", "ace.thi.dblore.savedHighlights",
      "ace.thi.dblore.savedMongoQueries", "ace.thi.dblore.savedMongoPipelines",
      "ace.thi.dblore.mongoViewPreferences",
    ]
    let saved = keys.map { data(forKey: $0, suite: suite) }
    #expect(saved.allSatisfy { $0 != nil })
    let provider = SavedFiltersLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 5)
    #expect(summary.bytes == Int64(saved.reduce(0) { $0 + ($1?.count ?? 0) }))
    #expect(summary.location == nil)

    try await expectRoundTrip(provider, category: .savedFilters) {
      #expect(keys.allSatisfy { data(forKey: $0, suite: suite) == nil })
    } afterImport: {
      #expect(keys.map { data(forKey: $0, suite: suite) } == saved)
    }
    expectUnrelated(suite)

    // An export made before the MongoDB files existed still imports
    let older = try makeFolder()
    defer { remove(older) }
    try saved[0]!.write(to: older.appendingPathComponent("savedFilters.json"))
    try await provider.importData(from: older)
    #expect(data(forKey: keys[0], suite: suite) == saved[0])
    #expect(keys.dropFirst().allSatisfy { data(forKey: $0, suite: suite) == nil })
  }

  @Test("SQL snippets round-trip; an imported file keeps only its valid entries")
  func sqlSnippets() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let key = SQLSnippetStore.defaultsKey
    let snippets = [
      SQLSnippet(name: "Select", trigger: "sel", body: "SELECT ${1:*} FROM ${2}"),
      SQLSnippet(name: "Count", trigger: "cnt", body: "SELECT count(*) FROM $0"),
    ]
    setData(try JSONEncoder().encode(snippets), forKey: key, suite: suite)
    let provider = SQLSnippetsLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 2)
    #expect(summary.location == nil)

    try await expectRoundTrip(provider, category: .sqlSnippets) {
      #expect(data(forKey: key, suite: suite) == nil)
    } afterImport: {
      #expect(SQLSnippetStore.decode(data(forKey: key, suite: suite)) == snippets)
    }
    expectUnrelated(suite)

    // A hand-edited file: the invalid entries are not saved
    let edited = try makeFolder()
    defer { remove(edited) }
    var entries = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(snippets)) as? [Any])
    entries.append(
      ["id": UUID().uuidString, "name": "Bad", "trigger": "two words", "body": "SELECT 1"])
    entries.append("not a snippet")
    try JSONSerialization.data(withJSONObject: entries)
      .write(to: edited.appendingPathComponent("sqlSnippets.json"))
    try await provider.importData(from: edited)
    let stored = try #require(data(forKey: key, suite: suite))
    #expect((try JSONSerialization.jsonObject(with: stored) as? [Any])?.count == 2)
    #expect(SQLSnippetStore.decode(stored) == snippets)
  }

  @Test("Sidebar folders round-trip")
  func sidebarFolders() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let key = SidebarFolderStore.defaultsKey
    let folders = [
      "PostgreSQL|h|5432|app": [
        SidebarFolder(name: "Auth", schema: "public", members: ["public.users"]),
        SidebarFolder(name: "Audit", schema: "audit"),
      ]
    ]
    setData(try JSONEncoder().encode(folders), forKey: key, suite: suite)
    let provider = SidebarFoldersLocalDataProvider(
      defaults: suite.defaults, domainName: suite.name)

    #expect(await provider.summary().itemCount == 2)
    try await expectRoundTrip(provider, category: .sidebarFolders) {
      #expect(data(forKey: key, suite: suite) == nil)
    } afterImport: {
      #expect(SidebarFolderStore.decode(data(forKey: key, suite: suite)) == folders)
    }
    expectUnrelated(suite)
  }

  @Test("Schema diagram positions round-trip")
  func schemaLayout() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let positions: [String: [[String: Any]]] = [
      "localhost:5432/app": [
        ["tableQualifiedName": "public.users", "x": 10.0, "y": 20.0],
        ["tableQualifiedName": "public.orders", "x": 30.0, "y": 40.0],
      ]
    ]
    var domain = suite.defaults.persistentDomain(forName: suite.name) ?? [:]
    domain["app.schema.nodePositions"] = positions
    suite.defaults.setPersistentDomain(domain, forName: suite.name)
    let provider = SchemaLayoutLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 2)
    #expect(summary.bytes > 0)
    #expect(summary.location == nil)

    try await expectRoundTrip(provider, category: .schemaLayout) {
      #expect(
        suite.defaults.persistentDomain(forName: suite.name)?["app.schema.nodePositions"] == nil)
    } afterImport: {
      let restored =
        suite.defaults.persistentDomain(forName: suite.name)?["app.schema.nodePositions"]
        as? [String: [[String: Any]]]
      let tables = restored?["localhost:5432/app"]?.compactMap {
        $0["tableQualifiedName"] as? String
      }
      #expect(tables?.sorted() == ["public.orders", "public.users"])
    }
    expectUnrelated(suite)
  }

  @Test("AI chats round-trip as JSON files")
  func aiChats() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let chats = root.appendingPathComponent("chats", isDirectory: true)
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    let conversation = AIConversation(
      id: UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, title: "Indexes",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      messages: [
        AIChatEntry(
          id: UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, role: .user,
          text: "add an index", isError: false)
      ]
    )
    let file = chats.appendingPathComponent("\(conversation.id.uuidString).json")
    try JSONEncoder().encode([conversation]).write(to: file)
    let original = try Data(contentsOf: file)
    let provider = AIChatsLocalDataProvider(root: chats)
    let suite = makeSuite()
    setUnrelated(suite)

    let summary = await provider.summary()
    #expect(summary.itemCount == 1)
    #expect(summary.bytes == Int64(original.count))
    #expect(summary.location == chats)

    let folder = try makeFolder(in: root)
    let notes = try await recordChanges {
      try await provider.export(to: folder)
      try await provider.clear()
      #expect(
        try FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)
          .isEmpty)
      try await provider.importData(from: folder)
    }
    #expect(notes == [LocalDataCategory.aiChats.rawValue, LocalDataCategory.aiChats.rawValue])
    #expect(try Data(contentsOf: file) == original)
    expectUnrelated(suite)
  }

  @Test("AI settings export strips keys and tokens")
  func aiSettings() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    let raw = """
      {"activeProvider":"openAI","configs":{"openAI":{"baseURL":"https://api.openai.com/v1","model":"gpt-4.1","apiKey":"sk-test-secret","accessToken":"tok-test-secret"}}}
      """
    setData(Data(raw.utf8), forKey: "app.settings.aiConfiguration", suite: suite)
    let provider = AISettingsLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 1)
    #expect(summary.bytes == Int64(Data(raw.utf8).count))
    #expect(summary.location == nil)

    let folder = try makeFolder()
    defer { remove(folder) }
    try await provider.export(to: folder)
    let exported = try textFiles(in: folder)
    #expect(exported.contains("gpt-4.1"))
    #expect(!exported.contains("sk-test-secret"))
    #expect(!exported.contains("tok-test-secret"))
    #expect(!exported.contains("apiKey"))
    #expect(!exported.contains("accessToken"))
    let notes = try await recordChanges {
      try await provider.clear()
      #expect(data(forKey: "app.settings.aiConfiguration", suite: suite) == nil)
      try await provider.importData(from: folder)
    }
    #expect(notes == [provider.category.rawValue, provider.category.rawValue])
    let restored = try textOf(data(forKey: "app.settings.aiConfiguration", suite: suite))
    #expect(restored.contains("gpt-4.1"))
    #expect(restored.contains("openAI"))
    #expect(!restored.contains("sk-test-secret"))
    #expect(!restored.contains("tok-test-secret"))
    expectUnrelated(suite)
  }

  @Test("Local model files round-trip without downloading")
  func localModels() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let models = root.appendingPathComponent("Models", isDirectory: true)
    let weights = models.appendingPathComponent("SampleModel", isDirectory: true)
      .appendingPathComponent("weights.bin")
    try FileManager.default.createDirectory(
      at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = Data("weights".utf8)
    try payload.write(to: weights)
    let provider = LocalModelsLocalDataProvider(root: models)
    let suite = makeSuite()
    setUnrelated(suite)

    let summary = await provider.summary()
    #expect(provider.category.isLarge)
    #expect(summary.itemCount == 1)
    #expect(summary.bytes == Int64(payload.count))
    #expect(summary.location == models)

    let folder = try makeFolder(in: root)
    let notes = try await recordChanges {
      try await provider.export(to: folder)
      try await provider.clear()
      #expect(FileManager.default.fileExists(atPath: weights.path) == false)
      try await provider.importData(from: folder)
    }
    #expect(
      notes == [LocalDataCategory.localModels.rawValue, LocalDataCategory.localModels.rawValue])
    #expect(try Data(contentsOf: weights) == payload)
    expectUnrelated(suite)
  }

  @Test("Data Rewind reports its file, deletes every entry, and exports nothing")
  func dataRewind() async throws {
    let root = try makeRoot()
    defer { remove(root) }
    let url = root.appendingPathComponent("rewind.sqlite")
    let store = try RewindStore(url: url)
    try store.record(
      RewindEntry(
        id: 0, connectionKey: "SQLite||0|/tmp/a.db", schema: "main", table: "t",
        qualifiedName: "\"t\"", engine: .sqlite, created: Date(), state: .pending,
        editKind: .staged, statementCount: 1, columns: [], notCaptured: false,
        notRewindableReason: nil),
      rows: [RewindRow(operation: .delete, primaryKey: ["id": "1"], before: ["id": "1"])])
    let provider = DataRewindLocalDataProvider(store: store, fileURL: url)

    let summary = await provider.summary()
    #expect(summary.itemCount == 1)
    #expect(summary.bytes == (try store.fileSize()))
    #expect(summary.location == url)

    let folder = try makeFolder(in: root)
    try await provider.export(to: folder)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

    let notes = try await recordChanges { try await provider.clear() }
    #expect(notes == [LocalDataCategory.dataRewind.rawValue])
    #expect(try store.count() == 0)

    // A file the store could not open is removed from disk
    let unreadable = root.appendingPathComponent("broken.sqlite")
    try Data("not sqlite".utf8).write(to: unreadable)
    try await DataRewindLocalDataProvider(store: nil, fileURL: unreadable).clear()
    #expect(!FileManager.default.fileExists(atPath: unreadable.path))
  }

  @Test("App settings skip password and secret keys")
  func appSettings() async throws {
    let suite = makeSuite()
    setUnrelated(suite)
    setString("dark", forKey: "app.settings.themePreference", suite: suite)
    setString("password-hash-value", forKey: "app.settings.safeModePassword", suite: suite)
    setString("secret-value", forKey: "app.settings.apiSecret", suite: suite)
    let provider = AppSettingsLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    let summary = await provider.summary()
    #expect(summary.itemCount == 1)
    #expect(summary.bytes > 0)
    #expect(summary.location == nil)

    let folder = try makeFolder()
    defer { remove(folder) }
    try await provider.export(to: folder)
    let exported = try textFiles(in: folder)
    #expect(exported.contains("dark"))
    #expect(!exported.contains("password-hash-value"))
    #expect(!exported.contains("secret-value"))
    #expect(!exported.contains("safeModePassword"))
    let notes = try await recordChanges {
      try await provider.clear()
      #expect(string(forKey: "app.settings.themePreference", suite: suite) == nil)
      #expect(
        string(forKey: "app.settings.safeModePassword", suite: suite) == "password-hash-value")
      #expect(string(forKey: "app.settings.apiSecret", suite: suite) == "secret-value")
      try await provider.importData(from: folder)
    }
    #expect(notes == [provider.category.rawValue, provider.category.rawValue])
    #expect(string(forKey: "app.settings.themePreference", suite: suite) == "dark")
    #expect(string(forKey: "app.settings.safeModePassword", suite: suite) == "password-hash-value")
    expectUnrelated(suite)
  }

  @Test("App settings leave out values JSON cannot hold, so the count matches the file")
  func appSettingsSkipNonJSONValues() async throws {
    let suite = makeSuite()
    setString("dark", forKey: "app.settings.themePreference", suite: suite)
    setData(Data([0x01, 0x02]), forKey: "app.settings.futureBlob", suite: suite)
    let provider = AppSettingsLocalDataProvider(defaults: suite.defaults, domainName: suite.name)

    #expect(await provider.summary().itemCount == 1)

    let folder = try makeFolder()
    defer { remove(folder) }
    try await provider.export(to: folder)
    let file = try Data(contentsOf: folder.appendingPathComponent("appSettings.json"))
    let exported = try JSONSerialization.jsonObject(with: file) as? [String: Any]
    #expect(exported?.keys.sorted() == ["app.settings.themePreference"])

    try await provider.importData(from: folder)
    #expect(data(forKey: "app.settings.futureBlob", suite: suite) == Data([0x01, 0x02]))
  }

  @Test("Provider and category sources do not call Keychain")
  func sourcesDoNotCallKeychain() throws {
    let providers = try source("Dblore/Utilities/DataManagement/LocalDataProviders.swift")
    let categories = try source("Dblore/Utilities/DataManagement/LocalDataCategory.swift")
    let session = try source("Dblore/Utilities/SessionManager.swift")
    for file in [providers, categories] {
      #expect(!file.contains("SecItem"))
      #expect(!file.contains("import Security"))
    }
    let clearAll = functionBody("clearAll(defaults:", in: session)
    #expect(clearAll.contains("removeObject") || clearAll.contains("persistentDomain"))
    #expect(!clearAll.contains("SecItem"))
  }

  // MARK: - Fixtures

  private struct Suite {
    var name: String
    var defaults: UserDefaults
  }

  private func makeSuite() -> Suite {
    let name = "ace.thi.Dblore.tests.localdata.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return Suite(name: name, defaults: defaults)
  }

  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-localdata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeFolder(in root: URL? = nil) throws -> URL {
    let parent = root ?? FileManager.default.temporaryDirectory
    let url = parent.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func setUnrelated(_ suite: Suite) {
    setString("keep-me", forKey: "dblore.test.unrelated", suite: suite)
  }

  private func expectUnrelated(_ suite: Suite) {
    #expect(string(forKey: "dblore.test.unrelated", suite: suite) == "keep-me")
  }

  private func setString(_ value: String, forKey key: String, suite: Suite) {
    var domain = suite.defaults.persistentDomain(forName: suite.name) ?? [:]
    domain[key] = value
    suite.defaults.setPersistentDomain(domain, forName: suite.name)
  }

  private func setData(_ value: Data, forKey key: String, suite: Suite) {
    var domain = suite.defaults.persistentDomain(forName: suite.name) ?? [:]
    domain[key] = value
    suite.defaults.setPersistentDomain(domain, forName: suite.name)
  }

  private func data(forKey key: String, suite: Suite) -> Data? {
    suite.defaults.persistentDomain(forName: suite.name)?[key] as? Data
  }

  private func string(forKey key: String, suite: Suite) -> String? {
    suite.defaults.persistentDomain(forName: suite.name)?[key] as? String
  }

  private func textOf(_ data: Data?) throws -> String {
    guard let data else {
      Issue.record("missing data")
      return ""
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func textFiles(in folder: URL) throws -> String {
    let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
    return try files.map { relative in
      try String(contentsOf: folder.appendingPathComponent(relative), encoding: .utf8)
    }.joined(separator: "\n")
  }

  private func recordChanges(_ body: () async throws -> Void) async rethrows -> [String] {
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let box = NoteBox()
    let token = NotificationCenter.default.addObserver(
      forName: .localDataChanged, object: nil, queue: nil
    ) { note in
      if let value = note.userInfo?[LocalDataCategory.userInfoKey] as? String {
        box.values.append(value)
      }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    try await body()
    return box.values
  }

  private func expectRoundTrip(
    _ provider: LocalDataProvider, category: LocalDataCategory,
    afterClear: () -> Void, afterImport: () -> Void
  ) async throws {
    let folder = try makeFolder()
    defer { remove(folder) }
    let notes = try await recordChanges {
      try await provider.export(to: folder)
      try await provider.clear()
      afterClear()
      try await provider.importData(from: folder)
    }
    #expect(notes == [category.rawValue, category.rawValue])
    afterImport()
  }

  private func historyJSON(host: String, password: String) throws -> Data {
    try configArrayJSON(host: host, password: password)
  }

  private func configJSON(host: String, password: String) throws -> Data {
    var object =
      try JSONSerialization.jsonObject(with: try encodedConfig(host: host)) as! [String: Any]
    object["password"] = password
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func configArrayJSON(host: String, password: String) throws -> Data {
    let entry = ConnectionHistoryEntry(
      config: ConnectionConfig(host: host, port: 5432, database: "app", username: "ada"))
    var objects =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode([entry])) as! [[String: Any]]
    var config = objects[0]["config"] as! [String: Any]
    config["password"] = password
    objects[0]["config"] = config
    return try JSONSerialization.data(withJSONObject: objects)
  }

  private func encodedConfig(host: String) throws -> Data {
    try JSONEncoder().encode(
      ConnectionConfig(host: host, port: 5432, database: "app", username: "ada"))
  }

  private func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
  }

  private func functionBody(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: "func \(signature)") else { return "" }
    let rest = source[start.lowerBound...]
    guard
      let next = rest.dropFirst().range(of: "\n  func ")
        ?? rest.dropFirst().range(of: "\n  private")
    else { return String(rest) }
    return String(rest[..<next.lowerBound])
  }
}

private final class NoteBox: @unchecked Sendable {
  var values: [String] = []
}
