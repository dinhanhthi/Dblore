// EngineRoutingTests.swift
// Each engine gets its own catalog SQL and transaction start. DuckDB is refused with
// `engineUnavailable` while its plugin is not installed; it never falls back to PostgreSQL.
// ClickHouse and SQL Server read their catalog through the engine plugin's introspector and are
// refused the same way without their plugin. Redis is a `RedisSession` once its plugin is
// installed: it opens only a plugin that answers hello as `redis` with the `argv` feature, sends
// commands as exact argument bytes and forwards the brakes and the close to its plugin session.

import Foundation
import Testing

@testable import Dblore

@Suite("Engine routing")
struct EngineRoutingTests {
  private func connectFake(_ type: DatabaseType) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager(
      sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract()))
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return manager
  }

  @Test("DuckDB routes to the DuckDB introspector, never PostgreSQL catalog SQL")
  func duckdbIntrospector() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    #expect(await manager.introspector is DuckDBSchemaIntrospector)
    _ = try await manager.fetchTables()
    let catalogReads = factory.sessions.flatMap(\.queries)
    #expect(catalogReads.contains { $0.contains("duckdb_tables()") })
    #expect(!catalogReads.contains { $0.contains("pg_") })
  }

  @Test(
    "ClickHouse and SQL Server route to the engine plugin introspector",
    arguments: [DatabaseType.clickhouse, .sqlserver])
  func enginePluginIntrospector(type: DatabaseType) async throws {
    #expect(try await connectFake(type).introspector is EnginePluginIntrospector)
  }

  @Test("App transactions use each engine's own BEGIN")
  func appOwnedBegin() async throws {
    #expect(try await connectFake(.postgresql).appOwnedBeginSQL == "BEGIN")
    #expect(try await connectFake(.sqlite).appOwnedBeginSQL == "BEGIN IMMEDIATE")
    #expect(try await connectFake(.duckdb).appOwnedBeginSQL == "BEGIN TRANSACTION")
    #expect(try await connectFake(.mysql).appOwnedBeginSQL == "START TRANSACTION")
  }

  /// Statements sent by an app-owned BEGIN on a fake session whose capabilities claim brakes.
  private func appBeginStatements(_ type: DatabaseType) async throws -> [String] {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    let before = factory.statements.count
    try await manager.beginAppTransaction(caller: nil)
    return Array(factory.statements.dropFirst(before))
  }

  @Test("PostgreSQL suspends the idle-in-transaction timeout after the app BEGIN")
  func postgresqlSuspendsIdleTimeout() async throws {
    #expect(
      try await appBeginStatements(.postgresql) == [
        "BEGIN", "SET LOCAL idle_in_transaction_session_timeout = 0",
      ])
  }

  @Test("MySQL sends nothing after the app BEGIN: it has no idle-in-transaction timeout")
  func mysqlSendsNoIdleTimeoutSuspension() async throws {
    #expect(try await appBeginStatements(.mysql) == ["START TRANSACTION"])
  }

  @Test("MySQL routes to the MySQL introspector bound to the connected database")
  func mysqlIntrospector() async throws {
    let manager = try await connectFake(.mysql)
    let introspector = try #require(await manager.introspector as? MySQLSchemaIntrospector)
    #expect(introspector.database == "db")
  }

  @Test("Connecting to MySQL opens a MySQL session (a closed port fails to connect)")
  func mysqlConnectRefused() async throws {
    let manager = DatabaseConnectionManager(sessionFactory: AppDatabaseSessionFactory())
    do {
      try await manager.connect(config: mysqlConfig)
      Issue.record("MySQL connect should fail")
    } catch DatabaseError.connectionFailed {}
    #expect(await manager.session == nil)
  }

  @Test("Testing a MySQL connection probes the server (a closed port fails to connect)")
  func mysqlTestConnectionRefused() async throws {
    let manager = DatabaseConnectionManager(sessionFactory: AppDatabaseSessionFactory())
    do {
      _ = try await manager.testConnection(config: mysqlConfig)
      Issue.record("MySQL test connection should fail")
    } catch DatabaseError.connectionFailed {}
  }

  private var mysqlConfig: ConnectionConfig {
    ConnectionConfig(
      databaseType: .mysql, host: "127.0.0.1", port: 1, database: "db", username: "u",
      sslMode: .disable, timeoutSeconds: 5)
  }

  /// The app factory with no plugin installed, whatever this Mac has installed.
  private func managerWithoutPlugins() -> DatabaseConnectionManager {
    DatabaseConnectionManager(
      sessionFactory: AppDatabaseSessionFactory(
        duckDBLibraryLoader: { nil }, enginePluginInstalled: { _ in false }))
  }

  /// Engines shipped by a plugin; none has an installed plugin in these tests.
  static let pluginEngines = DatabaseType.allCases.filter(\.capabilities.requiresPlugin)

  @Test("ClickHouse, SQL Server and Redis are plugin engines, as DuckDB is")
  func pluginEnginesListed() {
    #expect(Self.pluginEngines == [.duckdb, .clickhouse, .sqlserver, .redis])
  }

  @Test("Redis is a RedisSession once its plugin is installed, engineUnavailable before")
  func redisSessionNeedsPlugin() async throws {
    let config = ConnectionConfig(databaseType: .redis, host: "", database: "0")
    let session = try await AppDatabaseSessionFactory(enginePluginInstalled: { _ in true })
      .makeSession(config: config)
    #expect(session is RedisSession)
    do {
      _ = try await AppDatabaseSessionFactory(enginePluginInstalled: { _ in false })
        .makeSession(config: config)
      Issue.record("Redis makeSession should fail without its plugin")
    } catch DatabaseError.engineUnavailable(let refused) {
      #expect(refused == .redis)
    }
  }

  private static let redisConfig = ConnectionConfig(
    databaseType: .redis, host: "cache.example.com", port: 6379, database: "0", username: "u",
    password: "pw", sslMode: .disable, timeoutSeconds: 5)

  private func redisSession(_ fake: FakeEnginePlugin) -> RedisSession {
    RedisSession(
      pluginID: fake.install(), config: Self.redisConfig,
      hostKeyValidator: RejectUnknownSSHHostKeys())
  }

  @Test(
    "A plugin that is not a Redis plugin with argv is refused before its open (no password sent)",
    arguments: [("fake", ["argv"]), ("redis", [])])
  func redisHelloRefused(engine: String, features: [String]) async throws {
    let fake = FakeEnginePlugin()
    fake.engine = engine
    fake.features = features
    let session = redisSession(fake)

    let error = await #expect(throws: DatabaseError.self) { try await session.open() }

    guard case .connectionFailed(let message) = error else {
      Issue.record("Expected connectionFailed, got \(String(describing: error))")
      return
    }
    #expect(message.contains("Update the Redis plugin"))
    #expect(fake.count { if case .open = $0 { true } else { false } } == 0)
    await session.close()
  }

  @Test("A Redis session sends a command's exact bytes in its db and refuses SQL text")
  func redisSessionSendsArgv() async throws {
    let fake = FakeEnginePlugin()
    fake.engine = "redis"
    fake.features = ["argv"]
    fake.columns = [
      .init(name: "path", type: "text"), .init(name: "type", type: "text"),
      .init(name: "value", type: "value"),
    ]
    fake.batches = [[[.text("0"), .text("simple"), .text("OK")]]]
    let session = redisSession(fake)
    try await session.open()
    let command = RedisCommand(args: [Data("SET".utf8), Data("k".utf8), Data([0xFF, 0x00])], db: 3)

    let source = try await session.send(command)
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }

    #expect(try RedisReply(rows: rows) == .simple(.text("OK")))
    let sent = fake.requests.compactMap { if case .argv(let argv) = $0.kind { argv } else { nil } }
    #expect(sent.map(\.args) == [command.args])
    #expect(sent.map(\.db) == [3])
    await #expect(throws: (any Error).self) { _ = try await session.query("SELECT 1", binds: []) }
    await #expect(throws: (any Error).self) { _ = try await session.command("SET", binds: []) }
    #expect(fake.count { if case .query = $0 { true } else { false } } == 0)
    #expect(fake.count { if case .command = $0 { true } else { false } } == 0)
    await session.close()
  }

  @Test(
    "A Redis session forwards the brakes, cancel, error redaction, a loss and the close")
  func redisSessionForwards() async throws {
    let fake = FakeEnginePlugin()
    fake.engine = "redis"
    fake.features = ["argv"]
    // More rows events than the credit: the command stays in flight until cancelled
    fake.batches = Array(repeating: [[.int(1)]], count: 4)
    let session = redisSession(fake)
    try await session.open()
    #expect(session.serverVersion == "fake 1")

    try await session.applySessionSettings(
      statementTimeoutSeconds: 2, lockTimeoutSeconds: 0, idleTimeoutSeconds: 0)
    let settings = fake.requests.compactMap {
      if case .settings(let settings) = $0.kind { settings } else { nil }
    }
    #expect(settings.map(\.statementTimeoutSeconds) == [2])

    let running = try await session.send(RedisCommand(args: [Data("EVAL".utf8)], db: 0))
    let id = try #require(
      fake.requests.first { if case .argv = $0.kind { true } else { false } }
    ).id
    await session.interrupt()
    #expect(fake.count { $0 == .cancel(target: id) } == 1)
    withExtendedLifetime(running) {}

    let echoed = EnginePluginError.server(.init(code: .query, message: "bad password pw"))
    #expect(session.formatError(echoed) == "bad password ••••")

    var events = session.closeEvents.makeAsyncIterator()
    fake.loseConnection(try #require(fake.openedConnection))
    #expect(await events.next() == .connectionLost)
    await session.close()
    #expect(fake.count { $0 == .close } == 1)
  }

  @Test(
    "Connecting to a plugin engine without its plugin fails with engineUnavailable",
    arguments: pluginEngines)
  func pluginEngineConnectRefused(type: DatabaseType) async throws {
    let manager = managerWithoutPlugins()
    let config = ConnectionConfig(databaseType: type, host: "", database: "/tmp/x.\(type.rawValue)")
    do {
      try await manager.connect(config: config)
      Issue.record("\(type.rawValue) connect should fail")
    } catch DatabaseError.engineUnavailable(let refused) {
      #expect(refused == type)
      // The form offers its Install button for every plugin engine
      #expect(
        ConnectionErrorAction.action(for: DatabaseError.engineUnavailable(refused))
          == .openPluginSettings)
    }
    #expect(await manager.session == nil)
  }

  @Test(
    "Testing a plugin engine connection without its plugin fails with engineUnavailable",
    arguments: pluginEngines)
  func pluginEngineTestConnectionRefused(type: DatabaseType) async throws {
    let manager = managerWithoutPlugins()
    let config = ConnectionConfig(databaseType: type, host: "", database: "/tmp/x.\(type.rawValue)")
    do {
      _ = try await manager.testConnection(config: config)
      Issue.record("\(type.rawValue) test connection should fail")
    } catch DatabaseError.engineUnavailable(let refused) {
      #expect(refused == type)
    }
  }

  @Test(
    "Connect and Test Connection ask the factory's plugin check, which builds a plugin session",
    arguments: [DatabaseType.clickhouse, .sqlserver])
  func enginePluginCheckComesFromFactory(type: DatabaseType) async throws {
    let asked = AskedEngines()
    let manager = DatabaseConnectionManager(
      sessionFactory: AppDatabaseSessionFactory(enginePluginInstalled: { type in
        await asked.append(type)
        return false
      }))
    let config = ConnectionConfig(databaseType: type, host: "", database: "db")
    do {
      try await manager.connect(config: config)
      Issue.record("\(type.rawValue) connect should fail")
    } catch DatabaseError.engineUnavailable(let refused) {
      #expect(refused == type)
    }
    do {
      _ = try await manager.testConnection(config: config)
      Issue.record("\(type.rawValue) test connection should fail")
    } catch DatabaseError.engineUnavailable(let refused) {
      #expect(refused == type)
    }
    #expect(await asked.types == [type, type])
    // Installed: the factory builds the plugin session (not opened here, so nothing loads)
    let session = try await AppDatabaseSessionFactory(enginePluginInstalled: { _ in true })
      .makeSession(config: config)
    #expect(session is EnginePluginSession)
  }
}

/// The engines a plugin check was asked about, in order.
private actor AskedEngines {
  private(set) var types: [DatabaseType] = []

  func append(_ type: DatabaseType) { types.append(type) }
}
