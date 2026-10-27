// SQLFormatterTests.swift
// Tests for the SQL formatter behind the editor's Format button

import Foundation
import Testing

@testable import Dblore

@Suite("SQL Formatter Tests")
struct SQLFormatterTests {

  @Test("Clauses start a line, SELECT items align, joins put ON below")
  func formatsQuery() {
    let sql = """
      SELECT a.id, a.bot, a.method, a.candelete, a.canupdate,
               COUNT(d.id) AS ndocs,
               last_run.status AS last_status, last_run.info AS last_info
        FROM autoupdate a
        LEFT JOIN document d
               ON d.bot = a.bot AND d.sourcetype = 'auto_' || a.method || '_' || a.id
        LEFT JOIN LATERAL (
            SELECT status, info FROM useraction u
            WHERE u.autoupdate = a.id ORDER BY u.create_time DESC LIMIT 1
        ) last_run ON true
        WHERE a.type = 'documents'
          -- AND a.method = 'sharepoint'
        GROUP BY a.id, a.bot, a.method, a.candelete, a.canupdate, last_run.status, last_run.info
        HAVING COUNT(d.id) > 0
        ORDER BY ndocs ASC
        LIMIT 20;
      """
    let expected = """
      SELECT a.id,
             a.bot,
             a.method,
             a.candelete,
             a.canupdate,
             COUNT(d.id) AS ndocs,
             last_run.status AS last_status,
             last_run.info AS last_info
      FROM autoupdate a
      LEFT JOIN document d
        ON d.bot = a.bot AND d.sourcetype = 'auto_' || a.method || '_' || a.id
      LEFT JOIN LATERAL (
        SELECT status,
               info
        FROM useraction u
        WHERE u.autoupdate = a.id
        ORDER BY u.create_time DESC
        LIMIT 1
      ) last_run
        ON TRUE
      WHERE a.type = 'documents'
      -- AND a.method = 'sharepoint'
      GROUP BY a.id, a.bot, a.method, a.candelete, a.canupdate, last_run.status, last_run.info
      HAVING COUNT(d.id) > 0
      ORDER BY ndocs ASC
      LIMIT 20;
      """
    #expect(SQLFormatter.format(sql) == expected)
    #expect(SQLFormatter.format(expected) == expected)
  }

