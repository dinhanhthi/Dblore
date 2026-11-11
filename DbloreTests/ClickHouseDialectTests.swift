// ClickHouseDialectTests.swift
// ClickHouse quoting, lexing, classification and parameter placeholders (ClickHouse SQL syntax
// docs: identifiers, string literals, comments, heredoc, query parameters)

import Foundation
import Testing

@testable import Dblore

@Suite("ClickHouse dialect")
struct ClickHouseDialectTests {

  private static let dialect = SQLDialect.clickhouse

  private static func classify(_ sql: String) -> [ClassifiedStatement] {
    SQLStatementClassifier.classify(sql, dialect: dialect)
  }

  /// What the read-only gate lets through: a read-only-safe statement that lifts no brake and
  /// changes no privilege
  private static func passesReadOnly(_ statement: ClassifiedStatement) -> Bool {
    statement.isReadOnlySafe && !statement.resetsSessionBrakes && !statement.changesPrivileges
  }

  // MARK: - Quoting cannot escape

  /// Names and values holding every character the quoting escapes, and a statement after it
  static let hostileTexts = [
    "a`b", #"a\b"#, #"a\`; DROP TABLE t; --"#, "a`; DROP TABLE t; --", "a'; DROP TABLE t; --",
    #"a\'; DROP TABLE t; --"#, "a\"b", #"tail\"#,
  ]

  @Test("A quoted name is one identifier token", arguments: hostileTexts)
  func identifierStaysOneToken(_ name: String) throws {
    let quoted = try Self.dialect.quoteIdentifier(name)
    let tokens = SQLTokenizer.tokens(quoted, dialect: Self.dialect)
    #expect(tokens.count == 1)
    #expect(tokens.first?.kind == .quotedIdentifier)
    let statements = Self.classify("SELECT * FROM \(quoted)")
    #expect(statements.count == 1)
    #expect(statements.first?.kind == .read)
  }

  @Test("Backtick quoting escapes backslash and backtick; NUL is refused")
  func identifierEscapes() throws {
    #expect(try Self.dialect.quoteIdentifier(#"a`b\c"#) == #"`a\`b\\c`"#)
    #expect(throws: SQLDialectError.nulInIdentifier) { try Self.dialect.quoteIdentifier("a\0b") }
  }

  @Test("A quoted value is one string token", arguments: hostileTexts)
  func literalStaysOneToken(_ value: String) {
    let literal = Self.dialect.literal(.string(value))
    let tokens = SQLTokenizer.tokens(literal, dialect: Self.dialect)
    #expect(tokens.count == 1)
    #expect(tokens.first?.kind == .string)
    let statements = Self.classify("SELECT \(literal)")
    #expect(statements.count == 1)
    #expect(statements.first?.kind == .read)
  }

  @Test("String literals escape backslash and quote")
  func literalEscapes() {
    #expect(Self.dialect.literal(.string(#"it's a\b"#)) == #"'it\'s a\\b'"#)
  }

  // MARK: - The scanner reads statements as the server does

