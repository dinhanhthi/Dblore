// SQLParameterRewriterTests.swift
// :name becomes one dialect placeholder per distinct name, in first-seen order.

import Foundation
import Testing

@testable import Dblore

struct RewriteCase: Sendable, CustomTestStringConvertible {
  let source: String
  let postgresql: String
  let sqlite: String
  let names: [String]

  var testDescription: String { source }
}

struct OpaqueCase: Sendable, CustomTestStringConvertible {
  let dialect: SQLDialect
  let source: String
  let rewritten: String
  let names: [String]

  var testDescription: String { "\(dialect.promptName): \(source)" }
}

struct PositionalCase: Sendable, CustomTestStringConvertible {
  let dialect: SQLDialect
  let sql: String
  let expected: Bool

  var testDescription: String { "\(dialect.promptName): \(sql)" }
}

private let rewriteCases: [RewriteCase] = [
  RewriteCase(
    source: ":x IS NULL OR col = :x",
    postgresql: "$1 IS NULL OR col = $1",
    sqlite: "?1 IS NULL OR col = ?1",
    names: ["x"]),
  RewriteCase(
    source: "fn(:b, :a, :b)",
    postgresql: "fn($1, $2, $1)",
    sqlite: "fn(?1, ?2, ?1)",
    names: ["b", "a"]),
  RewriteCase(
    source: "WHERE col=:x",
    postgresql: "WHERE col=$1",
    sqlite: "WHERE col=?1",
    names: ["x"]),
  RewriteCase(
    source: ":id::text",
    postgresql: "$1::text",
    sqlite: "?1::text",
    names: ["id"]),
]

/// Statements whose only colons are casts, slices, assignment, or a colon that is not a name.
private let unchangedSources: [String] = [
  "",
  "SELECT 1",
  "SELECT a::int",
  "SELECT ::name",
  "SELECT arr[1:2]",
  "SELECT arr[lo:hi]",
  "SELECT a := 1",
  "SELECT id:name",
  "SELECT ):name",
  "SELECT ]:name",
  "SELECT : name",
  "SELECT :1",
  "SELECT 1:2",
  "SELECT $1",
  "SELECT ?",
]

private func opaqueCase(_ dialect: SQLDialect, _ body: String) -> OpaqueCase {
  OpaqueCase(
    dialect: dialect,
    source: "SELECT :id\(body)",
    rewritten: "SELECT \(dialect.placeholder(1))\(body)",
    names: ["id"])
}

private let opaqueCases: [OpaqueCase] = {
  let both: [SQLDialect] = [.postgresql, .sqlite]
  let shared = [", ':a'", ", E':a'", " -- :a", " /* :a */", ", \":a\""]
  var cases = shared.flatMap { body in both.map { opaqueCase($0, body) } }
  cases.append(opaqueCase(.postgresql, ", $$:a$$"))
  cases.append(opaqueCase(.postgresql, ", $tag$:a$tag$"))
  cases.append(opaqueCase(.sqlite, ", [:a]"))
  cases.append(opaqueCase(.sqlite, ", `:a`"))
  return cases
}()

