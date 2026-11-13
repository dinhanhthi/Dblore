// RedisKeyBrowserModelTests.swift
// The Redis key browser's pure logic (keyspace and SCAN parsing, merge, tree split, labels,
// MATCH as one argument) and its reads through the gate on a fake session, read-only included.

import Foundation
import Observation
import Testing

@testable import Dblore

/// Set from an observation's `onChange`
private final class ObservedFlag: @unchecked Sendable {
  var isSet = false
}

@MainActor
@Suite("Redis key browser")
struct RedisKeyBrowserModelTests {
  private typealias Model = RedisKeyBrowserModel

  private static func row(_ path: String, _ type: String, _ value: CellValue) -> [CellValue] {
    [.string(path), .string(type), value]
  }

  /// A SCAN reply: cursor, then the keys as bulk strings (text when UTF-8, else bytes)
  private static func scanRows(cursor: String, keys: [Data]) -> [[CellValue]] {
    var rows = [
      row("0", "array", .int(2)), row("0.0", "bulk", .string(cursor)),
      row("0.1", "array", .int(keys.count)),
    ]
    for (index, key) in keys.enumerated() {
      let text = String(data: key, encoding: .utf8).flatMap { Data($0.utf8) == key ? $0 : nil }
      rows.append(row("0.1.\(index)", "bulk", text.map(CellValue.string) ?? .data(key)))
    }
    return rows
  }