  @Test("A backslash-escaped quote keeps the rest of the line inside the string")
  func escapedQuoteIsOneString() {
    let statements = Self.classify(#"SELECT 'a\'; ALTER TABLE t DELETE WHERE 1; --'"#)
    #expect(statements.count == 1)
    #expect(statements.first?.kind == .read)
  }

  /// Text a server-side write hides in under another engine's lexing: each must reach the
  /// read-only gate as something it refuses
  static let hiddenWrites = [
    // An escaped quote, then the real close: the ALTER is a statement of its own
    #"SELECT 'a\''; ALTER TABLE t DELETE WHERE 1; --'"#,
    // Backslash escapes in backtick and double-quoted identifiers
    #"SELECT `a\``; DROP TABLE t; --`"#,
    #"SELECT "a\""; DROP TABLE t; --""#,
    // `--` ends at LF only: a CR keeps the comment going
    "-- c\rSELECT 1\nDROP TABLE t",
    // A `# ` comment ends at the line end: the `;` and the verb after it are seen
    "SELECT 1 # it's\n; DROP TABLE t",
    // Heredoc: `$$'$$` is a whole string, so the quote opens nothing
    "SELECT $$'$$; DROP TABLE t; --'",
    // `//` is a line comment too
    "SELECT 1 // it's\n; DROP TABLE t",
    // A `‘…’` string ends at its closing quote, whatever ASCII quote it holds
    "SELECT \u{2018}'\u{2019}; DROP TABLE t; --'",
    // A heredoc tag is ASCII word characters only: `$x y$` opens none
    "SELECT $x y$; DROP TABLE t; $x y$",
    // A server before that rule reads `$a'$ ' $a'$` as a heredoc, so the brake is not hidden
    "SELECT $a'$ ' $a'$, 1 SETTINGS max_execution_time = 0 --'",
    // After `.` the server reads `1e` and a `--` comment, not the sign `1e-`
    "SELECT x.1e--'\n, 1 SETTINGS max_execution_time = 0 --'",
    // An escaped quoted name may spell a brake
    #"SELECT 1 SETTINGS `max\x5fexecution_time` = 0"#,
    // A non-ASCII space splits words on the server
    "SELECT 1 SETTINGS\u{A0}max_execution_time = 0",
    // `PARALLEL WITH` runs every statement of the chain, whatever the first verb is
    "SELECT 1 PARALLEL WITH DROP TABLE orders",
    "EXISTS TABLE t PARALLEL WITH CREATE TABLE x (a UInt8) ENGINE = Memory",
    "(SELECT 1) PARALLEL WITH DROP TABLE orders",
    "((EXISTS TABLE t)) PARALLEL WITH CREATE TABLE x (a UInt8) ENGINE = Memory",
    // A query-level setting that lifts the statement timeout
    "SELECT 1 SETTINGS max_execution_time = 0",
  ]

  @Test("A write or lifted brake is never read-only safe", arguments: hiddenWrites)
  func hiddenWriteIsRefused(_ sql: String) {
    let statements = Self.classify(sql)
    #expect(!statements.isEmpty)
    #expect(statements.contains { !Self.passesReadOnly($0) })
  }

  // MARK: - Writes and destructive statements

  static let writes = [
    "INSERT INTO t VALUES (1)", "ALTER TABLE t UPDATE c = 1 WHERE 1",
    "ALTER TABLE t DELETE WHERE 1", "OPTIMIZE TABLE t FINAL", "SYSTEM DROP DNS CACHE",
    "KILL QUERY WHERE query_id = 'q'", "TRUNCATE TABLE t", "EXCHANGE TABLES a AND b",
    "RENAME TABLE a TO b", "ATTACH TABLE t", "DETACH TABLE t", "DROP TABLE t",
    "REPLACE TABLE t (a UInt8) ENGINE = Memory",
  ]

  @Test("ClickHouse write verbs are writes", arguments: writes)
  func writeVerbs(_ sql: String) throws {
    let statement = try #require(Self.classify(sql).first)
    let kind = SQLStatementClassifier.effectiveKind(statement.kind)
    #expect([.dml, .ddl, .utility].contains(kind))
  }

  @Test("Statements that delete data are marked destructive, others are not")
  func destructiveFlag() {
    let destructive = [
      "ALTER TABLE t DELETE WHERE 1", "ALTER TABLE db.t ON CLUSTER c DROP PARTITION 202401",
      "ALTER TABLE t CLEAR COLUMN c", "TRUNCATE TABLE t", "DROP TABLE t",
      "REPLACE TABLE t (a UInt8) ENGINE = Memory", "OPTIMIZE TABLE t FINAL DEDUPLICATE",
    ]
    for sql in destructive {
      #expect(Self.classify(sql).first?.isDestructive == true, "\(sql)")
    }
    let kept = [
      "ALTER TABLE t UPDATE c = 1 WHERE 1", "DETACH TABLE t", "INSERT INTO t VALUES (1)",
      "SELECT 'DROP' FROM t", "EXPLAIN ALTER TABLE t DELETE WHERE 1",
    ]
    for sql in kept {
      #expect(Self.classify(sql).first?.isDestructive == false, "\(sql)")
    }
  }

  @Test("A PARALLEL WITH chain fails closed and counts as destructive")
  func parallelWithChain() throws {
    let chains = [
      "SELECT 1 PARALLEL WITH DROP TABLE orders",
      "EXISTS TABLE t PARALLEL WITH CREATE TABLE x (a UInt8) ENGINE = Memory",
      "CREATE TABLE x (a UInt8) ENGINE = Memory parallel with DROP TABLE orders",
      "DROP TABLE scratch PARALLEL WITH DROP TABLE orders",
      "(SELECT 1) PARALLEL WITH DROP TABLE orders",
      "((EXISTS TABLE t)) PARALLEL WITH CREATE TABLE x (a UInt8) ENGINE = Memory",
    ]
    for sql in chains {
      let statement = try #require(Self.classify(sql).first)
      #expect(statement.kind == .unknown, "\(sql)")
      #expect(statement.isDestructive, "\(sql)")
    }
    // Only the two words next to each other, at any depth: a string or a column named
    // `parallel` with no WITH right after it is not a chain (a column `parallel` right before a
    // WITH fails closed too)
    for sql in [
      "SELECT 'PARALLEL WITH' FROM t", "SELECT parallel FROM t",
      "SELECT parallel, x FROM t WHERE x IN (SELECT parallel FROM u)",
    ] {
      let statement = try #require(Self.classify(sql).first)
      #expect(statement.kind == .read, "\(sql)")
      #expect(!statement.isDestructive, "\(sql)")
    }
  }

  @Test("ALTER ... DELETE after an escaped-quote string asks for confirmation")
  func destructiveAfterEscapedQuoteAsks() throws {
    let classified = Self.classify(#"SELECT 'a\''; ALTER TABLE t DELETE WHERE 1; --'"#)
    #expect(classified.map(\.kind) == [.read, .ddl])
    #expect(classified.last?.isDestructive == true)
    let listed = try #require(
      NotebookViewModel.statementsNeedingConfirmation(
        classified, commitStyle: .confirm, dialect: Self.dialect))
    #expect(listed.map(\.index) == [1])
  }

  // MARK: - Parameters

  @Test(":name becomes {pN:String}, numbered by distinct name")
  func namedParametersNumbered() {
    let result = SQLParameterRewriter.rewrite(
      statement: "SELECT * FROM t WHERE a = :a AND b = :b OR a = :a", dialect: Self.dialect)
    #expect(
      result.text == "SELECT * FROM t WHERE a = {p1:String} AND b = {p2:String} OR a = {p1:String}")
    #expect(result.names == ["a", "b"])
  }

