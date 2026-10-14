// MySQLEditTargetTests.swift
// Result column origins on MySQL 8.4 (3307) and MariaDB 11.4 (3308): a single-table result is
// editable (origins from the column definitions' schema, orgTable and orgName, resolved to
// ORDINAL_POSITION), with mixed-case names, a table name with a dot and a db-qualified FROM;
// joins and expressions are not; aliases keep their origin; a zero-row result keeps its origins.
// Foreign keys come from information_schema and the referenced-row lookup runs with backticks
// and `?` binds. Names whose dotted spelling collides across databases keep distinct
// identities. Server cases are opt-in (`.requiresMySQL`). Tables use the `Met_` prefix.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLEditTargetTests {
  typealias Server = MySQLSessionTests.Server

  private static let database = TestMySQLDatabase.database
  private static let users = "Met_Users"
  private static let dotted = "met.dot"
  private static let orders = "Met_Orders"
  private let policy = ProtectionPolicy(protectionLevel: .none)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  // MARK: - No server

  @Test("A MySQL qualified name is two backtick-quoted identifiers")
  func backtickQualifiedName() {
    func accepts(_ name: String) -> Bool {
      CellUpdateStatement.isServerQualifiedName(name, dialect: .mysql)
    }
    #expect(accepts("`db`.`t`"))
    #expect(accepts("`my.db`.`we``ird`"))
    #expect(!accepts("`db`.`t"))
    #expect(!accepts("`db`.``"))
    #expect(!accepts("`db`.`t`; DROP TABLE x"))
    #expect(!accepts(#""db"."t""#))
    #expect(!accepts("`t`"))
    // The PostgreSQL rule does not accept backticks.
    #expect(!CellUpdateStatement.isServerQualifiedName("`db`.`t`"))
  }

  @Test("The lookup SQL quotes with backticks")
  func lookupSQLUsesBackticks() {
    let key = ForeignKey(
      constraintName: "fk", sourceSchema: "db", sourceTable: "child", sourceColumns: ["p"],
      targetSchema: "my.db", targetTable: "Pa`rent", targetColumns: ["ID"])
    let query = ForeignKeyLookup.lookupSQL(for: key, values: ["p": .int(7)], dialect: .mysql)
    #expect(query?.sql == "SELECT * FROM `my.db`.`Pa``rent` WHERE `ID` = :fk1 LIMIT 2")
    #expect(query?.parameters == ["fk1": .text("7")])
  }

  // MARK: - Server

  @Test(
    "A single-table result is editable, mixed case, dotted and db-qualified", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func singleTableIsEditable(server: Server) async throws {
    try await withFixtures(server) { viewModel, manager in
      let usersID = TableRef.mysql(database: Self.database, table: Self.users)
      let dottedID = TableRef.mysql(database: Self.database, table: Self.dotted)
      let cases: [(sql: String, tableID: TableRef, key: [String], maxRows: Int)] = [
        ("SELECT * FROM Met_Users", usersID, ["UserID"], 100),
        ("SELECT * FROM `\(Self.database)`.Met_Users", usersID, ["UserID"], 100),
        ("SELECT * FROM `met.dot` ORDER BY id", dottedID, ["id"], 100),
        // Capped (truncated) read: the origins are still resolved.
        ("SELECT * FROM Met_Users", usersID, ["UserID"], 1),
      ]
      for item in cases {
        let (result, targets) = try await run(item.sql, viewModel, manager, maxRows: item.maxRows)
        #expect(result.columns.map(\.origin?.columnOrdinal) == [1, 2], "\(item.sql)")
        #expect(result.columns.allSatisfy { $0.origin?.tableID == item.tableID }, "\(item.sql)")
        let target = try #require(targets.editTarget, "\(item.sql)")
        #expect(target.tableID == item.tableID)
        #expect(target.primaryKeyColumns == item.key)
      }
    }
  }

  @Test(
    "Joins and expressions are not editable; an alias keeps its origin", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func joinsExpressionsAndAliases(server: Server) async throws {
    try await withFixtures(server) { viewModel, manager in
      let join = try await run(
        "SELECT u.UserID, d.v FROM Met_Users u JOIN `met.dot` d ON d.id = u.UserID",
        viewModel, manager)
      #expect(join.targets.editTarget == nil)
      #expect(join.targets.lookupRelation == nil)
      #expect(Set(join.result.columns.compactMap(\.origin?.tableID)).count == 2)

      let expression = try await run(
        "SELECT UserID, Name, 1 + 1 AS two FROM Met_Users", viewModel, manager)
      #expect(expression.result.columns.map(\.origin?.columnOrdinal) == [1, 2, nil])
      #expect(expression.targets.editTarget == nil)

      let aliased = try await run("SELECT UserID AS u, Name FROM Met_Users", viewModel, manager)
      #expect(aliased.result.columns.map(\.origin?.columnOrdinal) == [1, 2])
      #expect(aliased.targets.editTarget == nil)
      #expect(aliased.targets.lookupRelation?.baseColumns == ["UserID", "Name"])
    }
  }

  @Test("A zero-row result keeps its origins", .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func zeroRowsKeepOrigins(server: Server) async throws {
    try await withFixtures(server) { viewModel, manager in
      let (result, targets) = try await run(
        "SELECT * FROM Met_Users WHERE 1 = 0", viewModel, manager)
      #expect(result.rows.isEmpty)
      #expect(result.columns.map(\.origin?.columnOrdinal) == [1, 2])
      #expect(targets.editTarget?.primaryKeyColumns == ["UserID"])
    }
  }

  @Test(
    "Foreign keys come from information_schema and the lookup returns the referenced row",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func foreignKeyLookup(server: Server) async throws {
    try await withFixtures(server) { viewModel, manager in
      let keys = try await manager.fetchForeignKeys().filter { $0.sourceTable == Self.orders }
      let key = try #require(keys.first)
      #expect(keys.count == 1)
      #expect(key.sourceSchema == Self.database)
      #expect(key.sourceColumns == ["UserRef"])
      #expect(key.targetSchema == Self.database)
      #expect(key.targetTable == Self.users)
      #expect(key.targetColumns == ["UserID"])

      viewModel.databaseForeignKeys = keys
      let found = try await viewModel.lookupReferencedRow(
        column: "UserRef", schema: Self.database, table: Self.orders,
        rowColumns: ["id", "UserRef"], values: ["id": .int(1), "UserRef": .int(7)])
      #expect(found?.rows.count == 1)
      #expect(found?.rows.first == [.int(7), .string("Ada")])
    }
  }

  @Test(
    "Names whose dotted spelling collides keep distinct identities", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func dottedNamesDoNotCollide(server: Server) async throws {
    // `<db>.dot`.c and `<db>`.`dot.c` both spelled "<db>.dot.c" before the identity was quoted.
    let otherDatabase = "\(Self.database).dot"
    let root = DatabaseConnectionManager()
    try await root.connect(config: MySQLManagerTests.rootConfig(server))
    let rootSetup = [
      "DROP DATABASE IF EXISTS `\(otherDatabase)`",
      "CREATE DATABASE `\(otherDatabase)`",
      "CREATE TABLE `\(otherDatabase)`.c (id INT PRIMARY KEY, v INT)",
      "INSERT INTO `\(otherDatabase)`.c VALUES (7, 700)",
      "GRANT SELECT ON `\(otherDatabase)`.* TO 'dblore_test'@'%'",
    ]
    let rootTearDown = [
      "REVOKE ALL PRIVILEGES ON `\(otherDatabase)`.* FROM 'dblore_test'@'%'",
      "DROP DATABASE IF EXISTS `\(otherDatabase)`",
    ]
    do {
      for sql in rootSetup { _ = try await root.executeInternal(sql) }
      try await withFixtures(server) { viewModel, manager in
        _ = try await manager.executeInternal("CREATE TABLE `dot.c` (id INT PRIMARY KEY, v INT)")
        _ = try await manager.executeInternal("INSERT INTO `dot.c` VALUES (7, 70)")
        let localID = TableRef.mysql(database: Self.database, table: "dot.c")
        let otherID = TableRef.mysql(database: otherDatabase, table: "c")
        #expect(localID != otherID)

        // The local table first: its ordinals are cached before the other database is read.
        let local = try await run("SELECT * FROM `dot.c`", viewModel, manager)
        #expect(local.result.columns.map(\.origin?.tableID) == [localID, localID])
        #expect(local.targets.editTarget?.tableID == localID)
        #expect(local.targets.editTarget?.qualifiedName == "`\(Self.database)`.`dot.c`")

        let other = try await run("SELECT * FROM `\(otherDatabase)`.c", viewModel, manager)
        #expect(other.result.columns.map(\.origin?.tableID) == [otherID, otherID])
        #expect(other.result.columns.map(\.origin?.columnOrdinal) == [1, 2])
        // Same column names as `dot.c`: before, its cached ordinals made this result
        // editable as `dot.c`. Another database is never editable.
        #expect(other.targets.editTarget == nil)

        let join = try await run(
          "SELECT l.id, l.v, o.id, o.v FROM `dot.c` l JOIN `\(otherDatabase)`.c o ON o.id = l.id",
          viewModel, manager)
        #expect(join.result.rows.count == 1)
        #expect(
          join.result.columns.map(\.origin?.tableID) == [localID, localID, otherID, otherID])
        #expect(join.targets.editTarget == nil)
        #expect(join.targets.lookupRelation == nil)
      }
    } catch {
      for sql in rootTearDown { _ = try? await root.executeInternal(sql) }
      await root.disconnect()
      throw error
    }
    for sql in rootTearDown { _ = try? await root.executeInternal(sql) }
    await root.disconnect()
  }

  @Test(
    "A view in another database never edits a same-named base table", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func crossDatabaseViewIsNotEditable(server: Server) async throws {
    // Measured 2026-10-10: for a view, MySQL 8.4 reports the view's database and name; MariaDB
    // 11.4 reports the BASE table's database with the VIEW's name. So on MariaDB the origin of
    // `<other>`.Met_Alias (a view over <db>.Met_Base) is <db>.Met_Alias, a real base table.
    let otherDatabase = "\(Self.database)_xv"
    let root = DatabaseConnectionManager()
    try await root.connect(config: MySQLManagerTests.rootConfig(server))
    let rootSetup = [
      "DROP VIEW IF EXISTS `\(Self.database)`.Met_View",
      "DROP DATABASE IF EXISTS `\(otherDatabase)`",
      "CREATE DATABASE `\(otherDatabase)`",
      "CREATE TABLE `\(otherDatabase)`.Met_Src (id INT PRIMARY KEY, v INT)",
      "INSERT INTO `\(otherDatabase)`.Met_Src VALUES (1, 100)",
      "GRANT SELECT ON `\(otherDatabase)`.* TO 'dblore_test'@'%'",
    ]
    let rootTearDown = [
      "REVOKE ALL PRIVILEGES ON `\(otherDatabase)`.* FROM 'dblore_test'@'%'",
      "DROP DATABASE IF EXISTS `\(otherDatabase)`",
      "DROP VIEW IF EXISTS `\(Self.database)`.Met_View",
    ]
    do {
      for sql in rootSetup { _ = try await root.executeInternal(sql) }
      try await withFixtures(server) { viewModel, manager in
        for sql in [
          "CREATE TABLE Met_Base (id INT PRIMARY KEY, v INT)",
          "INSERT INTO Met_Base VALUES (1, 10)",
          "CREATE TABLE Met_Alias (id INT PRIMARY KEY, v INT)",
          "INSERT INTO Met_Alias VALUES (1, 1)",
        ] {
          _ = try await manager.executeInternal(sql)
        }
        for sql in [
          "CREATE VIEW `\(otherDatabase)`.Met_Alias AS SELECT id, v FROM `\(Self.database)`.Met_Base",
          "CREATE VIEW `\(Self.database)`.Met_View AS SELECT id, v FROM `\(otherDatabase)`.Met_Src",
        ] {
          _ = try await root.executeInternal(sql)
        }
        let localAlias = TableRef.mysql(database: Self.database, table: "Met_Alias")

        let view = try await run("SELECT * FROM `\(otherDatabase)`.Met_Alias", viewModel, manager)
        #expect(view.result.rows == [[.int(1), .int(10)]])
        let reported = view.result.columns.first?.origin?.tableID
        if server == .mariadb {
          #expect(reported == localAlias)
        } else {
          #expect(reported == .mysql(database: otherDatabase, table: "Met_Alias"))
        }
        #expect(view.targets.editTarget == nil)
        #expect(view.targets.lookupRelation == nil)

        // A view in the connected database over another database's table.
        let local = try await run("SELECT * FROM Met_View", viewModel, manager)
        #expect(local.result.rows == [[.int(1), .int(100)]])
        #expect(local.targets.editTarget == nil)

        // The same unqualified name after USE: the current database is no longer the
        // connected one.
        _ = try await manager.execute(userSQL: "USE `\(otherDatabase)`", policy: policy)
        let used = try await run("SELECT * FROM Met_Alias", viewModel, manager)
        #expect(used.result.rows == [[.int(1), .int(10)]])
        #expect(used.targets.editTarget == nil)
        #expect(used.targets.lookupRelation == nil)
        _ = try await manager.execute(userSQL: "USE `\(Self.database)`", policy: policy)

        // The real base table stays editable.
        let base = try await run("SELECT * FROM Met_Alias", viewModel, manager)
        #expect(base.result.rows == [[.int(1), .int(1)]])
        #expect(base.targets.editTarget?.tableID == localAlias)
      }
    } catch {
      for sql in rootTearDown { _ = try? await root.executeInternal(sql) }
      await root.disconnect()
      throw error
    }
    for sql in rootTearDown { _ = try? await root.executeInternal(sql) }
    await root.disconnect()
  }

  @Test("The lookup relation drops a column whose cached ordinal names another column")
  func lookupRelationChecksSourceName() {
    let tableID = TableRef.mysql(database: "db", table: "t")
    let table = EditTable(
      oid: 1, attributeNames: [1: "id", 2: "b"], primaryKeyColumns: ["id"],
      tableRef: tableID, schema: "db", name: "t")
    func column(_ name: String, source: String, ordinal: Int) -> ColumnInfo {
      ColumnInfo(
        name: name, type: "INT", origin: ColumnOrigin(tableID: tableID, columnOrdinal: ordinal),
        sourceName: ColumnSourceName(schema: "db", table: "t", column: source))
    }
    // An alias keeps its base column.
    #expect(
      CellUpdateStatement.lookupRelation(
        columns: [column("x", source: "id", ordinal: 1)], table: table)?.baseColumns == ["id"])
    // A stale ordinal (columns renamed since it was cached) is no lookup at all.
    #expect(
      CellUpdateStatement.lookupRelation(
        columns: [column("a", source: "a", ordinal: 2)], table: table) == nil)
  }

  // MARK: - Helpers

  private func run(
    _ sql: String, _ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager,
    maxRows: Int = 100
  ) async throws -> (result: QueryResult, targets: ResultTargets) {
    let epoch = await manager.connectionEpoch
    let result = try await manager.execute(userSQL: sql, policy: policy, maxRows: maxRows)
    let targets = await viewModel.resultTargets(
      for: sql, result: result, connectionManager: manager, epoch: epoch)
    return (result, targets)
  }

  /// `Met_Users (UserID PK, Name)` with (7, 'Ada') and (8, 'Bo'), `met.dot (id PK, v)` with
  /// (7, 70), `Met_Orders (id PK, UserRef -> Met_Users)` with (1, 7). Dropped on every path.
  private func withFixtures(
    _ server: Server,
    _ body: (NotebookViewModel, DatabaseConnectionManager) async throws -> Void
  ) async throws {
    let config = MySQLManagerTests.config(server)
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: config)
      for sql in Self.dropStatements + Self.createStatements {
        _ = try await manager.executeInternal(sql)
      }
      let viewModel = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config))
      viewModel.connectionManager = manager
      viewModel.connectionState = .connected
      try await body(viewModel, manager)
    } catch {
      await Self.tearDown(manager)
      throw error
    }
    await Self.tearDown(manager)
  }

  private static func tearDown(_ manager: DatabaseConnectionManager) async {
    for sql in dropStatements {
      _ = try? await manager.executeInternal(sql)
    }
    await manager.disconnect()
  }

  private static let dropStatements = [
    "DROP TABLE IF EXISTS Met_Orders",
    "DROP TABLE IF EXISTS Met_Users",
    "DROP TABLE IF EXISTS `met.dot`",
    "DROP TABLE IF EXISTS `dot.c`",
    "DROP TABLE IF EXISTS Met_Base",
    "DROP TABLE IF EXISTS Met_Alias",
  ]

  private static let createStatements = [
    "CREATE TABLE Met_Users (UserID INT PRIMARY KEY, Name VARCHAR(10))",
    "INSERT INTO Met_Users VALUES (7, 'Ada'), (8, 'Bo')",
    "CREATE TABLE `met.dot` (id INT PRIMARY KEY, v INT)",
    "INSERT INTO `met.dot` VALUES (7, 70)",
    """
    CREATE TABLE Met_Orders (id INT PRIMARY KEY, UserRef INT,
      CONSTRAINT met_fk FOREIGN KEY (UserRef) REFERENCES Met_Users (UserID))
    """,
    "INSERT INTO Met_Orders VALUES (1, 7)",
  ]
}
