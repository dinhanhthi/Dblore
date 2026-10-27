// MySQLTempTableTrackerTests.swift
// MySQL temporary tables of the session (`MySQLTempTableTracker`): names from successful
// CREATE TEMPORARY TABLE, removed by DROP [TEMPORARY] TABLE and by error 1146, cleared on
// reconnect. Case rule: as typed, compared exactly. No live server: a fake MySQL session.

import Foundation
import Testing

@testable import Dblore

@Suite("MySQL temp table tracker")
@MainActor
struct MySQLTempTableTrackerTests {
  private typealias Name = MySQLTempTableTracker.Name
  private let open = ProtectionPolicy(protectionLevel: .none)

  // MARK: - Parsing and case rule

  @Test("CREATE TEMPORARY TABLE tracks the name as typed, unqualified in the connected database")
  func createTracksNameAsTyped() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TEMPORARY TABLE Scratch (id INT)", connected: "shop")
    tracker.noteSucceeded("create temporary table other_db.Copy like orders", connected: "shop")
    #expect(
      tracker.names == [
        Name(database: "shop", name: "Scratch"), Name(database: "other_db", name: "Copy"),
      ])
    #expect(tracker.tables.map(\.qualifiedName) == ["shop.Scratch", "other_db.Copy"])
    #expect(tracker.tables.allSatisfy { $0.isTemporary })
  }

  @Test("Backticks and doubled backticks give the identifier's content")
  func quotedNames() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TEMPORARY TABLE `my``tbl` (id INT)", connected: "shop")
    tracker.noteSucceeded(
      "CREATE TEMPORARY TABLE /* note */ `Other DB` . `a.b` AS SELECT 1", connected: "shop")
    #expect(
      tracker.names == [
        Name(database: "shop", name: "my`tbl"), Name(database: "Other DB", name: "a.b"),
      ])
    tracker.noteSucceeded("DROP TEMPORARY TABLE `my``tbl`, `Other DB`.`a.b`", connected: "shop")
    #expect(tracker.names.isEmpty)
  }

  @Test("Names compare exactly: a DROP in another case or database keeps the entry")
  func caseRule() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TEMPORARY TABLE Foo (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE foo (id INT)", connected: "shop")
    #expect(tracker.names.map(\.name) == ["Foo", "foo"])
    tracker.noteSucceeded("DROP TABLE FOO", connected: "shop")
    tracker.noteSucceeded("DROP TABLE other.Foo", connected: "shop")
    #expect(tracker.names.map(\.name) == ["Foo", "foo"])
    tracker.noteSucceeded("DROP TABLE foo", connected: "shop")
    #expect(tracker.names == [Name(database: "shop", name: "Foo")])
  }

  @Test("IF NOT EXISTS tracks once; MariaDB OR REPLACE is a create")
  func ifNotExistsAndOrReplace() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TEMPORARY TABLE IF NOT EXISTS t (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE IF NOT EXISTS t (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE OR REPLACE TEMPORARY TABLE u (id INT)", connected: "shop")
    #expect(tracker.names.map(\.name) == ["t", "u"])
  }

  @Test("DROP [TEMPORARY] TABLE [IF EXISTS] with several names removes the tracked ones")
  func multiTableDrop() {
    var tracker = MySQLTempTableTracker()
    for name in ["a", "b", "c", "d"] {
      tracker.noteSucceeded("CREATE TEMPORARY TABLE \(name) (id INT)", connected: "shop")
    }
    tracker.noteSucceeded("DROP TEMPORARY TABLE IF EXISTS a, missing, shop.b", connected: "shop")
    #expect(tracker.names.map(\.name) == ["c", "d"])
    // A temporary table hides the base table of the same name: plain DROP TABLE drops it
    tracker.noteSucceeded("drop table if exists c restrict", connected: "shop")
    #expect(tracker.names.map(\.name) == ["d"])
  }

  @Test("Other statements and non-identifier names are not tracked")
  func ignoredStatements() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TABLE plain (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE \"quoted\" (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE /*!32300 TEMPORARY */ TABLE hidden (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE nodb (id INT)", connected: "")
    tracker.noteSucceeded("SELECT 1", connected: "shop")
    #expect(tracker.names.isEmpty)
  }

  @Test("Error 1146 naming a tracked table removes it, and only it")
  func missingTableMessage() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TEMPORARY TABLE gone (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE kept (id INT)", connected: "shop")
    tracker.forgetMissing(serverMessage: "Table 'shop.gone' doesn't exist")
    #expect(tracker.names.map(\.name) == ["kept"])
  }

  @Test("After USE, unqualified CREATE and DROP use that database")
  func useChangesDefaultDatabase() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("USE other_db", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE x (id INT)", connected: "shop")
    tracker.noteSucceeded("use `Odd``Db`", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE y (id INT)", connected: "shop")
    #expect(
      tracker.names == [Name(database: "other_db", name: "x"), Name(database: "Odd`Db", name: "y")])
    tracker.noteSucceeded("USE other_db", connected: "shop")
    tracker.noteSucceeded("DROP TEMPORARY TABLE x", connected: "shop")
    #expect(tracker.names == [Name(database: "Odd`Db", name: "y")])
  }

  @Test("A USE that cannot be read stops unqualified tracking until reset")
  func unreadableUseStopsUnqualifiedTracking() {
    for unreadable in ["/*!32312 USE other_db*/", "USE 'other_db'", "USE a b"] {
      var tracker = MySQLTempTableTracker()
      tracker.noteSucceeded("CREATE TEMPORARY TABLE kept (id INT)", connected: "shop")
      tracker.noteSucceeded(unreadable, connected: "shop")
      tracker.noteSucceeded("CREATE TEMPORARY TABLE x (id INT)", connected: "shop")
      tracker.noteSucceeded("CREATE TEMPORARY TABLE shop.q (id INT)", connected: "shop")
      #expect(
        tracker.names == [Name(database: "shop", name: "kept"), Name(database: "shop", name: "q")],
        "\(unreadable)")
      tracker.reset()
      tracker.noteSucceeded("CREATE TEMPORARY TABLE x (id INT)", connected: "shop")
      #expect(tracker.names == [Name(database: "shop", name: "x")], "\(unreadable)")
    }
  }

  @Test("While the default database is unknown, an unqualified DROP removes the name everywhere")
  func unknownDatabaseDropRemovesEveryMatch() {
    var tracker = MySQLTempTableTracker()
    tracker.noteSucceeded("CREATE TEMPORARY TABLE kept (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE other.kept (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE other.Kept (id INT)", connected: "shop")
    tracker.noteSucceeded("CREATE TEMPORARY TABLE other.stays (id INT)", connected: "shop")
    tracker.noteSucceeded("USE 'unreadable'", connected: "shop")
    tracker.noteSucceeded("DROP TABLE kept", connected: "shop")
    #expect(
      tracker.names == [
        Name(database: "other", name: "Kept"), Name(database: "other", name: "stays"),
      ])
  }

  // MARK: - Through the connection manager

  @Test("A successful CREATE is tracked and listed as temporary; a failed one is not")
  func managerTracksSuccessfulCreate() async throws {
    let (manager, session) = try await connect(.mysql)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE scratch (id INT)", policy: open)
    session.failNextCommand(containing: "broken")
    await #expect(throws: DatabaseError.self) {
      _ = try await manager.execute(
        userSQL: "CREATE TEMPORARY TABLE broken (id INT)", policy: open)
    }
    let tables = try await manager.fetchTables()
    #expect(tables.map(\.qualifiedName) == ["db.scratch"])
    #expect(tables.map(\.isTemporary) == [true])

    _ = try await manager.execute(userSQL: "DROP TEMPORARY TABLE scratch", policy: open)
    #expect(await manager.mysqlTempTables.names.isEmpty)
  }

  @Test("Reconnecting clears the tracked names and restores the connected database")
  func reconnectClears() async throws {
    let (manager, _) = try await connect(.mysql)
    _ = try await manager.execute(userSQL: "USE other_db", policy: open)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE scratch (id INT)", policy: open)
    #expect(await manager.mysqlTempTables.names == [Name(database: "other_db", name: "scratch")])
    await manager.disconnect()
    try await manager.connect(config: Self.config(.mysql))
    #expect(await manager.mysqlTempTables.names.isEmpty)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE scratch (id INT)", policy: open)
    #expect(await manager.mysqlTempTables.names == [Name(database: "db", name: "scratch")])
  }

  @Test("The server's error 1146 for a tracked table removes it and reloads the sidebar")
  func managerForgetsMissingTable() async throws {
    let (manager, _) = try await connect(.mysql)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE scratch (id INT)", policy: open)
    // The CREATE's own reload, taken here
    #expect(await manager.takeSchemaRefresh())
    let query = "SELECT * FROM `db`.`scratch` LIMIT 100"
    _ = await manager.queryFailure(
      MySQLSessionError(code: 1064, sqlState: "42000", message: "'db.scratch' syntax"),
      query: query, startTime: Date())
    #expect(await manager.mysqlTempTables.names.count == 1)
    #expect(!(await manager.takeSchemaRefresh()))
    let missing = await manager.queryFailure(
      MySQLSessionError(code: 1146, sqlState: "42S02", message: "Table 'db.scratch' doesn't exist"),
      query: query, startTime: Date())
    #expect(missing.localizedDescription.contains("1146"))
    #expect(await manager.mysqlTempTables.names.isEmpty)
    // The sidebar reloads without the name
    #expect(await manager.takeSchemaRefresh())
  }

  @Test("App-built DROP TABLE (schema change, sequential commands) untracks the temporary table")
  func appBuiltDropUntracks() async throws {
    let (manager, _) = try await connect(.mysql)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE a (id INT)", policy: open)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE b (id INT)", policy: open)
    let epoch = await manager.connectionEpoch
    _ = try await manager.executeGatedSchemaChange(
      ["DROP TABLE `db`.`a`"], policy: open, connectionEpoch: epoch)
    #expect(await manager.mysqlTempTables.names == [Name(database: "db", name: "b")])
    _ = try await manager.executeGatedSequentialCommands(
      ["DROP TABLE `b`"], policy: open, connectionEpoch: epoch, expectedRows: nil)
    #expect(await manager.mysqlTempTables.names.isEmpty)
  }

  @Test("A statement opening with an executable comment stops unqualified tracking")
  func managerExecutableCommentUse() async throws {
    let (manager, _) = try await connect(.mysql)
    _ = try await manager.execute(userSQL: "/*!32312 USE other_db*/", policy: open)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE x (id INT)", policy: open)
    #expect(await manager.mysqlTempTables.names.isEmpty)
  }

  @Test("Other engines track nothing")
  func otherEnginesIgnored() async throws {
    let (manager, _) = try await connect(.postgresql)
    _ = try await manager.execute(userSQL: "CREATE TEMPORARY TABLE scratch (id INT)", policy: open)
    #expect(await manager.mysqlTempTables.names.isEmpty)
  }

  // MARK: - Helpers

  private func connect(
    _ databaseType: DatabaseType
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.config(databaseType))
    return (manager, try #require(factory.sessions.first))
  }

  private static func config(_ databaseType: DatabaseType) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: databaseType, host: "fake", port: 1, database: "db", username: "u",
      password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
  }
}
