// RedisKeyIdentityTests.swift
// The key browser's command builders: every key, member, field, value, pattern and stream id is
// its own argument with its exact bytes, the command runs in the key's database, and the gate
// classifies each command as the read or write it is. A key's bytes stay its identity from the
// SCAN reply through the tree rows and the key tab to the edit sent through the gate.

import Foundation
import Testing

@testable import Dblore

@Suite("Redis key command builders")
struct RedisKeyIdentityTests {

  private static func text(_ value: String) -> Data { Data(value.utf8) }

  /// `\xff\x00\r\nFLUSHALL`: a key that would run a second command if spliced into command text
  private static let injectionKey = Data([0xFF, 0x00, 0x0D, 0x0A]) + text("FLUSHALL")
  /// Not UTF-8 (a lone continuation byte, a truncated sequence), with a space and a quote
  private static let binaryKey = Data([0x80, 0x20, 0x22, 0xC3])
  /// "café" precomposed (U+00E9) and decomposed (e + U+0301): equal as Swift strings, not as bytes
  private static let cafeNFC = Data([0x63, 0x61, 0x66, 0xC3, 0xA9])
  private static let cafeNFD = Data([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81])

  /// Payloads with CR LF and spaces, so a splice would show as extra arguments
  private static let member = text("m 1\r\nDEL x")
  private static let field = text("f 2\r\nFLUSHDB")
  private static let value = Data([0x00, 0xFF]) + text(" v\r\nSHUTDOWN")
  private static let streamID = text("1-1\r\n*")
  /// An id `XADD` takes (it refuses `streamID`, which would not be one argument's worth of id)
  private static let addID = text("1526919030474-55")