  @Test("{name:Type} is the user's own placeholder: not rewritten, and mixed with :name refused")
  func typedSubstitutionLeftAlone() {
    for sql in ["SELECT {id:UInt32}", "SELECT { id :UInt32 }", "SELECT {id: Nullable(String)}"] {
      #expect(SQLParameterRewriter.rewrite(statement: sql, dialect: Self.dialect).text == sql)
      #expect(SQLParameterRewriter.parameterNames(in: sql, dialect: Self.dialect).isEmpty)
    }
    let mixed = "SELECT {p1:String}, :name"
    #expect(SQLParameterRewriter.parameterNames(in: mixed, dialect: Self.dialect) == ["name"])
    #expect(SQLParameterRewriter.containsPositionalPlaceholder(in: mixed, dialect: Self.dialect))
    #expect(
      !SQLParameterRewriter.containsPositionalPlaceholder(
        in: "SELECT a ? 1 : 2, :name", dialect: Self.dialect))
  }

  @Test("A typed placeholder takes the column's type, and String for a type text that could escape")
  func typedPlaceholder() {
    #expect(Self.dialect.placeholder(2, type: "Nullable(UInt64)") == "{p2:Nullable(UInt64)}")
    #expect(
      Self.dialect.placeholder(1, type: "DateTime64(3, 'UTC')") == "{p1:DateTime64(3, 'UTC')}")
    for hostile in [
      "UInt8}; DROP TABLE t", "UInt8 -- x", "UInt8//", "String\n", "Enum8('a\\'' = 1)",
      "Enum8('a)", "",
    ] {
      #expect(Self.dialect.placeholder(1, type: hostile) == "{p1:String}", "\(hostile)")
    }
    #expect(SQLDialect.postgresql.placeholder(3, type: "int8") == "$3")
  }

  // MARK: - SQL fragments

  @Test("LIKE subjects are text, and a named database is always kept")
  func fragments() throws {
    #expect(Self.dialect.like(column: "c", pattern: "'a%'") == "toString(c) LIKE 'a%'")
    #expect(
      Self.dialect.like(column: "c", pattern: "'a%'", negated: true, caseInsensitive: true)
        == "toString(c) NOT ILIKE 'a%'")
    #expect(
      Self.dialect.caseInsensitiveLike(column: "c", pattern: "'a%'") == "toString(c) ILIKE 'a%'")
    #expect(try Self.dialect.qualified(schema: "default", name: "t") == "`default`.`t`")
  }
}
