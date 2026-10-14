// MySQLDialectSitesTests.swift
// SQLDialect.mysql: backtick identifiers, backslash-escaped literals, bare `?` placeholders,
// EXPLAIN prefixes, CAST(x AS CHAR) text casts and LIKE in place of ILIKE.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("MySQL dialect sites")
struct MySQLDialectSitesTests {

  // MARK: - Names

  @Test(
    "Identifiers are backticked with embedded backticks doubled",
    arguments: [
      ("id", "`id`"),
      ("a`b", "`a``b`"),
      (#"a"b"#, #"`a"b`"#),
      ("", "``"),
    ])
  func quoteIdentifier(name: String, expected: String) throws {
    #expect(try SQLDialect.mysql.quoteIdentifier(name) == expected)
  }

  @Test("A NUL in an identifier is rejected")
  func nulInIdentifier() {
    #expect(throws: SQLDialectError.nulInIdentifier) {
      try SQLDialect.mysql.quoteIdentifier("a\0b")
    }
  }

  @Test("A schema (database) qualifies the name")
  func qualified() throws {
    #expect(try SQLDialect.mysql.qualified(schema: "db", name: "t") == "`db`.`t`")
    #expect(try SQLDialect.mysql.qualified(schema: nil, name: "t") == "`t`")
  }

  // MARK: - Literals

  @Test(
    "Literals escape quotes and backslashes",
    arguments: [
      (CellValue.string("plain"), "'plain'"),
      (.string("o'brien"), "'o''brien'"),
      (.string(#"C:\p"#), #"'C:\\p'"#),
      (.string(#"a\'b"#), #"'a\\''b'"#),
      (.json(#"{"a":"\n"}"#), #"'{"a":"\\n"}'"#),
      (.bool(true), "TRUE"),
      (.null, "NULL"),
      (.double(.nan), "NULL"),
      (.double(.infinity), "NULL"),
      (.data(Data([0x00, 0x0A, 0xFF])), "X'000AFF'"),
    ])
  func literal(value: CellValue, expected: String) {
    #expect(SQLDialect.mysql.literal(value) == expected)
  }

  // MARK: - Placeholders

  // MARK: - EXPLAIN

  @Test(
    "EXPLAIN, EXPLAIN FORMAT=JSON and EXPLAIN ANALYZE; buffers ignored",
    arguments: [
      (false, false, String?.none, "EXPLAIN"),
      (false, true, nil, "EXPLAIN"),
      (false, false, "json", "EXPLAIN FORMAT=JSON"),
      (false, true, "json", "EXPLAIN FORMAT=JSON"),
      (true, false, nil, "EXPLAIN ANALYZE"),
      (true, true, "json", "EXPLAIN ANALYZE"),
    ])
  func explainPrefix(analyze: Bool, buffers: Bool, format: String?, expected: String) {
    #expect(
      SQLDialect.mysql.explainPrefix(analyze: analyze, buffers: buffers, format: format)
        == expected)
  }

  @Test("ExplainRequest asks MySQL for the tabular plan")
  func explainRequest() throws {
    let plain = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: false, dialect: .mysql)
    #expect(plain.sql == "EXPLAIN SELECT 1")
    let analyzed = try ExplainRequest(
      statement: "SELECT 1", analyze: true, buffers: false, dialect: .mysql,
      mysqlServer: MySQLServerInfo(version: "8.4.11"))
    #expect(analyzed.sql == "EXPLAIN ANALYZE SELECT 1")
  }

  // MARK: - Table filter

  @Test(
    "LIKE filters cast to CHAR and never use ILIKE",
    arguments: [
      (FilterOperator.like, "CAST(`c` AS CHAR) LIKE 'v'"),
      (.notLike, "CAST(`c` AS CHAR) NOT LIKE 'v'"),
      (.ilike, "CAST(`c` AS CHAR) LIKE 'v'"),
      (.notIlike, "CAST(`c` AS CHAR) NOT LIKE 'v'"),
    ])
  func filter(op: FilterOperator, expected: String) {
    let filter = TableFilter(
      conditions: [FilterCondition(column: "c", op: op, value: "v", connector: .and)])
    #expect(filter.whereClause(dialect: .mysql) == expected)
  }
}
