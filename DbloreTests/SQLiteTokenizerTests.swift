// SQLiteTokenizerTests.swift
// SQLite lexical rules: strings, identifiers, comments, and dollar signs

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite Tokenizer")
struct SQLiteTokenizerTests {

  private let tokenizer = SQLTokenizer(dialect: .sqlite)

  @Test("Strings use doubled quotes only and never a backslash escape")
  func stringsUseDoubledQuotesOnly() {
    #expect(
      tokenizer.splitStatements("SELECT 'it''s;'; SELECT 2") == ["SELECT 'it''s;'", "SELECT 2"])
    #expect(tokenizer.tokens("SELECT 'it''s'").map(\.text) == ["SELECT", "it's"])

    let backslash = tokenizer.tokens("SELECT 'a\\b'")
    #expect(backslash.map(\.kind) == [.word, .string])
    #expect(backslash.map(\.text) == ["SELECT", "a\\b"])
    #expect(tokenizer.splitStatements("SELECT 'a\\'; SELECT 2") == ["SELECT 'a\\'", "SELECT 2"])

    // `E'…'` is an identifier plus a plain string, not a PostgreSQL escape string.
    #expect(
      tokenizer.splitStatements("SELECT E'a\\';b'; SELECT 2") == ["SELECT E'a\\'", "b'; SELECT 2"])
    #expect(tokenizer.tokens("SELECT e'a\\b'").map(\.kind) == [.word, .word, .string])
  }

  @Test("Identifiers may be double-quoted, bracketed, or backticked")
  func quotedIdentifiers() {
    #expect(
      tokenizer.splitStatements("SELECT \"a;b\"; SELECT 2") == ["SELECT \"a;b\"", "SELECT 2"])
    #expect(tokenizer.splitStatements("SELECT [a;b]; SELECT 2") == ["SELECT [a;b]", "SELECT 2"])
    #expect(tokenizer.splitStatements("SELECT `a;b`; SELECT 2") == ["SELECT `a;b`", "SELECT 2"])

    let tokens = tokenizer.tokens("SELECT \"A\"\"B\" [C] `D``E`")
    #expect(tokens.map(\.kind) == [.word, .quotedIdentifier, .quotedIdentifier, .quotedIdentifier])
    #expect(tokens.map(\.text) == ["SELECT", "A\"B", "C", "D`E"])

    // A bracket identifier ends at the first `]`.
    let brackets = tokenizer.tokens("SELECT [a]]b]")
    #expect(brackets.map(\.kind) == [.word, .quotedIdentifier, .symbol, .word, .symbol])
    #expect(brackets.map(\.text) == ["SELECT", "a", "]", "B", "]"])
  }

  @Test("Block comments end at the first closer")
  func blockCommentsDoNotNest() {
    #expect(
      tokenizer.splitStatements("/* a /* b */ SELECT 1; SELECT 2")
        == ["/* a /* b */ SELECT 1", "SELECT 2"])
    #expect(tokenizer.tokens("SELECT /* a /* b */ 1").map(\.text) == ["SELECT", "1"])
  }

  @Test("A dollar sign does not open a quote")
  func dollarIsNotAQuote() {
    #expect(
      tokenizer.splitStatements("SELECT $$ a; b $$; SELECT 2") == [
        "SELECT $$ a", "b $$", "SELECT 2",
      ])
    #expect(
      tokenizer.splitStatements("SELECT $tag$ a; $tag$; SELECT 2") == [
        "SELECT $tag$ a", "$tag$", "SELECT 2",
      ])
    // `$` continues an identifier, so `$$a$$` is two symbols plus one word, never one string.
    let dollars = tokenizer.tokens("SELECT $$a$$")
    #expect(dollars.map(\.kind) == [.word, .symbol, .symbol, .word])
    #expect(dollars.map(\.text) == ["SELECT", "$", "$", "A$$"])
    #expect(dollars.allSatisfy { $0.kind != .string })
    #expect(
      tokenizer.splitStatements("SELECT $$a;b$$; SELECT 2") == ["SELECT $$a", "b$$", "SELECT 2"])
    #expect(tokenizer.tokens("SELECT a$b").map(\.text) == ["SELECT", "A$B"])
  }
}
