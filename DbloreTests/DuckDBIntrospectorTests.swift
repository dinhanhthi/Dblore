// DuckDBIntrospectorTests.swift
// DuckDB catalog: pure key/column mapping, then the real catalog through the hardened session
// (file, read-only reopen, in-memory) against the dev plugin.

import Foundation
import Testing

@testable import Dblore

@Suite("DuckDB catalog mapping")
@MainActor
struct DuckDBCatalogMappingTests {
  private func part(
    _ table: String, _ index: Int, _ kind: DuckDBCatalog.KeyKind, _ column: String,
    referencedTable: String? = nil, referencedColumn: String? = nil
  ) -> DuckDBCatalog.KeyPart {
    DuckDBCatalog.KeyPart(
      schema: "s", table: table, constraintIndex: index, kind: kind,
      constraintName: "k\(index)", column: column, referencedTable: referencedTable,
      referencedColumn: referencedColumn)
  }

  @Test("Key columns: primary key, single-column unique only, input order kept")
  func columnsFromKeys() throws {
    let rows = ["id", "code", "a", "b"].map {
      DuckDBCatalog.ColumnRow(
        schema: "s", relation: "t", name: $0, type: "INTEGER", isNullable: $0 != "id")
    }
    let keys = [
      part("t", 0, .primaryKey, "id"),
      part("t", 1, .unique, "code"),
      part("t", 2, .unique, "a"),
      part("t", 2, .unique, "b"),
      part("t", 3, .unique, "id"),
      part("other", 4, .primaryKey, "code"),
    ]
    let columns = try #require(DuckDBCatalog.columnsByRelation(rows, keys: keys)["s.t"])
    #expect(columns.map(\.name) == ["id", "code", "a", "b"])
    #expect(columns.map(\.isPrimaryKey) == [true, false, false, false])
    #expect(columns.map(\.isUnique) == [false, true, false, false])
    #expect(columns.map(\.isNullable) == [false, true, true, true])
  }

  @Test("Foreign keys group by constraint in key order; a broken key is skipped")
  func foreignKeyGrouping() {
    let keys = [
      part("g", 5, .foreignKey, "y", referencedTable: "c", referencedColumn: "b"),
      part("g", 5, .foreignKey, "x", referencedTable: "c", referencedColumn: "a"),
      part("g", 6, .primaryKey, "x"),
      part("h", 7, .foreignKey, "z", referencedTable: "c", referencedColumn: nil),
    ]
    let foreignKeys = DuckDBCatalog.foreignKeys(keys)
    #expect(foreignKeys.count == 1)
    let key = foreignKeys.first
    #expect(key?.constraintName == "k5")
    #expect(key?.sourceColumns == ["y", "x"])
    #expect(key?.targetQualifiedName == "s.c")
    #expect(key?.targetColumns == ["b", "a"])
    #expect(key?.onDelete == .noAction)
  }

  @Test("Keys of different tables never merge, even with the same constraint index")
  func sameIndexInTwoTables() throws {
    let rows = ["t", "u"].map {
      DuckDBCatalog.ColumnRow(
        schema: "s", relation: $0, name: "a", type: "INTEGER", isNullable: true)
    }
    let keys = [
      part("t", 1, .unique, "a"), part("u", 1, .unique, "a"),
      part("t", 2, .foreignKey, "a", referencedTable: "c", referencedColumn: "x"),
      part("u", 2, .foreignKey, "a", referencedTable: "c", referencedColumn: "y"),
      part("t", 3, .primaryKey, "a"), part("u", 3, .primaryKey, "b"),
    ]
    let columns = DuckDBCatalog.columnsByRelation(rows, keys: keys.filter { $0.kind == .unique })
    #expect(columns["s.t"]?.map(\.isUnique) == [true])
    #expect(columns["s.u"]?.map(\.isUnique) == [true])
    let foreignKeys = DuckDBCatalog.foreignKeys(keys)
    #expect(foreignKeys.map(\.sourceTable) == ["t", "u"])
    #expect(foreignKeys.map(\.targetColumns) == [["x"], ["y"]])
    #expect(DuckDBCatalog.primaryKey(keys) == ["a"])
  }

