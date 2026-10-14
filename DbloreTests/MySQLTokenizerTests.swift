// MySQLTokenizerTests.swift
// MySQL lexical rules: backticks, # and "-- " comments, backslash strings, executable comments,
// and the DELIMITER client directive

import Foundation
import Testing

@testable import Dblore

@Suite("MySQL Tokenizer")
struct MySQLTokenizerTests {

  private let tokenizer = SQLTokenizer(dialect: .mysql)

  @Test("Backticks quote identifiers, with a doubled backtick as escape")
  func backtickIdentifiers() {
    #expect(tokenizer.splitStatements("SELECT `a;b`; SELECT 2") == ["SELECT `a;b`", "SELECT 2"])
    let tokens = tokenizer.tokens("SELECT `a``b`, `C` FROM t")
    #expect(
      tokens.map(\.kind) == [.word, .quotedIdentifier, .symbol, .quotedIdentifier, .word, .word])
    #expect(tokens.map(\.text) == ["SELECT", "a`b", ",", "C", "FROM", "T"])
  }

  @Test("# starts a comment that ends at the line break")
  func hashComments() {
    #expect(
      tokenizer.splitStatements("SELECT 1 # c; d\nFROM t; SELECT 2")
        == ["SELECT 1 # c; d\nFROM t", "SELECT 2"])
    #expect(tokenizer.tokens("SELECT a#b;\n, c").map(\.text) == ["SELECT", "A", ",", "C"])
  }

  @Test("-- starts a comment only before whitespace, a control character or the end")
  func doubleDashComments() {
    #expect(
      tokenizer.splitStatements("SELECT 1 -- c; d\nFROM t; SELECT 2")
        == ["SELECT 1 -- c; d\nFROM t", "SELECT 2"])
    #expect(tokenizer.tokens("SELECT 1 --\tx;").map(\.text) == ["SELECT", "1"])
    #expect(tokenizer.tokens("SELECT 1 --\u{01}x;").map(\.text) == ["SELECT", "1"])
    #expect(tokenizer.tokens("SELECT 1 --").map(\.text) == ["SELECT", "1"])
    #expect(tokenizer.tokens("SELECT 5--1").map(\.text) == ["SELECT", "5", "-", "-", "1"])
    #expect(tokenizer.splitStatements("SELECT 5--1; SELECT 2") == ["SELECT 5--1", "SELECT 2"])
  }

  @Test("Single and double quotes are strings with backslash and doubled-quote escapes")
  func backslashStrings() {
    #expect(
      tokenizer.splitStatements("SELECT 'it\\'s;', \"a\\\"b;\"; SELECT 2")
        == ["SELECT 'it\\'s;', \"a\\\"b;\"", "SELECT 2"])
    let tokens = tokenizer.tokens("SELECT 'a\\b', \"c\", 'd''e'")
    #expect(tokens.map(\.kind) == [.word, .string, .symbol, .string, .symbol, .string])
    #expect(tokens.map(\.text) == ["SELECT", "a\\b", ",", "c", ",", "d'e"])

    // `E'…'` is a word plus a string, not a PostgreSQL escape string.
    #expect(tokenizer.tokens("SELECT E'a\\';b'").map(\.kind) == [.word, .word, .string])
  }

  @Test("A dollar sign does not open a quote")
  func noDollarQuoting() {
    #expect(
      tokenizer.splitStatements("SELECT $$ a; b $$; SELECT 2") == [
        "SELECT $$ a", "b $$", "SELECT 2",
      ])
  }

  @Test("Block comments end at the first closer")
  func blockCommentsDoNotNest() {
    #expect(
      tokenizer.splitStatements("/* a /* b */ SELECT 1; SELECT 2")
        == ["/* a /* b */ SELECT 1", "SELECT 2"])
    #expect(tokenizer.tokens("SELECT /*+ hint */ 1").map(\.text) == ["SELECT", "1"])
  }

  @Test("/*! and /*M! comments are executable comments, kept as their own token")
  func executableComments() {
    let tokens = tokenizer.tokens("SELECT /*! STRAIGHT_JOIN */ 1")
    #expect(tokens.map(\.kind) == [.word, .executableComment, .word])
    #expect(tokens.map(\.text) == ["SELECT", "/*! STRAIGHT_JOIN */", "1"])

    for comment in ["/*!50001 DROP TABLE t */", "/*M! x */", "/*M!100100 x */", "/*!*/"] {
      #expect(tokenizer.tokens(comment).map(\.kind) == [.executableComment])
    }
    #expect(tokenizer.tokens("SELECT /*! x").map(\.text) == ["SELECT", "/*! x"])
    #expect(
      tokenizer.splitStatements("SELECT 1 /*! ; */; SELECT 2") == ["SELECT 1 /*! ; */", "SELECT 2"])
    #expect(tokenizer.strippingComments("SELECT /*! x */ 1 # c") == "SELECT /*! x */ 1")
  }

  @Test("DELIMITER changes the statement separator and is not a statement")
  func delimiterDirective() {
    let script = """
      DELIMITER //
      CREATE PROCEDURE p() BEGIN SELECT 1; END//
      DELIMITER ;
      SELECT 2; SELECT 3
      """
    #expect(
      tokenizer.splitStatements(script) == [
        "CREATE PROCEDURE p() BEGIN SELECT 1; END", "SELECT 2", "SELECT 3",
      ])

    let trigger = """
      delimiter $$
      CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN SET @a = 1; END$$
      delimiter ;
      """
    #expect(
      tokenizer.splitStatements(trigger) == [
        "CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW BEGIN SET @a = 1; END"
      ])
  }

  @Test("The delimiter is not matched inside strings or comments")
  func delimiterInsideQuotes() {
    #expect(
      tokenizer.splitStatements("DELIMITER //\nSELECT '//', `//` # //\n; SELECT 1//")
        == ["SELECT '//', `//` # //\n; SELECT 1"])
  }

  @Test("DELIMITER is a directive only at the start of a statement")
  func delimiterOnlyAtStatementStart() {
    #expect(
      tokenizer.splitStatements("SELECT delimiter FROM t; SELECT 2")
        == ["SELECT delimiter FROM t", "SELECT 2"])
    #expect(
      tokenizer.splitStatements("-- setup\nDELIMITER //\nSELECT 1; SELECT 2//")
        == ["-- setup", "SELECT 1; SELECT 2"])
  }

  @Test("/*+ optimizer hints stay comments and expose their text")
  func optimizerHints() {
    let sql = "SELECT /*+ MAX_EXECUTION_TIME(1) */ 1, '/*+ x */' /* y */ # /*+ z */\n FROM t"
    #expect(tokenizer.tokens(sql).map(\.text) == ["SELECT", "1", ",", "/*+ x */", "FROM", "T"])
    #expect(tokenizer.optimizerHints(sql) == ["/*+ MAX_EXECUTION_TIME(1) */"])
    #expect(tokenizer.optimizerHints("SELECT /*!+ x */ 1 /* + y */").isEmpty)
  }
}