  /// Every builder for `key` (db 3), with the exact argument array and the kind the gate gives it
  private static func everyBuilder(
    _ key: Data
  ) throws -> [(
    name: String, command: RedisCommand, args: [Data], kind: StatementKind
  )] {
    let ref = RedisKeyRef(db: 3, bytes: key)
    let other = RedisKeyRef(db: 3, bytes: key + injectionKey)
    let (m, f, v) = (member, field, value)
    return [
      // Reads
      (
        "SCAN", RedisKeyCommands.scan(db: 3, cursor: 42, match: key, type: key),
        [
          text("SCAN"), text("42"), text("MATCH"), key, text("COUNT"), text("500"), text("TYPE"),
          key,
        ],
        .read
      ),
      ("TYPE", RedisKeyCommands.type(ref), [text("TYPE"), key], .read),
      ("PTTL", RedisKeyCommands.pttl(ref), [text("PTTL"), key], .read),
      ("STRLEN", RedisKeyCommands.strlen(ref), [text("STRLEN"), key], .read),
      (
        "MEMORY USAGE", RedisKeyCommands.memoryUsage(ref),
        [text("MEMORY"), text("USAGE"), key], .read
      ),
      (
        "GETRANGE", RedisKeyCommands.getRange(ref),
        [text("GETRANGE"), key, text("0"), text("262143")], .read
      ),
      (
        "HSCAN", RedisKeyCommands.hscan(ref, cursor: 7, count: 100),
        [text("HSCAN"), key, text("7"), text("COUNT"), text("100")], .read
      ),
      (
        "LRANGE", RedisKeyCommands.lrange(ref, start: 0, stop: 99),
        [text("LRANGE"), key, text("0"), text("99")], .read
      ),
      (
        "SSCAN", RedisKeyCommands.sscan(ref, cursor: 0, count: 100),
        [text("SSCAN"), key, text("0"), text("COUNT"), text("100")], .read
      ),
      (
        "ZRANGE", RedisKeyCommands.zrange(ref, start: 100, stop: -1),
        [text("ZRANGE"), key, text("100"), text("-1"), text("WITHSCORES")], .read
      ),
      (
        "XRANGE", try #require(RedisKeyCommands.xrange(ref, after: text("5-3"), count: 100)),
        [text("XRANGE"), key, text("5-4"), text("+"), text("COUNT"), text("100")], .read
      ),
      ("INFO", RedisKeyCommands.infoKeyspace(db: 3), [text("INFO"), text("keyspace")], .read),
      (
        "HSTRLEN", RedisKeyEditor.hstrlen(ref, field: f), [text("HSTRLEN"), key, f], .read
      ),
      // Writes
      (
        "SET", RedisKeyCommands.set(ref, value: v),
        [text("SET"), key, v, text("KEEPTTL"), text("XX")], .dml
      ),
      ("HSET", RedisKeyCommands.hset(ref, field: f, value: v), [text("HSET"), key, f, v], .dml),
      (
        "HSETNX", RedisKeyCommands.hsetnx(ref, field: f, value: v),
        [text("HSETNX"), key, f, v], .dml
      ),
      ("HDEL", RedisKeyCommands.hdel(ref, field: f), [text("HDEL"), key, f], .dml),
      (
        "LSET", RedisKeyCommands.lset(ref, index: -2, value: v),
        [text("LSET"), key, text("-2"), v], .dml
      ),
      ("RPUSH", RedisKeyCommands.rpush(ref, value: v), [text("RPUSH"), key, v], .dml),
      ("LPUSH", RedisKeyCommands.lpush(ref, value: v), [text("LPUSH"), key, v], .dml),
      ("SADD", RedisKeyCommands.sadd(ref, member: m), [text("SADD"), key, m], .dml),
      ("SREM", RedisKeyCommands.srem(ref, member: m), [text("SREM"), key, m], .dml),
      (
        "ZADD", try #require(RedisKeyCommands.zadd(ref, score: 1.5, member: m)),
        [text("ZADD"), key, text("1.5"), m], .dml
      ),
      (
        "ZADD NX", try #require(RedisKeyCommands.zaddNX(ref, score: 1.5, member: m)),
        [text("ZADD"), key, text("NX"), text("1.5"), m], .dml
      ),
      ("ZREM", RedisKeyCommands.zrem(ref, member: m), [text("ZREM"), key, m], .dml),
      (
        "XADD", try #require(RedisKeyCommands.xadd(ref, id: addID, fields: [(f, v), (m, v)])),
        [text("XADD"), key, addID, f, v, m, v], .dml
      ),
      (
        "XADD *", try #require(RedisKeyCommands.xadd(ref, id: nil, fields: [(f, v)])),
        [text("XADD"), key, text("*"), f, v], .dml
      ),
      ("XDEL", RedisKeyCommands.xdel(ref, id: streamID), [text("XDEL"), key, streamID], .dml),
      (
        "PEXPIRE", try #require(RedisKeyCommands.pexpire(ref, milliseconds: 60_000)),
        [text("PEXPIRE"), key, text("60000")], .dml
      ),
      ("PERSIST", RedisKeyCommands.persist(ref), [text("PERSIST"), key], .dml),
      (
        "RENAMENX", try #require(RedisKeyCommands.renameNX(ref, to: other)),
        [text("RENAMENX"), key, other.bytes], .dml
      ),
      ("UNLINK", RedisKeyCommands.unlink(ref), [text("UNLINK"), key], .dml),
      // Create, one per type
      (
        "create string", RedisKeyCommands.createString(ref, value: v),
        [text("SET"), key, v, text("NX")], .dml
      ),
      (
        "create hash", RedisKeyCommands.createHash(ref, field: f, value: v),
        [text("HSET"), key, f, v], .dml
      ),
      ("create list", RedisKeyCommands.createList(ref, value: v), [text("RPUSH"), key, v], .dml),
      ("create set", RedisKeyCommands.createSet(ref, member: m), [text("SADD"), key, m], .dml),
      (
        "create sorted set",
        try #require(RedisKeyCommands.createSortedSet(ref, score: -2, member: m)),
        [text("ZADD"), key, text("-2.0"), m], .dml
      ),
      (
        "create stream", RedisKeyCommands.createStream(ref, field: f, value: v),
        [text("XADD"), key, text("*"), f, v], .dml
      ),
    ]
  }

  @Test(
    "Every builder keeps the key and each payload as one argument, byte for byte, in the key's db",
    arguments: [injectionKey, binaryKey, cafeNFC, cafeNFD])
  func everyBuilderKeepsArguments(key: Data) throws {
    for builder in try Self.everyBuilder(key) {
      #expect(builder.command.args == builder.args, "\(builder.name)")
      #expect(builder.command.db == 3, "\(builder.name)")
      let classification = RedisCommandClassifier.classify(builder.command.args)
      #expect(classification.refusal == nil, "\(builder.name)")
      #expect(classification.statement.kind == builder.kind, "\(builder.name)")
      #expect(classification.statement.isDestructive == false, "\(builder.name)")
    }
  }

