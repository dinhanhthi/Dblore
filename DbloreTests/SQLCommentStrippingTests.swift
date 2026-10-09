// SQLCommentStrippingTests.swift
// The query shown above each side of a result compare: comments removed, blank lines collapsed

import Foundation
import Testing

@testable import Dblore

@Suite("SQL comment stripping")
struct SQLCommentStrippingTests {
  @Test(
    "Comments are removed and string contents are kept",
    arguments: [
      // Line comments, whole-line and trailing
      ("-- header\nSELECT 1; -- trailing\n", "SELECT 1;"),
      // Block comment between tokens keeps them apart
      ("SELECT/* x */1", "SELECT 1"),
      // Multi-line and nested block comments
      ("/* a\n /* b */ c\n*/\nSELECT 1", "SELECT 1"),
      // Comment markers inside strings, identifiers and E-strings stay
      ("SELECT '--', '/* x */' FROM t", "SELECT '--', '/* x */' FROM t"),
      ("SELECT \"a--b\" FROM t -- gone", "SELECT \"a--b\" FROM t"),
      (#"SELECT E'it\'s -- here' -- gone"#, #"SELECT E'it\'s -- here'"#),
      // Dollar-quoted bodies are kept verbatim, blank lines included
      ("SELECT $$ -- a\n\n b $$ -- c", "SELECT $$ -- a\n\n b $$"),
      ("SELECT $fn$ /* x */ $fn$", "SELECT $fn$ /* x */ $fn$"),
      // Lines left blank by comments collapse; indentation stays
      ("SELECT id,\n  -- note\n\n  name\nFROM t\n\n/* end */", "SELECT id,\n  name\nFROM t"),
      ("-- only a comment", ""),
    ])
  func strips(input: String, expected: String) {
    #expect(SQLTokenizer.strippingComments(input) == expected)
  }

  @Test("SQLite has no dollar quotes, so a comment after $$ is removed")
  func sqliteDialect() {
    #expect(SQLTokenizer(dialect: .sqlite).strippingComments("SELECT $$ -- x") == "SELECT $$")
    #expect(SQLTokenizer.strippingComments("SELECT $$ -- x") == "SELECT $$ -- x")
  }
}
