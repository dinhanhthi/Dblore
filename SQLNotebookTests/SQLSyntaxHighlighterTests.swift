// SQLSyntaxHighlighterTests.swift
// Unit tests for SQLSyntaxHighlighter utility
// Converted to Swift Testing framework

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SQLNotebook

@Suite("SQL Syntax Highlighter Tests")
@MainActor
struct SQLSyntaxHighlighterTests {

  // MARK: - Keyword Detection Tests

  @Test("Keyword highlighting in SELECT statement")
  func keywordHighlighting() {
    let sql = "SELECT * FROM users WHERE id = 1"
    let attributed = SQLSyntaxHighlighter.highlight(sql)
    let string = String(attributed.string)

    // Verify the string content is preserved
    #expect(string == sql)
  }

  @Test("Keywords are case-insensitive")
  func keywordsCaseInsensitive() {
    let sqlLower = "select * from users"
    let sqlUpper = "SELECT * FROM USERS"
    let sqlMixed = "SeLeCt * FrOm UsErS"

    let attributedLower = SQLSyntaxHighlighter.highlight(sqlLower)
    let attributedUpper = SQLSyntaxHighlighter.highlight(sqlUpper)
    let attributedMixed = SQLSyntaxHighlighter.highlight(sqlMixed)

    // All should preserve original casing
    #expect(String(attributedLower.string) == sqlLower)
    #expect(String(attributedUpper.string) == sqlUpper)
    #expect(String(attributedMixed.string) == sqlMixed)
  }