  @Test("Literals, quoted identifiers and trailing comments are kept verbatim")
  func keepsLiteralsAndComments() {
    let sql = "select 'from x, y' as \"Order\", -- first\ncount(*) -- total\nfrom t /* keep */"
    #expect(
      SQLFormatter.format(sql)
        == "SELECT 'from x, y' AS \"Order\", -- first\n       count(*) -- total\nFROM t /* keep */"
    )
  }

  @Test("Formatting is idempotent")
  func isIdempotent() {
    let sql =
      "-- report\nwith c as (select a, b from t where x between 1 and 2) select * from c left join d on d.a = c.a; update t set a = 1, b = 'x' where id = 3;"
    let once = SQLFormatter.format(sql)
    #expect(SQLFormatter.format(once) == once)
  }

  @Test("A line comment ending in a combining mark still ends the line")
  func keepsLineCommentWithCombiningMark() {
    let output = SQLFormatter.format("select 1 --\u{301}\n+ 2")
    #expect(Array(output.unicodeScalars) == Array("SELECT 1 --\u{301}\n+ 2".unicodeScalars))
  }

  @Test("Words with non-ASCII look-alikes are not keywords")
  func ignoresNonASCIIKeywordLookalikes() {
    let output = SQLFormatter.format("select li\u{212A}e")
    #expect(Array(output.unicodeScalars) == Array("SELECT li\u{212A}e".unicodeScalars))
  }

  @Test("Newline-separated string constants stay on separate lines")
  func keepsStringContinuation() {
    #expect(SQLFormatter.format("select 'foo'\n'bar'") == "SELECT 'foo'\n'bar'")
  }

  @Test("Dollar quotes and escape strings are kept verbatim")
  func keepsDollarQuotesAndEscapeStrings() {
    let sql = "select $tag$ a,  from $tag$, e'x\\' y'"
    #expect(SQLFormatter.format(sql) == "SELECT $tag$ a,  from $tag$,\n       e'x\\' y'")
  }

  @Test("Plain strings containing a backslash are returned unchanged")
  func keepsBackslashStrings() {
    let sql = "select 'a\\', b'"
    #expect(SQLFormatter.format(sql) == sql)
  }

  @Test("Indent and case options change only indentation and word case")
  func appliesIndentAndCaseOptions() {
    let sql = "select a, count(x) from t where id in (select id, name from u)"
    var options = SQLFormatter.Options()
    options.indent = .tab
    options.keywordCase = .lower
    options.functionCase = .upper
    #expect(
      SQLFormatter.format(sql, options: options)
        == "select a,\n       COUNT(x)\nfrom t\nwhere id in (\n\tselect id,\n\t       name\n\tfrom u\n)"
    )
    options.indent = .spaces(4)
    options.keywordCase = .preserve
    options.functionCase = .preserve
    #expect(
      SQLFormatter.format("Select a from t where id in (select id from u)", options: options)
        == "Select a\nfrom t\nwhere id in (\n    select id\n    from u\n)"
    )
  }

  @Test("Function case leaves a table name before its column list")
  func keepsTableNameCase() {
    var options = SQLFormatter.Options()
    options.functionCase = .upper
    #expect(
      SQLFormatter.format("insert into t(a) values (lower(x))", options: options)
        == "INSERT INTO t(a)\nVALUES (LOWER(x))")
  }

  @Test("Leading commas break before the comma, except before a trailing line comment")
  func placesLeadingCommas() {
    var options = SQLFormatter.Options()
    options.commaPosition = .leading
    let expected = "SELECT a\n     , b, -- note\n       c\nFROM t\nGROUP BY a, b"
    #expect(
      SQLFormatter.format("select a, b, -- note\n c from t group by a, b", options: options)
        == expected)
    #expect(SQLFormatter.format(expected, options: options) == expected)
  }

  @Test("Lines wider than the limit wrap at commas, AND and OR, not inside BETWEEN")
  func wrapsLongLines() {
    let sql =
      "select a from t where alpha = 1 and beta = 2 and gamma between 1 and 3 group by alpha, beta, gamma, delta"
    var options = SQLFormatter.Options()
    options.maxLineWidth = 30
    let expected = """
      SELECT a
      FROM t
      WHERE alpha = 1 AND beta = 2
        AND gamma BETWEEN 1 AND 3
      GROUP BY alpha, beta, gamma,
        delta
      """
    #expect(SQLFormatter.format(sql, options: options) == expected)
    #expect(SQLFormatter.format(expected, options: options) == expected)
    options.commaPosition = .leading
    #expect(
      SQLFormatter.format(sql, options: options).hasSuffix("GROUP BY alpha, beta, gamma\n  , delta")
    )
  }

  @Test("The safety net ignores keyword and function case but rejects other token changes")
  func comparesTokens() {
    #expect(
      SQLFormatter.hasSameTokens(
        "select count(x) from t", "SELECT COUNT(x) FROM t", dialect: .postgresql))
    #expect(!SQLFormatter.hasSameTokens("select a from t", "select a from u", dialect: .postgresql))
    #expect(!SQLFormatter.hasSameTokens("select a, b", "select a b", dialect: .postgresql))
  }

  @Test("Parameters and qualified names keep their case under any keyword case")
  func keepsParameterAndQualifiedNameCase() {
    let sql = "select t.first from t where id = :first and k = :Key"
    var options = SQLFormatter.Options()
    #expect(
      SQLFormatter.format(sql, options: options)
        == "SELECT t.first\nFROM t\nWHERE id = :first AND k = :Key")
    options.keywordCase = .lower
    #expect(
      SQLFormatter.format(
        sql.uppercased().replacingOccurrences(of: ":KEY", with: ":Key"), options: options)
        == "select T.FIRST\nfrom T\nwhere ID = :FIRST and K = :Key")
  }

  @Test("Function case re-cases only known function names, never table names")
  func recasesOnlyKnownFunctions() {
    var options = SQLFormatter.Options()
    options.functionCase = .lower
    let tables = [
      "CREATE INDEX i ON MyTable(a)", "INSERT INTO shop.MyTable(a)\nVALUES (Lower(b))",
      "INSERT INTO shop.Rank(a)\nVALUES (Lower(b))",
      "CREATE UNIQUE INDEX i ON Lead((Lower(email)))", "CREATE INDEX ON Rank((Lower(a)))",
      "COPY Rank(a, b)\nFROM 'x'\nWHERE Lower(a) = 'y'",
      "ANALYZE Count(a);\n\nVACUUM Rank(a);\n\nSELECT Lower(x)\nFROM t",
      "INSERT IGNORE Rank(a)\nVALUES (Lower(b))", "INSERT LOW_PRIORITY Lead(a)\nVALUES (Lower(b))",
      "INSERT DELAYED Count(a)\nVALUES (Lower(b))",
      "INSERT HIGH_PRIORITY Rank(a)\nVALUES (Lower(b))", "REPLACE Rank(a)\nVALUES (Lower(b))",
      "REPLACE INTO Lead(a)\nVALUES (Lower(b))",
    ]
    for sql in tables {
      #expect(
        SQLFormatter.format(sql, dialect: .mysql, options: options)
          == sql.replacingOccurrences(of: "Lower(", with: "lower("))
    }
    let cte = SQLFormatter.format(
      "WITH a AS (SELECT 1), Rank(x) AS (SELECT COUNT(y) FROM t) SELECT Lower(x) FROM Rank",
      dialect: .mysql, options: options)
    #expect(
      cte
        == "WITH a AS (\n  SELECT 1\n), Rank(x) AS (\n  SELECT count(y)\n  FROM t\n)\nSELECT lower(x)\nFROM Rank"
    )
    let calls = SQLFormatter.format(
      "SELECT Count(*) AS n, Rank() OVER (ORDER BY a) FROM t", dialect: .mysql, options: options)
    #expect(calls == "SELECT count(*) AS n,\n       rank() OVER (ORDER BY a)\nFROM t")
  }

  @Test("Fresh settings give the default formatter options")
  @MainActor
  func settingsDefaultToDefaultOptions() throws {
    let name = "SQLFormatterTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    #expect(AppSettings(defaults: suite).formatterOptions == SQLFormatter.Options.default)
  }

  @Test("The safety net rejects a word whose case changed unless it is a keyword or function")
  func rejectsIdentifierCaseChange() {
    #expect(!SQLFormatter.hasSameTokens("select a from t", "select A from t", dialect: .postgresql))
    #expect(!SQLFormatter.hasSameTokens("select :first", "select :FIRST", dialect: .postgresql))
    #expect(!SQLFormatter.hasSameTokens("select :limit", "select : limit", dialect: .postgresql))
  }

  @Test("A wrap never splits a parameter from its colon")
  func doesNotWrapInsideParameter() {
    var options = SQLFormatter.Options()
    options.maxLineWidth = 20
    let output = SQLFormatter.format(
      "select a from t where alpha = 1 and beta = :or", options: options)
    #expect(output == "SELECT a\nFROM t\nWHERE alpha = 1\n  AND beta = :or")
  }

  @Test("Clause keywords after a dot are names and stay inline")
  func keepsQualifiedClauseWordsInline() {
    let sql =
      "SELECT o.order, plan.limit FROM o JOIN plan ON o.id = plan.id ORDER BY o.order LIMIT 5"
    let expected =
      "SELECT o.order,\n       plan.limit\nFROM o\nJOIN plan\n  ON o.id = plan.id\nORDER BY o.order\nLIMIT 5"
    #expect(SQLFormatter.format(sql) == expected)
    #expect(SQLFormatter.format(expected) == expected)
  }
}