  @Test("An NFC and an NFD \"café\" stay distinct keys with distinct argument bytes")
  func normalizationTwinsStayDistinct() {
    let nfc = RedisKeyRef(db: 0, bytes: Self.cafeNFC)
    let nfd = RedisKeyRef(db: 0, bytes: Self.cafeNFD)
    #expect(nfc != nfd)
    #expect(RedisKeyCommands.type(nfc).args[1] == Self.cafeNFC)
    #expect(RedisKeyCommands.type(nfd).args[1] == Self.cafeNFD)
    #expect(RedisKeyCommands.unlink(nfc) != RedisKeyCommands.unlink(nfd))
  }

  @Test(
    "The next stream page starts at the id right after the last one seen",
    arguments: [
      ("0-0", "0-1"),
      ("1526919030474-55", "1526919030474-56"),
      ("5-18446744073709551615", "6-0"),
      ("18446744073709551614-18446744073709551615", "18446744073709551615-0"),
    ])
  func nextStreamID(last: String, next: String) throws {
    #expect(RedisKeyCommands.nextStreamID(after: Self.text(last)) == Self.text(next))
    let command = try #require(
      RedisKeyCommands.xrange(
        RedisKeyRef(db: 0, bytes: Self.injectionKey), after: Self.text(last),
        count: 50))
    #expect(command.args[2] == Self.text(next))
  }

  @Test(
    "A malformed or final stream id gives no next page start, never a guessed one",
    arguments: [
      "", "5", "5-", "-5", "5-1-2", "+5-1", "5-+1", "5--1", " 5-1", "5-1 ", "a-1", "5-1\r\n",
      "0x5-1", "5.0-1", "5\u{2013}1", "18446744073709551616-0", "0-18446744073709551616",
      "18446744073709551615-18446744073709551615",
    ])
  func malformedStreamID(last: String) {
    #expect(RedisKeyCommands.nextStreamID(after: Self.text(last)) == nil)
    #expect(
      RedisKeyCommands.xrange(
        RedisKeyRef(db: 0, bytes: Self.text("s")), after: Self.text(last),
        count: 50) == nil)
  }

  @Test("The first stream page starts at -, the first SCAN page at cursor 0 without TYPE")
  func firstPages() throws {
    let key = RedisKeyRef(db: 15, bytes: Self.injectionKey)
    let xrange = try #require(RedisKeyCommands.xrange(key, after: nil, count: 100))
    #expect(
      xrange.args == [
        Self.text("XRANGE"), Self.injectionKey, Self.text("-"), Self.text("+"),
        Self.text("COUNT"), Self.text("100"),
      ])
    let scan = RedisKeyCommands.scan(db: 15, cursor: 0, match: Self.text("*"))
    #expect(
      scan.args == [
        Self.text("SCAN"), Self.text("0"), Self.text("MATCH"), Self.text("*"),
        Self.text("COUNT"), Self.text("500"),
      ])
    #expect(scan.db == 15)
    let last = RedisKeyCommands.scan(db: 0, cursor: .max, match: Self.text("*"))
    #expect(last.args[1] == Self.text("18446744073709551615"))
    #expect(RedisCommandClassifier.classify(scan.args).statement.kind == .read)
  }

  @Test(
    "XADD takes an id only as *, <ms>, <ms>-* or <ms>-<seq>, its exact bytes as one argument",
    arguments: [
      "*", "0", "5", "5-*", "5-0", "0-1", "007-0010", "18446744073709551615-18446744073709551615",
    ])
  func xaddValidID(id: String) throws {
    let key = RedisKeyRef(db: 2, bytes: Self.injectionKey)
    let command = try #require(
      RedisKeyCommands.xadd(key, id: Self.text(id), fields: [(Self.field, Self.value)]))
    #expect(
      command.args == [
        Self.text("XADD"), Self.injectionKey, Self.text(id), Self.field, Self.value,
      ])
    #expect(command.db == 2)
  }

  @Test(
    "XADD refuses an id Redis would read as an option or that is not a stream id",
    arguments: [
      "", "MAXLEN", "maxlen", "MINID", "NOMKSTREAM", "LIMIT", "~", "=", "-", "+", "5-", "-5",
      "*-1", "*-*", "5-*-1", "5-1-2", "+5-1", "5-+1", "-5-1", "5--1", " 5-1", "5-1 ", "5-1\r\n",
      "\r\n5-1", "5-1\r\nMAXLEN", "a-1", "0x5", "5.0", "5\u{2013}1", "\u{0663}", "5-\u{0663}",
      "\u{FF15}-1", "18446744073709551616", "18446744073709551616-0", "0-18446744073709551616",
      "**",
    ])
  func xaddRefusedID(id: String) {
    let key = RedisKeyRef(db: 0, bytes: Self.text("s"))
    #expect(
      RedisKeyCommands.xadd(key, id: Self.text(id), fields: [(Self.field, Self.value)]) == nil)
  }

  @Test(
    "Builders refuse what Redis would misread: a non-finite score, a cross-db rename, a TTL <= 0")
  func refusedInputs() throws {
    let key = RedisKeyRef(db: 1, bytes: Self.injectionKey)
    for score in [Double.nan, .infinity, -.infinity] {
      #expect(RedisKeyCommands.zadd(key, score: score, member: Self.member) == nil)
      #expect(RedisKeyCommands.createSortedSet(key, score: score, member: Self.member) == nil)
    }
    // The score text parses back to the same Double
    for score in [0.1, -2.5e-300, 1e20, 5e-324, 123_456_789.123_456_78, -0.0] {
      let command = try #require(RedisKeyCommands.zadd(key, score: score, member: Self.member))
      let parsed = try #require(Double(String(decoding: command.args[2], as: UTF8.self)))
      #expect(parsed.bitPattern == score.bitPattern)
    }
    #expect(RedisKeyCommands.renameNX(key, to: RedisKeyRef(db: 2, bytes: Self.cafeNFC)) == nil)
    #expect(RedisKeyCommands.pexpire(key, milliseconds: 0) == nil)
    #expect(RedisKeyCommands.pexpire(key, milliseconds: -1) == nil)
    #expect(RedisKeyCommands.xadd(key, id: nil, fields: []) == nil)
  }
}

