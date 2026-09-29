// SchemaCatalogTests.swift
// Pure mapping of bulk pg_catalog column rows: display type from format_type, grouping by
// "schema.relation" in attnum order, and the flag rules (unique only when not primary key).

import Testing

@testable import Dblore

@Suite("Schema Catalog")
@MainActor
struct SchemaCatalogTests {
  @Test(
    "displayType table",
    arguments: [
      ("integer", "INTEGER"),
      ("character varying(255)", "CHARACTER VARYING(255)"),
      ("numeric(10,2)", "NUMERIC(10,2)"),
      ("integer[]", "INTEGER[]"),
      ("timestamp(6) without time zone", "TIMESTAMP(6) W/O TZ"),
      ("timestamp without time zone", "TIMESTAMP W/O TZ"),
      ("timestamp with time zone", "TIMESTAMP W TZ"),
      ("time(3) with time zone", "TIME(3) W TZ"),
      ("public.mood", "PUBLIC.MOOD"),
      ("\"MyType\"", "\"MYTYPE\""),
      ("INTEGER", "INTEGER"),
      ("TIMESTAMP WITH TIME ZONE", "TIMESTAMP W TZ"),
    ]
  )
  func displayType(formatType: String, expected: String) {
    #expect(SchemaCatalog.displayType(formatType: formatType) == expected)
  }

  private func row(
    _ schema: String, _ relation: String, _ name: String, type: String = "integer",
    notNull: Bool = false, identity: Bool = false, pk: Bool = false, unique: Bool = false
  ) -> SchemaCatalog.ColumnRow {
    SchemaCatalog.ColumnRow(
      schema: schema, relation: relation, name: name, formatType: type, notNull: notNull,
      isIdentity: identity, isPK: pk, isUnique: unique)
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

  @Test("empty input gives empty result")
  func empty() {
    #expect(SchemaCatalog.columnsByRelation([]).isEmpty)
  }
}
