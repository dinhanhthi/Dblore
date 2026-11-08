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
  SQLDialect.postgresql, SQLDialect.sqlite, SQLDialect.duckdb,
].flatMap { dialect in
  quotedIdentifierCases.map { (dialect, $0.0, $0.1) }
}

private let qualifiedCases: [(SQLDialect, String?, String, String)] = [
  (.postgresql, nil, "users", #""users""#),
  (.postgresql, "public", "users", #""public"."users""#),
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
  (.duckdb, nil, "users", #""users""#),
  (.duckdb, "main", "users", #""users""#),
  (.duckdb, "public", "users", #""public"."users""#),
  (.duckdb, "a\"b", "c\"d", #""a""b"."c""d""#),
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
  (.date(sampleDate), "'2020-01-02T03:04:05.000000Z'"),
]

private let sharedLiteralDialectCases: [(SQLDialect, CellValue, String)] = [
  SQLDialect.postgresql, SQLDialect.sqlite, SQLDialect.duckdb,
].flatMap { dialect in
  sharedLiteralCases.map { (dialect, $0.0, $0.1) }
}

private let byteSample = Data([0x00, 0x0A, 0xFF])

private let specialLiteralCases: [(SQLDialect, CellValue, String)] = [
  (.postgresql, .double(.nan), "'NaN'::pg_catalog.float8"),
  (.postgresql, .double(.infinity), "'Infinity'::pg_catalog.float8"),
  (.postgresql, .double(-.infinity), "'-Infinity'::pg_catalog.float8"),
  (.mongodb, .double(.nan), "'NaN'::float8"),
  (.mongodb, .double(-.infinity), "'-Infinity'::float8"),
  (.sqlite, .double(.nan), "NULL"),
  (.sqlite, .double(.infinity), "NULL"),
  (.sqlite, .double(-.infinity), "NULL"),
  (.postgresql, .data(byteSample), #"'\x000aff'"#),
  (.postgresql, .data(Data()), #"'\x'"#),
  (.sqlite, .data(byteSample), "X'000AFF'"),
  (.sqlite, .data(Data()), "X''"),
  (.duckdb, .double(.nan), "'NaN'::DOUBLE"),
  (.duckdb, .double(.infinity), "'Infinity'::DOUBLE"),
  (.duckdb, .double(-.infinity), "'-Infinity'::DOUBLE"),
  (.duckdb, .data(byteSample), #"'\x00\x0A\xFF'::BLOB"#),
  (.duckdb, .data(Data()), "''::BLOB"),
]

/// Security: each quote or backslash is followed by U+0301, so it and the mark form one
/// `Character` that is not equal to the bare quote. Every quote scalar must still be doubled.
private let combiningMarkText = "a'\u{301}\"\u{301}`\u{301}\\\u{301}b"

private let combiningMarkIdentifierCases: [(SQLDialect, String)] = [
  (.postgresql, "\"a'\u{301}\"\"\u{301}`\u{301}\\\u{301}b\""),
  (.sqlite, "\"a'\u{301}\"\"\u{301}`\u{301}\\\u{301}b\""),
  (.duckdb, "\"a'\u{301}\"\"\u{301}`\u{301}\\\u{301}b\""),
  (.mysql, "`a'\u{301}\"\u{301}``\u{301}\\\u{301}b`"),
]

private let combiningMarkLiteralCases: [(SQLDialect, String)] = [
  (.postgresql, "E'a''\u{301}\"\u{301}`\u{301}\\\\\u{301}b'"),
  (.mysql, "'a''\u{301}\"\u{301}`\u{301}\\\\\u{301}b'"),
  (.sqlite, "'a''\u{301}\"\u{301}`\u{301}\\\u{301}b'"),
  (.duckdb, "'a''\u{301}\"\u{301}`\u{301}\\\u{301}b'"),
]

private let placeholderCases: [(SQLDialect, Int, String)] = [
  (.postgresql, 0, "$0"),
  (.postgresql, 1, "$1"),
  (.postgresql, 12, "$12"),
  (.sqlite, 0, "?0"),
  (.sqlite, 1, "?1"),
  (.sqlite, 12, "?12"),
  (.duckdb, 0, "$0"),
  (.duckdb, 1, "$1"),
  (.duckdb, 12, "$12"),
]

private let limitOffsetCases: [(SQLDialect, Int, Int, String)] = [
  (.postgresql, 0, 0, "LIMIT 0 OFFSET 0"),
  (.postgresql, 10, 25, "LIMIT 10 OFFSET 25"),
  (.sqlite, 0, 0, "LIMIT 0 OFFSET 0"),
  (.sqlite, 10, 25, "LIMIT 10 OFFSET 25"),
  (.duckdb, 10, 25, "LIMIT 10 OFFSET 25"),
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
  (.duckdb, false, false, nil, "EXPLAIN"),
  (.duckdb, true, false, nil, "EXPLAIN ANALYZE"),
  (.duckdb, false, true, nil, "EXPLAIN"),
  (.duckdb, true, true, nil, "EXPLAIN ANALYZE"),
  (.duckdb, false, false, "json", "EXPLAIN (FORMAT JSON)"),
  (.duckdb, true, false, "json", "EXPLAIN (ANALYZE, FORMAT JSON)"),
  (.duckdb, false, true, "json", "EXPLAIN (FORMAT JSON)"),
  (.duckdb, true, true, "json", "EXPLAIN (ANALYZE, FORMAT JSON)"),
]

/// Security: a PostgreSQL statement on user data names `pg_catalog`'s operators, functions and
/// built-in types, so nothing planted in a schema on the `search_path` runs. Each row is one
/// dialect's output for the same calls; every non-PostgreSQL row is today's text.
private func qualificationSample(_ dialect: SQLDialect) -> [String] {
  [
    dialect.comparison("c", .lessOrEqual, "$1"),
    dialect.inList("c", ["'a'", "'b'"]),
    dialect.inList("c", ["'a'", "'b'"], negated: true),
    dialect.like(column: "c", pattern: "'a!%'", escape: "'!'"),
    dialect.like(column: "c", pattern: "'a'", caseInsensitive: true),
    dialect.like(column: "c", pattern: "'a'", escape: "'!'", negated: true, caseInsensitive: true),
    dialect.function("count", "*"),
    dialect.concatenation("'v'", "c"),
    dialect.cast("$1", to: "uuid"),
  ]
}

private let qualifiedPostgresSample = [
  "c OPERATOR(pg_catalog.<=) $1",
  "(c OPERATOR(pg_catalog.=) 'a' OR c OPERATOR(pg_catalog.=) 'b')",
  "(c OPERATOR(pg_catalog.<>) 'a' AND c OPERATOR(pg_catalog.<>) 'b')",
  "c::pg_catalog.text OPERATOR(pg_catalog.~~) pg_catalog.like_escape('a!%', '!')",
  "c::pg_catalog.text OPERATOR(pg_catalog.~~*) 'a'",
  "c::pg_catalog.text OPERATOR(pg_catalog.!~~*) pg_catalog.like_escape('a', '!')",
  "pg_catalog.count(*)",
  "'v' OPERATOR(pg_catalog.||) c",
  "$1::pg_catalog.uuid",
]

private let unchangedDialectSamples: [(SQLDialect, [String])] = [
  (
    .mysql,
    [
      "c <= $1", "c IN ('a', 'b')", "c NOT IN ('a', 'b')",
      "CAST(c AS CHAR) LIKE 'a!%' ESCAPE '!'", "LOWER(CAST(c AS CHAR)) LIKE LOWER('a')",
      "CAST(c AS CHAR) NOT LIKE 'a' ESCAPE '!'", "count(*)", "CONCAT('v', c)",
      "CAST($1 AS uuid)",
    ]
  ),
  (
    .sqlite,
    [
      "c <= $1", "c IN ('a', 'b')", "c NOT IN ('a', 'b')", "c LIKE 'a!%' ESCAPE '!'",
      "LOWER(c) LIKE LOWER('a')", "c NOT LIKE 'a' ESCAPE '!'", "count(*)", "'v' || c",
      "CAST($1 AS uuid)",
    ]
  ),
  (
    .duckdb,
    [
      "c <= $1", "c IN ('a', 'b')", "c NOT IN ('a', 'b')", "c::VARCHAR LIKE 'a!%' ESCAPE '!'",
      "c::VARCHAR ILIKE 'a'", "c::VARCHAR NOT ILIKE 'a' ESCAPE '!'", "count(*)", "'v' || c",
      "CAST($1 AS uuid)",
    ]
  ),
  (
    .mongodb,
    [
      "c <= $1", "c IN ('a', 'b')", "c NOT IN ('a', 'b')", "c::text LIKE 'a!%' ESCAPE '!'",
      "c::text ILIKE 'a'", "c::text NOT ILIKE 'a' ESCAPE '!'", "count(*)", "'v' || c",
      "CAST($1 AS uuid)",
    ]
  ),
]

/// PostgreSQL type data as the schema read reports it: a built-in, a citext column (extension in
/// `public`), the same without the extension's schema, and a domain over citext
private let builtInType = PostgresColumnType(
  oid: 25, operand: .qualified, castName: nil, compareCast: nil, operatorSchema: nil)
private let citextType = PostgresColumnType(
  oid: 16_385, operand: .bare, castName: "public.citext", compareCast: nil,
  operatorSchema: "public")
private let citextNoSchemaType = PostgresColumnType(
  oid: 16_385, operand: .bare, castName: "public.citext", compareCast: nil, operatorSchema: nil)
private let citextDomainType = PostgresColumnType(
  oid: 16_400, operand: .bare, castName: "public.cit_dom", compareCast: "public.citext",
  operatorSchema: "public")

/// Security: an operator is always schema-qualified, `pg_catalog`'s or the owning extension's, so
/// one planted in another schema on the `search_path` is never chosen
private let typedComparisonCases: [(PostgresColumnType?, SQLComparison, String)] = [
  (nil, .equal, "c OPERATOR(pg_catalog.=) $1"),
  (builtInType, .equal, "c OPERATOR(pg_catalog.=) $1"),
  (citextType, .equal, "c OPERATOR(public.=) $1"),
  (citextType, .notEqual, "c OPERATOR(public.<>) $1"),
  (citextType, .less, "c OPERATOR(public.<) $1"),
  (citextType, .greaterOrEqual, "c OPERATOR(public.>=) $1"),
  (citextNoSchemaType, .equal, "c OPERATOR(pg_catalog.=) $1"),
  (citextDomainType, .equal, "c::public.citext OPERATOR(public.=) $1::public.citext"),
  (citextDomainType, .greater, "c::public.citext OPERATOR(public.>) $1::public.citext"),
]

private let typedSplitCases: [(PostgresColumnType?, String, String)] = [
  (nil, "c OPERATOR(pg_catalog.>) ", ""),
  (citextType, "c OPERATOR(public.>) ", ""),
  (citextDomainType, "c::public.citext OPERATOR(public.>) ", "::public.citext"),
]

@Suite("SQL Dialect")
struct SQLDialectTests {
  @Test(
    "Identifiers are double-quoted; embedded quotes are doubled; unicode and empty pass through",
    arguments: quoteCases)
  func quoteIdentifier(dialect: SQLDialect, name: String, expected: String) throws {
    #expect(try dialect.quoteIdentifier(name) == expected)
  }

  @Test("Text for a -- comment keeps every line break as a visible escape on one line")
  func lineCommentSafe() {
    let text = SQLDialect.lineCommentSafe(
      "a\r\nDROP TABLE t;\nb\rc\u{0B}d\u{0C}e\u{85}f\u{2028}g\u{2029}DROP TABLE u")
    #expect(!text.contains { $0.isNewline })
    #expect(text == #"a\r\nDROP TABLE t;\nb\rc\u{B}d\u{C}e\u{85}f\u{2028}g\u{2029}DROP TABLE u"#)
  }

  @Test(
    "A NUL in an identifier is rejected",
    arguments: [SQLDialect.postgresql, SQLDialect.sqlite, SQLDialect.duckdb])
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
    "The default schema is omitted, except on PostgreSQL; any other schema stays qualified",
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

  @Test("A date literal keeps its microseconds: naive is the wall clock, zoned the bind form")
  func dateLiteralsKeepFractions() {
    // 2026-10-15 12:00:00.123456 UTC
    let date = CellValue.date(Date(timeIntervalSince1970: 1_792_065_600.123456))
    for dialect in [SQLDialect.postgresql, .duckdb, .mysql, .sqlite] {
      #expect(dialect.literal(date, wallClock: true) == "'2026-10-15 12:00:00.123456'")
    }
    #expect(SQLDialect.postgresql.literal(date) == "'2026-10-15T12:00:00.123456Z'")
    #expect(
      SQLDialect.postgresql.literal(date, wallClock: false) == "'2026-10-15T12:00:00.123456Z'")
    #expect(SQLDialect.duckdb.literal(date) == "'2026-10-15T12:00:00.123456Z'")
    // MySQL reads the text in the session's UTC zone, so no zone is written
    #expect(SQLDialect.mysql.literal(date) == "'2026-10-15 12:00:00.123456'")
    // Other values ignore the flag
    #expect(SQLDialect.postgresql.literal(.int(1), wallClock: true) == "1")
  }

  @Test(
    "Non-finite doubles and bytea or blob literals",
    arguments: specialLiteralCases)
  func specialLiterals(dialect: SQLDialect, value: CellValue, expected: String) {
    #expect(dialect.literal(value) == expected)
  }

  /// Security: decimal text is written bare only when it is plain digits, or the cell's text
  /// would run as SQL
  @Test(
    "A decimal is unquoted only as plain digits; any other text is a quoted string",
    arguments: [SQLDialect.postgresql, .mysql, .sqlite, .duckdb])
  func decimalLiterals(dialect: SQLDialect) {
    for text in ["0", "-12.50", "12345678901234567890.123456789"] {
      #expect(dialect.literal(.decimal(text)) == text)
    }
    for text in [
      "1;DROP TABLE t", "1e5", "NaN", "Infinity", "-Infinity", "--1", " 1", "1 ", "+1", ".5",
      "1.", "", "1)--", "１",
    ] {
      #expect(dialect.literal(.decimal(text)) == dialect.literal(.string(text)), "\(text)")
    }
  }

  @Test("Placeholders use the index as given", arguments: placeholderCases)
  func placeholder(dialect: SQLDialect, index: Int, expected: String) {
    #expect(dialect.placeholder(index) == expected)
  }

  @Test(
    "EXPLAIN options are PostgreSQL-only; SQLite is EXPLAIN QUERY PLAN; DuckDB takes ANALYZE and FORMAT",
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
      (SQLDialect.sqlite, #"LOWER("weird""name") LIKE LOWER('o''brien')"#),
      (SQLDialect.mysql, #"LOWER(CAST("weird""name" AS CHAR)) LIKE LOWER('o''brien')"#),
      (SQLDialect.duckdb, #""weird""name"::VARCHAR ILIKE 'o''brien'"#),
    ])
  func caseInsensitiveLike(dialect: SQLDialect, expected: String) {
    #expect(
      dialect.caseInsensitiveLike(column: #""weird""name""#, pattern: "'o''brien'") == expected)
  }

  @Test("PostgreSQL names pg_catalog's operators and functions")
  func postgresQualified() {
    #expect(qualificationSample(.postgresql) == qualifiedPostgresSample)
  }

  @Test("Other dialects write today's text", arguments: unchangedDialectSamples)
  func otherDialectsUnqualified(dialect: SQLDialect, expected: [String]) {
    #expect(qualificationSample(dialect) == expected)
  }

  @Test(
    "A typed comparison names pg_catalog's or the extension's operator",
    arguments: typedComparisonCases)
  func typedComparison(type: PostgresColumnType?, op: SQLComparison, expected: String) {
    #expect(SQLDialect.postgresql.comparison("c", op, "$1", type: type) == expected)
  }

  @Test("A typed IN chain qualifies every term, with the domain's compare cast")
  func typedInList() {
    #expect(
      SQLDialect.postgresql.inList("c", ["'a'", "'b'"], type: citextType)
        == "(c OPERATOR(public.=) 'a' OR c OPERATOR(public.=) 'b')")
    #expect(
      SQLDialect.postgresql.inList("c", ["'a'", "'b'"], negated: true, type: citextDomainType)
        == "(c::public.citext OPERATOR(public.<>) 'a'::public.citext"
        + " AND c::public.citext OPERATOR(public.<>) 'b'::public.citext)")
  }

  @Test(
    "The split typed comparison puts the value between lead and trail", arguments: typedSplitCases)
  func typedSplit(type: PostgresColumnType?, lead: String, trail: String) {
    let parts = SQLDialect.postgresql.comparisonParts("c", .greater, type: type)
    #expect(parts.lead == lead)
    #expect(parts.trail == trail)
  }

  @Test("An extension operand without its schema compares qualified")
  func operandFromColumnType() {
    #expect(SQLOperandKind(column: nil) == .qualified)
    #expect(SQLOperandKind(column: citextNoSchemaType) == .qualified)
    #expect(SQLOperandKind(column: citextType) == .bare)
  }

  @Test("Other dialects write today's text for a typed comparison")
  func typedOtherDialects() {
    let sqlite = SQLDialect.sqlite
    #expect(sqlite.comparison("c", .equal, "?1", type: citextDomainType) == "c = ?1")
    #expect(
      sqlite.inList("c", ["'a'", "'b'"], negated: true, type: citextType) == "c NOT IN ('a', 'b')")
    let parts = sqlite.comparisonParts("c", .less, type: citextDomainType)
    #expect(parts.lead == "c < ")
    #expect(parts.trail == "")
  }

  /// `::pg_catalog.integer` does not exist: the parser binds keyword type names itself
  @Test(
    "A cast keeps keyword type names and user types; other built-in names get pg_catalog",
    arguments: [
      ("integer", "$1::integer"),
      ("character varying(20)", "$1::character varying(20)"),
      ("timestamp(3) with time zone", "$1::timestamp(3) with time zone"),
      ("double precision[]", "$1::double precision[]"),
      ("numeric(10,2)", "$1::numeric(10,2)"),
      ("text", "$1::pg_catalog.text"),
      ("text[]", "$1::pg_catalog.text[]"),
      ("int4", "$1::pg_catalog.int4"),
      ("timestamptz", "$1::pg_catalog.timestamptz"),
      (#""char""#, #"$1::pg_catalog."char""#),
      ("pg_catalog.jsonb", "$1::pg_catalog.jsonb"),
      ("oidvector", "$1::pg_catalog.oidvector"),
      ("int2vector", "$1::pg_catalog.int2vector"),
      ("pg_node_tree", "$1::pg_catalog.pg_node_tree"),
      ("aclitem[]", "$1::pg_catalog.aclitem[]"),
      ("my_enum", "$1::my_enum"),
      ("app.text", "$1::app.text"),
      ("citext", "$1::citext"),
    ])
  func postgresCast(type: String, expected: String) {
    #expect(SQLDialect.postgresql.cast("$1", to: type) == expected)
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

  /// Compared by scalars: `String ==` uses canonical equivalence and would hide the bug
  @Test(
    "A quote followed by a combining mark is still doubled in an identifier",
    arguments: combiningMarkIdentifierCases)
  func combiningMarkIdentifier(dialect: SQLDialect, expected: String) throws {
    let quoted = try dialect.quoteIdentifier(combiningMarkText)
    #expect(Array(quoted.unicodeScalars) == Array(expected.unicodeScalars))
  }

  @Test(
    "A quote or backslash followed by a combining mark is still escaped in a literal",
    arguments: combiningMarkLiteralCases)
  func combiningMarkLiteral(dialect: SQLDialect, expected: String) {
    let literal = dialect.literal(.string(combiningMarkText))
    #expect(Array(literal.unicodeScalars) == Array(expected.unicodeScalars))
  }

  @Test("DuckDB names itself and never writes an escape string")
  func duckdbPromptNameAndLiterals() {
    let attack = #"\' ; DELETE FROM secrets; --"#
    #expect(SQLDialect.duckdb.promptName == "DuckDB")
    #expect(SQLDialect.duckdb.literal(.string(attack)) == #"'\'' ; DELETE FROM secrets; --'"#)
    #expect(SQLDialect.duckdb.literal(.string(#"a\b"#)) == #"'a\b'"#)
    #expect(SQLDialect.duckdb != SQLDialect.postgresql)
    #expect(SQLDialect.duckdb != SQLDialect.sqlite)
  }
}