// MARK: - Key tabs

/// A key tab (`TabDocumentType.redisKey`) is session-only: never written to the workspace or the
/// launch snapshot, never decoded back. A click opens the key in one reused preview tab at once;
/// a double click keeps that tab.
extension RedisKeyIdentityTests {
  @MainActor
  private static func redisWorkspace() -> WorkspaceManager {
    WorkspaceManager(
      workspace: Workspace(
        name: "Cache",
        connectionConfig: ConnectionConfig(databaseType: .redis, host: "fake", database: "0")),
      restoreTabs: false)
  }

  @MainActor
  private static func decodedWorkspace(_ data: Data) throws -> Workspace {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Workspace.self, from: data)
  }

  @Test("A kept or pinned key tab is never saved; the other tabs and the active tab hand-over stay")
  @MainActor
  func keyTabsNeverPersisted() throws {
    let manager = Self.redisWorkspace()
    let command = manager.newSQLFile()
    let kept = try #require(manager.pinRedisKey(RedisKeyRef(db: 3, bytes: Self.injectionKey)))
    let pinned = try #require(manager.pinRedisKey(RedisKeyRef(db: 0, bytes: Self.cafeNFC)))
    // In the pinned zone too (set directly: the Pin action refuses key tabs)
    let index = try #require(manager.tabs.firstIndex { $0.id == pinned })
    manager.tabs[index].isPinned = true
    manager.selectTab(id: kept)
    #expect(manager.tabs.first { $0.id == kept }?.isPreview == false)

    let saved = try Self.decodedWorkspace(manager.encodedWorkspaceData())
    #expect(saved.tabs.map(\.id) == [command])
    #expect(!saved.tabs.contains { $0.documentType == .redisKey })
    #expect(saved.activeTabId == command)

    // The launch snapshot of this untitled workspace goes through the same encoding
    let session = LaunchSessionCapture.session(
      windows: [
        LaunchSessionCapture.WindowDescriptor(
          frame: WindowFrame(x: 0, y: 0, width: 800, height: 600),
          isMiniaturized: false, groupID: "cache", tabIndex: 0, isSelectedInGroup: true,
          orderedIndex: 0, content: .workspace(manager.id))
      ],
      workspaces: [manager.id: manager])
    guard case .workspace(let launch) = session.windows.first?.content else {
      Issue.record("Expected the captured window to be the untitled workspace")
      return
    }
    #expect(launch.workspace?.tabs.map(\.id) == [command])
    #expect(launch.workspace?.activeTabId == command)
    #expect(!launch.textOverlays.contains { $0.tabId == kept || $0.tabId == pinned })
  }

  @Test("Decoding never yields a key tab: a tab item refuses one, a workspace drops it")
  @MainActor
  func keyTabsNeverDecoded() async throws {
    let item = Data(#"{"id":"\#(UUID().uuidString)","documentType":"redisKey","title":"k"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TabItem.self, from: item) }

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = folder.appendingPathComponent("ping.redis")
    let other = folder.appendingPathComponent("key.redis")
    try Data("PING".utf8).write(to: script)
    try Data("GET k".utf8).write(to: other)
    let keyRef = WorkspaceTabReference(fileURL: other, documentType: .redisKey, title: "k")
    let scriptRef = WorkspaceTabReference(fileURL: script, documentType: .sqlFile, title: "ping")
    // No connection: a loaded workspace with one would auto-connect
    let file = Workspace(name: "Cache", tabs: [keyRef, scriptRef], activeTabId: keyRef.id)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let url = folder.appendingPathComponent("cache.sqlws")
    try encoder.encode(file).write(to: url)

    let loaded = try await WorkspaceManager.load(from: url)
    defer { loaded.releaseFileAccess() }
    #expect(loaded.tabs.map(\.id) == [scriptRef.id])
    // Launch restore builds tab shells from the decoded workspace
    let shells = WorkspaceManager(workspace: try Self.decodedWorkspace(Data(contentsOf: url)))
    #expect(shells.tabs.map(\.id) == [scriptRef.id])
    #expect(shells.activeTabId == nil)
  }

  @Test("A click opens the key in one reused preview tab at once; its own key selects that tab")
  @MainActor
  func clickOpensPreview() throws {
    let manager = Self.redisWorkspace()
    let nfc = RedisKeyRef(db: 0, bytes: Self.cafeNFC)
    let nfd = RedisKeyRef(db: 0, bytes: Self.cafeNFD)
    let id = try #require(manager.openRedisKey(nfc))
    let tab = try #require(manager.tabs.first { $0.id == id })
    #expect(manager.activeTabId == id)
    #expect(tab.documentType == .redisKey && tab.isPreview && tab.redisKey == nfc)
    #expect(tab.title == "café")
    // The NFD twin is another key: the preview tab now shows it
    #expect(manager.openRedisKey(nfd) == id)
    #expect(manager.tabs.count == 1 && manager.tabs.first?.redisKey == nfd)
    // The same key again selects its tab
    manager.newSQLFile()
    #expect(manager.openRedisKey(nfd) == id)
    #expect(manager.activeTabId == id && manager.tabs.count == 2)
    // The title is escaped and capped
    let long = RedisKeyRef(db: 0, bytes: Self.injectionKey + Data(repeating: 0x61, count: 500))
    #expect(manager.openRedisKey(long) == id)
    let title = try #require(manager.tabs.first { $0.id == id }?.title)
    #expect(!title.unicodeScalars.contains { $0.properties.generalCategory == .control })
    #expect(title.count <= WorkspaceManager.redisKeyTitleLength + 1 && title.hasSuffix("…"))
    // Never in a SQL workspace
    let sql = WorkspaceManager(workspace: Workspace(name: "Draft"), restoreTabs: false)
    #expect(sql.openRedisKey(nfc) == nil && sql.tabs.isEmpty)
  }

  @Test("A double click keeps the key's tab; a later click on that key reuses it")
  @MainActor
  func doubleClickKeepsTab() throws {
    let manager = Self.redisWorkspace()
    let home = RedisKeyRef(db: 0, bytes: Self.text("user:1"))
    let other = RedisKeyRef(db: 3, bytes: Self.text("user:1"))
    // The single click acts first, the double click adds to it
    let preview = try #require(manager.openRedisKey(home))
    let kept = try #require(manager.pinRedisKey(home))
    #expect(kept == preview)
    #expect(manager.tabs.first { $0.id == kept }?.isPreview == false)
    // Same bytes in another db is another key: a new preview tab
    let next = try #require(manager.openRedisKey(other))
    #expect(next != kept)
    #expect(manager.openRedisKey(home) == kept)
    #expect(manager.activeTabId == kept && manager.tabs.count == 2)
    // A double click on a key with no tab keeps the preview it opened in
    let third = RedisKeyRef(db: 0, bytes: Self.binaryKey)
    #expect(manager.pinRedisKey(third) == next)
    #expect(manager.tabs.first { $0.id == next }?.isPreview == false)
    #expect(manager.tabs.count == 2)
  }
}

