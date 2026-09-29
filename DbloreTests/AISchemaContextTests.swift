// AISchemaContextTests.swift
// Unit tests for AI schema table selection and rendering

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("AI Schema Context Tests")
struct AISchemaContextTests {

  private func table(
    _ name: String, schema: String = "public", columns: [String] = ["id"], rowCount: Int? = nil
  ) -> DatabaseTable {
    DatabaseTable(
      schema: schema, name: name,
      columns: columns.map { DatabaseColumn(name: $0, type: "text") }, rowCount: rowCount)
  }

  private func fk(_ from: String, _ fromCol: String, _ to: String, _ toCol: String) -> ForeignKey {
    ForeignKey(
      constraintName: "fk_\(from)_\(to)", sourceSchema: "public", sourceTable: from,
      sourceColumns: [fromCol], targetSchema: "public", targetTable: to, targetColumns: [toCol])
  }

  @Test("table name match outranks column match")
  func nameBeatsColumn() {
    let tables = [table("orders", columns: ["id", "customer_id"]), table("customers")]
    let result = AISchemaContext.relevantTables(
      question: "show customers", tables: tables, foreignKeys: [])
    #expect(result.map(\.name) == ["customers", "orders"])
  }

  @Test("plural tokens are stripped")
  func pluralStrip() {
    let tables = [table("a"), table("user")]
    let result = AISchemaContext.relevantTables(
      question: "list users", tables: tables, foreignKeys: [])
    #expect(result.first?.name == "user")
  }

  @Test("foreign keys boost related tables")
  func fkBoost() {
    let tables = [table("zeta"), table("items"), table("invoice")]
    let fks = [fk("items", "invoice_id", "invoice", "id")]
    let result = AISchemaContext.relevantTables(
      question: "invoice", tables: tables, foreignKeys: fks)
    // invoice: 10 (name); items: 5 (column invoice_id) + 3 (fk); zeta: 0
    #expect(result.map(\.name) == ["invoice", "items"])
    let boosted = AISchemaContext.relevantTables(
      question: "invoice", tables: [table("zeta"), table("items")], foreignKeys: fks)
    #expect(boosted.isEmpty == false)
  }

  @Test("FK boost pulls in an unmatched linked table")
  func fkBoostUnmatched() {
    let tables = [table("zeta"), table("lines"), table("invoice")]
    let fks = [fk("lines", "ref", "invoice", "id")]
    let result = AISchemaContext.relevantTables(
      question: "invoice", tables: tables, foreignKeys: fks)
    #expect(result.map(\.name) == ["invoice", "lines"])
  }

  @Test("no match falls back to first 20 tables")
  func fallback() {
    let tables = (0..<30).map { table("t\($0)") }
    let result = AISchemaContext.relevantTables(
      question: "zzzz", tables: tables, foreignKeys: [])
    #expect(result.count == 20)
    #expect(result.first?.name == "t0")
  }

  @Test("limit caps results")
  func limitCaps() {
    let tables = (0..<10).map { table("user\($0)") }
    let result = AISchemaContext.relevantTables(
      question: "user", tables: tables, foreignKeys: [], limit: 3)
    #expect(result.count == 3)
  }

  @Test("explicit selection overrides scoring")
  func explicitOverrides() {
    let tables = [table("users"), table("orders")]
    let result = AISchemaContext.selectTables(
      explicit: ["public.orders"], question: "users", tables: tables, foreignKeys: [])
    #expect(result.map(\.name) == ["orders"])
    let scored = AISchemaContext.selectTables(
      explicit: [], question: "users", tables: tables, foreignKeys: [])
    #expect(scored.first?.name == "users")
  }

  @Test("render lists columns with flags and FK lines")
  func renderFormat() {
    let users = DatabaseTable(
      schema: "public", name: "users",
      columns: [
        DatabaseColumn(name: "id", type: "int4", isNullable: false, isPrimaryKey: true),
        DatabaseColumn(name: "email", type: "text", isNullable: false, isUnique: true),
        DatabaseColumn(name: "bio", type: "text"),
      ])
    let orders = table("orders", columns: ["user_id"])
    let out = AISchemaContext.render(
      tables: [users, orders], foreignKeys: [fk("orders", "user_id", "users", "id")])
    #expect(
      out.contains("public.users(id int4 PK NOT NULL, email text NOT NULL UNIQUE, bio text)"))
    #expect(out.contains("FK public.orders(user_id) -> public.users(id)"))
  }

  @Test("FK lines only for rendered tables")
  func fkOnlyAmongRendered() {
    let out = AISchemaContext.render(
      tables: [table("orders")], foreignKeys: [fk("orders", "user_id", "users", "id")])
    #expect(!out.contains("FK "))
  }

  @Test("budget cuts tables and reports the remainder")
  func budgetCut() {
    let tables = (0..<10).map { table("table_number_\($0)") }
    let out = AISchemaContext.render(tables: tables, foreignKeys: [], budgetChars: 100)
    #expect(out.contains("-- … and "))
    #expect(out.contains("more tables"))
    #expect(!out.contains("table_number_9"))
  }

  @Test("row counts are never rendered")
  func noRowCount() {
    let out = AISchemaContext.render(
      tables: [table("users", rowCount: 12345)], foreignKeys: [])
    #expect(!out.contains("12345"))
  }
}
