// PostgresLexingPinTests.swift
// Snapshot of the PostgreSQL scanner, so dialect branches never change PostgreSQL lexing

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL Lexing Pin")
struct PostgresLexingPinTests {

  /// One line per lexeme (`L`), token (`T`), statement (`S`) and the comment-stripped text (`C`),
  /// from the static entry points the dialect-less callers use.
  static func snapshot(_ sql: String) -> String {
    var lines: [String] = []
    let scalars = Array(sql.unicodeScalars)
    var i = 0
    while i < scalars.count {
      let lexeme = SQLTokenizer.lexeme(in: scalars, at: i)
      let kind: String
      if case .quoted(let tokenKind, let content) = lexeme.kind {
        kind = "quoted.\(tokenKind) \(content.debugDescription)"
      } else {
        kind = "\(lexeme.kind)"
      }
      lines.append("L \(kind) \(SQLTokenizer.text(scalars, lexeme.range).debugDescription)")
      i = lexeme.range.upperBound
    }
    for token in SQLTokenizer.tokens(sql) {
      lines.append("T \(token.kind) \(token.text.debugDescription) @\(token.depth)")
    }
    for statement in SQLTokenizer.splitStatements(sql) {
      lines.append("S \(statement.debugDescription)")
    }
    lines.append("C \(SQLTokenizer.strippingComments(sql).debugDescription)")
    return lines.joined(separator: "\n")
  }

  static let corpus: [String] = [
    "SELECT 5 # 3, a#b FROM t",
    "SELECT E'it\\'s;', e'x\\\\y' FROM t; SELECT 'a''b'",
    "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql; SELECT $tag$ a $$ b; $tag$, $1",
    "SELECT /* a /* b; */ c */ 1; /*! SELECT 2; */ /*M!50000 x */ /*+ hint */ SELECT 3",
    "SELECT 1 -- c; d\nFROM t --x\n; SELECT 2 --",
    "SELECT \"a;b\", \"A\"\"B\" FROM `t;u`",
    "SELECT x::int, '{}'::jsonb ? 'k', d ?| array['a'] FROM t WHERE id = :name AND n = :n2",
    "SELECT 'a\\b'; SELECT \"c\\d\"; SELECT 2",
    "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2",
  ]

