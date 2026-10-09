// DuckDBDialectSitesTests.swift
// The dialect-aware sites decide DuckDB explicitly: tokenizer, classifier, parameter rewriter,
// table filter, syntax highlighter, Safe Mode LIKE check and EXPLAIN. PostgreSQL and SQLite
// rows pin the existing behavior at the same sites.
// Left on the static PostgreSQL tokenizer on purpose: first-keyword lookups (statement routing,
// query parsing, result and editor views, edit types), transaction tracking (TransactionState),
// the PostgreSQL-only capped-read cursor checks (usesCursor, mayCallFunctions callers) and the
// CREATE / ALTER ROLE password check.

import Foundation
import Testing

@testable import Dblore

private func kinds(_ sql: String, _ dialect: SQLDialect) -> [StatementKind] {
  SQLStatementClassifier.classify(sql, dialect: dialect).map(\.kind)
}

@MainActor
@Suite("DuckDB dialect sites")
struct DuckDBDialectSitesTests {

  // MARK: - Tokenizer

  @Test("A DuckDB plain string keeps its backslash as data; PostgreSQL marks it ambiguous")
  func plainStringBackslash() {
    let sql = #"SELECT 'C:\path'"#
    #expect(SQLTokenizer(dialect: .duckdb).tokens(sql).last?.kind == .string)
    #expect(SQLTokenizer(dialect: .postgresql).tokens(sql).last?.kind == .backslashString)
    #expect(SQLTokenizer(dialect: .sqlite).tokens(sql).last?.kind == .string)
  }