// MARK: - Key identity through the edit flow

/// History rows a write context handed over (kept here, never written to the History store)
@MainActor
private final class EditHistorySink {
  var outcomes: [QueryHistoryOutcome] = []
}

/// A key's exact bytes go from the `SCAN` reply's cells through the sidebar's tree rows and the
/// key tab to the edit command the gate sends, never through a label or a Swift `String`
/// comparison: a binary key keeps its bytes, NFC / NFD twins stay two keys, and an edit under the
/// epoch of an older connection is refused before anything is sent.
extension RedisKeyIdentityTests {
  private static let editDB = 3

  /// A Redis workspace on a fake session, connected to db `editDB` (no protection, Immediate)
  @MainActor
  private static func connectedWorkspace() async throws -> (
    WorkspaceManager, FakeDatabaseSessionFactory, ConnectionConfig
  ) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    var config = ConnectionConfig(
      databaseType: .redis, host: "fake", port: 6379, database: "\(editDB)", username: "",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent)
    config.applyCommitStyle(.immediate)
    let manager = WorkspaceManager(
      workspace: Workspace(name: "Cache", connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(sessionFactory: factory),
      sanitizesFileConfig: false)
    try await manager.connectionManager.connect(config: config)
    return (manager, factory, config)
  }

  /// A `SCAN` reply as the plugin's rows: a key that is valid UTF-8 is a text cell, any other a
  /// bytes cell (`.data`)
  private static func scanRows(_ keys: [Data]) -> [[CellValue]] {
    func row(_ path: String, _ type: String, _ value: CellValue) -> [CellValue] {
      [.string(path), .string(type), value]
    }
    var rows = [
      row("0", "array", .int(2)), row("0.0", "bulk", .string("0")),
      row("0.1", "array", .int(keys.count)),
    ]
    for (index, key) in keys.enumerated() {
      let text = String(data: key, encoding: .utf8).flatMap { Data($0.utf8) == key ? $0 : nil }
      rows.append(row("0.1.\(index)", "bulk", text.map(CellValue.string) ?? .data(key)))
    }
    return rows
  }