  @Test("Primary key columns keep key order")
  func primaryKeyOrder() {
    let keys = [
      part("t", 1, .unique, "a"), part("t", 2, .primaryKey, "b"),
      part("t", 2, .primaryKey, "a"),
    ]
    #expect(DuckDBCatalog.primaryKey(keys) == ["b", "a"])
    #expect(DuckDBCatalog.primaryKey([part("t", 1, .unique, "a")]).isEmpty)
  }

  @Test("Names split on a known schema only")
  func split() {
    let schemas = ["main", "Sales"]
    #expect(DuckDBCatalog.split("t", schemas: schemas, currentSchema: "main")! == ("main", "t"))
    #expect(
      DuckDBCatalog.split("sales.t", schemas: schemas, currentSchema: "main")! == ("Sales", "t"))
    #expect(
      DuckDBCatalog.split("x.y", schemas: schemas, currentSchema: "main")! == ("main", "x.y"))
    #expect(DuckDBCatalog.split("", schemas: schemas, currentSchema: "main") == nil)
  }
}

@Suite("DuckDB introspector", .requiresDuckDBPlugin, .serialized)
@MainActor
struct DuckDBIntrospectorTests {
  private let introspector = DuckDBSchemaIntrospector()
  private static let odd = "odd \"s\""

  private static let fixture = [
    #"CREATE SCHEMA "odd ""s""""#,
    #"""
    CREATE TABLE main.parent (
      id INTEGER PRIMARY KEY, code VARCHAR UNIQUE, n INTEGER NOT NULL DEFAULT 5 CHECK (n > 0))
    """#,
    "INSERT INTO main.parent VALUES (1, 'a', 1), (2, 'b', 2)",
    "CREATE TABLE main.kid (pid INTEGER REFERENCES main.parent (id), note VARCHAR)",
    #"""
    CREATE TABLE "odd ""s"""."child tbl" (
      "weird col" INTEGER, "ünï" VARCHAR DEFAULT 'x', a INTEGER NOT NULL, b INTEGER,
      PRIMARY KEY (b, a), UNIQUE (a, "weird col"), CHECK (a >= 0))
    """#,
    #"""
    CREATE TABLE "odd ""s""".grand (
      x INTEGER, y INTEGER, FOREIGN KEY (y, x) REFERENCES "odd ""s"""."child tbl" (b, a))
    """#,
    #"CREATE UNIQUE INDEX "idx u" ON "odd ""s"""."child tbl" ("weird col")"#,
    #"CREATE INDEX idx_c ON "odd ""s"""."child tbl" ("ünï")"#,
    #"CREATE VIEW "odd ""s""".v AS SELECT id, code FROM main.parent"#,
  ]

