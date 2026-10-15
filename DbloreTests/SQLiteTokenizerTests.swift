// SQLiteTokenizerTests.swift
// SQLite lexical rules: strings, identifiers, comments, dollar signs, and trigger bodies

import Foundation
import SQLite3
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

// MARK: - Trigger bodies

/// The SQLite split cuts where SQLite's own `sqlite3_complete` says a statement ends, so a
/// `CREATE TRIGGER ... BEGIN ...; ...; END` body stays one statement.
extension SQLiteTokenizerTests {
  @Test("A trigger with several statements is one statement")
  func triggerWithSeveralStatements() {
    let trigger =
      "CREATE TRIGGER log_insert AFTER INSERT ON a BEGIN INSERT INTO b (x) VALUES (new.x);"
      + " UPDATE c SET n = n + 1; DELETE FROM d WHERE id = new.id; END"
    #expect(tokenizer.splitStatements(trigger + ";") == [trigger])
    #expect(Self.referenceSplit(trigger + ";") == [trigger])
  }

  @Test("CASE ... END inside a trigger does not end it")
  func caseEndInsideTrigger() {
    let trigger =
      "create temp trigger t before update on a begin select case when new.x > 0 then 1"
      + " else raise(abort, 'negative; no') end; end"
    #expect(tokenizer.splitStatements(trigger + "; SELECT 2") == [trigger, "SELECT 2"])
  }

  @Test("A trigger next to plain statements")
  func triggerNextToPlainStatements() {
    let trigger =
      "CREATE TEMPORARY TRIGGER IF NOT EXISTS t AFTER DELETE ON a BEGIN"
      + " DELETE FROM b WHERE a_id = old.id; /* c; */ END -- done;\n"
    let script =
      "CREATE TABLE a (id INTEGER PRIMARY KEY);\n" + trigger
      + ";\nINSERT INTO a VALUES (1); SELECT CASE WHEN 1 THEN 2 END; END; SELECT 3"
    let expected = [
      "CREATE TABLE a (id INTEGER PRIMARY KEY)",
      trigger.trimmingCharacters(in: .whitespacesAndNewlines),
      "INSERT INTO a VALUES (1)", "SELECT CASE WHEN 1 THEN 2 END", "END", "SELECT 3",
    ]
    #expect(tokenizer.splitStatements(script) == expected)
    #expect(Self.referenceSplit(script) == expected)
  }

  @Test(
    "Cuts match sqlite3_complete",
    arguments: [
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END; SELECT 2",
      "EXPLAIN CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END; SELECT 2",
      "EXPLAIN QUERY PLAN SELECT 1; CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END;",
      "CREATE TABLE trigger_log (x); CREATE VIEW v AS SELECT 1; SELECT 'trigger; end'",
      "CREATE TRIGGER \"end\" AFTER INSERT ON [a;b] BEGIN SELECT `x;`; END; SELECT 1",
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END END; SELECT 2; END; SELECT 3",
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1;\u{0B}END; SELECT 2; END; SELECT 3",
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; -- c\r; END;\n SELECT 2; END; SELECT 3",
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END$x; END;",
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END",
      "SELECT 1; CREATE /* x */ TRIGGER t AFTER INSERT ON a BEGIN SELECT 1;  END ; SELECT 2;",
      "CREATE UNIQUE INDEX i ON a (x); CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END;",
    ])
  func cutsMatchSQLite(script: String) {
    #expect(tokenizer.splitStatements(script) == Self.referenceSplit(script))
  }

  @Test("A line comment ends only at a line feed, as in SQLite")
  func lineCommentEndsAtLineFeed() {
    #expect(
      tokenizer.tokens("DELETE FROM t -- note\rWHERE id = 1").map(\.text) == [
        "DELETE", "FROM", "T",
      ])
    #expect(
      tokenizer.splitStatements("SELECT 1 -- a\r; SELECT 2\n; SELECT 3") == [
        "SELECT 1 -- a\r; SELECT 2", "SELECT 3",
      ])
  }

  @Test("PostgreSQL and DuckDB still split at every semicolon")
  func otherDialectsUnchanged() {
    let trigger = "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END"
    #expect(SQLTokenizer.splitStatements(trigger, dialect: .postgresql).count == 2)
    #expect(SQLTokenizer.splitStatements(trigger, dialect: .duckdb).count == 2)
  }

  /// Statements as SQLite reads them: each ends at the first `;` where `sqlite3_complete` of the
  /// text since the previous end is true. Trimmed like `splitStatements`; blank pieces dropped.
  static func referenceSplit(_ script: String) -> [String] {
    let scalars = Array(script.unicodeScalars)
    var pieces: [String] = []
    var start = 0
    for index in scalars.indices where scalars[index] == ";" {
      let prefix = text(scalars[start...index])
      if sqlite3_complete(prefix) != 0 {
        pieces.append(text(scalars[start..<index]))
        start = index + 1
      }
    }
    pieces.append(text(scalars[start...]))
    return pieces.map(trimmed).filter { !$0.isEmpty }
  }

  private static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
    var result = String.UnicodeScalarView()
    result.append(contentsOf: scalars)
    return String(result)
  }

  private static func trimmed(_ text: String) -> String {
    let space: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0C}", "\u{0B}"]
    var scalars = Array(text.unicodeScalars)
    while let first = scalars.first, space.contains(first) { scalars.removeFirst() }
    while let last = scalars.last, space.contains(last) { scalars.removeLast() }
    return Self.text(scalars[...])
  }
}