  /// The key rows of `editDB` the sidebar shows after reading `keys` with `SCAN`
  @MainActor
  private static func treeKeys(
    _ keys: [Data], workspace: WorkspaceManager, factory: FakeDatabaseSessionFactory
  ) async throws -> [RedisKeyRef] {
    let session = try #require(factory.sessions.last)
    session.answerRedisSends(with: scanRows(keys))
    let browser = RedisKeyBrowserModel()
    await browser.open(
      manager: workspace.connectionManager, policy: { workspace.redisKeyPolicy },
      homeDatabase: editDB)
    #expect(browser.listings[editDB]?.error == nil)
    return browser.rows(db: editDB).compactMap { row in
      if case .key(let ref) = row.id { return ref }
      return nil
    }
  }

  /// The key a tab shows, read back from the workspace's tabs
  @MainActor
  private static func tabKey(_ id: UUID, in workspace: WorkspaceManager) throws -> RedisKeyRef {
    try #require(workspace.tabs.first { $0.id == id }?.redisKey)
  }

  /// The epoch the key tab's load read `key` under (every edit of the key is sent under it)
  @MainActor
  private static func loadEpoch(
    _ key: RedisKeyRef, workspace: WorkspaceManager
  ) async throws -> UInt64 {
    let model = RedisKeyViewerModel()
    await model.load(key, manager: workspace.connectionManager, policy: workspace.redisKeyPolicy)
      .value
    let epoch = try #require(model.loadEpoch)
    model.stop()
    return epoch
  }

