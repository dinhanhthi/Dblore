// SQLDialectTests.swift
// SQLDialect quotes identifiers, renders CellValue literals, and builds dialect-specific fragments.

import Foundation
import Testing

@testable import Dblore

/// `"name"` with embedded `"` doubled. Shared by both dialects.
private let quotedIdentifierCases: [(String, String)] = [
  ("id", #""id""#),
  ("a\"b", #""a""b""#),
  ("\"", #""""""#),
  ("café", #""café""#),
  ("用户", #""用户""#),
  ("", #""""#),
]

private let quoteCases: [(SQLDialect, String, String)] = [
  SQLDialect.postgresql, SQLDialect.sqlite,
].flatMap { dialect in
  quotedIdentifierCases.map { (dialect, $0.0, $0.1) }
}

private let qualifiedCases: [(SQLDialect, String?, String, String)] = [
  (.postgresql, nil, "users", #""users""#),
  (.postgresql, "public", "users", #""users""#),
  (.postgresql, "main", "users", #""main"."users""#),
  (.postgresql, "app", "users", #""app"."users""#),
  (.postgresql, "a\"b", "c\"d", #""a""b"."c""d""#),
  (.postgresql, "schéma", "表", #""schéma"."表""#),
  (.postgresql, "", "users", #"""."users""#),
  (.postgresql, nil, "", #""""#),
  (.sqlite, nil, "users", #""users""#),
  (.sqlite, "main", "users", #""users""#),
  (.sqlite, "public", "users", #""public"."users""#),
  (.sqlite, "app", "t", #""app"."t""#),
  (.sqlite, "a\"b", "c\"d", #""a""b"."c""d""#),
  (.sqlite, "", "t", #"""."t""#),
]

private let sampleDate = Date(timeIntervalSince1970: 1_577_934_245)

private let sharedLiteralCases: [(CellValue, String)] = [
  (.null, "NULL"),
  (.bool(true), "TRUE"),
  (.bool(false), "FALSE"),
  (.int(0), "0"),
  (.int(42), "42"),
  (.int(-7), "-7"),
  (.double(0), "0.0"),
  (.double(1.5), "1.5"),
  (.double(-2.25), "-2.25"),
  (.string("plain"), "'plain'"),
  (.string(""), "''"),
  (.string("o'brien"), "'o''brien'"),
  (.string("a'b'c"), "'a''b''c'"),
  (.json(#"{"a":1}"#), #"'{"a":1}'"#),
  (.json(#"{"a":"o'b"}"#), #"'{"a":"o''b"}'"#),
  (.date(sampleDate), "'2020-01-02T03:04:05Z'"),
]

private let sharedLiteralDialectCases: [(SQLDialect, CellValue, String)] = [
  SQLDialect.postgresql, SQLDialect.sqlite,
].flatMap { dialect in
  sharedLiteralCases.map { (dialect, $0.0, $0.1) }
}

private let byteSample = Data([0x00, 0x0A, 0xFF])

private let specialLiteralCases: [(SQLDialect, CellValue, String)] = [
  (.postgresql, .double(.nan), "'NaN'::float8"),
  (.postgresql, .double(.infinity), "'Infinity'::float8"),
  (.postgresql, .double(-.infinity), "'-Infinity'::float8"),
  (.sqlite, .double(.nan), "NULL"),
  (.sqlite, .double(.infinity), "NULL"),
  (.sqlite, .double(-.infinity), "NULL"),
  (.postgresql, .data(byteSample), #"'\x000aff'"#),
  (.postgresql, .data(Data()), #"'\x'"#),
  (.sqlite, .data(byteSample), "X'000AFF'"),
  (.sqlite, .data(Data()), "X''"),
]

private let placeholderCases: [(SQLDialect, Int, String)] = [
  (.postgresql, 0, "$0"),
  (.postgresql, 1, "$1"),
  (.postgresql, 12, "$12"),
  (.sqlite, 0, "?0"),
  (.sqlite, 1, "?1"),
  (.sqlite, 12, "?12"),
]

private let limitOffsetCases: [(SQLDialect, Int, Int, String)] = [
  (.postgresql, 0, 0, "LIMIT 0 OFFSET 0"),
  (.postgresql, 10, 25, "LIMIT 10 OFFSET 25"),
  (.sqlite, 0, 0, "LIMIT 0 OFFSET 0"),
  (.sqlite, 10, 25, "LIMIT 10 OFFSET 25"),
]

private let explainCases: [(SQLDialect, Bool, Bool, String?, String)] = [
  (.postgresql, false, false, nil, "EXPLAIN"),
  (.postgresql, true, false, nil, "EXPLAIN (ANALYZE)"),
  (.postgresql, false, true, nil, "EXPLAIN (BUFFERS)"),
  (.postgresql, true, true, nil, "EXPLAIN (ANALYZE, BUFFERS)"),
  (.postgresql, false, false, "json", "EXPLAIN (FORMAT JSON)"),
  (.postgresql, true, false, "json", "EXPLAIN (ANALYZE, FORMAT JSON)"),
  (.postgresql, false, true, "json", "EXPLAIN (BUFFERS, FORMAT JSON)"),
  (.postgresql, true, true, "json", "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)"),
  (.postgresql, false, false, "TeXt", "EXPLAIN (FORMAT TEXT)"),
  (.sqlite, false, false, nil, "EXPLAIN QUERY PLAN"),
  (.sqlite, true, false, nil, "EXPLAIN QUERY PLAN"),
  (.sqlite, false, true, nil, "EXPLAIN QUERY PLAN"),
  (.sqlite, true, true, nil, "EXPLAIN QUERY PLAN"),
  (.sqlite, false, false, "json", "EXPLAIN QUERY PLAN"),
  (.sqlite, true, false, "json", "EXPLAIN QUERY PLAN"),
  (.sqlite, false, true, "json", "EXPLAIN QUERY PLAN"),
  (.sqlite, true, true, "json", "EXPLAIN QUERY PLAN"),
  (.sqlite, true, true, "TeXt", "EXPLAIN QUERY PLAN"),
]

@Suite("SQL Dialect")
struct SQLDialectTests {
  @Test(
    "Identifiers are double-quoted; embedded quotes are doubled; unicode and empty pass through",
    arguments: quoteCases)
  func quoteIdentifier(dialect: SQLDialect, name: String, expected: String) throws {
    #expect(try dialect.quoteIdentifier(name) == expected)
  }

  @Test(
    "A NUL in an identifier is rejected", arguments: [SQLDialect.postgresql, SQLDialect.sqlite])
  func nulInIdentifier(dialect: SQLDialect) {
    #expect(throws: SQLDialectError.nulInIdentifier) {
      try dialect.quoteIdentifier("a\0b")
    }
    #expect(throws: SQLDialectError.nulInIdentifier) {
      try dialect.qualified(schema: "a\0", name: "users")
    }
    #expect(throws: SQLDialectError.nulInIdentifier) {
      try dialect.qualified(schema: "app", name: "a\0")
    }
  }

  @Test(
    "The default schema is omitted; any other schema stays qualified",
    arguments: qualifiedCases)
  func qualified(dialect: SQLDialect, schema: String?, name: String, expected: String) throws {
    #expect(try dialect.qualified(schema: schema, name: name) == expected)
  }

  @Test(
    "NULL, booleans, integers, finite doubles, strings, JSON, and dates",
    arguments: sharedLiteralDialectCases)
  func sharedLiterals(dialect: SQLDialect, value: CellValue, expected: String) {
    #expect(dialect.literal(value) == expected)
  }

  @Test(
    "Non-finite doubles and bytea or blob literals",
    arguments: specialLiteralCases)
  func specialLiterals(dialect: SQLDialect, value: CellValue, expected: String) {
    #expect(dialect.literal(value) == expected)
  }

  @Test("Placeholders use the index as given", arguments: placeholderCases)
  func placeholder(dialect: SQLDialect, index: Int, expected: String) {
    #expect(dialect.placeholder(index) == expected)
  }

  @Test("LIMIT and OFFSET are the same text on both dialects", arguments: limitOffsetCases)
  func limitOffset(dialect: SQLDialect, limit: Int, offset: Int, expected: String) {
    #expect(dialect.limitOffset(limit: limit, offset: offset) == expected)
  }

  @Test(
    "EXPLAIN options are PostgreSQL-only; SQLite is always EXPLAIN QUERY PLAN",
    arguments: explainCases)
  func explainPrefix(
    dialect: SQLDialect, analyze: Bool, buffers: Bool, format: String?, expected: String
  ) {
    #expect(dialect.explainPrefix(analyze: analyze, buffers: buffers, format: format) == expected)
  }

  @Test(
    "Case-insensitive LIKE inserts fragments unchanged",
    arguments: [
      (SQLDialect.postgresql, #""weird""name"::text ILIKE 'o''brien'"#),
      (SQLDialect.sqlite, #""weird""name" LIKE 'o''brien'"#),
    ])
  func caseInsensitiveLike(dialect: SQLDialect, expected: String) {
    #expect(
      dialect.caseInsensitiveLike(column: #""weird""name""#, pattern: "'o''brien'") == expected)
  }

  @Test(
    "Default schema and UPDATE ONLY support",
    arguments: [
      (SQLDialect.postgresql, "public", true),
      (SQLDialect.sqlite, "main", false),
    ])
  func capabilities(dialect: SQLDialect, schema: String, updateOnly: Bool) {
    #expect(dialect.defaultSchema == schema)
    #expect(dialect.supportsUpdateOnly == updateOnly)
  }

  @Test(
    "SQLite LIKE is case-insensitive; PostgreSQL LIKE is not",
    arguments: [
      (SQLDialect.sqlite, true),
      (SQLDialect.postgresql, false),
    ])
  func likeIsCaseInsensitive(dialect: SQLDialect, insensitive: Bool) {
    #expect(dialect.likeIsCaseInsensitive == insensitive)
  }

  @Test("A PostgreSQL backslash is an escape string; quotes stay doubled; SQLite stays plain")
  func backslashAndQuoteLiterals() {
    let attack = #"\' ; DELETE FROM secrets; --"#
    #expect(
      SQLDialect.postgresql.literal(.string(attack)) == #"E'\\'' ; DELETE FROM secrets; --'"#)
    #expect(SQLDialect.sqlite.literal(.string(attack)) == #"'\'' ; DELETE FROM secrets; --'"#)
    #expect(SQLDialect.postgresql.literal(.string("o'brien")) == "'o''brien'")
    #expect(SQLDialect.sqlite.literal(.string("o'brien")) == "'o''brien'")
    #expect(SQLDialect.sqlite.literal(.string(#"a\b"#)) == #"'a\b'"#)
    #expect(SQLDialect.postgresql.literal(.string(#"\n\t\x"#)) == #"E'\\n\\t\\x'"#)
  }

  @Test("DatabaseType.dialect selects the matching dialect")
  func databaseTypeDialect() {
    #expect(DatabaseType.postgresql.dialect == SQLDialect.postgresql)
    #expect(DatabaseType.sqlite.dialect == SQLDialect.sqlite)
    #expect(SQLDialect.postgresql != SQLDialect.sqlite)
  }
}