  private static func connect(
    level: ConnectionProtectionLevel = .none
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .redis, host: "fake", port: 6379, database: "3", username: "",
        sslMode: .disable, protectionLevel: level, safeMode: .silent))
    return (manager, try #require(factory.sessions.first))
  }

  // MARK: - Keyspace

  @Test("INFO keyspace counts are read strictly; malformed lines are ignored")
  func keyspaceParsing() {
    let text = [
      "# Keyspace", "db0:keys=12,expires=2,avg_ttl=0", "db3:keys=11,expires=0,avg_ttl=5",
      "db40:keys=1", "db3:keys=99", "dbx:keys=1", "db-1:keys=1", "db5:keys=-1",
      "db6:expires=1,keys=3", "db7:keys=1٣", "db٣:keys=1", "db99999999999:keys=1",
      "db8:keys=99999999999999999999", "db9 :keys=1", "",
    ].joined(separator: "\r\n")
    #expect(Model.parseKeyspace(Data(text.utf8)) == [0: 12, 3: 11, 40: 1])
    #expect(Model.parseKeyspace(Data("db2:keys=4\n".utf8)) == [2: 4])
    let max = DatabaseConnectionManager.maxRedisDatabaseIndex
    #expect(Model.parseKeyspace(Data("db\(max):keys=1\ndb\(max + 1):keys=1".utf8)) == [max: 1])
  }

  @Test("Keyspace caps: bytes read and databases kept")
  func keyspaceCaps() {
    let many = (0..<1_000).map { "db\($0):keys=1" }.joined(separator: "\n")
    #expect(Model.parseKeyspace(Data(many.utf8)).count == Model.maxKeyspaceDatabases)
    let padded = String(repeating: "#", count: Model.maxKeyspaceBytes) + "\ndb1:keys=1"
    #expect(Model.parseKeyspace(Data(padded.utf8)).isEmpty)
  }

  @Test("The database rows are 0–15 plus the keyspace's, counts 0 when not named")
  func databaseRows() {
    let rows = Model.databases(keyspace: [3: 11, 40: 1], homeDatabase: 0)
    #expect(rows.map(\.index) == Array(0...15) + [40])
    #expect(rows[0].keyCount == 0)
    #expect(rows[3].keyCount == 11)
    #expect(rows.last?.keyCount == 1)
    #expect(
      Model.databases(keyspace: nil, homeDatabase: 0).map(\.keyCount)
        == Array(repeating: nil, count: 16))
  }

  @Test("The home database always has a row, with or without keyspace counts")
  func homeDatabaseRow() {
    let max = DatabaseConnectionManager.maxRedisDatabaseIndex
    let rows = Model.databases(keyspace: [40: 1], homeDatabase: 20)
    #expect(rows.map(\.index) == Array(0...15) + [20, 40])
    #expect(rows.first { $0.index == 20 }?.keyCount == 0)
    let unread = Model.databases(keyspace: nil, homeDatabase: max)
    #expect(unread.map(\.index) == Array(0...15) + [max])
    #expect(unread.last?.keyCount == nil)
    #expect(Model.databases(keyspace: [:], homeDatabase: 3).map(\.index) == Array(0...15))
    #expect(Model.databases(keyspace: [:], homeDatabase: max + 1).map(\.index) == Array(0...15))
    #expect(Model.databases(keyspace: [:], homeDatabase: -1).map(\.index) == Array(0...15))
  }

  @Test("INFO keyspace answers a bulk or verbatim string, nothing else")
  func keyspaceReply() throws {
    #expect(try Model.keyspaceText(.bulk(.text("db0:keys=1"))) == Data("db0:keys=1".utf8))
    #expect(try Model.keyspaceText(.verbatim(.bytes(Data([0x64])))) == Data([0x64]))
    #expect(throws: RedisReplyDecodingError.self) { try Model.keyspaceText(.integer(1)) }
  }

  // MARK: - SCAN

  @Test("A SCAN reply keeps the exact key bytes and reads the cursor strictly")
  func scanParsing() throws {
    let binary = Data([0xFF, 0x00, 0x0D, 0x0A]) + Data("FLUSHALL".utf8)
    let page = try Model.scanPage(
      RedisReply(rows: Self.scanRows(cursor: "18446744073709551615", keys: [binary])))
    #expect(page.cursor == UInt64.max)
    #expect(page.keys == [binary])
    for bad in ["", "-1", "1 ", "18446744073709551616", "٣", "0x1"] {
      #expect(throws: RedisReplyDecodingError.self) {
        try Model.scanPage(RedisReply(rows: Self.scanRows(cursor: bad, keys: [])))
      }
    }
    #expect(throws: RedisReplyDecodingError.self) {
      try Model.scanPage(.array([.bulk(.text("0")), .array([.integer(1)])]))
    }
  }

  @Test("Merge drops repeats and stops at the cap")
  func mergeDedupesAndCaps() {
    var keys: [Data] = []
    var seen: Set<Data> = []
    let a = Data("a".utf8)
    let b = Data("b".utf8)
    let c = Data("c".utf8)
    #expect(Model.merge([a, b, a], into: &keys, seen: &seen, cap: 3) == 2)
    #expect(Model.merge([b, c, Data("d".utf8)], into: &keys, seen: &seen, cap: 3) == 1)
    #expect(keys == [a, b, c])
  }

  @Test("MATCH is the pattern's exact bytes as one argument, * when empty")
  func matchIsOneArgument() {
    let pattern = "user:* x\r\nFLUSHALL"
    let command = RedisKeyCommands.scan(db: 2, cursor: 7, match: Model.matchArgument(pattern))
    #expect(
      command.args == ["SCAN", "7", "MATCH", pattern, "COUNT", "500"].map { Data($0.utf8) })
    #expect(Model.matchArgument("") == Data("*".utf8))
  }

  // MARK: - Tree

  @Test("The tree splits on the : byte; a key and a folder of the same name are two rows")
  func treeSplit() {
    let keys = ["user:2", "user", "user:1", "a::b", "z"].map { Data($0.utf8) }
    let tree = Model.tree(keys, db: 0)
    #expect(tree.map(\.label) == ["a", "user", "user", "z"])
    #expect(tree[1].id == .folder(db: 0, prefix: Data("user:".utf8)))
    #expect(tree[1].keyCount == 2)
    #expect(tree[2].id == .key(RedisKeyRef(db: 0, bytes: Data("user".utf8))))
    #expect(tree[1].children.map(\.label) == ["1", "2"])
    // `a::b`: folder "a", empty folder, key "b"
    #expect(tree[0].children.map(\.label) == [""])
    #expect(tree[0].children[0].children.map(\.id) == [.key(RedisKeyRef(db: 0, bytes: keys[3]))])
    // Collapsed: top level only; expanded "user": its keys under it
    let collapsed = Model.rows(tree, expanded: [], expandsAll: false)
    #expect(collapsed.count == 4)
    let opened = Model.rows(tree, expanded: [tree[1].id], expandsAll: false)
    #expect(opened.map(\.label) == ["a", "user", "1", "2", "user", "z"])
    #expect(opened[2].depth == 1)
    #expect(Model.rows(tree, expanded: [], expandsAll: true).count == 8)
  }

  @Test("NFC and NFD twins stay two rows with byte identities")
  func normalizationTwins() {
    let nfc = Data("caf\u{E9}".utf8)
    let nfd = Data("cafe\u{301}".utf8)
    let rows = Model.rows(Model.tree([nfc, nfd], db: 1), expanded: [], expandsAll: false)
    #expect(Set(rows.map(\.id)).count == 2)
    #expect(
      Set(rows.map(\.id)) == [.key(RedisKeyRef(db: 1, bytes: nfc)), .key(.init(db: 1, bytes: nfd))])
  }

  @Test("Tree depth is capped; the rest of the key stays in the leaf")
  func treeDepthCap() {
    let key = Data(String(repeating: ":", count: 10_000).utf8)
    var depth = 0
    var nodes = Model.tree([key], db: 0)
    while let first = nodes.first, !first.children.isEmpty {
      depth += 1
      nodes = first.children
    }
    #expect(depth == Model.maxTreeDepth - 1)
    #expect(nodes.first?.id == .key(RedisKeyRef(db: 0, bytes: key)))
  }

  @Test("Labels escape binary and control bytes and are cut")
  func labels() {
    let binary = Data([0xFF, 0x00, 0x0D, 0x0A]) + Data("FLUSHALL".utf8)
    #expect(Model.label(binary) == #"\xff\x00\r\nFLUSHALL"#)
    #expect(Model.label(Data("a\u{202E}b".utf8)) == #"a\u{202E}b"#)
    #expect(Model.label(Data("caf\u{E9}".utf8)) == "caf\u{E9}")
    let long = Model.label(Data(String(repeating: "k", count: 1_000).utf8))
    #expect(long.count == Model.maxLabelLength + 1)
    #expect(long.hasSuffix("…"))
  }

  @Test("A label escapes only a bounded prefix of a huge key")
  func hugeKeyLabel() {
    let size = 5 * 1_048_576
    let start = ContinuousClock.now
    let binary = Model.label(Data(repeating: 0xFF, count: size))
    let text = Model.label(Data(repeating: 0x6B, count: size))
    // Escaping all 5 MiB of 0xFF (20 M characters) would take seconds in a Debug build
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(binary == String(repeating: #"\xff"#, count: Model.maxLabelLength / 4) + "…")
    #expect(text == String(repeating: "k", count: Model.maxLabelLength) + "…")
  }

  @Test("A cut inside a multi-byte character keeps the label text; a cut key always ends in …")
  func cutLabels() {
    // 1 + 600 × 2 bytes: the byte cut falls inside an "é"
    let accented = Model.label(Data(("a" + String(repeating: "\u{E9}", count: 600)).utf8))
    #expect(!accented.contains(#"\x"#))
    #expect(accented == "a" + String(repeating: "\u{E9}", count: Model.maxLabelLength - 1) + "…")
    // Combining marks join one character: few characters, yet the key was cut
    let marks = Model.label(Data(("e" + String(repeating: "\u{301}", count: 1_000)).utf8))
    #expect(marks.count < Model.maxLabelLength)
    #expect(marks.hasSuffix("…"))
  }

  @Test("Tooltips are built with the tree: a key's whole escaped name, a folder's segment")
  func tooltips() {
    let key = Data("user:\r\n1".utf8)
    let tree = Model.tree([key], db: 0)
    #expect(tree.map(\.tooltip) == ["user"])
    #expect(tree[0].children.map(\.tooltip) == [#"user:\r\n1"#])
    #expect(tree[0].children.map(\.label) == [#"\r\n1"#])
    let rows = Model.rows(tree, expanded: [], expandsAll: true)
    #expect(rows.map(\.tooltip) == ["user", #"user:\r\n1"#])
  }

  // MARK: - Reads through the gate

  @Test("A read-only connection loads counts and keys with INFO keyspace and SCAN only")
  func readOnlyLoads() async throws {
    let (manager, session) = try await Self.connect(level: .readOnly)
    session.answerRedisSends(with: [Self.row("0", "bulk", .string("db3:keys=2,expires=0"))])
    let model = Model()
    await model.open(
      manager: manager, policy: { ProtectionPolicy(protectionLevel: .readOnly) },
      homeDatabase: 3)
    #expect(model.databasesError == nil)
    #expect(model.databases.first { $0.index == 3 }?.keyCount == 2)
    // The same answer to SCAN is no SCAN reply: that db's error, not a refusal
    #expect(model.listings[3]?.error?.contains("read-only") == false)

    session.answerRedisSends(
      with: Self.scanRows(cursor: "0", keys: ["k:1", "k:2"].map { Data($0.utf8) }))
    await model.setPattern("k:* \r\n")?.value
    #expect(model.listings[3]?.keys.count == 2)
    #expect(model.listings[3]?.isComplete == true)
    #expect(model.listings[3]?.error == nil)
    let sent = session.redisCommands
    #expect(sent.first == RedisKeyCommands.infoKeyspace(db: 3))
    #expect(sent.allSatisfy { $0.db == 3 })
    #expect(
      sent.last?.args
        == ["SCAN", "0", "MATCH", "k:* \r\n", "COUNT", "500"].map { Data($0.utf8) })
    #expect(!sent.contains { $0.args.first == Data("CONFIG".utf8) })
  }

  @Test("An empty page with a cursor keeps Load more; cursor 0 ends it")
  func emptyPagesKeepPaging() async throws {
    let (manager, session) = try await Self.connect()
    session.answerRedisSends(with: Self.scanRows(cursor: "42", keys: []))
    let model = Model()
    await model.open(
      manager: manager, policy: { ProtectionPolicy(protectionLevel: .none) }, homeDatabase: 0)
    let listing = try #require(model.listings[0])
    #expect(listing.keys.isEmpty)
    #expect(listing.cursor == 42)
    #expect(listing.canLoadMore)
    // INFO keyspace (1) + one Load more of at most `maxScansPerPage` SCANs
    #expect(session.redisCommands.count == 1 + Model.maxScansPerPage)

    session.answerRedisSends(with: Self.scanRows(cursor: "0", keys: [Data("x".utf8)]))
    await model.loadPage(db: 0)
    #expect(model.listings[0]?.keys == [Data("x".utf8)])
    #expect(model.listings[0]?.canLoadMore == false)
    #expect(session.redisCommands.last?.args[1] == Data("42".utf8))
  }

  @Test("A page for a pattern since replaced is dropped", .timeLimit(.minutes(1)))
  func stalePageDropped() async throws {
    let (manager, session) = try await Self.connect()
    session.answerRedisSends(with: Self.scanRows(cursor: "0", keys: []))
    let model = Model()
    await model.open(
      manager: manager, policy: { ProtectionPolicy(protectionLevel: .none) }, homeDatabase: 0)
    session.answerRedisSends(with: Self.scanRows(cursor: "0", keys: [Data("old".utf8)]))
    session.holdNextRedisSend()
    let old = Task { await model.reloadListings() }
    let held = await boundedWait("Redis send held") {
      while session.heldRedisSendCount == 0, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
    #expect(held == true)
    let sentBefore = session.redisCommands.count
    session.answerRedisSends(with: Self.scanRows(cursor: "0", keys: [Data("new".utf8)]))
    let new = try #require(model.setPattern("n*"))
    // The new page answered before the old one is released
    let newSent = await boundedWait("new SCAN sent") {
      while session.redisCommands.count == sentBefore, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
    #expect(newSent == true)
    await new.value
    #expect(model.listings[0]?.keys == [Data("new".utf8)])
    session.releaseHeldRedisSends()
    await old.value
    #expect(model.listings[0]?.keys == [Data("new".utf8)])
  }

  // MARK: - Cached rows

  /// Reads what the sidebar's list reads (everything but the selection)
  private static func readList(_ model: Model) {
    _ = model.rows(db: 0)
    _ = model.listings[0]
    _ = model.pattern
    _ = model.databases
    _ = model.databasesError
    _ = model.isLoadingDatabases
    _ = model.expandedDatabases
  }

  /// Whether `change` notifies a reader of `read`
  private static func notifies(
    _ read: () -> Void, on change: () -> Void
  ) -> Bool {
    let flag = ObservedFlag()
    withObservationTracking(read) { flag.isSet = true }
    change()
    return flag.isSet
  }

  @Test("Rows are cached: rebuilt on a tree, folder or pattern change, never on a selection")
  func cachedRows() async throws {
    let (manager, session) = try await Self.connect()
    let keys = ["a:1", "a:2", "b"].map { Data($0.utf8) }
    session.answerRedisSends(with: Self.scanRows(cursor: "0", keys: keys))
    let model = Model()
    await model.open(
      manager: manager, policy: { ProtectionPolicy(protectionLevel: .none) }, homeDatabase: 0)
    let tree = try #require(model.listings[0]?.tree)
    #expect(model.rows(db: 0) == Model.rows(tree, expanded: [], expandsAll: false))
    #expect(model.rows(db: 0).count == 2)

    // A selection: nothing the list reads changes
    let key = RedisKeyRef(db: 0, bytes: keys[2])
    #expect(!Self.notifies({ Self.readList(model) }, on: { model.select(key) }))
    #expect(model.selectedKey == key)

    // A folder opens and closes
    let folder = tree[0].id
    #expect(Self.notifies({ _ = model.rows(db: 0) }, on: { model.toggleFolder(folder) }))
    #expect(model.rows(db: 0) == Model.rows(tree, expanded: [folder], expandsAll: false))
    #expect(model.rows(db: 0).count == 4)
    model.toggleFolder(folder)
    #expect(model.rows(db: 0) == Model.rows(tree, expanded: [], expandsAll: false))

    // A pattern: cleared at once, then the new tree with every folder open
    session.answerRedisSends(
      with: Self.scanRows(cursor: "0", keys: ["a:1", "c:1"].map { Data($0.utf8) }))
    let reads = model.setPattern("*:1")
    #expect(model.rows(db: 0).isEmpty)
    await reads?.value
    let filtered = try #require(model.listings[0]?.tree)
    #expect(model.rows(db: 0) == Model.rows(filtered, expanded: [], expandsAll: true))
    #expect(model.rows(db: 0).count == 4)

    // A new tree (Load more, Reload)
    session.answerRedisSends(with: Self.scanRows(cursor: "0", keys: [Data("d".utf8)]))
    await model.reloadListings()
    #expect(model.rows(db: 0).map(\.label) == ["d"])

    model.reset()
    #expect(model.rows(db: 0).isEmpty)
  }

  @Test("A folder click is ignored while a pattern draws every folder open")
  func folderToggleIgnoredWithPattern() async {
    let model = Model()
    let folder = Model.NodeID.folder(db: 0, prefix: Data("a:".utf8))
    await model.setPattern("a*")?.value
    model.toggleFolder(folder)
    #expect(model.expandedFolders.isEmpty)
    await model.setPattern("")?.value
    model.toggleFolder(folder)
    #expect(model.expandedFolders == [folder])
  }

  @Test("A click selects the key at once; reset forgets it")
  func selection() {
    let model = Model()
    let key = RedisKeyRef(db: 3, bytes: Data([0xFF]))
    model.select(key)
    #expect(model.selectedKey == key)
    model.reset()
    #expect(model.selectedKey == nil)
  }
}
