// TemporaryTablesSidebarTests.swift
// Temporary tables in the catalog: `DatabaseTable.isTemporary` from the SQLite `temp` schema
// (a real session) and from PostgreSQL's `pg_my_temp_schema()` (catalog rows fed by a fake
// session). In the sidebar they leave the schema groups and the schema filter for the Temporary
// section (`SidebarSectionModel.temporarySplit`).

import Foundation
import Testing

@testable import Dblore

@Suite("Temporary tables sidebar")
@MainActor
struct TemporaryTablesSidebarTests {
  // MARK: - Catalog flags

  @Test("SQLite flags tables of the temp schema only")
  func sqliteTempSchemaIsFlagged() async throws {
    try await withSQLiteSession { session in
      _ = try await session.command("CREATE TABLE kept (id INTEGER PRIMARY KEY)", binds: [])
      _ = try await session.command("CREATE TEMP TABLE scratch (id INTEGER)", binds: [])
      let tables = try await SQLiteSchemaIntrospector().tables(in: session)
      let scratch = try #require(tables.first { $0.name == "scratch" })
      #expect(scratch.schema == "temp")
      #expect(scratch.isTemporary)
      let kept = try #require(tables.first { $0.name == "kept" })
      #expect(kept.schema == "main")
      #expect(!kept.isTemporary)
    }
  }

  @Test("SQLite lists no temp schema while the session holds no temp table")
  func sqliteWithoutTempTables() async throws {
    try await withSQLiteSession { session in
      _ = try await session.command("CREATE TABLE kept (id INTEGER PRIMARY KEY)", binds: [])
      let tables = try await SQLiteSchemaIntrospector().tables(in: session)
      #expect(tables.map(\.qualifiedName) == ["main.kept"])
      #expect(tables.allSatisfy { !$0.isTemporary })
    }
  }

  @Test("PostgreSQL flags tables of the session's own temp schema")
  func postgresMyTempSchemaIsFlagged() async throws {
    let session = FakeDatabaseSession(
      capabilities: .contract(), columns: [],
      rows: [
        [.string("pg_temp_3"), .string("scratch"), .null, .bool(true)],
        [.string("public"), .string("orders"), .int(10), .bool(false)],
      ],
      slowQueries: false)
    let tables = try await PostgresSchemaIntrospector().tables(in: session)
    #expect(tables.map(\.qualifiedName) == ["pg_temp_3.scratch", "public.orders"])
    #expect(tables.map(\.isTemporary) == [true, false])
    #expect(session.queries.count == 1)
    let sql = try #require(session.queries.first)
    #expect(sql.contains("n.oid = pg_my_temp_schema()"))
  }

  // MARK: - Sidebar section

  @Test(
    "Temporary tables go to the Temporary section, never to a schema group",
    arguments: [
      (["public.orders"], ["pg_temp_3.scratch"], ["public"]),
      (["main.kept"], ["temp.scratch"], ["main"]),
      (["shop.orders"], ["shop.scratch", "other_db.t"], ["shop"]),
    ])
  func temporaryTablesLeaveSchemaGroups(
    base: [String], temporary: [String], schemas: [String]
  ) {
    let tables =
      base.map { Self.table($0) } + temporary.map { Self.table($0, isTemporary: true) }
    let split = SidebarSectionModel.temporarySplit(tables)
    #expect(split.temporary.map(\.qualifiedName) == temporary)
    #expect(split.regular.map(\.qualifiedName) == base)
    #expect(Set(split.regular.map(\.schema)) == Set(schemas))
  }

