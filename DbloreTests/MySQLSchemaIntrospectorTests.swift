// MySQLSchemaIntrospectorTests.swift
// MySQLSchemaIntrospector against MySQL 8.4 (3307) and MariaDB 11.4 (3308): tables, views and
// column flags, row estimates, routines and triggers with their source, the edit target, foreign
// keys (composite, in key order), names that need backticks, MariaDB sequences, and a user
// without the privilege to read a routine or trigger source. Opt-in (`.requiresMySQL`).
// Fixtures are created by root (functions and triggers need it under binary logging) with
// DEFINER `dblore_test`, read as `dblore_test`, and use the `msi` prefix.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct MySQLSchemaIntrospectorTests {
  typealias Server = MySQLSessionTests.Server

  private static let database = TestMySQLDatabase.database
  private static let odd = "msi odd"
  private static let parent = "msi_parent"
  private static let noKey = "msi_nopk"
  private static let view = "msi view"
  private static let function = "msi `fn"
  private static let procedure = "msi proc"
  private static let trigger = "msi trg"

  private let introspector = MySQLSchemaIntrospector(database: TestMySQLDatabase.database)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  @Test(
    "Tables, views and column flags of the connected database", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func tablesViewsAndColumns(server: Server) async throws {
    try await withFixtures(server) { session in
      let tables = try await introspector.tables(in: session)
      let tableNames = Set(tables.filter { $0.name.hasPrefix("msi") }.map(\.name))
      #expect(tableNames == [Self.odd, Self.parent, Self.noKey])
      #expect(tables.allSatisfy { $0.schema == Self.database })

      let views = try await introspector.views(in: session)
      #expect(views.map(\.name).filter { $0.hasPrefix("msi") } == [Self.view])
      #expect(views.allSatisfy { $0.schema == Self.database })

      let columns = try await introspector.allColumns(in: session)
      let odd = try #require(columns["\(Self.database).\(Self.odd)"])
      #expect(
        odd.map(\.name) == ["id", "select", "n", "g", "s", "created", "pb", "pa", "u1", "u2"])
      let byName = Dictionary(uniqueKeysWithValues: odd.map { ($0.name, $0) })
      #expect(byName["id"]?.isPrimaryKey == true)
      #expect(byName["id"]?.isIdentity == true)
      #expect(byName["id"]?.isNullable == false)
      #expect(byName["id"]?.isUnique == false)
      #expect(byName["select"]?.isUnique == true)
      #expect(byName["select"]?.isPrimaryKey == false)
      #expect(byName["g"]?.isGenerated == true)
      #expect(byName["s"]?.isGenerated == true)
      // MySQL lists an expression default as DEFAULT_GENERATED: not a generated column.
      #expect(byName["created"]?.isGenerated == false)
      #expect(byName["n"]?.isIdentity == false)
      // Part of a two-column UNIQUE key: not unique on its own.
      #expect(byName["u1"]?.isUnique == false)
      #expect(byName["select"]?.type.lowercased().hasPrefix("varchar(10)") == true)

      // A NOT NULL UNIQUE column of a table without a primary key is not a primary key.
      let noKey = try #require(columns["\(Self.database).\(Self.noKey)"])
      #expect(noKey.map(\.isPrimaryKey) == [false])
      #expect(noKey.map(\.isUnique) == [true])

      let parent = try #require(columns["\(Self.database).\(Self.parent)"])
      #expect(parent.filter(\.isPrimaryKey).map(\.name) == ["a", "b"])
      #expect(columns["\(Self.database).\(Self.view)"]?.map(\.name) == ["id"])
    }
  }

  @Test(
    "Row estimates come from TABLE_ROWS; the exact count reads the table", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func rowEstimates(server: Server) async throws {
    try await withFixtures(server) { session in
      _ = try await session.command(
        "INSERT INTO \(Self.parent) VALUES (1, 1), (1, 2), (2, 1)", binds: [])
      _ = try await session.command("ANALYZE TABLE \(Self.parent)", binds: [])
      let tables = try await introspector.tables(in: session)
      let parent = try #require(tables.first { $0.name == Self.parent })
      #expect(parent.rowCount != nil)
      #expect(
        try await introspector.rowCount(schema: Self.database, table: Self.parent, in: session)
          == 3)
      #expect(
        try await introspector.rowCount(schema: Self.database, table: Self.odd, in: session)
          == 0)
    }
  }

  @Test(
    "Functions, procedures and triggers are listed and their source is returned",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func routinesAndTriggers(server: Server) async throws {
    try await withFixtures(server) { session in
      let functions = try await introspector.functions(in: session)
      let function = try #require(functions.first { $0.name == Self.function })
      #expect(function.schema == Self.database)
      #expect(function.returnType == "varchar(20)")
      #expect(function.arguments.hasPrefix("x int"))
      #expect(function.arguments.hasSuffix(", y varchar(5)"))

      let procedures = try await introspector.procedures(in: session)
      let procedure = try #require(procedures.first { $0.name == Self.procedure })
      #expect(procedure.schema == Self.database)
      #expect(procedure.arguments.hasPrefix("IN a int"))
      #expect(procedure.arguments.contains(", OUT b int"))
      #expect(!procedures.contains { $0.name == Self.function })

      let triggers = try await introspector.triggers(in: session)
      let trigger = try #require(triggers.first { $0.name == Self.trigger })
      #expect(trigger.schema == Self.database)
      #expect(trigger.table == Self.odd)
      #expect(trigger.timing == .before)
      #expect(trigger.events == [.insert])
      #expect(trigger.enabled)

      let functionSource = try await introspector.definition(of: .function(function), in: session)
      #expect(functionSource?.contains("RETURN CONCAT(x, y)") == true)
      let procedureSource = try await introspector.definition(
        of: .procedure(procedure), in: session)
      #expect(procedureSource?.contains("SET b = a") == true)
      let triggerSource = try await introspector.definition(of: .trigger(trigger), in: session)
      #expect(triggerSource?.contains("SET NEW.n = 1") == true)
    }
  }

  @Test(
    "editTable resolves the table, its key and generated columns with a mysql: identity",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func editTable(server: Server) async throws {
    try await withFixtures(server) { session in
      let odd = try #require(try await introspector.editTable(named: Self.odd, in: session))
      #expect(odd.resolvedTableRef == .mysql(database: Self.database, table: Self.odd))
      #expect(odd.resolvedTableRef.identity == "mysql:`\(Self.database)`.`\(Self.odd)`")
      #expect(odd.oid != 0)
      #expect(odd.primaryKeyColumns == ["id"])
      #expect(odd.attributeNames[1] == "id")
      #expect(odd.attributeNames[2] == "select")
      #expect(odd.attributeNames.count == 10)
      #expect(odd.generatedColumns == ["g", "s"])
      #expect(odd.qualifiedName == "`\(Self.database)`.`msi odd`")
      #expect(odd.schema == Self.database)
      #expect(odd.name == Self.odd)
      #expect(odd.updateOnly == false)

      // `db.table`, and a composite key in key order.
      let parent = try #require(
        try await introspector.editTable(named: "\(Self.database).\(Self.parent)", in: session))
      #expect(parent.name == Self.parent)
      #expect(parent.primaryKeyColumns == ["a", "b"])
      #expect(
        try await introspector.primaryKeyColumns(of: Self.parent, in: session) == ["a", "b"])

      // No primary key, a view, and a missing table are not editable.
      #expect(try await introspector.editTable(named: Self.noKey, in: session) == nil)
      #expect(try await introspector.primaryKeyColumns(of: Self.noKey, in: session) == [])
      #expect(try await introspector.editTable(named: Self.view, in: session) == nil)
      #expect(try await introspector.editTable(named: "msi_missing", in: session) == nil)
    }
  }

  @Test(
    "A composite foreign key keeps its column order and actions", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func foreignKeys(server: Server) async throws {
    try await withFixtures(server) { session in
      let keys = try await introspector.foreignKeys(in: session)
      let key = try #require(keys.first { $0.constraintName == "msi fk" })
      #expect(key.sourceSchema == Self.database)
      #expect(key.sourceTable == Self.odd)
      #expect(key.sourceColumns == ["pa", "pb"])
      #expect(key.targetSchema == Self.database)
      #expect(key.targetTable == Self.parent)
      #expect(key.targetColumns == ["a", "b"])
      // The default update rule reads NO ACTION on MySQL and RESTRICT on MariaDB.
      #expect(key.onDelete == .cascade)
      #expect(keys.filter { $0.constraintName == "msi fk" }.count == 1)
    }
  }

  @Test("MariaDB sequences are not listed as tables", .requiresMySQL)
  func mariaDBSequencesHidden() async throws {
    try await withFixtures(.mariadb) { session in
      try await Self.asRoot(.mariadb) { root in
        _ = try await root.command(
          "CREATE SEQUENCE \(Self.database).msi_seq", binds: [])
      }
      #expect(!(try await introspector.tables(in: session)).contains { $0.name == "msi_seq" })
      #expect(!(try await introspector.views(in: session)).contains { $0.name == "msi_seq" })
      #expect(try await introspector.allColumns(in: session)["\(Self.database).msi_seq"] == nil)
    }
  }

  @Test(
    "Without the privilege to read a source, definition is nil", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func sourceWithoutPrivilege(server: Server) async throws {
    let user = "msi_exec"
    let password = "msi-exec-5c1"
    try await withFixtures(server) { session in
      let trigger = try #require(
        try await introspector.triggers(in: session).first { $0.name == Self.trigger })
      try await Self.asRoot(server) { root in
        _ = try await root.command("DROP USER IF EXISTS '\(user)'@'%'", binds: [])
        _ = try await root.command(
          "CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'", binds: [])
      }
      do {
        let db = try SQLDialect.mysql.quoteIdentifier(Self.database)
        try await Self.asRoot(server) { root in
          _ = try await root.command(
            "GRANT EXECUTE ON FUNCTION \(db).\(try Self.quote(Self.function)) TO '\(user)'@'%'",
            binds: [])
          _ = try await root.command(
            "GRANT SELECT ON \(db).\(try Self.quote(Self.odd)) TO '\(user)'@'%'", binds: [])
        }
        if server == .mysql {
          try await TestMySQLDatabase.primeAuthCache(username: user, password: password)
        }
        try await MySQLSessionTests.withSession(
          MySQLSessionTests.config(port: server.port, username: user, password: password)
        ) { limited in
          // EXECUTE shows the function but not its body.
          let function = try #require(
            try await introspector.functions(in: limited).first { $0.name == Self.function })
          #expect(try await introspector.definition(of: .function(function), in: limited) == nil)
          // No TRIGGER privilege: the trigger is not listed and SHOW CREATE TRIGGER is refused.
          #expect(try await introspector.triggers(in: limited).isEmpty)
          #expect(try await introspector.definition(of: .trigger(trigger), in: limited) == nil)
        }
      } catch {
        try? await Self.asRoot(server) { root in
          _ = try await root.command("DROP USER IF EXISTS '\(user)'@'%'", binds: [])
        }
        throw error
      }
      try await Self.asRoot(server) { root in
        _ = try await root.command("DROP USER IF EXISTS '\(user)'@'%'", binds: [])
      }
    }
  }

  // MARK: - Fixtures

  /// Creates the fixtures as root, runs `body` with a `dblore_test` session, then drops them on
  /// every path.
  private func withFixtures(
    _ server: Server, _ body: (MySQLSession) async throws -> Void
  ) async throws {
    try await Self.asRoot(server) { root in
      for sql in try Self.dropStatements() + Self.createStatements() {
        _ = try await root.command(sql, binds: [])
      }
    }
    do {
      try await MySQLSessionTests.withSession(MySQLSessionTests.config(port: server.port)) {
        session in try await body(session)
      }
    } catch {
      try? await Self.dropFixtures(server)
      throw error
    }
    try await Self.dropFixtures(server)
  }

  private static func dropFixtures(_ server: Server) async throws {
    try await asRoot(server) { root in
      for sql in try dropStatements() {
        _ = try await root.command(sql, binds: [])
      }
    }
  }

  private static func asRoot(
    _ server: Server, _ body: (MySQLSession) async throws -> Void
  ) async throws {
    try await MySQLSessionTests.withSession(
      MySQLSessionTests.config(port: server.port, username: "root", password: "dblore123"), body)
  }

  private static func quote(_ name: String) throws -> String {
    try SQLDialect.mysql.quoteIdentifier(name)
  }

  private static func dropStatements() throws -> [String] {
    let db = try quote(database)
    return [
      "DROP VIEW IF EXISTS \(db).\(try quote(view))",
      "DROP TABLE IF EXISTS \(db).\(try quote(odd))",
      "DROP TABLE IF EXISTS \(db).\(parent)",
      "DROP TABLE IF EXISTS \(db).\(noKey)",
      "DROP FUNCTION IF EXISTS \(db).\(try quote(function))",
      "DROP PROCEDURE IF EXISTS \(db).\(try quote(procedure))",
      // A MariaDB sequence (mariaDBSequencesHidden) drops as a table.
      "DROP TABLE IF EXISTS \(db).msi_seq",
    ]
  }

  private static func createStatements() throws -> [String] {
    let db = try quote(database)
    let definer = "DEFINER = `\(TestMySQLDatabase.username)`@`%`"
    return [
      "CREATE TABLE \(db).\(parent) (a INT, b INT, PRIMARY KEY (a, b))",
      """
      CREATE TABLE \(db).\(try quote(odd)) (
        id INT AUTO_INCREMENT PRIMARY KEY,
        `select` VARCHAR(10) UNIQUE,
        n INT,
        g INT AS (n * 2) VIRTUAL,
        s INT AS (n + 1) STORED,
        created TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
        pb INT,
        pa INT,
        u1 INT,
        u2 INT,
        UNIQUE KEY msi_u (u1, u2),
        CONSTRAINT `msi fk` FOREIGN KEY (pa, pb) REFERENCES \(parent) (a, b) ON DELETE CASCADE)
      """,
      "CREATE TABLE \(db).\(noKey) (x INT NOT NULL UNIQUE)",
      "CREATE VIEW \(db).\(try quote(view)) AS SELECT id FROM \(db).\(try quote(odd))",
      """
      CREATE \(definer) FUNCTION \(db).\(try quote(function))(x INT, y VARCHAR(5))
      RETURNS VARCHAR(20) DETERMINISTIC RETURN CONCAT(x, y)
      """,
      """
      CREATE \(definer) PROCEDURE \(db).\(try quote(procedure))(IN a INT, OUT b INT) SET b = a
      """,
      """
      CREATE \(definer) TRIGGER \(db).\(try quote(trigger)) BEFORE INSERT ON \(db).\(try quote(odd))
      FOR EACH ROW SET NEW.n = 1
      """,
    ]
  }
}
