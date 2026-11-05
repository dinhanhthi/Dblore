// SQLRestoreDropTargetTests.swift
// Before a restore that drops, `executeGatedRestore` reads the target's catalog and refuses, with
// nothing executed, a DROP that would reach more than the script recreates: PostgreSQL
// partitions and owned sequences (DROP TABLE takes them along) and types that are not enums
// (DROP TYPE drops them), DuckDB schema names that also name a database of the session and a
// session moved off `main` (USE, SET schema), SQLite names in temp or only in an attached
// database (an unqualified DROP looks there). The decisions are pure
// (`SQLRestorePlan.check...DropTargets`); PostgreSQL and DuckDB reads, and an unreadable SQLite
// database list, run on a fake session, other SQLite reads on real files.

import Foundation
import Testing

@testable import Dblore

@Suite("SQL restore drop targets")
struct SQLRestoreDropTargetTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static func script(_ engine: DatabaseType, _ statements: [String]) -> String {
    let header = SQLDumpAssembler.header(
      engine: engine, created: Date(timeIntervalSince1970: 1_760_000_000), version: 2)
    return ([header] + statements).map { $0 + "\n" }.joined()
  }

  private static func key(_ schema: String, _ name: String) -> [[UInt8]] {
    [Array(schema.utf8), Array(name.utf8)]
  }

  private static func strings(_ values: String...) -> [CellValue] { values.map { .string($0) } }

  // MARK: - PostgreSQL

  private static let postgresDropDump = script(
    .postgresql,
    [
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "DROP TABLE IF EXISTS \"app\".\"events\", app.Logs;",
      "DROP SEQUENCE IF EXISTS \"app\".\"logs_id_seq\";",
      "DROP TYPE IF EXISTS \"app\".\"mood\";",
      "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok');",
      "CREATE SEQUENCE \"app\".\"logs_id_seq\" AS integer START WITH 1;",
      "CREATE TABLE \"app\".\"events\" (\"at\" date) PARTITION BY RANGE (at);",
      "CREATE TABLE app.logs (\"id\" integer);",
    ])

  private static let postgresDrops = SQLRestorePlan.PostgresDrops(
    tables: [key("app", "events"), key("app", "logs")], types: [key("app", "mood")],
    createdSequences: [key("app", "logs_id_seq")])

  @Test("PostgreSQL: the plan keeps the dropped tables and types and the sequences it creates")
  func postgresPlanRecordsDrops() throws {
    let plan = try SQLRestorePlan(script: Self.postgresDropDump, engine: .postgresql)
    #expect(plan.postgresDrops == Self.postgresDrops)
    #expect(plan.droppedDuckDBSchemas.isEmpty && plan.droppedSQLiteNames.isEmpty)
    // A script that drops only views and sequences reads nothing
    let views = try SQLRestorePlan(
      script: Self.script(
        .postgresql,
        ["DROP VIEW IF EXISTS \"app\".\"v\";", "CREATE VIEW \"app\".\"v\" AS SELECT 1;"]),
      engine: .postgresql)
    #expect(views.postgresDrops == nil)
  }

  @Test(
    "PostgreSQL: a kept partition or child, an owned sequence not created, or a non-enum refuses",
    arguments: [
      (
        [strings("inherits", "app", "events", "app", "events_2024")],
        SQLRestoreError.dropTakesAlong(
          table: "app.events", object: "app.events_2024", objectKind: "partition or child table")
      ),
      (
        [strings("owns", "app", "logs", "app", "logs_other_seq")],
        .dropTakesAlong(
          table: "app.logs", object: "app.logs_other_seq", objectKind: "owned sequence")
      ),
      ([strings("type", "app", "mood", "d", "")], .dropTypeIsDomain(name: "app.mood")),
      // DROP TYPE on a range also drops its multirange and constructors
      ([strings("type", "app", "mood", "r", "")], .dropTypeNotEnum(name: "app.mood")),
      ([strings("type", "app", "mood", "c", "")], .dropTypeNotEnum(name: "app.mood")),
      ([strings("type", "app", "mood", "b", "")], .dropTypeNotEnum(name: "app.mood")),
      ([strings("inherits", "app", "events")], .dropTargetsUnreadable("unexpected answer")),
      ([strings("rule", "app", "events", "", "")], .dropTargetsUnreadable("unexpected answer")),
      (
        [[CellValue.string("owns"), .null, .string("logs"), .string("app"), .string("x")]],
        .dropTargetsUnreadable("unexpected answer")
      ),
    ] as [([[CellValue]], SQLRestoreError)])
  func postgresRefusals(rows: [[CellValue]], expected: SQLRestoreError) {
    #expect(throws: expected) {
      try SQLRestorePlan.checkPostgresDropTargets(rows, Self.postgresDrops)
    }
  }

  @Test("PostgreSQL: dropped partitions, recreated sequences and objects the script leaves pass")
  func postgresPasses() throws {
    var drops = Self.postgresDrops
    drops.tables.insert(Self.key("app", "events_2024"))
    try SQLRestorePlan.checkPostgresDropTargets(
      [
        Self.strings("inherits", "app", "events", "app", "events_2024"),
        Self.strings("owns", "app", "logs", "app", "logs_id_seq"),
        // Tables, types and names the script does not drop; case is exact
        Self.strings("inherits", "app", "other", "app", "other_1"),
        Self.strings("owns", "app", "Logs", "app", "x_seq"),
        Self.strings("type", "app", "positive", "d", ""),
        Self.strings("type", "App", "mood", "r", ""),
      ], drops)
  }

  @Test("PostgreSQL: an unquoted name folds to the catalog's lowercase, a quoted one stays exact")
  func postgresCaseAgainstTheCatalog() throws {
    func drops(_ name: String) throws -> SQLRestorePlan.PostgresDrops? {
      try SQLRestorePlan(
        script: Self.script(
          .postgresql,
          ["DROP TABLE IF EXISTS \(name);", "CREATE TABLE \(name) (\"id\" integer);"]),
        engine: .postgresql
      ).postgresDrops
    }
    let child = Self.strings("inherits", "app", "foo", "app", "foo_1")
    let unquoted = try #require(try drops("app.Foo"))
    #expect(unquoted.tables == [Self.key("app", "foo")])
    #expect(
      throws: SQLRestoreError.dropTakesAlong(
        table: "app.foo", object: "app.foo_1", objectKind: "partition or child table")
    ) { try SQLRestorePlan.checkPostgresDropTargets([child], unquoted) }
    let quoted = try #require(try drops("\"app\".\"Foo\""))
    #expect(quoted.tables == [Self.key("app", "Foo")])
    try SQLRestorePlan.checkPostgresDropTargets([child], quoted)
  }

  @Test("PostgreSQL: a DROP of a name over 63 bytes, which the server truncates, is refused")
  func postgresLongNamesRefused() throws {
    // Two-byte letters: 63 and 64 UTF-8 bytes, far fewer characters
    let fits = String(repeating: "é", count: 31) + "a"
    let long = String(repeating: "é", count: 32)
    func script(schema: String, name: String) -> String {
      let target = "\"\(schema)\".\"\(name)\""
      return Self.script(
        .postgresql,
        ["DROP TABLE IF EXISTS \(target);", "CREATE TABLE \(target) (\"id\" integer);"])
    }
    let plan = try SQLRestorePlan(script: script(schema: "app", name: fits), engine: .postgresql)
    #expect(plan.postgresDrops?.tables == [Self.key("app", fits)])
    for (schema, name) in [("app", long), (long, "t")] {
      let error = #expect(throws: SQLRestoreError.self) {
        try SQLRestorePlan(script: script(schema: schema, name: name), engine: .postgresql)
      }
      guard case .statementRefused(let index, _) = error else {
        Issue.record("Unexpected \(String(describing: error))")
        continue
      }
      #expect(index == 0)
    }
  }

  @Test("PostgreSQL: the catalog read asks only for what the plan drops")
  func postgresQueryFollowsTheDrops() {
    func branches(_ drops: SQLRestorePlan.PostgresDrops) -> [String] {
      let query = DatabaseConnectionManager.postgresDropTargetsQuery(drops)
      return ["inherits", "owns", "type"].filter {
        query.contains("SELECT '\($0)'::pg_catalog.text")
      }
    }
    var tables = Self.postgresDrops
    tables.types = []
    #expect(branches(tables) == ["inherits", "owns"])
    var types = Self.postgresDrops
    types.tables = []
    #expect(branches(types) == ["type"])
    #expect(branches(Self.postgresDrops) == ["inherits", "owns", "type"])
    // No table row type or array type: DROP TYPE refuses those without CASCADE
    let query = DatabaseConnectionManager.postgresDropTargetsQuery(types)
    #expect(
      query.contains("c.relkind OPERATOR(pg_catalog.=) 'c'")
        && query.contains("e.typarray OPERATOR(pg_catalog.=) t.oid"))
    #expect(!query.contains("UNION ALL"))
  }

  private func connect(
    _ type: DatabaseType, database: String = "db", rows: [[CellValue]]
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: type.capabilities, rows: rows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 5432, database: database, username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return (manager, factory)
  }

  private func restoreError(_ manager: DatabaseConnectionManager, _ script: String) async -> Error?
  {
    do {
      _ = try await manager.executeGatedRestore(
        script: script, policy: open, connectionEpoch: await manager.connectionEpoch)
      return nil
    } catch {
      return error
    }
  }

  @Test("PostgreSQL: the catalog read comes first; a refusal sends nothing else")
  func postgresReadBeforeTheBatch() async throws {
    let (manager, factory) = try await connect(
      .postgresql, rows: [Self.strings("inherits", "app", "events", "app", "events_2024")])
    let error = await restoreError(manager, Self.postgresDropDump)
    #expect(
      error as? SQLRestoreError
        == .dropTakesAlong(
          table: "app.events", object: "app.events_2024", objectKind: "partition or child table"))
    #expect(error?.localizedDescription.contains("Nothing was executed") == true)
    #expect(
      factory.statements == [DatabaseConnectionManager.postgresDropTargetsQuery(Self.postgresDrops)]
    )

    let (passing, passingFactory) = try await connect(.postgresql, rows: [])
    let summary = try await passing.executeGatedRestore(
      script: Self.postgresDropDump, policy: open, connectionEpoch: await passing.connectionEpoch)
    #expect(summary.count(.drop) == 3)
    let sent = passingFactory.statements
    #expect(sent.first == DatabaseConnectionManager.postgresDropTargetsQuery(Self.postgresDrops))
    #expect(sent.dropFirst().first == "BEGIN")
  }

  // MARK: - DuckDB

  private static let duckdbDatabases = [
    strings("memory", "main", ""), strings("foo", "main", ""), strings("system", "main", ""),
    strings("temp", "main", ""),
  ]

  @Test("DuckDB: the plan keeps the schemas it drops in, lowercased")
  func duckdbPlanRecordsSchemas() throws {
    let plan = try SQLRestorePlan(
      script: Self.script(
        .duckdb,
        [
          "CREATE SCHEMA IF NOT EXISTS \"S\";", "DROP VIEW IF EXISTS \"main\".\"v\";",
          "DROP TABLE IF EXISTS \"S\".\"t\";", "CREATE TABLE s.t(id INTEGER);",
          "CREATE VIEW v AS SELECT 1;",
        ]), engine: .duckdb)
    #expect(plan.droppedDuckDBSchemas == ["s", "main"])
    #expect(plan.postgresDrops == nil && plan.droppedSQLiteNames.isEmpty)
  }

  @Test(
    "DuckDB: a schema that names a database, a moved session or an odd answer refuses",
    arguments: [
      (duckdbDatabases, ["foo"], SQLRestoreError.dropNamesDuckDBDatabase(name: "foo")),
      (duckdbDatabases, ["memory", "s"], .dropNamesDuckDBDatabase(name: "memory")),
      (
        [strings("memory", "s2", "s2")], ["s"],
        .duckdbSessionNotAtMain(schema: "s2", searchPath: "s2")
      ),
      (
        [strings("memory", "main", "memory.main")], ["s"],
        .duckdbSessionNotAtMain(schema: "main", searchPath: "memory.main")
      ),
      ([], ["s"], .dropTargetsUnreadable("unexpected answer")),
      ([strings("memory", "main")], ["s"], .dropTargetsUnreadable("unexpected answer")),
      (
        [[CellValue.string("memory"), .string("main"), .null]], ["s"],
        .dropTargetsUnreadable("unexpected answer")
      ),
    ] as [([[CellValue]], [String], SQLRestoreError)])
  func duckdbRefusals(rows: [[CellValue]], schemas: [String], expected: SQLRestoreError) {
    #expect(throws: expected) {
      try SQLRestorePlan.checkDuckDBDropTargets(rows, droppedSchemas: Set(schemas))
    }
  }

  @Test("DuckDB: database and schema names compare across ASCII case")
  func duckdbNamesFoldCase() {
    #expect(throws: SQLRestoreError.dropNamesDuckDBDatabase(name: "foo")) {
      try SQLRestorePlan.checkDuckDBDropTargets(
        [Self.strings("memory", "main", ""), Self.strings("FOO", "main", "")],
        droppedSchemas: ["foo"])
    }
  }

  @Test("DuckDB: schemas of the current database at its defaults pass")
  func duckdbPasses() throws {
    try SQLRestorePlan.checkDuckDBDropTargets(Self.duckdbDatabases, droppedSchemas: ["main", "s2"])
  }

  @Test("DuckDB: the read comes before the batch; a refusal sends nothing else")
  func duckdbReadBeforeTheBatch() async throws {
    let dump = Self.script(
      .duckdb,
      [
        "DROP TABLE IF EXISTS \"foo\".\"orders\";", "CREATE SCHEMA IF NOT EXISTS \"foo\";",
        "CREATE TABLE foo.orders(x INTEGER);",
      ])
    let (manager, factory) = try await connect(
      .duckdb, database: DuckDBSession.inMemoryPath, rows: Self.duckdbDatabases)
    let error = await restoreError(manager, dump)
    #expect(error as? SQLRestoreError == .dropNamesDuckDBDatabase(name: "foo"))
    #expect(factory.statements == [DatabaseConnectionManager.duckdbDropTargetsQuery])

    let (moved, movedFactory) = try await connect(
      .duckdb, database: DuckDBSession.inMemoryPath, rows: [Self.strings("memory", "s2", "s2")])
    let movedError = await restoreError(
      moved,
      Self.script(.duckdb, ["DROP TABLE IF EXISTS \"main\".\"t\";", "CREATE TABLE t(x INTEGER);"]))
    #expect(
      movedError as? SQLRestoreError == .duckdbSessionNotAtMain(schema: "s2", searchPath: "s2"))
    #expect(movedFactory.statements == [DatabaseConnectionManager.duckdbDropTargetsQuery])
  }

  // MARK: - SQLite

  @Test("SQLite: a dropped name in temp, or only in an attached database, refuses")
  func sqliteDecisions() throws {
    let dropped: Set<[UInt8]> = [Array("parent".utf8)]
    try SQLRestorePlan.checkSQLiteDropTargets(
      [("main", "Parent"), ("other", "parent"), ("other", "child")], dropped: dropped)
    #expect(throws: SQLRestoreError.dropReachesOtherDatabase(name: "PARENT", database: "other")) {
      try SQLRestorePlan.checkSQLiteDropTargets([("other", "PARENT")], dropped: dropped)
    }
    #expect(throws: SQLRestoreError.dropReachesOtherDatabase(name: "parent", database: "temp")) {
      try SQLRestorePlan.checkSQLiteDropTargets(
        [("main", "parent"), ("temp", "parent")], dropped: dropped)
    }
  }

  @Test(
    "SQLite: a database list with a NULL or a non-text name refuses; nothing else is sent",
    arguments: [[[CellValue.null]], [[.int(1)]], [[.string("main"), .string("x")]]])
  func sqliteDatabaseListUnreadable(rows: [[CellValue]]) async throws {
    let (manager, factory) = try await connect(.sqlite, rows: rows)
    let error = await restoreError(manager, Self.sqliteDropDump)
    #expect(error as? SQLRestoreError == .dropTargetsUnreadable("unexpected answer"))
    #expect(factory.statements == [DatabaseConnectionManager.sqliteDatabasesQuery])
  }

  @Test("SQLite: the plan keeps the dropped tables and views")
  func sqlitePlanRecordsNames() throws {
    let plan = try SQLRestorePlan(
      script: Self.script(
        .sqlite,
        [
          "PRAGMA defer_foreign_keys = ON;", "DROP VIEW IF EXISTS \"V\";",
          "DROP TABLE IF EXISTS \"Parent\";", "CREATE TABLE parent (id INTEGER PRIMARY KEY);",
          "CREATE VIEW v AS SELECT 1;",
        ]), engine: .sqlite)
    #expect(plan.droppedSQLiteNames == [Array("v".utf8), Array("parent".utf8)])
    #expect(plan.droppedSQLiteTables == [Array("parent".utf8)])
  }

  private static func makeDatabase(_ statements: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-drop-targets-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    for statement in statements { try handle.execute(statement) }
    return url
  }

  private static func removeDatabase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  /// `main` with `other` attached as configured on the connection
  @MainActor
  private static func connectSQLite(
    _ main: URL, attaching other: URL
  ) async throws -> DatabaseConnectionManager {
    var config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: main.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.attachedDatabases = [AttachedDatabase(name: "other", path: other.path, bookmark: nil)]
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: config)
    return manager
  }

  private static func count(_ url: URL, _ sql: String) throws -> Int64? {
    let statement = try SQLiteHandle(url: url).prepare(sql)
    guard try statement.step() else { return nil }
    return statement.columnInt(0)
  }

  private static let sqliteDropDump = script(
    .sqlite,
    [
      "PRAGMA defer_foreign_keys = ON;", "DROP TABLE IF EXISTS \"parent\";",
      "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT);",
      "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(1, 'new');",
    ])

  @Test("SQLite: a table only in an attached database or in temp is never dropped")
  func sqliteAttachedAndTempRefused() async throws {
    let other = try Self.makeDatabase([
      "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)",
      "INSERT INTO parent VALUES (1, 'attached')",
    ])
    defer { Self.removeDatabase(other) }
    let main = try Self.makeDatabase([])
    defer { Self.removeDatabase(main) }
    let manager = try await Self.connectSQLite(main, attaching: other)
    let attached = try await manager.executeInternal("SELECT count(*) FROM other.parent")
    #expect(attached.rows == [[.int(1)]])
    let error = await restoreError(manager, Self.sqliteDropDump)
    #expect(
      error as? SQLRestoreError == .dropReachesOtherDatabase(name: "parent", database: "other"))
    #expect(error?.localizedDescription.contains("Nothing was executed") == true)

    // A temp table of the same name shadows main's
    _ = try await manager.executeInternal("CREATE TABLE main.parent (id INTEGER PRIMARY KEY)")
    _ = try await manager.executeInternal("CREATE TEMP TABLE parent (id INTEGER)")
    let temp = await restoreError(manager, Self.sqliteDropDump)
    #expect(temp as? SQLRestoreError == .dropReachesOtherDatabase(name: "parent", database: "temp"))
    await manager.disconnect()
    #expect(try Self.count(other, "SELECT count(*) FROM parent WHERE name = 'attached'") == 1)
    #expect(try Self.count(main, "SELECT count(*) FROM sqlite_master WHERE name = 'parent'") == 1)
  }

  @Test("SQLite: with the name in main, the attached database's table is left alone")
  func sqliteMainTableRestored() async throws {
    let other = try Self.makeDatabase([
      "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)",
      "INSERT INTO parent VALUES (1, 'attached')",
    ])
    defer { Self.removeDatabase(other) }
    let main = try Self.makeDatabase([
      "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT, old TEXT)",
      "INSERT INTO parent VALUES (7, 'old', 'x')",
    ])
    defer { Self.removeDatabase(main) }
    let manager = try await Self.connectSQLite(main, attaching: other)
    let summary = try await manager.executeGatedRestore(
      script: Self.sqliteDropDump, policy: open, connectionEpoch: await manager.connectionEpoch)
    await manager.disconnect()
    #expect(summary.count(.drop) == 1)
    #expect(try Self.count(main, "SELECT count(*) FROM parent WHERE name = 'new'") == 1)
    #expect(try Self.count(main, "SELECT count(*) FROM parent") == 1)
    #expect(try Self.count(other, "SELECT count(*) FROM parent WHERE name = 'attached'") == 1)
  }
}