  @Test("The schema filter lists no temp schema")
  func schemaFilterLeavesOutTempSchemas() {
    let tables = [
      Self.table("public.orders"), Self.table("sales.leads"),
      Self.table("pg_temp_3.scratch", isTemporary: true),
    ]
    let regular = SidebarSectionModel.temporarySplit(tables).regular.map(\.schema)
    #expect(
      SidebarSectionModel.listedSchemas(regular, hidden: [], defaultSchema: "public")
        == ["public", "sales"])
    // A temp schema hidden before it left the menu counts as no hidden schema
    #expect(SidebarSectionModel.hiddenSchemasLabel(regular, hidden: ["pg_temp_3"]) == nil)
  }

  @Test("A temporary table named like a base table leaves the base table in its schema")
  func sameNameBaseTableStaysInSchema() {
    let split = SidebarSectionModel.temporarySplit([
      Self.table("public.scratch"), Self.table("pg_temp_3.scratch", isTemporary: true),
    ])
    #expect(split.regular.map(\.qualifiedName) == ["public.scratch"])
    #expect(split.temporary.map(\.qualifiedName) == ["pg_temp_3.scratch"])
  }

  @Test("A PostgreSQL temp schema with a table, a sequence and a view is never a schema")
  func postgresTempSchemaObjectsStayTemporary() {
    let tables = [
      Self.table("public.orders"), Self.table("pg_temp_3.scratch", isTemporary: true),
    ]
    // The schemas the sidebar reads: tables, the temp serial's sequence, a temp view, and a
    // temp schema holding a view only (found by its name)
    let schemas = ["public", "pg_temp_3", "pg_temp_3", "pg_temp_3", "pg_toast_temp_3", "pg_temp_7"]
    let temporary = SidebarSectionModel.temporarySchemas(
      schemas, tables: tables, databaseType: .postgresql)
    #expect(temporary == ["pg_temp_3", "pg_toast_temp_3", "pg_temp_7"])
    #expect(
      SidebarSectionModel.listedSchemas(
        Set(schemas).subtracting(temporary), hidden: [], defaultSchema: "public") == ["public"])
    let split = SidebarSectionModel.temporarySplit(tables, temporarySchemas: temporary)
    #expect(split.temporary.map(\.qualifiedName) == ["pg_temp_3.scratch"])
    #expect(split.regular.map(\.qualifiedName) == ["public.orders"])
  }

  @Test("A SQLite temp view keeps temp out of the schemas")
  func sqliteTempViewStaysTemporary() {
    let tables = [Self.table("main.kept")]
    let schemas = ["main", "temp"]
    let temporary = SidebarSectionModel.temporarySchemas(
      schemas, tables: tables, databaseType: .sqlite)
    #expect(temporary == ["temp"])
    #expect(
      SidebarSectionModel.listedSchemas(
        Set(schemas).subtracting(temporary), hidden: [], defaultSchema: "main") == ["main"])
  }

  @Test("MySQL names no temp schema: only the temporary table leaves its database")
  func mysqlHasNoTempSchema() {
    let tables = [
      Self.table("shop.orders"), Self.table("other_db.t", isTemporary: true),
      Self.table("reports.daily"),
    ]
    let temporary = SidebarSectionModel.temporarySchemas(
      ["shop", "other_db", "reports"], tables: tables, databaseType: .mysql)
    #expect(temporary.isEmpty)
    let split = SidebarSectionModel.temporarySplit(tables, temporarySchemas: temporary)
    #expect(Set(split.regular.map(\.schema)) == ["shop", "reports"])
  }

  @Test("The Temporary section stays when every regular schema is hidden")
  func temporaryShowsWhenEverySchemaIsHidden() {
    #expect(
      !SidebarSectionModel.showsEverySchemaHiddenScreen(
        listed: [], schemas: ["public", "sales"], hidden: ["public", "sales"],
        hasTemporary: true))
    #expect(
      SidebarSectionModel.showsEverySchemaHiddenScreen(
        listed: [], schemas: ["public", "sales"], hidden: ["public", "sales"],
        hasTemporary: false))
    #expect(
      !SidebarSectionModel.showsEverySchemaHiddenScreen(
        listed: ["sales"], schemas: ["public", "sales"], hidden: ["public"],
        hasTemporary: false))
  }

  @Test("MySQL temporary rows offer no item that reads the structure or columns")
  func temporaryRowStructureItems() {
    let temp = Self.table("shop.t", isTemporary: true)
    #expect(!SidebarSectionModel.rowReadsStructure(temp, databaseType: .mysql))
    #expect(SidebarSectionModel.rowReadsStructure(Self.table("shop.t"), databaseType: .mysql))
    #expect(SidebarSectionModel.rowReadsStructure(temp, databaseType: .postgresql))
    #expect(SidebarSectionModel.rowReadsStructure(temp, databaseType: .sqlite))
    // The row gates Build Join Query, Rename and Drop with it
    let reads = SidebarSectionModel.rowReadsStructure(temp, databaseType: .mysql)
    #expect(
      SidebarSectionModel.rowActions(
        for: .tables, name: temp.name, language: .sql, canChangeSchema: reads,
        canBuildJoinQuery: reads
      ).isEmpty)
  }

  @Test("Temporary rows name their schema only when the temporary tables span two schemas")
  func temporaryRowsShowSchema() {
    #expect(
      SidebarSectionModel.temporaryRowsShowSchema([
        Self.table("shop.t", isTemporary: true), Self.table("other_db.t", isTemporary: true),
      ]))
    #expect(
      !SidebarSectionModel.temporaryRowsShowSchema([
        Self.table("pg_temp_3.a", isTemporary: true), Self.table("pg_temp_3.b", isTemporary: true),
      ]))
    #expect(!SidebarSectionModel.temporaryRowsShowSchema([]))
  }

  // MARK: - Helpers

  /// A catalog row for "schema.name"
  private static func table(_ qualified: String, isTemporary: Bool = false) -> DatabaseTable {
    let parts = qualified.split(separator: ".", maxSplits: 1).map(String.init)
    return DatabaseTable(schema: parts[0], name: parts[1], isTemporary: isTemporary)
  }

  private func withSQLiteSession(
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-temp-tables-\(UUID().uuidString).db")
    defer { removeDatabase(at: url) }
    let session = SQLiteSession(
      config: ConnectionConfig(
        databaseType: .sqlite, database: url.path, username: "unused", password: "unused",
        sslMode: .disable))
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  private func removeDatabase(at url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