private let positionalCases: [PositionalCase] = [
  PositionalCase(dialect: .postgresql, sql: "SELECT $1", expected: true),
  PositionalCase(dialect: .postgresql, sql: "SELECT $12", expected: true),
  PositionalCase(dialect: .postgresql, sql: "SELECT ($1)", expected: true),
  PositionalCase(dialect: .postgresql, sql: "SELECT ?", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT ?1", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT col ?| ARRAY['a']", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT '$1'", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT $$ $1 $$", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT a$1", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT $", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT $ 1", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT 1 -- $1", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT /* $1 */ 1", expected: false),
  PositionalCase(dialect: .postgresql, sql: "SELECT :id", expected: false),
  PositionalCase(dialect: .sqlite, sql: "SELECT ?", expected: true),
  PositionalCase(dialect: .sqlite, sql: "SELECT ?1", expected: true),
  PositionalCase(dialect: .sqlite, sql: "SELECT ?12", expected: true),
  PositionalCase(dialect: .sqlite, sql: "SELECT ?name", expected: true),
  PositionalCase(dialect: .sqlite, sql: "SELECT $1", expected: false),
  PositionalCase(dialect: .sqlite, sql: "SELECT '?'", expected: false),
  PositionalCase(dialect: .sqlite, sql: "SELECT 1 -- ?", expected: false),
  PositionalCase(dialect: .sqlite, sql: "SELECT /* ?1 */ 1", expected: false),
  PositionalCase(dialect: .sqlite, sql: "SELECT [?]", expected: false),
  PositionalCase(dialect: .sqlite, sql: "SELECT :id", expected: false),
]

@Suite("SQL Parameter Rewriter")
struct SQLParameterRewriterTests {
  @Test(
    "Distinct :name values become one placeholder in first-seen order",
    arguments: rewriteCases)
  func distinctNames(_ sample: RewriteCase) {
    let postgresql = SQLParameterRewriter.rewrite(statement: sample.source, dialect: .postgresql)
    let sqlite = SQLParameterRewriter.rewrite(statement: sample.source, dialect: .sqlite)
    #expect(postgresql.text == sample.postgresql)
    #expect(postgresql.names == sample.names)
    #expect(sqlite.text == sample.sqlite)
    #expect(sqlite.names == sample.names)
  }

  @Test("A statement with no :name is returned unchanged", arguments: unchangedSources)
  func unchanged(_ source: String) {
    for dialect in [SQLDialect.postgresql, SQLDialect.sqlite] {
      let result = SQLParameterRewriter.rewrite(statement: source, dialect: dialect)
      #expect(result.text == source)
      #expect(result.names.isEmpty)
    }
  }

  @Test(
    "Strings, comments, dollar quotes, and quoted identifiers are not parameters",
    arguments: opaqueCases)
  func opaqueRegions(_ sample: OpaqueCase) {
    let result = SQLParameterRewriter.rewrite(statement: sample.source, dialect: sample.dialect)
    #expect(result.text == sample.rewritten)
    #expect(result.names == sample.names)
  }

  @Test("CRLF around a placeholder is preserved")
  func preservesCRLF() {
    let source = "SELECT :id\r\nFROM t"
    #expect(
      SQLParameterRewriter.rewrite(statement: source, dialect: .postgresql)
        == (text: "SELECT $1\r\nFROM t", names: ["id"]))
    #expect(
      SQLParameterRewriter.rewrite(statement: source, dialect: .sqlite)
        == (text: "SELECT ?1\r\nFROM t", names: ["id"]))
  }

  @Test("A non-ASCII name keeps its spelling, and earlier non-ASCII text stays put")
  func nonASCIIName() {
    let source = "SELECT '名', :名前"
    #expect(
      SQLParameterRewriter.rewrite(statement: source, dialect: .postgresql)
        == (text: "SELECT '名', $1", names: ["名前"]))
    #expect(
      SQLParameterRewriter.rewrite(statement: source, dialect: .sqlite)
        == (text: "SELECT '名', ?1", names: ["名前"]))
  }

  @Test("Dollar quotes hide :name only on PostgreSQL")
  func dollarQuotesFollowDialect() {
    let source = "SELECT $$ :a $$"
    #expect(
      SQLParameterRewriter.rewrite(statement: source, dialect: .postgresql)
        == (text: source, names: []))
    #expect(
      SQLParameterRewriter.rewrite(statement: source, dialect: .sqlite)
        == (text: "SELECT $$ ?1 $$", names: ["a"]))
  }

  @Test("parameterNames lists distinct names in first-occurrence order")
  func parameterNamesInOrder() {
    let script = "SELECT :b; SELECT ':no' /* :no */, :a, :b"
    for dialect in [SQLDialect.postgresql, SQLDialect.sqlite] {
      #expect(SQLParameterRewriter.parameterNames(in: script, dialect: dialect) == ["b", "a"])
    }
    #expect(SQLParameterRewriter.parameterNames(in: "", dialect: .postgresql).isEmpty)
  }

  @Test(
    "Positional placeholders are $n on PostgreSQL and ? or ?n on SQLite",
    arguments: positionalCases)
  func positionalPlaceholders(_ sample: PositionalCase) {
    #expect(
      SQLParameterRewriter.containsPositionalPlaceholder(in: sample.sql, dialect: sample.dialect)
        == sample.expected)
  }
}
