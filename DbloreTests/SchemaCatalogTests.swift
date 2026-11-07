// SchemaCatalogTests.swift
// Pure mapping of bulk pg_catalog column rows: display type from format_type, grouping by
// "schema.relation" in attnum order, and the flag rules (unique only when not primary key). Also
// the `array_agg(...)::text` array text split into names (escapes and combining marks).

import Testing

@testable import Dblore

@Suite("Schema Catalog")
@MainActor
struct SchemaCatalogTests {
  private func row(
    _ schema: String, _ relation: String, _ name: String, type: String = "integer",
    notNull: Bool = false, identity: Bool = false, pk: Bool = false, unique: Bool = false,
    postgresType: PostgresColumnType? = nil
  ) -> SchemaCatalog.ColumnRow {
    SchemaCatalog.ColumnRow(
      schema: schema, relation: relation, name: name, formatType: type, notNull: notNull,
      isIdentity: identity, isPK: pk, isUnique: unique, postgresType: postgresType)
  }

  @Test("groups by schema.relation keeping input order")
  func grouping() {
    let result = SchemaCatalog.columnsByRelation([
      row("public", "users", "id"),
      row("sales", "orders", "id"),
      row("public", "users", "email"),
      row("sales", "orders", "total"),
      row("public", "users", "age"),
    ])
    #expect(Set(result.keys) == ["public.users", "sales.orders"])
    #expect(result["public.users"]?.map(\.name) == ["id", "email", "age"])
    #expect(result["sales.orders"]?.map(\.name) == ["id", "total"])
    #expect(result["public.users"]?.first?.type == "INTEGER")
  }

  @Test("key format matches DatabaseTable.qualifiedName")
  func keyFormat() {
    let table = DatabaseTable(schema: "s", name: "t")
    let result = SchemaCatalog.columnsByRelation([row("s", "t", "c")])
    #expect(result[table.qualifiedName] != nil)
  }

  @Test("primary key is not flagged unique")
  func pkNotUnique() {
    let cols = SchemaCatalog.columnsByRelation([
      row("public", "t", "id", pk: true, unique: true),
      row("public", "t", "code", unique: true),
    ])["public.t"]
    #expect(cols?[0].isPrimaryKey == true)
    #expect(cols?[0].isUnique == false)
    #expect(cols?[1].isUnique == true)
  }

  @Test("nullable and identity mapping")
  func flags() {
    let cols = SchemaCatalog.columnsByRelation([
      row("public", "t", "a", notNull: true, identity: true),
      row("public", "t", "b"),
    ])["public.t"]
    #expect(cols?[0].isNullable == false)
    #expect(cols?[0].isIdentity == true)
    #expect(cols?[1].isNullable == true)
    #expect(cols?[1].isIdentity == false)
  }

  @Test("a row's PostgreSQL type data reaches its column; a row without it gives nil")
  func postgresType() {
    let citext = PostgresColumnType(
      oid: 16_385, operand: .bare, castName: "public.citext", compareCast: nil,
      operatorSchema: "public")
    let cols = SchemaCatalog.columnsByRelation([
      row("public", "t", "email", type: "citext", postgresType: citext),
      row("public", "t", "id"),
    ])["public.t"]
    #expect(cols?[0].postgresType == citext)
    #expect(cols?[1].postgresType == nil)
  }

  @Test("array text splits per scalar and resolves backslash escapes in quoted elements")
  func arrayText() {
    // A quote followed by a combining mark is one Character: the split must see the quote
    let names = CatalogValue.stringList(.string(#"{"a\"b","c\\d","\#u{301}x y",plain}"#))
    #expect(
      names.map { Array($0.unicodeScalars) }
        == ["a\"b", "c\\d", "\u{301}x y", "plain"].map { Array($0.unicodeScalars) })
  }

  @Test("a partition row of the table listing points at its parent's table id")
  func partitionParent() async throws {
    let session = FakeDatabaseSession(
      capabilities: .contract(), columns: [],
      rows: [
        [.string("public"), .string("events"), .null, .bool(false), .null, .null],
        [
          .string("archive"), .string("events_2026_10"), .int(5), .bool(false),
          .string("public"), .string("events"),
        ],
      ], slowQueries: false)
    let tables = try await PostgresSchemaIntrospector().tables(in: session)
    #expect(tables.map(\.name) == ["events", "events_2026_10"])
    #expect(tables[0].parentID == nil)
    #expect(tables[1].parentID == tables[0].id)
  }

  @Test(
    "allColumns reads the type data of non-built-in oids only; no extension schema compares qualified"
  )
  func allColumnsTypeData() async throws {
    // The column read: eight column cells, then the type oid
    func cells(_ name: String, _ oid: CellValue) -> [CellValue] {
      [.string("public"), .string("t"), .string(name), .string("x")]
        + [false, false, false, false].map { .bool($0) } + [oid]
    }
    let s = CellValue.string
    let columnRows: [[CellValue]] = [
      cells("email", .int(16_385)), cells("handle", .int(16_390)), cells("tags", .int(16_388)),
      cells("note", .int(25)), cells("lost", .int(16_391)),
      // No type oid
      cells("unread", .null),
    ]
    // The type read: oid, operand, cast name, compare cast, operator schema
    let typeRows: [[CellValue]] = [
      [.int(16_385), s("bare"), s("public.citext"), .null, s("public")],
      [.int(16_390), s("bare"), s("public.cit_dom"), s("public.citext"), s("public")],
      [.int(16_388), s("qualified"), s("public.citext[]"), .null, .null],
      // Bare without the extension's schema
      [.int(16_391), s("bare"), s("public.citext"), .null, .null],
    ]
    let session = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [], slowQueries: false,
      queryAnswer: { _, binds in
        FakeQueryAnswer(columns: [], rows: binds.isEmpty ? columnRows : typeRows)
      })
    let columns = try #require(
      try await PostgresSchemaIntrospector().allColumns(in: session)["public.t"])
    let types = columns.map(\.postgresType)
    #expect(columns.map(\.name) == ["email", "handle", "tags", "note", "lost", "unread"])
    #expect(
      types[0]
        == PostgresColumnType(
          oid: 16_385, operand: .bare, castName: "public.citext", compareCast: nil,
          operatorSchema: "public"))
    #expect(
      types[1]
        == PostgresColumnType(
          oid: 16_390, operand: .bare, castName: "public.cit_dom", compareCast: "public.citext",
          operatorSchema: "public"))
    #expect(
      types[2]
        == PostgresColumnType(
          oid: 16_388, operand: .qualified, castName: "public.citext[]", compareCast: nil,
          operatorSchema: nil))
    // A built-in type (text) is not read: nil, which compares qualified
    #expect(types[3] == nil)
    #expect(types[5] == nil)
    // One type read over the distinct non-built-in oids, ascending
    #expect(session.statements.count == 2)
    #expect(session.statementBinds.last == [.text("{16385,16388,16390,16391}")])
    #expect(
      types.map(SQLOperandKind.init(column:))
        == [.bare, .bare, .qualified, .qualified, .qualified, .qualified])

    // Only built-in types (int4, text): no type read at all
    let builtInRows = [cells("id", .int(23)), cells("note", .int(25))]
    let builtInOnly = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [], slowQueries: false,
      queryAnswer: { _, binds in
        FakeQueryAnswer(columns: [], rows: binds.isEmpty ? builtInRows : [])
      })
    let builtIns = try #require(
      try await PostgresSchemaIntrospector().allColumns(in: builtInOnly)["public.t"])
    #expect(builtIns.map(\.postgresType) == [nil, nil])
    #expect(builtInOnly.statements.count == 1)
  }
}