  /// The workspace's gated write path, its History handed to `sink`
  @MainActor
  private static func gatedContext(
    _ workspace: WorkspaceManager, sink: EditHistorySink
  ) -> RedisKeyWriteContext {
    RedisKeyWriteContext.gated(
      manager: workspace.connectionManager, policy: { workspace.redisKeyPolicy },
      commitStyle: { .immediate }, recordHistory: { sink.outcomes += $0 })
  }

  @Test("A binary key read back as a bytes cell reaches the tab and every edit with its bytes")
  @MainActor
  func binaryKeyFlowsToEdits() async throws {
    let plain = Self.text("plain")
    // The binary key comes as a bytes cell, the plain one as a text cell
    #expect(
      Self.scanRows([Self.injectionKey, plain]).suffix(2).map { $0[2] } == [
        .data(Self.injectionKey), .string("plain"),
      ])
    let (workspace, factory, _) = try await Self.connectedWorkspace()
    let keys = try await Self.treeKeys(
      [Self.injectionKey, plain], workspace: workspace, factory: factory)
    let inDB = [Self.injectionKey, plain].map { RedisKeyRef(db: Self.editDB, bytes: $0) }
    #expect(Set(keys) == Set(inDB))
    let row = try #require(keys.first { $0.bytes == Self.injectionKey })

