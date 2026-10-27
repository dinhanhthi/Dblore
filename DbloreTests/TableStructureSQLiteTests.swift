// TableStructureSQLiteTests.swift
// SQLiteSchemaIntrospector.tableStructure against a temporary file: columns, keys, indexes and
// foreign keys from the pragmas, quoted and attached names, and the read through the actor.

import Foundation
import Testing

@testable import Dblore

@Suite("TableStructureSQLiteTests")
@MainActor
struct TableStructureSQLiteTests {
  private let introspector = SQLiteSchemaIntrospector()
  private typealias Column = TableStructure.Column

  @Test("Columns keep type, nullability, raw defaults, AUTOINCREMENT and generated kind")
  func columns() async throws {
    try await withFixture { session in
      let child = try await introspector.tableStructure(
        schema: "main", table: "child", in: session)
      #expect(child.tableID == .sqlite(schema: "main", table: "child"))
      #expect(child.schema == "main" && child.name == "child")
      #expect(
        child.columns == [
          Column(
            ordinal: 1, name: "id", dataType: "INTEGER", isNullable: true,
            identity: .autoIncrement),
          Column(
            ordinal: 2, name: "email", dataType: "TEXT", isNullable: false,
            defaultExpression: "'none'"),
          Column(
            ordinal: 3, name: "n", dataType: "INTEGER", isNullable: true,
            defaultExpression: "0"),
          Column(
            ordinal: 4, name: "double", dataType: "INTEGER", isNullable: true,
            generated: .init(expression: nil, isStored: false)),
          Column(
            ordinal: 5, name: "stored", dataType: "INTEGER", isNullable: true,
            generated: .init(expression: nil, isStored: true)),
          Column(ordinal: 6, name: "a", dataType: "INTEGER", isNullable: true),
          Column(ordinal: 7, name: "b", dataType: "TEXT", isNullable: true),
        ])

      let plain = try await introspector.tableStructure(
        schema: "main", table: "plain", in: session)
      #expect(plain.columns.allSatisfy { $0.identity == nil })
    }
  }

  @Test("A composite primary key is one constraint in key order, with its WITHOUT ROWID index")
  func compositePrimaryKey() async throws {
    try await withFixture { session in
      let parent = try await introspector.tableStructure(
        schema: "main", table: "parent", in: session)
      #expect(
        parent.constraints == [.init(name: nil, kind: .primaryKey, columns: ["b", "a"])])
      #expect(
        parent.indexes == [
          .init(
            name: "sqlite_autoindex_parent_1", keys: [.column("b"), .column("a")],
            isUnique: true, isPrimary: true, method: nil, isPartial: false, predicate: nil)
        ])
    }
  }

  @Test("Indexes: UNIQUE constraint, unique, expression and partial indexes")
  func indexes() async throws {
    try await withFixture { session in
      let child = try await introspector.tableStructure(
        schema: "main", table: "child", in: session)
      let byName = Dictionary(uniqueKeysWithValues: child.indexes.map { ($0.name, $0) })
      #expect(byName.count == 5)

      let constraintIndex = try #require(byName["sqlite_autoindex_child_1"])
      #expect(constraintIndex.keys == [.column("email")])
      #expect(constraintIndex.isUnique && !constraintIndex.isPrimary)

      let unique = try #require(byName["child_a_b"])
      #expect(unique.keys == [.column("a"), .column("b")])
      #expect(unique.isUnique && !unique.isPartial)

      let expression = try #require(byName["child_expr"])
      #expect(expression.keys == [.expression(nil), .column("n")])
      #expect(!expression.isUnique)

      let partial = try #require(byName["child_n_partial"])
      #expect(partial.keys == [.column("n")])
      #expect(partial.isPartial)
      #expect(partial.predicate == "n > 0")

      // The word appears twice in the text: partial, without a predicate
      let tricky = try #require(byName["child_b_partial"])
      #expect(tricky.isPartial)
      #expect(tricky.predicate == nil)
    }
  }

  @Test("Constraints: primary key, UNIQUE, a multi-column foreign key with actions, no CHECK")
  func constraints() async throws {
    try await withFixture { session in
      let child = try await introspector.tableStructure(
        schema: "main", table: "child", in: session)
      #expect(
        child.constraints == [
          .init(name: nil, kind: .primaryKey, columns: ["id"]),
          .init(name: "sqlite_autoindex_child_1", kind: .unique, columns: ["email"]),
          .init(
            name: nil,
            kind: .foreignKey(
              .init(
                schema: "main", table: "parent", columns: ["b", "a"], onUpdate: .cascade,
                onDelete: .setNull)),
            columns: ["b", "a"]),
        ])
    }
  }

  @Test("Names that need quoting are read as they are")
  func quotedNames() async throws {
    try await withDatabase { session in
      _ = try await session.command(
        "CREATE TABLE \"odd \"\"name\"\" t\" (\"col one\" TEXT PRIMARY KEY, \"x.y\" INT)",
        binds: [])
      _ = try await session.command(
        "CREATE INDEX \"idx \"\"q\"\"\" ON \"odd \"\"name\"\" t\" (\"x.y\")", binds: [])
      let odd = try await introspector.tableStructure(
        schema: "main", table: "odd \"name\" t", in: session)
      #expect(odd.columns.map(\.name) == ["col one", "x.y"])
      #expect(odd.constraints == [.init(name: nil, kind: .primaryKey, columns: ["col one"])])
      #expect(odd.indexes.contains { $0.name == "idx \"q\"" && $0.keys == [.column("x.y")] })
    }
  }

  @Test("An attached schema is read, not the main table of the same name")
  func attachedSchema() async throws {
    let otherURL = temporaryDatabaseURL()
    defer { removeDatabase(at: otherURL) }
    try await withDatabase { session in
      _ = try await session.command("CREATE TABLE item (only_main TEXT)", binds: [])
      // A quoted path: the session refuses a bound ATTACH file name
      let quoted = otherURL.path.replacingOccurrences(of: "'", with: "''")
      _ = try await session.command("ATTACH DATABASE '\(quoted)' AS \"other db\"", binds: [])
      _ = try await session.command(
        "CREATE TABLE \"other db\".owner (id INTEGER PRIMARY KEY)", binds: [])
      _ = try await session.command(
        """
        CREATE TABLE "other db".item (
          id INTEGER PRIMARY KEY,
          owner_id INTEGER REFERENCES owner (id) ON DELETE CASCADE
        )
        """,
        binds: [])
      let item = try await introspector.tableStructure(
        schema: "other db", table: "item", in: session)
      #expect(item.tableID == .sqlite(schema: "other db", table: "item"))
      #expect(item.columns.map(\.name) == ["id", "owner_id"])
      #expect(
        item.constraints.contains(
          .init(
            name: nil,
            kind: .foreignKey(
              .init(
                schema: "other db", table: "owner", columns: ["id"], onUpdate: .noAction,
                onDelete: .cascade)),
            columns: ["owner_id"])))
    }
  }

  @Test("A missing table, or a view, throws")
  func missingTable() async throws {
    try await withDatabase { session in
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: "main", table: "nope", in: session)
      }
      _ = try await session.command("CREATE TABLE base (id INTEGER)", binds: [])
      _ = try await session.command("CREATE VIEW base_view AS SELECT id FROM base", binds: [])
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: "main", table: "base_view", in: session)
      }
    }
  }

  @Test("The connection actor reads the structure through the catalog guard")
  func throughManager() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    try await withDatabase(at: url) { session in
      _ = try await session.command(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)", binds: [])
    }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: makeConfig(path: url.path))
    defer { Task { await manager.disconnect() } }
    let notes = try await manager.fetchTableStructure(schema: "main", table: "notes")
    #expect(notes.columns.map(\.name) == ["id", "body"])
  }

  // MARK: - Fixture

  private func withFixture(
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    try await withDatabase { session in
      let statements = [
        """
        CREATE TABLE parent (
          a INTEGER NOT NULL,
          b TEXT NOT NULL,
          PRIMARY KEY (b, a)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE child (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL DEFAULT 'none' UNIQUE,
          n INTEGER DEFAULT 0,
          double INTEGER GENERATED ALWAYS AS (n * 2) VIRTUAL,
          stored INTEGER GENERATED ALWAYS AS (n + 1) STORED,
          a INTEGER,
          b TEXT,
          FOREIGN KEY (b, a) REFERENCES parent (b, a)
            ON UPDATE CASCADE ON DELETE SET NULL
        )
        """,
        "CREATE UNIQUE INDEX child_a_b ON child (a, b DESC)",
        "CREATE INDEX child_expr ON child (lower(email), n)",
        "CREATE INDEX child_n_partial ON child (n) WHERE n > 0",
        "CREATE INDEX child_b_partial ON child (b) WHERE b <> 'nowhere'",
        "CREATE TABLE plain (id INTEGER PRIMARY KEY, note TEXT)",
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session)
    }
  }

  private func withDatabase(
    at url: URL? = nil, _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    let target = url ?? temporaryDatabaseURL()
    defer { if url == nil { removeDatabase(at: target) } }
    let session = SQLiteSession(config: makeConfig(path: target.path))
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  private func makeConfig(path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      database: path,
      username: "unused",
      password: "dblore-structure-password",
      sslMode: .disable
    )
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-structure-\(UUID().uuidString).db")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