  @Test("A file database: tree, keys, view, temp table hidden; same after a read-only reopen")
  func fileAndReadOnlyReopen() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-duckdb-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("catalog.duckdb").path
    var written: Snapshot?
    try await withSession(makeConfig(path: path)) { session in
      try await createFixture(session)
      _ = try await session.command("CREATE TEMP TABLE scratch (x INTEGER)", binds: [])
      let snapshot = try await snapshot(session)
      expectFixture(snapshot)
      written = snapshot
    }
    try await withSession(makeConfig(path: path, readOnlyFile: true)) { session in
      let reopened = try await snapshot(session)
      #expect(reopened == written)
    }
  }

  @Test("An in-memory database gives the same tree")
  func inMemory() async throws {
    try await withSession(makeConfig(path: DuckDBSession.inMemoryPath)) { session in
      try await createFixture(session)
      expectFixture(try await snapshot(session))
    }
  }

  @Test("Primary key, row count and empty catalogs")
  func lookups() async throws {
    try await withSession(makeConfig(path: DuckDBSession.inMemoryPath)) { session in
      try await createFixture(session)
      let key = try await introspector.primaryKeyColumns(
        of: "\(Self.odd).child tbl", in: session)
      #expect(key == ["b", "a"])
      #expect(try await introspector.primaryKeyColumns(of: "PARENT", in: session) == ["id"])
      #expect(try await introspector.primaryKeyColumns(of: "kid", in: session).isEmpty)
      #expect(try await introspector.rowCount(schema: "main", table: "parent", in: session) == 2)
      #expect(
        try await introspector.rowCount(schema: Self.odd, table: "child tbl", in: session) == 0)
      #expect(try await introspector.editTable(named: "parent", in: session) == nil)
      #expect(try await introspector.functions(in: session).isEmpty)
      #expect(try await introspector.procedures(in: session).isEmpty)
      #expect(try await introspector.triggers(in: session).isEmpty)
      #expect(try await introspector.users(in: session).isEmpty)
      #expect(try await introspector.roles(in: session).isEmpty)
    }
  }

  // MARK: - Expected tree

  private func expectFixture(_ snapshot: Snapshot) {
    #expect(
      snapshot.tables == [
        "main.kid rows=0", "main.parent rows=2", "\(Self.odd).child tbl rows=0",
        "\(Self.odd).grand rows=0",
      ])
    #expect(snapshot.views == ["\(Self.odd).v"])
    #expect(snapshot.viewDefinitions.allSatisfy { $0.contains("FROM main.parent") })
    #expect(
      snapshot.columns["main.parent"] == [
        "id INTEGER pk", "code VARCHAR null unique", "n INTEGER",
      ])
    // The unique index on "weird col" does not mark it: only UNIQUE constraints do.
    #expect(
      snapshot.columns["\(Self.odd).child tbl"] == [
        "weird col INTEGER null", "ünï VARCHAR null", "a INTEGER pk", "b INTEGER pk",
      ])
    #expect(snapshot.columns["\(Self.odd).v"] == ["id INTEGER null", "code VARCHAR null"])
    #expect(snapshot.columns.keys.contains("main.scratch") == false)
    #expect(
      snapshot.foreignKeys == [
        "main.kid(pid) -> main.parent(id)",
        "\(Self.odd).grand(y,x) -> \(Self.odd).child tbl(b,a)",
      ])
  }

  // MARK: - Helpers

  private struct Snapshot: Equatable {
    var tables: [String]
    var views: [String]
    var viewDefinitions: [String]
    var columns: [String: [String]]
    var foreignKeys: [String]
  }

  private func snapshot(_ session: DuckDBSession) async throws -> Snapshot {
    let tables = try await introspector.tables(in: session)
    let views = try await introspector.views(in: session)
    let columns = try await introspector.allColumns(in: session)
    let keys = try await introspector.foreignKeys(in: session)
    return Snapshot(
      tables: tables.map { "\($0.qualifiedName) rows=\($0.rowCount.map(String.init) ?? "nil")" },
      views: views.map { "\($0.schema).\($0.name)" },
      viewDefinitions: views.map { $0.definition ?? "" },
      columns: columns.mapValues { list in
        list.map { column in
          var text = "\(column.name) \(column.type)"
          if column.isNullable { text += " null" }
          if column.isPrimaryKey { text += " pk" }
          if column.isUnique { text += " unique" }
          return text
        }
      },
      foreignKeys: keys.map {
        "\($0.sourceQualifiedName)(\($0.sourceColumns.joined(separator: ","))) -> "
          + "\($0.targetQualifiedName)(\($0.targetColumns.joined(separator: ",")))"
      })
  }

  private func createFixture(_ session: DuckDBSession) async throws {
    for sql in Self.fixture {
      _ = try await session.command(sql, binds: [])
    }
  }

  private func makeConfig(path: String, readOnlyFile: Bool = false) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .duckdb, database: path, sslMode: .disable, protectionLevel: .none,
      statementTimeoutSeconds: 60, readOnlyFile: readOnlyFile)
  }

  private func withSession(
    _ config: ConnectionConfig, _ body: (DuckDBSession) async throws -> Void
  ) async throws {
    let session = DuckDBSession(config: config) { try DuckDBTestPlugin.library() }
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }
}
