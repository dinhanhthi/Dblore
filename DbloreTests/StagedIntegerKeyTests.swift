// StagedIntegerKeyTests.swift
// Next integer primary key for a staged insert, and the catalog lookup that decides it.

import Foundation
import Testing

@testable import Dblore

@Suite("Staged integer primary key")
struct StagedIntegerKeyTests {
  @Test("Only a single integer primary key is filled")
  func onlyASingleIntegerKey() {
    let columns = [
      ColumnInfo(name: "id", type: "int4"),
      ColumnInfo(name: "name", type: "text"),
      ColumnInfo(name: "n", type: "INTEGER"),
    ]
    #expect(StagedIntegerKey.integerColumn(primaryKey: ["id"], columns: columns) == "id")
    #expect(StagedIntegerKey.integerColumn(primaryKey: ["n"], columns: columns) == "n")
    #expect(StagedIntegerKey.integerColumn(primaryKey: ["name"], columns: columns) == nil)
    #expect(StagedIntegerKey.integerColumn(primaryKey: ["id", "n"], columns: columns) == nil)
    #expect(StagedIntegerKey.isIntegerType("bigint"))
    #expect(!StagedIntegerKey.isIntegerType("numeric"))
  }

  @Test("The next value is one past the highest known key, or 1")
  func nextValue() {
    #expect(StagedIntegerKey.nextValue(known: []) == 1)
    #expect(StagedIntegerKey.nextValue(known: [1, 4, 2]) == 5)
    #expect(StagedIntegerKey.nextValue(known: [-3]) == -2)
    #expect(StagedIntegerKey.nextValue(known: [Int.max]) == nil)
  }

  @Test("PostgreSQL lookup reads the default and the max id")
  func postgresLookup() {
    let sql = StagedIntegerKey.lookupSQL(
      schema: "public", table: "qa_people", column: "id", dialect: .postgresql)
    #expect(sql?.contains("information_schema.columns") == true)
    #expect(sql?.contains("c.column_default IS NOT NULL") == true)
    #expect(sql?.contains(#"MAX("id") FROM "public"."qa_people""#) == true)
    #expect(sql?.contains("table_name = 'qa_people'") == true)
  }

  @Test("SQLite lookup reads pragma_table_info")
  func sqliteLookup() {
    let sql = StagedIntegerKey.lookupSQL(
      schema: "main", table: "qa_people", column: "id", dialect: .sqlite)
    #expect(sql?.contains("pragma_table_info('qa_people', 'main')") == true)
    #expect(sql?.contains("dflt_value IS NOT NULL") == true)
    #expect(sql?.contains(#"MAX("id")"#) == true)
  }

  @Test("A lookup row is a bool and an optional max")
  func parseLookup() {
    #expect(
      StagedIntegerKey.parseLookup([.bool(false), .int(2)])?.hasDefault == false)
    #expect(StagedIntegerKey.parseLookup([.bool(false), .int(2)])?.serverMax == 2)
    #expect(StagedIntegerKey.parseLookup([.int(1), .null])?.hasDefault == true)
    #expect(StagedIntegerKey.parseLookup([.int(1), .null])?.serverMax == nil)
    #expect(StagedIntegerKey.parseLookup([.string("nope"), .int(1)]) == nil)
    #expect(StagedIntegerKey.parseLookup(nil) == nil)
  }
}
