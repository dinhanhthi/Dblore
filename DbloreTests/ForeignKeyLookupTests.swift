// ForeignKeyLookupTests.swift
// A source column's foreign key, the bound SELECT * … LIMIT 2, and the jump filter.
// A NULL component produces neither SQL nor a filter.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Foreign key lookup")
struct ForeignKeyLookupTests {
  private func key(
    _ constraint: String = "fk",
    schema: String = "public",
    table: String = "orders",
    source: [String],
    targetSchema: String = "public",
    targetTable: String = "users",
    target: [String]
  ) -> ForeignKey {
    ForeignKey(
      constraintName: constraint, sourceSchema: schema, sourceTable: table, sourceColumns: source,
      targetSchema: targetSchema, targetTable: targetTable, targetColumns: target)
  }

  @Test("The owning key is the first whose source column is in the row")
  func referenceFindsTheOwningKey() {
    let other = key("other", table: "invoices", source: ["user_id"], target: ["id"])
    let orders = key("orders_user", source: ["user_id"], target: ["id"])
    let keys = [other, orders]
    let match = ForeignKeyLookup.reference(
      for: "user_id", schema: "public", table: "orders", foreignKeys: keys,
      rowColumns: ["id", "user_id"])
    #expect(match?.constraintName == "orders_user")
    #expect(
      ForeignKeyLookup.reference(
        for: "id", schema: "public", table: "orders", foreignKeys: keys,
        rowColumns: ["id", "user_id"]) == nil)
    #expect(
      ForeignKeyLookup.reference(
        for: "user_id", schema: "public", table: "Orders", foreignKeys: keys,
        rowColumns: ["user_id"]) == nil)
  }

  @Test("A composite key counts only when every source column is present")
  func compositeNeedsEverySourceColumn() {
    let composite = key(
      "orders_tenant_user", source: ["tenant", "user_id"], targetTable: "memberships",
      target: ["tenant", "user_id"])
    let single = key("orders_user", source: ["user_id"], target: ["id"])
    let keys = [composite, single]

    let partial = ForeignKeyLookup.reference(
      for: "user_id", schema: "public", table: "orders", foreignKeys: keys,
      rowColumns: ["user_id"])
    #expect(partial?.constraintName == "orders_user")

    let full = ForeignKeyLookup.reference(
      for: "user_id", schema: "public", table: "orders", foreignKeys: keys,
      rowColumns: ["tenant", "user_id"])
    #expect(full?.constraintName == "orders_tenant_user")

    let alone = ForeignKeyLookup.reference(
      for: "tenant", schema: "public", table: "orders", foreignKeys: [composite],
      rowColumns: ["tenant"])
    #expect(alone == nil)
  }

  @Test("Schema matches exactly, including an empty schema")
  func schemaMatchesExactly() {
    let main = key("child_parent", schema: "main", table: "child", source: ["a"], target: ["a"])
    let other = key(
      "other_child", schema: "aux", table: "child", source: ["a"], targetSchema: "aux",
      target: ["a"])
    let keys = [other, main]
    #expect(
      ForeignKeyLookup.reference(
        for: "a", schema: "main", table: "child", foreignKeys: keys, rowColumns: ["a"])?
        .constraintName == "child_parent")
    #expect(
      ForeignKeyLookup.reference(
        for: "a", schema: "", table: "child", foreignKeys: keys, rowColumns: ["a"]) == nil)
    #expect(
      ForeignKeyLookup.reference(
        for: "a", schema: "public", table: "child", foreignKeys: keys, rowColumns: ["a"]) == nil)
  }

  @Test("Lookup SQL quotes the target and binds one :fk name per source column")
  func lookupSQLBindsSourceColumnsInOrder() {
    let link = key(
      "link_parent", schema: "main", table: "link", source: ["parent_b", "parent_a"],
      targetSchema: "main", targetTable: "parent", target: ["b", "a"])
    let values: [String: CellValue] = ["parent_b": .int(1), "parent_a": .string("x")]
    let expected = #"SELECT * FROM "main"."parent" WHERE "b" = :fk1 AND "a" = :fk2 LIMIT 2"#
    for dialect in [SQLDialect.postgresql, SQLDialect.sqlite] {
      let query = ForeignKeyLookup.lookupSQL(for: link, values: values, dialect: dialect)
      #expect(query?.sql == expected)
      #expect(query?.parameters == ["fk1": .text("1"), "fk2": .text("x")])
    }
  }

  @Test("Quoting matches the data viewer, and values stay out of the SQL")
  func quotingMatchesTheDataViewer() {
    let weird = key(
      "weird", source: ["user_id"], targetSchema: "my\"s", targetTable: "we\"ird",
      target: ["a\"b"])
    let query = ForeignKeyLookup.lookupSQL(
      for: weird, values: ["user_id": .string("'; DROP TABLE users;--")], dialect: .postgresql)
    #expect(
      query?.sql
        == #"SELECT * FROM "my""s"."we""ird" WHERE "a""b" = :fk1 LIMIT 2"#)
    #expect(query?.parameters == ["fk1": .text("'; DROP TABLE users;--")])

    let unqualified = key(
      "bare", source: ["id"], targetSchema: "", targetTable: "child", target: ["id"])
    let bare = ForeignKeyLookup.lookupSQL(
      for: unqualified, values: ["id": .int(7)], dialect: .sqlite)
    #expect(bare?.sql == #"SELECT * FROM "child" WHERE "id" = :fk1 LIMIT 2"#)

    let nul = key("nul", source: ["id"], target: ["a\0b"])
    let nulSQL = ForeignKeyLookup.lookupSQL(
      for: nul, values: ["id": .int(1)], dialect: .postgresql)
    let quoted = CellUpdateStatement.quoteIdentifier("a\0b")
    #expect(nulSQL?.sql == #"SELECT * FROM "public"."users" WHERE \#(quoted) = :fk1 LIMIT 2"#)
  }

  @Test("A null or missing component is not a lookup and not a filter")
  func nullComponentHasNoLookup() {
    let composite = key(source: ["tenant", "user_id"], target: ["tenant", "id"])
    let missing: [String: CellValue] = ["tenant": .int(1)]
    let nullTenant: [String: CellValue] = ["tenant": .null, "user_id": .int(2)]
    for values in [missing, nullTenant] {
      let query = ForeignKeyLookup.lookupSQL(
        for: composite, values: values, dialect: .postgresql)
      #expect(query == nil)
      #expect(ForeignKeyLookup.jumpFilter(for: composite, values: values) == nil)
    }
    let broken = key(source: ["a", "b"], target: ["id"])
    let both: [String: CellValue] = ["a": .int(1), "b": .int(2)]
    #expect(ForeignKeyLookup.lookupSQL(for: broken, values: both, dialect: .postgresql) == nil)
    #expect(ForeignKeyLookup.jumpFilter(for: broken, values: both) == nil)
  }

  @Test("The text NULL and an empty string are values, not SQL NULL")
  func textNullAndEmptyStringAreValues() {
    let orders = key(source: ["code"], target: ["code"])
    let textNull = ForeignKeyLookup.lookupSQL(
      for: orders, values: ["code": .string("NULL")], dialect: .postgresql)
    #expect(textNull?.sql == #"SELECT * FROM "public"."users" WHERE "code" = :fk1 LIMIT 2"#)
    #expect(textNull?.parameters == ["fk1": .text("NULL")])
    #expect(textNull?.sql.contains("= NULL") == false)

    let empty = ForeignKeyLookup.jumpFilter(for: orders, values: ["code": .string("")])
    #expect(empty?.conditions.map(\.value) == [""])
    #expect(empty?.conditions.map(\.op) == [.equals])
  }

  @Test("An empty-string jump stays in page SQL; a blank form row does not")
  func emptyStringJumpReachesPageSQL() {
    let orders = key(source: ["code"], target: ["code"])
    let empty = ForeignKeyLookup.jumpFilter(for: orders, values: ["code": .string("")])
    #expect(empty?.conditions.map(\.emptyStringIsValue) == [true])
    #expect(empty?.whereClause(dialect: .postgresql) == #""code" = ''"#)
    var viewer = DataViewerState(schema: "public", name: "users", orderColumns: [])
    viewer.filter = empty ?? TableFilter(conditions: [])
    #expect(viewer.pageSQL.contains(#"= ''"#))

    let composite = key(source: ["tenant", "code"], target: ["tenant", "code"])
    let both = ForeignKeyLookup.jumpFilter(
      for: composite, values: ["tenant": .string("acme"), "code": .string("")])
    #expect(both?.conditions.map(\.emptyStringIsValue) == [false, true])
    #expect(
      both?.whereClause(dialect: .postgresql) == #""tenant" = 'acme' AND "code" = ''"#)
    viewer.filter = both ?? TableFilter(conditions: [])
    let page = viewer.pageSQL
    #expect(page.contains(#""tenant" = 'acme'"#))
    #expect(page.contains(#""code" = ''"#))

    let blank = FilterCondition(column: "name", op: .equals, value: "")
    #expect(blank.emptyStringIsValue == false)
    #expect(TableFilter(conditions: [blank]).whereClause(dialect: .postgresql) == nil)
    let noColumn = FilterCondition(column: "", value: "", emptyStringIsValue: true)
    #expect(TableFilter(conditions: [noColumn]).whereClause(dialect: .postgresql) == nil)
  }

  @Test("The jump filter is equals on the target columns, in source order")
  func jumpFilterUsesTargetColumns() {
    let link = key(
      schema: "main", table: "link", source: ["parent_b", "parent_a"], targetSchema: "main",
      targetTable: "parent", target: ["b", "a"])
    let filter = ForeignKeyLookup.jumpFilter(
      for: link, values: ["parent_a": .int(2), "parent_b": .bool(true)])
    #expect(filter?.conditions.map(\.column) == ["b", "a"])
    #expect(filter?.conditions.map(\.op) == [.equals, .equals])
    #expect(filter?.conditions.map(\.value) == ["true", "2"])
    #expect(filter?.conditions.map(\.connector) == [.and, .and])
  }

  @Test("Non-null cell values become untyped text")
  func cellValuesBecomeText() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let dateText = "2023-11-14T22:13:20.000Z"
    let orders = key(source: ["v"], target: ["v"])
    let cases: [(CellValue, String)] = [
      (.int(42), "42"),
      (.double(1.239), "1.239"),
      (.bool(false), "false"),
      (.json(#"{"a":1}"#), #"{"a":1}"#),
      (.date(date), dateText),
      (.data(Data([0x0A, 0xFF])), "\\x0aff"),
    ]
    for (value, text) in cases {
      let query = ForeignKeyLookup.lookupSQL(
        for: orders, values: ["v": value], dialect: .postgresql)
      #expect(query?.parameters["fk1"] == .text(text))
    }
  }

  @Test("A date keeps its milliseconds")
  func dateKeepsFractionalSeconds() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.1234)
    let query = ForeignKeyLookup.lookupSQL(
      for: key(source: ["v"], target: ["v"]), values: ["v": .date(date)], dialect: .postgresql)
    #expect(query?.parameters["fk1"] == .text("2023-11-14T22:13:20.123Z"))
  }
}
