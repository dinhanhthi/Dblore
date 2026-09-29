// SQLTokenizerDollarQuoteTests.swift
// Tests for statement splitting with PostgreSQL dollar-quoted and escape strings

import Foundation
import Testing

@testable import Dblore

@Suite("SQL Tokenizer - Dollar Quote Splitting")
@MainActor
struct SQLTokenizerDollarQuoteTests {

  private func split(_ sql: String) -> [String] {
    DatabaseConnectionManager().splitSQLStatements(sql)
  }

  // MARK: - Dollar quotes

  @Test("Anonymous $$ block is not split on inner semicolons")
  func anonymousDollarQuote() {
    let result = split("DO $$ BEGIN DELETE FROM t; UPDATE t SET x = 1; END $$; SELECT 1")
    #expect(result == ["DO $$ BEGIN DELETE FROM t; UPDATE t SET x = 1; END $$", "SELECT 1"])
  }

  @Test("Tagged $fn$ block is not split on inner semicolons")
  func taggedDollarQuote() {
    let result = split(
      "CREATE FUNCTION f() RETURNS int AS $fn$ SELECT 1; $fn$ LANGUAGE sql; SELECT 2")
    #expect(
      result == [
        "CREATE FUNCTION f() RETURNS int AS $fn$ SELECT 1; $fn$ LANGUAGE sql", "SELECT 2",
      ])
  }

  @Test("Different tag nested inside a dollar quote stays one statement")
  func nestedDifferentTag() {
    let sql = "SELECT $a$ x; $b$ y; $b$ z; $a$"
    #expect(split(sql) == [sql])
  }

  @Test("Different tag nested inside, followed by another statement")
  func nestedDifferentTagThenStatement() {
    let result = split("SELECT $a$ x; $b$ y; $b$ z; $a$; SELECT 2")
    #expect(result == ["SELECT $a$ x; $b$ y; $b$ z; $a$", "SELECT 2"])
  }

  @Test("Tag with digits after the first character is valid")
  func tagWithDigits() {
    let result = split("SELECT $t1$ a; b $t1$; SELECT 2")
    #expect(result == ["SELECT $t1$ a; b $t1$", "SELECT 2"])
  }

  @Test("Dollar-quoted body directly after a keyword without space")
  func dollarQuoteAfterParen() {
    let result = split("SELECT ($$a;b$$); SELECT 2")
    #expect(result == ["SELECT ($$a;b$$)", "SELECT 2"])
  }

  @Test("$$ inside a single-quoted string does not open a dollar quote")
  func dollarInsideSingleQuote() {
    #expect(split("SELECT '$$'; SELECT 2") == ["SELECT '$$'", "SELECT 2"])
  }

  @Test("$$ inside a double-quoted identifier does not open a dollar quote")
  func dollarInsideDoubleQuote() {
    #expect(split("SELECT \"$$\"; SELECT 2") == ["SELECT \"$$\"", "SELECT 2"])
  }

  @Test("$$ inside a single-line comment does not open a dollar quote")
  func dollarInsideLineComment() {
    #expect(split("-- $$\nSELECT 1; SELECT 2") == ["-- $$\nSELECT 1", "SELECT 2"])
  }

  @Test("$$ inside a block comment does not open a dollar quote")
  func dollarInsideBlockComment() {
    #expect(split("/* $$ */ SELECT 1; SELECT 2") == ["/* $$ */ SELECT 1", "SELECT 2"])
  }

  @Test("Positional parameters are not dollar-quote tags")
  func positionalParameters() {
    #expect(split("SELECT $1; SELECT 2") == ["SELECT $1", "SELECT 2"])
    #expect(split("SELECT $1, $2; SELECT $3") == ["SELECT $1, $2", "SELECT $3"])
  }

  @Test("Identifier containing $ does not open a tag")
  func identifierWithDollar() {
    #expect(split("SELECT a$b$ FROM t; SELECT 2") == ["SELECT a$b$ FROM t", "SELECT 2"])
    #expect(split("SELECT a$$ ; SELECT 2") == ["SELECT a$$", "SELECT 2"])
  }

  @Test("Unterminated dollar quote keeps the rest as one statement")
  func unterminatedDollarQuote() {
    let result = split("SELECT 1; DO $$ BEGIN x; y;")
    #expect(result == ["SELECT 1", "DO $$ BEGIN x; y;"])
  }

  @Test("Lone $ at end of input does not crash")
  func loneDollarAtEnd() {
    #expect(split("SELECT $") == ["SELECT $"])
    #expect(split("SELECT $abc") == ["SELECT $abc"])
  }

  // MARK: - Token boundaries

  @Test("A dollar quote may open right after a closed dollar quote")
  func backToBackDollarQuotes() {
    let tokens = SQLTokenizer.tokens("SELECT $$a$$$$b$$")
    #expect(tokens.map(\.kind) == [.word, .string, .string])
    #expect(tokens.map(\.text) == ["SELECT", "$$a$$", "$$b$$"])
  }

  @Test("A dollar quote may open right after a number or positional parameter")
  func dollarQuoteAfterNumber() {
    #expect(split("SELECT 1$$a;b$$; SELECT 2") == ["SELECT 1$$a;b$$", "SELECT 2"])
    #expect(split("SELECT $1$$a;b$$; SELECT 2") == ["SELECT $1$$a;b$$", "SELECT 2"])
  }

  @Test("Parameters, identifiers with $ and tags keep their tokens")
  func dollarTokensUnchanged() {
    #expect(SQLTokenizer.tokens("SELECT $1").map(\.text) == ["SELECT", "$", "1"])
    #expect(SQLTokenizer.tokens("SELECT a$b").map(\.text) == ["SELECT", "A$B"])
    #expect(SQLTokenizer.tokens("SELECT $fn$ x; $fn$").map(\.text) == ["SELECT", "$fn$ x; $fn$"])
    #expect(SQLTokenizer.tokens("SELECT $€$ x $€$").map(\.text) == ["SELECT", "$€$ x $€$"])
  }

  // MARK: - Unicode scalars (PostgreSQL lexes bytes, not grapheme clusters)

  @Test("A combining mark after a quote does not hide the closing quote")
  func combiningMarkAfterQuote() {
    #expect(split("SELECT 'x'\u{301}; SELECT 2").count == 2)
    #expect(split("SELECT 1 /* */\u{301}; SELECT 2").count == 2)
  }

  @Test("Canonically equivalent scalars are not ASCII syntax")
  func canonicalEquivalents() {
    // U+037E GREEK QUESTION MARK is canonically equivalent to ";"
    #expect(split("SELECT 1\u{37E} SELECT 2").count == 1)
  }

  @Test("Only PostgreSQL whitespace separates tokens")
  func postgresWhitespace() {
    #expect(SQLTokenizer.tokens("SELECT\u{A0}1").map(\.text) == ["SELECT\u{A0}1"])
    #expect(SQLTokenizer.tokens("SELECT \u{A0}x").map(\.text) == ["SELECT", "\u{A0}X"])
    #expect(SQLTokenizer.tokens("SELECT\u{0C}1\u{0B}\t2").map(\.text) == ["SELECT", "1", "2"])
  }

  @Test("Statement texts are exact scalar substrings of the input")
  func exactSubstrings() {
    let result = split(" SELECT 'e\u{301}'\u{A0};\u{A0}SELECT \u{212A} ")
    #expect(result.count == 2)
    #expect(
      Array(result.first?.unicodeScalars ?? "".unicodeScalars)
        == Array("SELECT 'e\u{301}'\u{A0}".unicodeScalars))
    #expect(
      Array(result.last?.unicodeScalars ?? "".unicodeScalars)
        == Array("\u{A0}SELECT \u{212A}".unicodeScalars))
  }

  // MARK: - Escape strings

  @Test("E-string with backslash-escaped quote does not split")
  func escapeStringBackslashQuote() {
    #expect(split("SELECT E'a\\';b'; SELECT 2") == ["SELECT E'a\\';b'", "SELECT 2"])
  }

  @Test("Lowercase e-string with escaped quote does not split")
  func lowercaseEscapeString() {
    #expect(split("SELECT e'it\\'s;'; SELECT 2") == ["SELECT e'it\\'s;'", "SELECT 2"])
  }

  @Test("Standard string keeps backslash literal")
  func standardStringBackslash() {
    #expect(split("SELECT 'a\\'; SELECT 2") == ["SELECT 'a\\'", "SELECT 2"])
  }

  @Test("Identifier ending in E before a quote is not an E-string")
  func identifierEndingInE() {
    #expect(split("SELECT name'a\\'; SELECT 2") == ["SELECT name'a\\'", "SELECT 2"])
  }

  // MARK: - Existing behaviour

  @Test("Semicolons inside quotes and comments are still ignored")
  func existingQuotesAndComments() {
    #expect(split("SELECT 'a;b'; SELECT 2") == ["SELECT 'a;b'", "SELECT 2"])
    #expect(split("SELECT 'it''s;'; SELECT 2") == ["SELECT 'it''s;'", "SELECT 2"])
    #expect(split("SELECT \"a;b\"; SELECT 2") == ["SELECT \"a;b\"", "SELECT 2"])
    #expect(split("SELECT 1 -- a;b\n; SELECT 2") == ["SELECT 1 -- a;b", "SELECT 2"])
    #expect(split("SELECT /* a;b */ 1; SELECT 2") == ["SELECT /* a;b */ 1", "SELECT 2"])
  }
}
