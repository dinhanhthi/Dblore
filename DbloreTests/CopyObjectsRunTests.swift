// CopyObjectsRunTests.swift
// The Copy Objects run (`CopyObjectsRun`): SQLite to SQLite copies two tables with a foreign-key
// cycle with equal rows, a BLOB and a NULL byte for byte, a keyed and an unkeyed table over
// several reads, and rows past the 4 MiB chunk budget without reading any twice; a cancel leaves
// no table (real
// SQLite files in the temporary folder, source read through a read-only side manager). MySQL
// compensation (fake session recording statements): after a failing foreign key or CREATE TABLE
// only the tables the run created are dropped, in reverse order, with foreign key checks off.
// PostgreSQL and MySQL targets run in CI only (`.requiresPostgres`, `.requiresMySQL`).

import Foundation
import Testing
import os

@testable import Dblore

@Suite("CopyObjectsRunTests") @MainActor
struct CopyObjectsRunTests {
  typealias Engine = StructureDDLBuilder.Engine

  private static let sqlite = Engine.sqlite(libraryVersion: SQLiteLibraryVersion.current)
  private static let open = ProtectionPolicy(
    protectionLevel: .none, safeMode: .silent, protectedMode: false)

  /// a.b_id -> b and b.a_id -> a, every row pointing at a row of the other table
  private static let cycleSeed = [
    "CREATE TABLE a (id INTEGER PRIMARY KEY, b_id INTEGER REFERENCES b (id), label TEXT NOT NULL)",
    "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a (id))",
    "INSERT INTO a (id, b_id, label) VALUES (1, NULL, 'one'), (2, NULL, '')",
    "INSERT INTO b (id, a_id) VALUES (1, 2), (2, 1)",
    "UPDATE a SET b_id = id",
  ]

