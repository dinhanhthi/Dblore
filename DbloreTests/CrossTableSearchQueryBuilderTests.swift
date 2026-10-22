// CrossTableSearchQueryBuilderTests.swift
// Find a value in every table: the searched value is always a bind, identifiers are quoted per
// dialect, the LIKE pattern is escaped, binary and spatial columns are skipped, and every
// statement passes ReadOnlyQueryGuard.

import Foundation
import Testing

@testable import Dblore

@Suite("Cross-table search query builder")
struct CrossTableSearchQueryBuilderTests {
  typealias Builder = CrossTableSearchQueryBuilder

  private static let dialects: [SQLDialect] = [.postgresql, .mysql, .sqlite, .duckdb]

  private let columns: [Builder.Column] = [
    .init(name: "id", type: "integer", isPrimaryKey: true),
    .init(name: "email", type: "text"),
  ]

  @Test(
    "The value is a bind and never appears in the SQL text",
    arguments: dialects, Builder.Mode.allCases)
  func valueIsBound(dialect: SQLDialect, mode: Builder.Mode) throws {
    let value = "'; DROP TABLE x; --"
    let statement = try #require(
      try Builder.statement(
        schema: "app", table: "users", columns: columns, value: value, mode: mode,
        dialect: dialect))

    #expect(!statement.sql.contains("DROP"))
    #expect(!statement.sql.contains("'; "))
    #expect(!statement.sql.contains("--"))
    let expected = mode == .contains ? "%\(value)%" : value
    #expect(statement.parameters == [Builder.valueParameter: .text(expected)])
    // The gate binds `:v` (and nothing positional, which it refuses mixed with names)
    #expect(
      SQLParameterRewriter.parameterNames(in: statement.sql, dialect: dialect)
        == [Builder.valueParameter])
    #expect(
      !SQLParameterRewriter.containsPositionalPlaceholder(in: statement.sql, dialect: dialect))
  }

  @Test("Identifiers with quotes are quoted per dialect")
  func identifiersAreQuoted() throws {
    let columns: [Builder.Column] = [.init(name: #"co"l`x"#, type: "text", isPrimaryKey: true)]

    let postgres = try #require(
      try Builder.statement(
        schema: #"my"schema"#, table: #"ta"ble"#, columns: columns, value: "a", mode: .equals,
        dialect: .postgresql))
    #expect(
      postgres.sql
        == #"SELECT CAST("co""l`x" AS text), CASE WHEN CAST("co""l`x" AS text) = :v THEN 1 END "#
        + #"FROM "my""schema"."ta""ble" WHERE CAST("co""l`x" AS text) = :v LIMIT 50"#)

    let mysql = try #require(
      try Builder.statement(
        schema: "my`db", table: "ta`ble", columns: columns, value: "a", mode: .equals,
        dialect: .mysql))
    #expect(mysql.sql.contains("FROM `my``db`.`ta``ble`"))
    #expect(mysql.sql.contains(#"CAST(`co"l``x` AS CHAR) = :v"#))

    let sqlite = try #require(
      try Builder.statement(
        schema: "main", table: #"ta"ble"#, columns: columns, value: "a", mode: .equals,
        dialect: .sqlite))
    #expect(sqlite.sql.contains(#"FROM "main"."ta""ble""#))
    #expect(sqlite.sql.contains(#"CAST("co""l`x" AS TEXT) = :v"#))

    let duckdb = try #require(
      try Builder.statement(
        schema: "main", table: "t", columns: columns, value: "a", mode: .equals,
        dialect: .duckdb))
    #expect(duckdb.sql.contains(#"CAST("co""l`x" AS VARCHAR) = :v"#))
  }

  @Test("The LIKE pattern escapes %, _ and the escape character, with an ESCAPE clause")
  func likePatternIsEscaped() throws {
    let statement = try #require(
      try Builder.statement(
        schema: "public", table: "t", columns: columns, value: "50%_off!", mode: .contains,
        dialect: .postgresql))

    #expect(statement.parameters == [Builder.valueParameter: .text("%50!%!_off!!%")])
    #expect(statement.sql.contains("CAST(\"email\" AS text) LIKE :v ESCAPE '!'"))
    #expect(statement.sql.contains(" OR "))

    let equals = try #require(
      try Builder.statement(
        schema: "public", table: "t", columns: columns, value: "50%_off!", mode: .equals,
        dialect: .postgresql))
    #expect(equals.parameters == [Builder.valueParameter: .text("50%_off!")])
    #expect(!equals.sql.contains("LIKE"))
  }

  @Test("Binary and spatial columns are skipped; a table without castable columns has no statement")
  func binaryAndSpatialColumnsAreSkipped() throws {
    let mixed: [Builder.Column] = [
      .init(name: "photo", type: "bytea"),
      .init(name: "area", type: "geometry(Polygon,4326)"),
      .init(name: "spot", type: "point"),
      .init(name: "raw", type: "varbinary(16)"),
      .init(name: "file", type: "BLOB"),
      .init(name: "name", type: "character varying(40)"),
    ]
    let statement = try #require(
      try Builder.statement(
        schema: "public", table: "t", columns: mixed, value: "x", mode: .contains,
        dialect: .postgresql))
    #expect(statement.searchedColumns == ["name"])
    for skipped in ["photo", "area", "spot", "raw", "file"] {
      #expect(!statement.sql.contains("\"\(skipped)\""))
    }

    let noText: [Builder.Column] = [
      .init(name: "photo", type: "longblob"),
      .init(name: "shape", type: "public.geography"),
      .init(name: "pt", type: "POINT"),
    ]
    for dialect in Self.dialects {
      #expect(
        try Builder.statement(
          schema: "s", table: "t", columns: noText, value: "x", mode: .contains,
          dialect: dialect) == nil)
    }
  }

  @Test(
    "Opening a match filters with the search's LIKE semantics",
    arguments: [
      (
        Builder.Mode.contains, SQLDialect.postgresql, #""c"::text LIKE E'%C:\\t!%!_!!%' ESCAPE '!'"#
      ),
      (.equals, .postgresql, #""c"::text LIKE E'C:\\t!%!_!!' ESCAPE '!'"#),
      (.contains, .mysql, #"CAST(`c` AS CHAR) LIKE '%C:\\t!%!_!!%' ESCAPE '!'"#),
      (.equals, .mysql, #"CAST(`c` AS CHAR) LIKE 'C:\\t!%!_!!' ESCAPE '!'"#),
      (.contains, .sqlite, #""c" LIKE '%C:\t!%!_!!%' ESCAPE '!'"#),
      (.equals, .sqlite, #""c" LIKE 'C:\t!%!_!!' ESCAPE '!'"#),
    ])
  @MainActor
  func openedFilterMatchesTheSearch(mode: Builder.Mode, dialect: SQLDialect, expected: String) {
    // `\` stays a plain character (the backslash is no LIKE escape under `ESCAPE '!'`); `%`,
    // `_` and `!` are escaped as the search binds them
    let filter = CrossTableSearchModel.filter(column: "c", value: #"C:\t%_!"#, mode: mode)
    #expect(filter.whereClause(dialect: dialect) == expected)
  }

  @Test("Every built statement passes ReadOnlyQueryGuard", arguments: dialects)
  func everyStatementPassesTheGuard(dialect: SQLDialect) throws {
    for mode in Builder.Mode.allCases {
      for value in ["plain", "'; DROP TABLE x; --", "a:b $1 ?", "%_!"] {
        let statement = try #require(
          try Builder.statement(
            schema: "s", table: "t;DELETE", columns: columns, value: value, mode: mode,
            dialect: dialect))
        let checked = try ReadOnlyQueryGuard.check(
          statement.sql, dialect: dialect, refuseFileAccess: true)
        #expect(checked.count == 1)
      }
    }
  }
}