  @Test("A DuckDB plain string ends at the first quote after a backslash")
  func plainStringEndsAtQuote() {
    let tokens = SQLTokenizer(dialect: .duckdb).tokens(#"SELECT 'a\', 1"#)
    #expect(tokens.map(\.text) == ["SELECT", #"a\"#, ",", "1"])
  }

  @Test("DuckDB E'..' strings keep backslash escapes")
  func escapeString() {
    let tokens = SQLTokenizer(dialect: .duckdb).tokens(#"SELECT E'a\'b', 1"#)
    #expect(tokens.map(\.kind) == [.word, .string, .symbol, .word])
  }

  @Test("DuckDB dollar quotes hide a semicolon")
  func dollarQuote() {
    let statements = SQLTokenizer(dialect: .duckdb).splitStatements("SELECT $$a;b$$; SELECT 2")
    #expect(statements == ["SELECT $$a;b$$", "SELECT 2"])
  }

  // MARK: - Classifier

  @Test(
    "DuckDB strings with a backslash are reads",
    arguments: [
      #"SELECT 'C:\path'"#,
      #"SELECT '\xDE\xAD'::BLOB"#,
      "SELECT * FROM read_csv('C:\\data\\in.csv')",
    ])
  func backslashStringRead(sql: String) {
    #expect(kinds(sql, .duckdb) == [.read])
  }

  @Test("PostgreSQL still fails closed on a plain backslash string")
  func postgresBackslashStringUnknown() {
    #expect(kinds(#"SELECT 'C:\path'"#, .postgresql) == [.unknown])
  }

  @Test("A backslash before a quote cannot hide a DuckDB statement")
  func backslashQuoteDoesNotHideStatement() {
    #expect(kinds(#"SELECT 'a\'; DROP TABLE t; SELECT 'b'"#, .duckdb) == [.read, .ddl, .read])
  }

  @Test(
    "DuckDB placeholders are reads",
    arguments: [
      "SELECT * FROM t WHERE a = $1",
      "SELECT * FROM t WHERE a = ?",
      "SELECT * FROM t WHERE a = $name",
    ])
  func placeholdersRead(sql: String) {
    #expect(kinds(sql, .duckdb) == [.read])
  }

  @Test(
    "DuckDB FROM-first, PIVOT and UNPIVOT are reads",
    arguments: [
      "FROM t",
      "FROM t SELECT a, b WHERE a > 1",
      "FROM read_parquet('data.parquet') LIMIT 5",
      "PIVOT t ON year USING sum(amount)",
      "UNPIVOT t ON jan, feb INTO NAME month VALUE amount",
      "FROM t UNPIVOT (v FOR k IN (a, b))",
    ])
  func fromFirstRead(sql: String) {
    #expect(kinds(sql, .duckdb) == [.read])
  }

  @Test("DuckDB FROM-first keeps the nested-write and INTO rules")
  func fromFirstFailsClosed() {
    #expect(kinds("FROM (DELETE FROM t RETURNING *)", .duckdb) == [.unknown])
    #expect(kinds("FROM t SELECT a INTO u", .duckdb) == [.dml])
    #expect(kinds("PIVOT (INSERT INTO t VALUES (1)) ON a USING sum(b)", .duckdb) == [.unknown])
  }

  @Test("EXPLAIN and DESCRIBE of a DuckDB FROM-first query are reads")
  func explainFromFirst() {
    #expect(kinds("EXPLAIN FROM t", .duckdb) == [.explain(inner: .read, analyze: false)])
    #expect(kinds("DESCRIBE FROM t", .duckdb) == [.read])
  }

  @Test("FROM-first and PIVOT stay unrecognized on PostgreSQL and SQLite")
  func fromFirstOtherDialects() {
    for dialect in [SQLDialect.postgresql, .sqlite] {
      #expect(kinds("FROM t", dialect) == [.unknown])
      #expect(kinds("PIVOT t ON year USING sum(amount)", dialect) == [.unknown])
    }
  }

  @Test("DuckDB USE changes the session and is blocked")
  func useIsUtility() {
    let statements = SQLStatementClassifier.classify("USE other.main", dialect: .duckdb)
    #expect(statements.map(\.kind) == [.utility])
    let policy = ProtectionPolicy(protectionLevel: .readOnly)
    #expect(DatabaseConnectionManager.evaluate(statements, policy: policy) != .allowed)
  }

  // MARK: - Parameter rewriter

  @Test(
    "DuckDB positional placeholders are detected",
    arguments: [
      ("SELECT $1", true),
      ("SELECT ?", true),
      ("SELECT $name", true),
      ("SELECT @x", false),
      ("SELECT $$a$$", false),
      ("SELECT a$b", false),
    ])
  func duckdbPositional(sql: String, expected: Bool) {
    #expect(
      SQLParameterRewriter.containsPositionalPlaceholder(in: sql, dialect: .duckdb) == expected)
  }

  @Test("PostgreSQL and SQLite positional detection is unchanged")
  func otherPositional() {
    #expect(
      SQLParameterRewriter.containsPositionalPlaceholder(in: "SELECT $1", dialect: .postgresql))
    #expect(
      !SQLParameterRewriter.containsPositionalPlaceholder(in: "SELECT ?", dialect: .postgresql))
    #expect(SQLParameterRewriter.containsPositionalPlaceholder(in: "SELECT @x", dialect: .sqlite))
    #expect(SQLParameterRewriter.containsPositionalPlaceholder(in: "SELECT ?", dialect: .sqlite))
  }

  @Test("DuckDB :name becomes $n")
  func duckdbRewrite() {
    let result = SQLParameterRewriter.rewrite(
      statement: #"SELECT :a, :b, :a, 'C:\x', x::INT"#, dialect: .duckdb)
    #expect(result.text == #"SELECT $1, $2, $1, 'C:\x', x::INT"#)
    #expect(result.names == ["a", "b"])
  }

  // MARK: - Table filter

  @Test(
    "DuckDB LIKE filters cast to VARCHAR and keep ILIKE",
    arguments: [
      (FilterOperator.like, #""c"::VARCHAR LIKE 'v'"#),
      (.notLike, #""c"::VARCHAR NOT LIKE 'v'"#),
      (.ilike, #""c"::VARCHAR ILIKE 'v'"#),
      (.notIlike, #""c"::VARCHAR NOT ILIKE 'v'"#),
    ])
  func duckdbFilter(op: FilterOperator, expected: String) {
    #expect(filter(op, .duckdb) == expected)
  }

  @Test("PostgreSQL and SQLite LIKE filters are unchanged")
  func otherFilters() {
    #expect(filter(.notIlike, .postgresql) == #""c"::text NOT ILIKE 'v'"#)
    #expect(filter(.like, .postgresql) == #""c"::text LIKE 'v'"#)
    #expect(filter(.notIlike, .sqlite) == #""c" NOT LIKE 'v'"#)
    #expect(filter(.notLike, .sqlite) == #""c" NOT LIKE 'v'"#)
  }

  private func filter(_ op: FilterOperator, _ dialect: SQLDialect) -> String? {
    TableFilter(conditions: [FilterCondition(column: "c", op: op, value: "v", connector: .and)])
      .whereClause(dialect: dialect)
  }

  // MARK: - Syntax highlighter

  @Test("DuckDB highlighting: no backslash escape in a plain string")
  func highlighterPlainString() {
    let text = #"SELECT 'C:\dir\', 'x'"#
    #expect(spans(text, .duckdb) == ["'C:\\dir\\'", "'x'"])
    #expect(spans(text, .sqlite) == ["'C:\\dir\\'", "'x'"])
    #expect(spans(text, .postgresql) == ["'C:\\dir\\', '"])
  }

  @Test("DuckDB highlighting: E-strings, dollar quotes and comments")
  func highlighterOtherBlocks() {
    let text = "SELECT E'a\\'b', $$x$$ -- c\n/* d */"
    #expect(spans(text, .duckdb) == ["E'a\\'b'", "$$x$$", "-- c", "/* d */"])
  }

  private func spans(_ text: String, _ dialect: SQLDialect) -> [String] {
    let ns = text as NSString
    return SQLSyntaxHighlighter.scanBlockSpans(
      in: ns, range: NSRange(location: 0, length: ns.length), dialect: dialect
    ).map { ns.substring(with: $0.range) }
  }

  // MARK: - Safe Mode LIKE check

  @Test("DuckDB decodes only E-strings in a LIKE operand")
  func likeBackslashRule() {
    #expect(!matchesAll(#"DELETE FROM t WHERE a LIKE '\x25'"#, .duckdb))
    #expect(matchesAll(#"DELETE FROM t WHERE a LIKE E'\x25'"#, .duckdb))
    #expect(matchesAll(#"DELETE FROM t WHERE a LIKE '%'"#, .duckdb))
  }

  @Test("PostgreSQL and SQLite LIKE backslash rules are unchanged")
  func likeBackslashRuleOthers() {
    #expect(matchesAll(#"DELETE FROM t WHERE a LIKE E'\x25'"#, .postgresql))
    #expect(!matchesAll(#"DELETE FROM t WHERE a LIKE '\x25'"#, .sqlite))
    #expect(matchesAll(#"DELETE FROM t WHERE a LIKE '%'"#, .sqlite))
  }

  private func matchesAll(_ sql: String, _ dialect: SQLDialect) -> Bool {
    NotebookViewModel.scriptMatchesAllRowsByLike(
      SQLStatementClassifier.classify(sql, dialect: dialect), parameters: [:], dialect: dialect)
  }

  // MARK: - EXPLAIN

  @Test("DuckDB EXPLAIN is text, with ANALYZE of a write rolled back")
  func duckdbExplain() throws {
    let plain = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: false, dialect: .duckdb)
    #expect(plain.wrappedSQL == "EXPLAIN SELECT 1")

    let update = #"UPDATE t SET b = '\xDE'::BLOB WHERE id = 1"#
    let analyzed = try ExplainRequest(
      statement: update, analyze: true, buffers: true, dialect: .duckdb)
    #expect(analyzed.wrappedSQL == "BEGIN; EXPLAIN ANALYZE \(update); ROLLBACK;")
  }

  @Test("A DuckDB statement with a backslash string is one statement")
  func duckdbExplainSplit() throws {
    let request = try ExplainRequest(
      statement: #"SELECT 'C:\'"#, analyze: false, buffers: false, dialect: .duckdb)
    #expect(request.statement == #"SELECT 'C:\'"#)
  }

  @Test("PostgreSQL and SQLite EXPLAIN prefixes are unchanged")
  func otherExplain() throws {
    let postgres = try ExplainRequest(statement: "SELECT 1", analyze: false, buffers: false)
    #expect(postgres.wrappedSQL == "EXPLAIN (FORMAT JSON) SELECT 1")
    let sqlite = try ExplainRequest(
      statement: "SELECT 1", analyze: false, buffers: false, dialect: .sqlite)
    #expect(sqlite.wrappedSQL == "EXPLAIN QUERY PLAN SELECT 1")
  }
}