  @Test("DDL keywords (CREATE, TABLE, PRIMARY KEY)")
  func ddlKeywords() {
    let sql = "CREATE TABLE users (id INTEGER PRIMARY KEY)"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("DML keywords (INSERT, VALUES)")
  func dmlKeywords() {
    let sql = "INSERT INTO users (name) VALUES ('Alice')"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Function Detection Tests

  @Test("Function highlighting (COUNT)")
  func functionHighlighting() {
    let sql = "SELECT COUNT(*) FROM users"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Multiple aggregate functions")
  func multipleFunctions() {
    let sql = "SELECT COUNT(*), MAX(age), MIN(age), AVG(salary) FROM employees"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Nested functions")
  func nestedFunctions() {
    let sql = "SELECT UPPER(TRIM(name)) FROM users"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - String Literal Tests

  @Test("Single-quote strings")
  func singleQuoteStrings() {
    let sql = "SELECT * FROM users WHERE name = 'Alice'"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Strings with escaped quotes")
  func stringWithEscapedQuotes() {
    let sql = "SELECT 'O''Brien' AS name"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Multiple string literals")
  func multipleStrings() {
    let sql = "INSERT INTO users (first, last) VALUES ('John', 'Doe')"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("PostgreSQL dollar-quoted strings")
  func dollarQuotedStrings() {
    let sql = "SELECT $$Hello 'World'$$ AS greeting"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Number Tests

  @Test("Integer numbers")
  func integerNumbers() {
    let sql = "SELECT * FROM users WHERE age = 25"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Decimal numbers")
  func decimalNumbers() {
    let sql = "SELECT * FROM products WHERE price = 19.99"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Negative numbers")
  func negativeNumbers() {
    let sql = "SELECT * FROM accounts WHERE balance < -100.50"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Scientific notation")
  func scientificNotation() {
    let sql = "SELECT 1.5e10 AS big_number"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Comment Tests

  @Test("Single-line comment")
  func singleLineComment() {
    let sql = "SELECT * FROM users -- Get all users\nWHERE active = true"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Multi-line comment")
  func multiLineComment() {
    let sql = """
      SELECT *
      /* This is a
         multi-line comment */
      FROM users
      """
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Nested multi-line comments")
  func nestedMultiLineComments() {
    let sql = "SELECT * /* outer /* inner */ outer */ FROM users"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Operator Tests

  @Test("Comparison operators")
  func comparisonOperators() {
    let sql = "WHERE age >= 18 AND salary <= 100000"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Arithmetic operators")
  func arithmeticOperators() {
    let sql = "SELECT price * quantity - discount AS total"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Logical operators (AND, OR)")
  func logicalOperators() {
    let sql = "WHERE active = true AND (role = 'admin' OR role = 'moderator')"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Complex Query Tests

  @Test("Complex SELECT with JOINs and GROUP BY")
  func complexSelectQuery() {
    let sql = """
      SELECT
          u.id,
          u.name,
          COUNT(o.id) AS order_count,
          SUM(o.total) AS total_spent
      FROM users u
      LEFT JOIN orders o ON u.id = o.user_id
      WHERE u.created_at >= '2024-01-01'
      GROUP BY u.id, u.name
      HAVING COUNT(o.id) > 5
      ORDER BY total_spent DESC
      LIMIT 10
      """
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("CTE (Common Table Expression) query")
  func cteQuery() {
    let sql = """
      WITH active_users AS (
          SELECT * FROM users WHERE active = true
      )
      SELECT * FROM active_users
      WHERE created_at > NOW() - INTERVAL '30 days'
      """
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Subquery in WHERE clause")
  func subquery() {
    let sql = """
      SELECT name
      FROM users
      WHERE id IN (
          SELECT user_id FROM orders
          WHERE total > 1000
      )
      """
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Edge Cases

  @Test("Empty string")
  func emptyString() {
    let sql = ""
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == "")
  }

  @Test("Whitespace only")
  func whitespaceOnly() {
    let sql = "   \n\t  "
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Single keyword only")
  func singleKeyword() {
    let sql = "SELECT"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("Unicode characters in strings")
  func unicodeCharacters() {
    let sql = "SELECT '你好世界' AS greeting"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - PostgreSQL Specific Tests

  @Test("PostgreSQL data types (SERIAL, JSONB, TIMESTAMPTZ)")
  func postgreSQLDataTypes() {
    let sql = "CREATE TABLE test (id SERIAL, data JSONB, created TIMESTAMPTZ)"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("PostgreSQL cast operator (::)")
  func postgreSQLCastOperator() {
    let sql = "SELECT '2024-01-01'::DATE AS start_date"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  @Test("PostgreSQL arrays")
  func postgreSQLArrays() {
    let sql = "SELECT ARRAY[1, 2, 3] AS numbers"
    let attributed = SQLSyntaxHighlighter.highlight(sql)

    #expect(String(attributed.string) == sql)
  }

  // MARK: - Token Colors

  /// sRGB hex of a (dynamic) color; `NSColor(Color)` instances never compare equal
  private func hex(_ color: NSColor?) -> String? {
    guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
    return String(
      format: "%02X%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
      Int(rgb.blueComponent * 255), Int(rgb.alphaComponent * 255))
  }

  private func hex(_ color: Color) -> String? { hex(NSColor(color)) }

  /// Foreground color (sRGB hex) at the `occurrence`-th occurrence of `token`
  private func color(
    of token: String, in sql: String, occurrence: Int = 0
  ) -> String? {
    let attributed = SQLSyntaxHighlighter.highlight(sql)
    var range = (sql as NSString).range(of: token)
    for _ in 0..<occurrence {
      let start = range.upperBound
      range = (sql as NSString).range(
        of: token, range: NSRange(location: start, length: (sql as NSString).length - start))
    }
    return hex(
      attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
  }

  @Test("Token colors: keyword, function, type, number, string, identifier")
  func tokenColors() {
    let sql = "select count(id), x::int FROM t WHERE n = 42 AND s = 'abc'"
    #expect(color(of: "select", in: sql) == hex(Color.syntaxKeyword))
    #expect(color(of: "count", in: sql) == hex(Color.syntaxFunction))
    #expect(color(of: "int", in: sql) == hex(Color.syntaxFunction))
    #expect(color(of: "42", in: sql) == hex(Color.syntaxNumber))
    #expect(color(of: "'abc'", in: sql) == hex(Color.syntaxString))
    #expect(color(of: "id", in: sql) == hex(Color.foreground))
  }

  @Test("Keywords inside comments and strings keep the comment/string color")
  func keywordsInsideCommentsAndStrings() {
    let sql = "SELECT 1 -- FROM here\n/* WHERE 2 */ 'SELECT 3' $$COUNT(4)$$"
    #expect(color(of: "FROM", in: sql) == hex(Color.syntaxComment))
    #expect(color(of: "WHERE", in: sql) == hex(Color.syntaxComment))
    #expect(color(of: "2", in: sql) == hex(Color.syntaxComment))
    #expect(color(of: "SELECT", in: sql, occurrence: 1) == hex(Color.syntaxString))
    #expect(color(of: "COUNT", in: sql) == hex(Color.syntaxString))
  }

  @Test("Keywords only match whole words")
  func keywordsWholeWords() {
    let sql = "SELECT selection, inner_id FROM t INNER JOIN u ON true"
    #expect(color(of: "selection", in: sql) == hex(Color.foreground))
    #expect(color(of: "inner_id", in: sql) == hex(Color.foreground))
    #expect(color(of: "INNER", in: sql) == hex(Color.syntaxKeyword))
  }

  // MARK: - Performance Tests

  @Test("Highlighting performance with repeated queries", .timeLimit(.minutes(1)))
  func highlightingPerformance() {
    let longSQL = String(repeating: "SELECT * FROM users WHERE id = 1; ", count: 100)

    _ = SQLSyntaxHighlighter.highlight(longSQL)
  }

  @Test("Highlighting very long query with many columns", .timeLimit(.minutes(1)))
  func highlightingVeryLongQuery() {
    // Generate a very long SQL query
    var sql = "SELECT "
    for i in 0..<1000 {
      sql += "column_\(i), "
    }
    sql += "id FROM large_table"

    _ = SQLSyntaxHighlighter.highlight(sql)
  }
}