    let tab = try #require(workspace.openRedisKey(row))
    let key = try Self.tabKey(tab, in: workspace)
    #expect(key.bytes == Self.injectionKey && key.db == Self.editDB)
    // The tab's own reads name the key by its bytes
    let session = try #require(factory.sessions.last)
    let readsBefore = session.redisCommands.count
    let epoch = try await Self.loadEpoch(key, workspace: workspace)
    let reads = session.redisCommands.dropFirst(readsBefore)
    #expect(!reads.isEmpty)
    #expect(
      reads.allSatisfy {
        $0.args.filter { $0 == Self.injectionKey }.count == 1 && $0.db == Self.editDB
      })

    let (field, value) = (Self.text("f"), Self.text("v"))
    let writes: [RedisKeyWrite] = [
      try .stringValue(key, value: value, old: Self.text("old")),
      try .hashField(key, field: field, value: value, old: nil),
      try .listElement(key, index: 0, value: value, old: Self.text("old")),
      try .sortedSetMember(key, member: field, score: 2, oldScore: nil),
      try .addStreamEntry(key, fields: [(field, value)]),
      try .expire(key, seconds: 60),
      try .rename(key, to: Self.text("renamed")),
      .delete(key),
    ]
    for write in writes {
      let args = write.command.args
      #expect(args.filter { $0 == Self.injectionKey }.count == 1, "\(args[0])")
      #expect(args[1] == Self.injectionKey, "\(args[0])")
      #expect(write.command.db == Self.editDB, "\(args[0])")
    }
    #expect(
      writes.map { String(decoding: $0.command.args[0], as: UTF8.self) } == [
        "SET", "HSETNX", "LSET", "ZADD", "XADD", "PEXPIRE", "RENAMENX", "UNLINK",
      ])
    #expect(writes[0].command.args.suffix(2) == [Self.text("KEEPTTL"), Self.text("XX")])

    // Through the gate the same array reaches the session, byte for byte
    session.answerRedisSends(with: [[.string("0"), .string("simple"), .string("OK")]])
    let sink = EditHistorySink()
    let context = Self.gatedContext(workspace, sink: sink)
    let sentBefore = session.redisCommands.count
    for write in writes {
      _ = try await context.write(write.command, epoch, true)
    }
    #expect(Array(session.redisCommands.dropFirst(sentBefore)) == writes.map(\.command))
  }

  @Test("NFC and NFD \"café\" stay two tree rows and two tabs; an edit sends only its twin's bytes")
  @MainActor
  func normalizationTwinsThroughEdits() async throws {
    // Both come as text cells (equal as Swift strings, so matched by case, not by ==)
    for row in Self.scanRows([Self.cafeNFC, Self.cafeNFD]).suffix(2) {
      guard case .string = row[2] else {
        Issue.record("Expected a text cell, got \(row[2])")
        return
      }
    }
    let (workspace, factory, _) = try await Self.connectedWorkspace()
    let keys = try await Self.treeKeys(
      [Self.cafeNFC, Self.cafeNFD], workspace: workspace, factory: factory)
    #expect(keys.count == 2)
    let nfcRow = try #require(keys.first { $0.bytes == Self.cafeNFC })
    let nfdRow = try #require(keys.first { $0.bytes == Self.cafeNFD })
    #expect(nfcRow != nfdRow)

    // A kept tab for the NFC key: the NFD key opens its own tab, never the NFC one
    let nfcTab = try #require(workspace.pinRedisKey(nfcRow))
    let nfdTab = try #require(workspace.openRedisKey(nfdRow))
    #expect(nfdTab != nfcTab)
    #expect(workspace.openRedisKey(nfcRow) == nfcTab)
    #expect(workspace.openRedisKey(nfdRow) == nfdTab)
    #expect(workspace.tabs.count == 2)
    let nfc = try Self.tabKey(nfcTab, in: workspace)
    let nfd = try Self.tabKey(nfdTab, in: workspace)
    #expect(nfc.bytes == Self.cafeNFC && nfd.bytes == Self.cafeNFD)

    let session = try #require(factory.sessions.last)
    let sink = EditHistorySink()
    let editor = RedisKeyEditor(context: Self.gatedContext(workspace, sink: sink))
    for (key, own, twin) in [(nfc, Self.cafeNFC, Self.cafeNFD), (nfd, Self.cafeNFD, Self.cafeNFC)] {
      let epoch = try await Self.loadEpoch(key, workspace: workspace)
      // TYPE answers hash, then HSETNX is sent
      session.answerRedisSends(with: [[.string("0"), .string("simple"), .string("hash")]])
      let sentBefore = session.redisCommands.count
      let write = try RedisKeyWrite.hashField(
        key, field: Self.text("f"), value: Self.text("v"), old: nil)
      #expect(await editor.request(write, epoch: epoch) == .written(.simple(.text("hash"))))
      let sent = Array(session.redisCommands.dropFirst(sentBefore))
      #expect(sent == [RedisKeyCommands.type(key), write.command])
      for command in sent {
        #expect(command.args.filter { $0 == own }.count == 1)
        #expect(!command.args.contains { $0.range(of: twin) != nil })
      }
    }
    #expect(sink.outcomes.count == 2)
  }

  @Test("An edit under the epoch of an older connection sends nothing, not even its check")
  @MainActor
  func staleEpochEditRefused() async throws {
    let (workspace, factory, config) = try await Self.connectedWorkspace()
    let keys = try await Self.treeKeys(
      [Self.injectionKey], workspace: workspace, factory: factory)
    let row = try #require(keys.first)
    let key = try Self.tabKey(try #require(workspace.openRedisKey(row)), in: workspace)
    let loaded = try await Self.loadEpoch(key, workspace: workspace)
    // A reconnect since the key was read
    try await workspace.connectionManager.connect(config: config)
    #expect(await workspace.connectionManager.connectionEpoch != loaded)
    try #require(factory.sessions.last).answerRedisSends(
      with: [[.string("0"), .string("simple"), .string("hash")]])
    let sent = factory.redisCommands.count

    let sink = EditHistorySink()
    let context = Self.gatedContext(workspace, sink: sink)
    let write = try RedisKeyWrite.hashField(
      key, field: Self.text("f"), value: Self.text("v"), old: nil)
    await #expect {
      _ = try await context.write(write.command, loaded, true)
    } throws: { error in
      if case .sessionChanged = error as? DatabaseError { return true }
      return false
    }
    let editor = RedisKeyEditor(context: context)
    #expect(await editor.request(write, epoch: loaded) == nil)
    #expect(editor.phase == .failed(context.staleMessage))
    #expect(factory.redisCommands.count == sent)
    #expect(sink.outcomes.isEmpty)
  }
}
