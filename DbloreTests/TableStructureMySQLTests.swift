// TableStructureMySQLTests.swift
// MySQLSchemaIntrospector.tableStructure against MySQL 8.4 (3307) and MariaDB 11.4 (3308):
// raw defaults normalized to the same SQL text on both engines, AUTO_INCREMENT, generated
// columns, charset, collation, column and table comments, constraint-backed, prefix and (MySQL) functional
// indexes, a multi-column foreign key with actions, checks, and names that need backticks.
// Opt-in (`.requiresMySQL`). Fixtures are created by root, read as `dblore_test`, and use the
// `ts` prefix.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized) @MainActor
struct TableStructureMySQLTests {
  typealias Server = MySQLSessionTests.Server

  private static let database = TestMySQLDatabase.database
  private static let child = "ts child"
  private static let parent = "ts_parent"
  private let introspector = MySQLSchemaIntrospector(database: TestMySQLDatabase.database)

  /// Plain-TCP logins of the caching_sha2 fixture users need the server's auth cache.
  init() async throws {
    if MySQLIntegrationGate.isEnabled(env: ProcessInfo.processInfo.environment) {
      try await TestMySQLDatabase.primeAuthCache()
    }
  }

  @Test(
    "Columns: normalized defaults, AUTO_INCREMENT, generated, charset, collation, comment",
    .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func columns(server: Server) async throws {
    try await withFixtures(server) { session in
      let table = try await introspector.tableStructure(
        schema: Self.database, table: Self.child, in: session)
      #expect(table.tableID == .mysql(database: Self.database, table: Self.child))
      #expect(table.schema == Self.database && table.name == Self.child)
      #expect(table.comment == "it's the table")
      #expect(
        table.columns.map(\.name) == [
          "id", "name", "n", "m", "bs", "nl", "ts", "h", "g", "s", "pa", "pb", "q",
        ])
      #expect(table.columns.map(\.ordinal) == Array(1...13))
      let byName = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.name, $0) })

      let id = try #require(byName["id"])
      #expect(id.identity == .autoIncrement && id.extra == "auto_increment")
      #expect(id.dataType == "int" && id.columnType?.hasSuffix("unsigned") == true)
      #expect(!id.isNullable && id.defaultExpression == nil)

      let name = try #require(byName["name"])
      #expect(name.characterSet == "utf8mb4" && name.collation == "utf8mb4_bin")
      #expect(name.comment == "the name" && name.columnType == "varchar(20)")
      #expect(byName["n"]?.comment == nil && byName["n"]?.extra == nil)

      // The same raw SQL text on both engines
      #expect(name.defaultExpression == "'it''s'")
      #expect(byName["n"]?.defaultExpression == nil)
      #expect(byName["m"]?.defaultExpression == "0")
      #expect(byName["bs"]?.defaultExpression == #"'a\\b'"#)
      #expect(byName["nl"]?.defaultExpression == "'NULL'")
      #expect(byName["h"]?.defaultExpression == "(`m` + 1)")
      let ts = try #require(byName["ts"])
      #expect(ts.defaultExpression?.lowercased().hasPrefix("current_timestamp") == true)
      #expect(ts.extra?.lowercased().contains("on update current_timestamp") == true)
      #expect(ts.identity == nil && ts.generated == nil)

      let virtual = try #require(byName["g"]?.generated)
      #expect(!virtual.isStored && virtual.expression?.contains("`m` * 2") == true)
      let stored = try #require(byName["s"]?.generated)
      #expect(stored.isStored && stored.expression?.contains("`m` + 1") == true)
      #expect(byName["g"]?.defaultExpression == nil)
    }
  }

  @Test(
    "Indexes: PRIMARY, unique constraint, foreign key, prefix and functional", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func indexes(server: Server) async throws {
    try await withFixtures(server) { session in
      let table = try await introspector.tableStructure(
        schema: Self.database, table: Self.child, in: session)
      let byName = Dictionary(uniqueKeysWithValues: table.indexes.map { ($0.name, $0) })
      #expect(byName["ts k"]?.keys == [.column("n")])
      #expect(byName["ts k"]?.isUnique == true)
      #expect(
        byName["PRIMARY"]
          == .init(
            name: "PRIMARY", keys: [.column("id")], isUnique: true, isPrimary: true,
            method: "btree", isPartial: false, predicate: nil))
      #expect(
        byName["ts uq"]
          == .init(
            name: "ts uq", keys: [.column("name"), .column("m")], isUnique: true,
            isPrimary: false, method: "btree", isPartial: false, predicate: nil))
      #expect(byName["ts fk"]?.keys == [.column("pb"), .column("pa")])
      #expect(byName["ts fk"]?.isUnique == false)
      #expect(byName["ts_prefix"]?.keys == [.column("name")])
      if server == .mysql {
        #expect(byName["ts_expr"]?.keys == [.expression("(`m` + 1)")])
        // MySQL's escaped quotes are undone
        #expect(byName["ts_expr_q"]?.keys == [.expression(#"concat(`bs`,_utf8mb4'x\'y')"#)])
      }
    }
  }

  @Test(
    "Constraints: primary key, unique, foreign key with actions and checks", .requiresMySQL,
    arguments: [Server.mysql, .mariadb])
  func constraints(server: Server) async throws {
    try await withFixtures(server) { session in
      let table = try await introspector.tableStructure(
        schema: Self.database, table: Self.child, in: session)
      let keys = table.constraints.filter {
        if case .check = $0.kind { false } else { true }
      }
      #expect(
        keys == [
          .init(name: "PRIMARY", kind: .primaryKey, columns: ["id"]),
          .init(
            name: "ts fk",
            kind: .foreignKey(
              .init(
                schema: Self.database, table: Self.parent, columns: ["b", "a"],
                onUpdate: .setNull, onDelete: .cascade)),
            columns: ["pb", "pa"]),
          // A UNIQUE key and a foreign key may share a name on one table
          .init(
            name: "ts k",
            kind: .foreignKey(
              .init(
                schema: Self.database, table: Self.child, columns: ["id"], onUpdate: .cascade,
                onDelete: .setNull)),
            columns: ["q"]),
          .init(name: "ts k", kind: .unique, columns: ["n"]),
          .init(name: "ts uq", kind: .unique, columns: ["name", "m"]),
        ])
      let checks = table.constraints.compactMap { constraint -> (String?, String)? in
        if case .check(let expression) = constraint.kind {
          #expect(constraint.columns.isEmpty)
          return (constraint.name, expression)
        }
        return nil
      }
      #expect(checks.count == 3)
      #expect(checks.contains { $0.0 == "ts_ck" && $0.1.contains("`n` > 0") })
      // MySQL's escaped quotes are undone; MariaDB prints plain SQL
      let quoted = checks.first { $0.0 == "ts_ck_q" }?.1
      #expect(
        quoted
          == (server == .mysql ? #"(`bs` <> _utf8mb4'x\'y')"# : #"`bs` <> 'x\'y'"#))
      #expect(checks.contains { $0.0 != "ts_ck" && $0.1.contains("`m` >= 0") })

      let parent = try await introspector.tableStructure(
        schema: Self.database, table: Self.parent, in: session)
      #expect(
        parent.constraints == [.init(name: "PRIMARY", kind: .primaryKey, columns: ["b", "a"])])
      // No comment reads as nil, not ""
      #expect(parent.comment == nil)
    }
  }

  @Test("A missing table, or a view, throws", .requiresMySQL, arguments: [Server.mysql, .mariadb])
  func missingTable(server: Server) async throws {
    try await withFixtures(server) { session in
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: Self.database, table: "ts_nope", in: session)
      }
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: Self.database, table: "ts_v", in: session)
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
      for sql in try Self.dropStatements() + Self.createStatements(server) {
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

  private static func dropStatements() throws -> [String] {
    let db = try SQLDialect.mysql.quoteIdentifier(database)
    return [
      "DROP VIEW IF EXISTS \(db).ts_v",
      "DROP TABLE IF EXISTS \(db).`ts child`",
      "DROP TABLE IF EXISTS \(db).ts_parent",
    ]
  }

  private static func createStatements(_ server: Server) throws -> [String] {
    let db = try SQLDialect.mysql.quoteIdentifier(database)
    var statements = [
      "CREATE TABLE \(db).ts_parent (a INT, b INT, PRIMARY KEY (b, a))",
      #"""
      CREATE TABLE \#(db).`ts child` (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT 'it''s'
          COMMENT 'the name',
        n INT DEFAULT NULL,
        m INT NOT NULL DEFAULT 0 CHECK (m >= 0),
        bs VARCHAR(5) DEFAULT 'a\\b',
        nl VARCHAR(5) DEFAULT 'NULL',
        ts TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        h INT DEFAULT (m + 1),
        g INT AS (m * 2) VIRTUAL,
        s INT AS (m + 1) STORED,
        pa INT,
        pb INT,
        q INT UNSIGNED,
        CONSTRAINT `ts uq` UNIQUE (name, m),
        CONSTRAINT `ts fk` FOREIGN KEY (pb, pa) REFERENCES ts_parent (b, a)
          ON DELETE CASCADE ON UPDATE SET NULL,
        CONSTRAINT ts_ck CHECK (n > 0),
        CONSTRAINT ts_ck_q CHECK (bs <> 'x''y'),
        INDEX ts_q (q),
        UNIQUE KEY `ts k` (n),
        CONSTRAINT `ts k` FOREIGN KEY (q) REFERENCES `ts child` (id)
          ON DELETE SET NULL ON UPDATE CASCADE,
        INDEX ts_prefix (name(5))
      ) COMMENT = 'it''s the table'
      """#,
      "CREATE VIEW \(db).ts_v AS SELECT 1 AS x",
    ]
    if server == .mysql {
      statements.append("CREATE INDEX ts_expr ON \(db).`ts child` ((m + 1))")
      statements.append("CREATE INDEX ts_expr_q ON \(db).`ts child` ((concat(bs, 'x''y')))")
    }
    return statements
  }
}