  @Test("# is the XOR operator, not a comment")
  func hashIsXor() {
    let sql = Self.corpus[0]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L number "5"
        L whitespace " "
        L symbol "#"
        L whitespace " "
        L number "3"
        L symbol ","
        L whitespace " "
        L word "a"
        L symbol "#"
        L word "b"
        L whitespace " "
        L word "FROM"
        L whitespace " "
        L word "t"
        T word "SELECT" @0
        T word "5" @0
        T symbol "#" @0
        T word "3" @0
        T symbol "," @0
        T word "A" @0
        T symbol "#" @0
        T word "B" @0
        T word "FROM" @0
        T word "T" @0
        S "SELECT 5 # 3, a#b FROM t"
        C "SELECT 5 # 3, a#b FROM t"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("E'' strings take backslash escapes")
  func escapeStrings() {
    let sql = Self.corpus[1]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L quoted.string "it\\\'s;" "E\'it\\\'s;\'"
        L symbol ","
        L whitespace " "
        L quoted.string "x\\\\y" "e\'x\\\\y\'"
        L whitespace " "
        L word "FROM"
        L whitespace " "
        L word "t"
        L symbol ";"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L quoted.string "a\'b" "\'a\'\'b\'"
        T word "SELECT" @0
        T string "it\\\'s;" @0
        T symbol "," @0
        T string "x\\\\y" @0
        T word "FROM" @0
        T word "T" @0
        T symbol ";" @0
        T word "SELECT" @0
        T string "a\'b" @0
        S "SELECT E\'it\\\'s;\', e\'x\\\\y\' FROM t"
        S "SELECT \'a\'\'b\'"
        C "SELECT E\'it\\\'s;\', e\'x\\\\y\' FROM t; SELECT \'a\'\'b\'"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("$$ and $tag$ bodies are opaque")
  func dollarQuotes() {
    let sql = Self.corpus[2]
    #expect(
      Self.snapshot(sql) == #"""
        L word "CREATE"
        L whitespace " "
        L word "FUNCTION"
        L whitespace " "
        L word "f"
        L symbol "("
        L symbol ")"
        L whitespace " "
        L word "RETURNS"
        L whitespace " "
        L word "int"
        L whitespace " "
        L word "AS"
        L whitespace " "
        L dollarString "$$ SELECT 1; $$"
        L whitespace " "
        L word "LANGUAGE"
        L whitespace " "
        L word "sql"
        L symbol ";"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L dollarString "$tag$ a $$ b; $tag$"
        L symbol ","
        L whitespace " "
        L symbol "$"
        L number "1"
        T word "CREATE" @0
        T word "FUNCTION" @0
        T word "F" @0
        T symbol "(" @0
        T symbol ")" @0
        T word "RETURNS" @0
        T word "INT" @0
        T word "AS" @0
        T string "$$ SELECT 1; $$" @0
        T word "LANGUAGE" @0
        T word "SQL" @0
        T symbol ";" @0
        T word "SELECT" @0
        T string "$tag$ a $$ b; $tag$" @0
        T symbol "," @0
        T symbol "$" @0
        T word "1" @0
        S "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql"
        S "SELECT $tag$ a $$ b; $tag$, $1"
        C "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql; SELECT $tag$ a $$ b; $tag$, $1"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("Block comments nest, and /*! and /*M! are plain comments")
  func blockComments() {
    let sql = Self.corpus[3]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L comment "/* a /* b; */ c */"
        L whitespace " "
        L number "1"
        L symbol ";"
        L whitespace " "
        L comment "/*! SELECT 2; */"
        L whitespace " "
        L comment "/*M!50000 x */"
        L whitespace " "
        L comment "/*+ hint */"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L number "3"
        T word "SELECT" @0
        T word "1" @0
        T symbol ";" @0
        T word "SELECT" @0
        T word "3" @0
        S "SELECT /* a /* b; */ c */ 1"
        S "/*! SELECT 2; */ /*M!50000 x */ /*+ hint */ SELECT 3"
        C "SELECT  1;    SELECT 3"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("-- starts a comment with or without a following space")
  func lineComments() {
    let sql = Self.corpus[4]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L number "1"
        L whitespace " "
        L comment "-- c; d"
        L whitespace "\n"
        L word "FROM"
        L whitespace " "
        L word "t"
        L whitespace " "
        L comment "--x"
        L whitespace "\n"
        L symbol ";"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L number "2"
        L whitespace " "
        L comment "--"
        T word "SELECT" @0
        T word "1" @0
        T word "FROM" @0
        T word "T" @0
        T symbol ";" @0
        T word "SELECT" @0
        T word "2" @0
        S "SELECT 1 -- c; d\nFROM t --x"
        S "SELECT 2 --"
        C "SELECT 1\nFROM t\n; SELECT 2"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("Double quotes are identifiers and a backtick is a symbol")
  func doubleQuotedIdentifiers() {
    let sql = Self.corpus[5]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L quoted.quotedIdentifier "a;b" "\"a;b\""
        L symbol ","
        L whitespace " "
        L quoted.quotedIdentifier "A\"B" "\"A\"\"B\""
        L whitespace " "
        L word "FROM"
        L whitespace " "
        L symbol "`"
        L word "t"
        L symbol ";"
        L word "u"
        L symbol "`"
        T word "SELECT" @0
        T quotedIdentifier "a;b" @0
        T symbol "," @0
        T quotedIdentifier "A\"B" @0
        T word "FROM" @0
        T symbol "`" @0
        T word "T" @0
        T symbol ";" @0
        T word "U" @0
        T symbol "`" @0
        S "SELECT \"a;b\", \"A\"\"B\" FROM `t"
        S "u`"
        C "SELECT \"a;b\", \"A\"\"B\" FROM `t;u`"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test(":: casts, ? operators and :name params are symbols")
  func castsOperatorsAndParams() {
    let sql = Self.corpus[6]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L word "x"
        L symbol ":"
        L symbol ":"
        L word "int"
        L symbol ","
        L whitespace " "
        L quoted.string "{}" "\'{}\'"
        L symbol ":"
        L symbol ":"
        L word "jsonb"
        L whitespace " "
        L symbol "?"
        L whitespace " "
        L quoted.string "k" "\'k\'"
        L symbol ","
        L whitespace " "
        L word "d"
        L whitespace " "
        L symbol "?"
        L symbol "|"
        L whitespace " "
        L word "array"
        L symbol "["
        L quoted.string "a" "\'a\'"
        L symbol "]"
        L whitespace " "
        L word "FROM"
        L whitespace " "
        L word "t"
        L whitespace " "
        L word "WHERE"
        L whitespace " "
        L word "id"
        L whitespace " "
        L symbol "="
        L whitespace " "
        L symbol ":"
        L word "name"
        L whitespace " "
        L word "AND"
        L whitespace " "
        L word "n"
        L whitespace " "
        L symbol "="
        L whitespace " "
        L symbol ":"
        L word "n2"
        T word "SELECT" @0
        T word "X" @0
        T symbol ":" @0
        T symbol ":" @0
        T word "INT" @0
        T symbol "," @0
        T string "{}" @0
        T symbol ":" @0
        T symbol ":" @0
        T word "JSONB" @0
        T symbol "?" @0
        T string "k" @0
        T symbol "," @0
        T word "D" @0
        T symbol "?" @0
        T symbol "|" @0
        T word "ARRAY" @0
        T symbol "[" @0
        T string "a" @0
        T symbol "]" @0
        T word "FROM" @0
        T word "T" @0
        T word "WHERE" @0
        T word "ID" @0
        T symbol "=" @0
        T symbol ":" @0
        T word "NAME" @0
        T word "AND" @0
        T word "N" @0
        T symbol "=" @0
        T symbol ":" @0
        T word "N2" @0
        S "SELECT x::int, \'{}\'::jsonb ? \'k\', d ?| array[\'a\'] FROM t WHERE id = :name AND n = :n2"
        C "SELECT x::int, \'{}\'::jsonb ? \'k\', d ?| array[\'a\'] FROM t WHERE id = :name AND n = :n2"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("A backslash in a plain string is a backslashString")
  func backslashInPlainStrings() {
    let sql = Self.corpus[7]
    #expect(
      Self.snapshot(sql) == #"""
        L word "SELECT"
        L whitespace " "
        L quoted.backslashString "a\\b" "\'a\\b\'"
        L symbol ";"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L quoted.quotedIdentifier "c\\d" "\"c\\d\""
        L symbol ";"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L number "2"
        T word "SELECT" @0
        T backslashString "a\\b" @0
        T symbol ";" @0
        T word "SELECT" @0
        T quotedIdentifier "c\\d" @0
        T symbol ";" @0
        T word "SELECT" @0
        T word "2" @0
        S "SELECT \'a\\b\'"
        S "SELECT \"c\\d\""
        S "SELECT 2"
        C "SELECT \'a\\b\'; SELECT \"c\\d\"; SELECT 2"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }

  @Test("DELIMITER is an ordinary word")
  func delimiterIsNotADirective() {
    let sql = Self.corpus[8]
    #expect(
      Self.snapshot(sql) == #"""
        L word "DELIMITER"
        L whitespace " "
        L symbol "/"
        L symbol "/"
        L whitespace "\n"
        L word "CREATE"
        L whitespace " "
        L word "PROCEDURE"
        L whitespace " "
        L word "p"
        L symbol "("
        L symbol ")"
        L whitespace " "
        L word "BEGIN"
        L whitespace " "
        L word "SELECT"
        L whitespace " "
        L number "1"
        L symbol ";"
        L whitespace " "
        L word "END"
        L symbol "/"
        L symbol "/"
        L whitespace "\n"
        L word "DELIMITER"
        L whitespace " "
        L symbol ";"
        L whitespace "\n"
        L word "SELECT"
        L whitespace " "
        L number "2"
        T word "DELIMITER" @0
        T symbol "/" @0
        T symbol "/" @0
        T word "CREATE" @0
        T word "PROCEDURE" @0
        T word "P" @0
        T symbol "(" @0
        T symbol ")" @0
        T word "BEGIN" @0
        T word "SELECT" @0
        T word "1" @0
        T symbol ";" @0
        T word "END" @0
        T symbol "/" @0
        T symbol "/" @0
        T word "DELIMITER" @0
        T symbol ";" @0
        T word "SELECT" @0
        T word "2" @0
        S "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1"
        S "END//\nDELIMITER"
        S "SELECT 2"
        C "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2"
        """#)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql) == SQLTokenizer.tokens(sql))
    #expect(
      SQLTokenizer(dialect: .postgresql).splitStatements(sql) == SQLTokenizer.splitStatements(sql))
  }
}