  @Test("SQLite to SQLite copies two tables with a foreign-key cycle with equal rows")
  func sqliteCycle() async throws {
    try await withFiles { sourceURL, targetURL in
      let (seed, side) = try await Self.source(sourceURL, Self.cycleSeed)
      let target = try await Self.sqliteTarget(targetURL)
      let (plan, checked) = try await Self.plan(["a", "b"], from: side, into: target)
      let history = RecordedHistory()
      let reported = OSAllocatedUnfairLock(initialState: [[Int]]())
      let result = try await CopyObjectsRun(
        plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
        target: target, recorder: history
      ).run(progress: { done, total in reported.withLock { $0.append([done, total]) } })

      #expect(result.tables == 2)
      #expect(result.rows == 4)
      #expect(reported.withLock { $0 } == [[1, 2], [2, 2]])
      for table in ["a", "b"] {
        let read = "SELECT * FROM \(table) ORDER BY id"
        #expect(
          try await target.manager.executeInternal(read).rows
            == (try await seed.executeInternal(read).rows))
      }
      // Declared inline and checked at COMMIT
      #expect(try await target.manager.executeInternal("PRAGMA foreign_key_check").rows.isEmpty)
      #expect(
        try await target.manager.executeInternal(
          "SELECT count(*) FROM pragma_foreign_key_list('a')"
        ).rows == [[.int(1)]])
      let entries = await history.entries
      #expect(entries.map(\.sql) == ["Copy Objects: 2 tables, 4 rows from source.sqlite"])
      #expect(entries.first?.source == .dataImport)
      #expect(entries.first?.status == .success)
      await Self.disconnect(seed, side, target.manager)
    }
  }

  @Test("A BLOB and a NULL survive SQLite to SQLite byte for byte")
  func blobAndNull() async throws {
    try await withFiles { sourceURL, targetURL in
      let (seed, side) = try await Self.source(
        sourceURL,
        [
          "CREATE TABLE c (id INTEGER PRIMARY KEY, data BLOB, note TEXT)",
          """
          INSERT INTO c (id, data, note) VALUES (1, X'00FF1027', ''), (2, NULL, NULL),
            (3, X'', 'x'), (4, 'text in a blob', NULL)
          """,
        ])
      let target = try await Self.sqliteTarget(targetURL)
      let (plan, checked) = try await Self.plan(["c"], from: side, into: target)
      _ = try await CopyObjectsRun(
        plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
        target: target, recorder: nil
      ).run()

      let read =
        "SELECT id, typeof(data), hex(data), typeof(note), quote(note) FROM c ORDER BY id"
      let copied = try await target.manager.executeInternal(read).rows
      #expect(copied == (try await seed.executeInternal(read).rows))
      #expect(
        copied.first == [
          .int(1), .string("blob"), .string("00FF1027"), .string("text"), .string("''"),
        ])
      #expect(
        copied[1] == [.int(2), .string("null"), .string(""), .string("null"), .string("NULL")])
      await Self.disconnect(seed, side, target.manager)
    }
  }

  @Test(
    "SQLite to SQLite: 1,200 keyed and 1,200 unkeyed rows copy over three reads each",
    .timeLimit(.minutes(1)))
  func manyReads() async throws {
    try await withFiles { sourceURL, targetURL in
      let (seed, side) = try await Self.source(
        sourceURL,
        [
          "CREATE TABLE keyed (id INTEGER PRIMARY KEY, v TEXT)",
          "CREATE TABLE loose (k INTEGER, v TEXT)",
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1200)
          INSERT INTO keyed (id, v) SELECT i, 'row ' || i FROM n
          """,
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1200)
          INSERT INTO loose (k, v) SELECT i % 7, 'loose ' || i FROM n
          """,
        ])
      let target = try await Self.sqliteTarget(targetURL)
      let (plan, checked) = try await Self.plan(["keyed", "loose"], from: side, into: target)
      let reported = OSAllocatedUnfairLock(initialState: [[Int]]())
      let run = CopyObjectsRun(
        plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
        target: target, recorder: nil)
      let result = try await run.run(progress: { done, total in
        reported.withLock { $0.append([done, total]) }
      })

      #expect(result.rows == 2_400)
      #expect(result.warnings.contains { $0.contains("\"loose\": no usable primary key") })
      #expect(reported.withLock { $0 } == (1...6).map { [$0, 6] })
      #expect(await run.rowsFetched == 2_400)
      for read in [
        "SELECT count(*), sum(id), total(length(v)) FROM keyed",
        "SELECT count(*), sum(k), total(length(v)) FROM loose",
        "SELECT group_concat(v, ',') FROM (SELECT v FROM keyed ORDER BY id)",
        "SELECT group_concat(k || v, ',') FROM (SELECT k, v FROM loose ORDER BY v)",
      ] {
        #expect(
          try await target.manager.executeInternal(read).rows
            == (try await seed.executeInternal(read).rows))
      }
      await Self.disconnect(seed, side, target.manager)
    }
  }

  @Test(
    "Rows past the 4 MiB budget are sent in the next chunk, never read twice",
    // 3 minutes: the 600-row case takes ~9 s alone but nears 60 s under full-suite load
    .timeLimit(.minutes(3)),
    arguments: [
      // Ten 1 MiB BLOBs (2 MiB each toward the budget as hex): one read, two rows a chunk
      (10, "BLOB", "randomblob(1048576)", [500]),
      // 600 rows of 20 KiB text: the first read of 500 overflows (205 rows a chunk), so the next
      // read is limited to 205
      (600, "TEXT", "hex(randomblob(10240))", [500, 205]),
    ])
  func largeRows(count: Int, type: String, value: String, limits: [Int]) async throws {
    try await withFiles { sourceURL, targetURL in
      let (seed, side) = try await Self.source(
        sourceURL,
        [
          "CREATE TABLE big (id INTEGER PRIMARY KEY, v \(type))",
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(count))
          INSERT INTO big (id, v) SELECT i, \(value) FROM n
          """,
        ])
      let target = try await Self.sqliteTarget(targetURL)
      let (plan, checked) = try await Self.plan(["big"], from: side, into: target)
      let run = CopyObjectsRun(
        plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
        target: target, recorder: nil)
      let result = try await run.run()

      #expect(result.rows == count)
      #expect(await run.rowsFetched == count)
      #expect(await run.readLimits == limits)
      let read = "SELECT count(*), sum(id), total(length(v)), typeof(min(v)) FROM big"
      #expect(
        try await target.manager.executeInternal(read).rows
          == (try await seed.executeInternal(read).rows))
      let digest =
        "SELECT group_concat(hex(substr(v, 1, 8)), ',') FROM (SELECT v FROM big ORDER BY id)"
      #expect(
        try await target.manager.executeInternal(digest).rows
          == (try await seed.executeInternal(digest).rows))
      await Self.disconnect(seed, side, target.manager)
    }
  }

  @Test("Cancel leaves no table on a SQLite target", .timeLimit(.minutes(1)))
  func cancelLeavesNoTable() async throws {
    try await withFiles { sourceURL, targetURL in
      let (seed, side) = try await Self.source(
        sourceURL,
        [
          "CREATE TABLE big (id INTEGER PRIMARY KEY, v TEXT)",
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1200)
          INSERT INTO big (id, v) SELECT i, 'row ' || i FROM n
          """,
        ])
      let target = try await Self.sqliteTarget(targetURL)
      let (plan, checked) = try await Self.plan(["big"], from: side, into: target)
      let history = RecordedHistory()
      let run = CopyObjectsRun(
        plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
        target: target, recorder: history)
      do {
        // After the first of three chunks: the next one is refused
        _ = try await run.run(progress: { done, _ in if done == 1 { run.cancel() } })
        Issue.record("Expected the cancelled copy to stop")
      } catch CopyObjectsRunError.cancelled(let leftovers) {
        #expect(leftovers.isEmpty)
      }
      #expect(await history.entries.map(\.status) == [.cancelled])
      await Self.disconnect(seed, side, target.manager)
      // A new connection: nothing of the run is left in the file
      let check = try await Self.sqliteManager(targetURL)
      #expect(
        try await check.executeInternal("SELECT count(*) FROM sqlite_master").rows
          == [[.int(0)]])
      await check.disconnect()
    }
  }

  @Test(
    "MySQL: a failing statement drops only the tables the run created, in reverse order",
    arguments: [false, true])
  func mysqlCompensation(failCreate: Bool) async throws {
    try await withFiles { sourceURL, _ in
      let (seed, side) = try await Self.source(sourceURL, Self.cycleSeed)
      let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.mysql.capabilities)
      let manager = DatabaseConnectionManager(sessionFactory: factory)
      let config = ConnectionConfig(
        databaseType: .mysql, host: "fake", port: 3306, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false)
      try await manager.connect(config: config)
      let session = try #require(factory.sessions.last)
      let target = CopyObjectsTarget(manager: manager, config: config, policy: Self.open)
      var structures: [CopyObjectsPlanner.SourceTable] = []
      for table in ["a", "b"] {
        structures.append(
          .init(structure: try await side.fetchTableStructure(schema: "main", table: table)))
      }
      let plan = try CopyObjectsPlanner.plan(
        structures, source: Self.sqlite,
        target: .mysql(MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)),
        targetSchema: "db", existingNames: [])
      let checked = try CopyObjectsDDLCheck.check(plan.editableDDL, plan: plan)
      session.failNextCommand(
        containing: failCreate ? plan.tables[1].createStatement : "FOREIGN KEY")
      let sentBefore = factory.statements.count

      do {
        _ = try await CopyObjectsRun(
          plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
          target: target, recorder: nil
        ).run()
        Issue.record("Expected the copy to fail")
      } catch CopyObjectsRunError.failed(_, let leftovers) {
        #expect(leftovers.isEmpty)
      }

      let sent = Array(factory.statements.dropFirst(sentBefore))
      let drops = sent.filter { $0.hasPrefix("DROP") }
      #expect(
        drops
          == (failCreate
            ? ["DROP TABLE `db`.`a`"] : ["DROP TABLE `db`.`b`", "DROP TABLE `db`.`a`"]))
      let checksOff = try #require(sent.firstIndex(of: "SET FOREIGN_KEY_CHECKS = 0"))
      let checksOn = try #require(sent.firstIndex(of: "SET FOREIGN_KEY_CHECKS = 1"))
      let dropIndexes = sent.indices.filter { sent[$0].hasPrefix("DROP") }
      #expect(dropIndexes.allSatisfy { checksOff < $0 && $0 < checksOn })
      // A failed CREATE stops the run before any row is sent
      #expect(sent.contains { $0.hasPrefix("INSERT") } == !failCreate)
      await manager.disconnect()
      await Self.disconnect(seed, side)
    }
  }

  // MARK: - Live targets (CI)

  @Test(
    "PostgreSQL target: rows, booleans and bytes arrive", .requiresPostgres, .timeLimit(.minutes(1))
  )
  func postgresTarget() async throws {
    let suffix = UUID().uuidString.prefix(8).lowercased()
    try await withFiles { sourceURL, _ in
      let (seed, side) = try await Self.source(sourceURL, Self.liveSeed(suffix))
      let config = ConnectionConfig(
        host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
        username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
        timeoutSeconds: 30, protectionLevel: .none, safeMode: .silent, protectedMode: false)
      let manager = DatabaseConnectionManager()
      try await manager.connect(config: config)
      do {
        let target = CopyObjectsTarget(manager: manager, config: config, policy: Self.open)
        let (plan, checked) = try await Self.plan(
          ["p_\(suffix)", "c_\(suffix)"], from: side, into: target, engine: .postgresql)
        let result = try await CopyObjectsRun(
          plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
          target: target, recorder: nil
        ).run()
        #expect(result.rows == 3)
        // An empty text reads as '', not NULL
        #expect(
          try await manager.executeInternal(
            "SELECT id, flag, encode(data, 'hex'), note FROM c_\(suffix) ORDER BY id"
          ).rows == [
            [.int(1), .bool(true), .string("00ff"), .string("")],
            [.int(2), .bool(false), .null, .null],
          ])
        // The identity continues after the copied ids
        #expect(
          try await manager.executeInternal(
            "INSERT INTO c_\(suffix) (p_id, flag) VALUES (1, true) RETURNING id"
          ).rows == [[.int(3)]])
      } catch {
        await Self.dropLive(manager, suffix)
        await Self.disconnect(seed, side)
        throw error
      }
      await Self.dropLive(manager, suffix)
      await Self.disconnect(seed, side)
    }
  }

  @Test(
    "MySQL target: rows, booleans and bytes arrive", .requiresMySQL, .timeLimit(.minutes(1)),
    arguments: [MySQLSessionTests.Server.mysql, .mariadb])
  func mysqlTarget(server: MySQLSessionTests.Server) async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
    let suffix = UUID().uuidString.prefix(8).lowercased()
    try await withFiles { sourceURL, _ in
      let (seed, side) = try await Self.source(sourceURL, Self.liveSeed(suffix))
      var config = MySQLManagerTests.rootConfig(server)
      config.protectionLevel = .none
      config.safeMode = .silent
      config.protectedMode = false
      let manager = DatabaseConnectionManager()
      try await manager.connect(config: config)
      do {
        let info = try #require(await manager.mysqlServerInfo)
        let target = CopyObjectsTarget(manager: manager, config: config, policy: Self.open)
        let (plan, checked) = try await Self.plan(
          ["p_\(suffix)", "c_\(suffix)"], from: side, into: target, engine: .mysql(info))
        let result = try await CopyObjectsRun(
          plan: plan, checked: checked, source: side, sourceLabel: "source.sqlite",
          target: target, recorder: nil
        ).run()
        #expect(result.rows == 3)
        #expect(
          try await manager.executeInternal(
            "SELECT id, CAST(flag AS CHAR), HEX(data), note FROM c_\(suffix) ORDER BY id"
          ).rows == [
            [.int(1), .string("1"), .string("00FF"), .string("")],
            [.int(2), .string("0"), .null, .null],
          ])
      } catch {
        await Self.dropLive(manager, suffix)
        await Self.disconnect(seed, side)
        throw error
      }
      await Self.dropLive(manager, suffix)
      await Self.disconnect(seed, side)
    }
  }

  /// p (one row) and c (two rows, a foreign key to p, a boolean, a BLOB, a NULL)
  private static func liveSeed(_ suffix: some StringProtocol) -> [String] {
    [
      "CREATE TABLE p_\(suffix) (id INTEGER PRIMARY KEY, name TEXT)",
      """
      CREATE TABLE c_\(suffix) (id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES p_\(suffix) (id),
        flag BOOLEAN, data BLOB, note TEXT)
      """,
      "INSERT INTO p_\(suffix) (id, name) VALUES (1, 'p')",
      """
      INSERT INTO c_\(suffix) (id, p_id, flag, data, note) VALUES (1, 1, 1, X'00FF', ''),
        (2, 1, 0, NULL, NULL)
      """,
    ]
  }

  private static func dropLive(
    _ manager: DatabaseConnectionManager, _ suffix: some StringProtocol
  )
    async
  {
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS c_\(suffix)")
    _ = try? await manager.executeInternal("DROP TABLE IF EXISTS p_\(suffix)")
    await manager.disconnect()
  }

  // MARK: - Helpers

  /// Runs `body` with two new SQLite file URLs, removed afterwards
  private func withFiles(_ body: (URL, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-copy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(
      directory.appendingPathComponent("source.sqlite"),
      directory.appendingPathComponent("target.sqlite"))
  }

  private static func sqliteConfig(_ url: URL) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent, protectedMode: false)
  }

  private static func sqliteManager(_ url: URL) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(url))
    return manager
  }

  /// The seeded source file, and the read-only side manager the run reads it through
  private static func source(
    _ url: URL, _ seed: [String]
  ) async throws -> (seed: DatabaseConnectionManager, side: DatabaseConnectionManager) {
    let manager = try await sqliteManager(url)
    for statement in seed { _ = try await manager.executeInternal(statement) }
    let side = manager.makeReadOnlySideManager()
    var config = sqliteConfig(url)
    config.readOnlyFile = true
    try await manager.connectSideManager(side, config: config)
    return (manager, side)
  }

  private static func sqliteTarget(_ url: URL) async throws -> CopyObjectsTarget {
    CopyObjectsTarget(
      manager: try await sqliteManager(url), config: sqliteConfig(url), policy: open)
  }

  /// The plan of `tables` read on `side`, into the target's default schema, and its DDL checked
  /// as the preview shows it
  private static func plan(
    _ tables: [String], from side: DatabaseConnectionManager, into target: CopyObjectsTarget,
    engine: Engine = sqlite
  ) async throws -> (CopyObjectsPlan, CopyObjectsDDLCheck.Checked) {
    var structures: [CopyObjectsPlanner.SourceTable] = []
    for table in tables {
      structures.append(
        .init(structure: try await side.fetchTableStructure(schema: "main", table: table)))
    }
    let names = try await target.manager.copyTargetNames()
    let plan = try CopyObjectsPlanner.plan(
      structures, source: sqlite, target: engine, targetSchema: names.schema,
      existingNames: names.existingNames, existingConstraintNames: names.existingConstraintNames)
    return (plan, try CopyObjectsDDLCheck.check(plan.editableDDL, plan: plan))
  }

  private static func disconnect(_ managers: DatabaseConnectionManager...) async {
    for manager in managers { await manager.disconnect() }
  }
}

/// The History rows a run records
private actor RecordedHistory: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}
