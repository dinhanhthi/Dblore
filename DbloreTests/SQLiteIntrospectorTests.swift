// SQLiteIntrospectorTests.swift
// SQLiteSchemaIntrospector against a temporary file. The fixture is built here.
// Row estimates are read from sqlite_stat1, never from COUNT(*).

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite schema introspector")
@MainActor
struct SQLiteIntrospectorTests {
  private let introspector = SQLiteSchemaIntrospector()

  @Test("Tables, views, keys, generated columns, and foreign keys match the catalog")
  func catalogShapes() async throws {
    try await withFixture { session in
      let tables = try await introspector.tables(in: session)
      #expect(
        tables.map(Self.qualified) == [
          "main.child", "main.link", "main.notes", "main.pair", "main.parent",
        ])
      #expect(tables.allSatisfy { $0.schema == "main" && $0.rowCount == nil })
      #expect(tables.contains { $0.name.hasPrefix("sqlite_") } == false)

      let views = try await introspector.views(in: session)
      #expect(views.map(Self.qualified) == ["main.child_view"])

      let columns = try await introspector.allColumns(in: session)
      let child = try #require(columns["main.child"])
      #expect(child.map(\.name) == ["id", "email", "n", "double", "stored", "a", "b"])
      let id = try #require(child.first { $0.name == "id" })
      #expect(id.isPrimaryKey)
      #expect(!id.isUnique)
      #expect(!id.isGenerated)
      #expect(!id.isHidden)
      #expect(id.type == "INTEGER")
      let email = try #require(child.first { $0.name == "email" })
      #expect(email.isUnique)
      #expect(!email.isPrimaryKey)
      #expect(email.type == "TEXT")
      let virtualColumn = try #require(child.first { $0.name == "double" })
      #expect(virtualColumn.isGenerated)
      #expect(!virtualColumn.isHidden)
      #expect(!virtualColumn.isPrimaryKey)
      let storedColumn = try #require(child.first { $0.name == "stored" })
      #expect(storedColumn.isGenerated)
      #expect(!storedColumn.isHidden)

      let parent = try #require(columns["main.parent"])
      #expect(parent.map(\.name) == ["a", "b"])
      #expect(parent.allSatisfy { $0.isPrimaryKey && !$0.isNullable && !$0.isUnique })

      let pair = try #require(columns["main.pair"])
      #expect(pair.allSatisfy { !$0.isUnique && !$0.isPrimaryKey })

      let viewColumns = try #require(columns["main.child_view"])
      #expect(viewColumns.map(\.name) == ["id", "email", "double"])
      #expect(viewColumns.allSatisfy { !$0.isGenerated && !$0.isPrimaryKey })

      let foreignKeys = try await introspector.foreignKeys(in: session)
      #expect(foreignKeys.count == 2)
      let childKey = try #require(foreignKeys.first { $0.sourceTable == "child" })
      #expect(childKey.sourceSchema == "main")
      #expect(childKey.targetSchema == "main")
      #expect(childKey.targetTable == "parent")
      #expect(childKey.sourceColumns == ["b", "a"])
      #expect(childKey.targetColumns == ["b", "a"])
      #expect(childKey.onUpdate == .cascade)
      #expect(childKey.onDelete == .setNull)
      let linkKey = try #require(foreignKeys.first { $0.sourceTable == "link" })
      #expect(linkKey.sourceColumns == ["parent_b", "parent_a"])
      #expect(linkKey.targetColumns == ["b", "a"])
      #expect(linkKey.targetTable == "parent")
      #expect(linkKey.onUpdate == .noAction)
      #expect(linkKey.onDelete == .noAction)
    }
  }

  @Test("editTable requires a declared primary key, including WITHOUT ROWID")
  func editTableRequiresDeclaredPrimaryKey() async throws {
    try await withFixture { session in
      let parent = try #require(try await introspector.editTable(named: "parent", in: session))
      #expect(parent.primaryKeyColumns == ["b", "a"])
      #expect(parent.attributeNames == [Int16(0): "a", Int16(1): "b"])
      #expect(parent.qualifiedName == "\"main\".\"parent\"")
      #expect(!parent.updateOnly)
      #expect(parent.oid != 0)

      let child = try #require(try await introspector.editTable(named: "main.child", in: session))
      #expect(child.primaryKeyColumns == ["id"])
      #expect(
        child.attributeNames == [
          Int16(0): "id",
          Int16(1): "email",
          Int16(2): "n",
          Int16(3): "double",
          Int16(4): "stored",
          Int16(5): "a",
          Int16(6): "b",
        ])

      let notes = try await introspector.editTable(named: "notes", in: session)
      let pair = try await introspector.editTable(named: "pair", in: session)
      let view = try await introspector.editTable(named: "child_view", in: session)
      #expect(notes == nil)
      #expect(pair == nil)
      #expect(view == nil)
    }
  }

  @Test("Hidden virtual-table columns are flagged and are not generated")
  func hiddenColumnsAreFlagged() async throws {
    try await withDatabase { session in
      _ = try await session.command(
        "CREATE VIRTUAL TABLE docs USING fts5(title, body)", binds: [])
      let columns = try await introspector.allColumns(in: session)
      let docs = try #require(columns["main.docs"])
      let title = try #require(docs.first { $0.name == "title" })
      #expect(!title.isHidden)
      #expect(!title.isGenerated)
      let rank = try #require(docs.first { $0.name == "rank" })
      #expect(rank.isHidden)
      #expect(!rank.isGenerated)
    }
  }

  @Test("Row estimates come from sqlite_stat1, not a live row count")
  func rowEstimateComesFromStat1() async throws {
    try await withDatabase { session in
      _ = try await session.command("CREATE TABLE notes (body TEXT)", binds: [])
      _ = try await session.command("INSERT INTO notes (body) VALUES ('one')", binds: [])
      let before = try await introspector.tables(in: session)
      #expect(before.first { $0.name == "notes" }?.rowCount == nil)

      _ = try await session.command("ANALYZE notes", binds: [])
      _ = try await session.command(
        "UPDATE sqlite_stat1 SET stat = '99999' WHERE tbl = 'notes'", binds: [])
      let after = try await introspector.tables(in: session)
      #expect(after.first { $0.name == "notes" }?.rowCount == 99999)
      #expect(after.contains { $0.name == "sqlite_stat1" } == false)
    }
  }

  @Test("Attached databases are listed and are not editable")
  func attachedDatabasesAreListedReadOnly() async throws {
    let mainURL = temporaryDatabaseURL()
    let otherURL = temporaryDatabaseURL()
    defer {
      removeDatabase(at: mainURL)
      removeDatabase(at: otherURL)
    }
    let other = SQLiteSession(config: makeConfig(path: otherURL.path))
    try await other.open()
    _ = try await other.command(
      "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT)", binds: [])
    await other.close()

    let session = SQLiteSession(config: makeConfig(path: mainURL.path))
    try await session.open()
    do {
      _ = try await session.command("CREATE TABLE local (id INTEGER PRIMARY KEY)", binds: [])
      _ = try await session.command(
        "ATTACH DATABASE ? AS other", binds: [.text(otherURL.path)])
      let tables = try await introspector.tables(in: session)
      let item = try #require(tables.first { $0.schema == "other" && $0.name == "item" })
      #expect(item.rowCount == nil)
      #expect(tables.contains { $0.schema == "main" && $0.name == "local" })
      let attached = try await introspector.editTable(named: "other.item", in: session)
      #expect(attached == nil)
      let local = try #require(try await introspector.editTable(named: "local", in: session))
      #expect(local.primaryKeyColumns == ["id"])
      #expect(!local.updateOnly)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  @Test("Users, roles, functions, and procedures stay empty")
  func securityCatalogsStayEmpty() async throws {
    try await withFixture { session in
      let functions = try await introspector.functions(in: session)
      let procedures = try await introspector.procedures(in: session)
      let users = try await introspector.users(in: session)
      let roles = try await introspector.roles(in: session)
      #expect(functions.isEmpty)
      #expect(procedures.isEmpty)
      #expect(users.isEmpty)
      #expect(roles.isEmpty)
    }
  }

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
          email TEXT UNIQUE,
          n INTEGER,
          double INTEGER GENERATED ALWAYS AS (n * 2) VIRTUAL,
          stored INTEGER GENERATED ALWAYS AS (n + 1) STORED,
          a INTEGER,
          b TEXT,
          FOREIGN KEY (b, a) REFERENCES parent (b, a)
            ON UPDATE CASCADE ON DELETE SET NULL
        )
        """,
        "CREATE TABLE notes (body TEXT)",
        "CREATE TABLE pair (x INTEGER, y INTEGER, UNIQUE (x, y))",
        """
        CREATE TABLE link (
          parent_b TEXT,
          parent_a INTEGER,
          FOREIGN KEY (parent_b, parent_a) REFERENCES parent
        )
        """,
        "CREATE VIEW child_view AS SELECT id, email, double FROM child",
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session)
    }
  }

  private func withDatabase(
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let session = SQLiteSession(config: makeConfig(path: url.path))
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
      password: "dblore-introspector-password",
      sslMode: .disable
    )
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-introspector-\(UUID().uuidString).db")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-journal"))
  }

  private static func qualified(_ table: DatabaseTable) -> String {
    table.qualifiedName
  }

  private static func qualified(_ view: DatabaseView) -> String {
    view.qualifiedName
  }
}
