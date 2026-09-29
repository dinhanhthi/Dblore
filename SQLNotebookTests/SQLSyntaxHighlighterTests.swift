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

  // MARK: - UTF-16 Coverage Tests

  private func components(_ color: NSColor?) -> [CGFloat]? {
    guard let c = color?.usingColorSpace(.sRGB) else { return nil }
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
  }

  @Test("Font covers every UTF-16 unit with emoji/CJK")
  func fontCoversEveryUTF16Unit() {
    let sql = "SELECT '😀日本' AS a, 😀😀😀 FROM t WHERE x = 1"
    let attributed = withSyntaxHighlightingEnabled { SQLSyntaxHighlighter.highlight(sql) }
    let length = (sql as NSString).length
    #expect(attributed.length == length)
    for i in 0..<length {
      #expect(attributed.attribute(.font, at: i, effectiveRange: nil) != nil)
    }
  }

  @Test("String color covers the full string containing emoji")
  func stringColorCoversEmojiString() {
    let sql = "SELECT '😀日本' FROM t"
    let attributed = withSyntaxHighlightingEnabled { SQLSyntaxHighlighter.highlight(sql) }
    let literal = NSRange(location: 7, length: ("'😀日本'" as NSString).length)
    let expected = components(NSColor(Color.syntaxString))
    for i in literal.location..<NSMaxRange(literal) {
      #expect(
        components(attributed.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor)
          == expected)
    }
  }

  @Test("plainText covers full UTF-16 length")
  func plainTextCoversFullLength() {
    let settings = AppSettings.shared
    let previous = settings.syntaxHighlightingEnabled
    settings.syntaxHighlightingEnabled = false
    defer { settings.syntaxHighlightingEnabled = previous }

    let sql = "SELECT '😀日本' FROM t"
    let attributed = SQLSyntaxHighlighter.highlight(sql)
    let length = (sql as NSString).length
    for i in 0..<length {
      #expect(attributed.attribute(.font, at: i, effectiveRange: nil) != nil)
    }
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

  // MARK: - Equivalence with the original regexes

  private static let oldBlockRegex = try! NSRegularExpression(
    pattern: "--[^\n]*|/\\*[\\s\\S]*?\\*/|'(?:[^'\\\\]|\\\\.)*'|\\$\\$[\\s\\S]*?\\$\\$")
  private static let oldNumberRegex = try! NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b")

  private func randomStrings(
    count: Int, alphabet: [String], maxLength: Int, seed: UInt64
  )
    -> [String]
  {
    var rng = SeededGenerator(seed: seed)
    return (0..<count).map { _ in
      let length = Int(rng.next() % UInt64(maxLength + 1))
      return (0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }.joined()
    }
  }

  @Test("block scanner matches the original regex on random inputs and sub-ranges")
  func blockScannerMatchesOldRegex() {
    let alphabet = [
      "/", "*", "-", "'", "\\", "$", "\n", "\r", "a", "1", " ", "\u{2028}", "\u{1F600}",
    ]
    var rng = SeededGenerator(seed: 7)
    for text in randomStrings(count: 4000, alphabet: alphabet, maxLength: 40, seed: 42) {
      let ns = text as NSString
      // sub-range ends never split a surrogate pair (real ranges are paragraph-aligned)
      func aligned(_ i: Int) -> Int {
        i < ns.length && (0xDC00...0xDFFF).contains(ns.character(at: i)) ? i - 1 : i
      }
      let lo = ns.length == 0 ? 0 : aligned(Int(rng.next() % UInt64(ns.length + 1)))
      let hi = max(lo, aligned(lo + Int(rng.next() % UInt64(ns.length - lo + 1))))
      for range in [
        NSRange(location: 0, length: ns.length), NSRange(location: lo, length: hi - lo),
      ] {
        var expected: [NSRange] = []
        Self.oldBlockRegex.enumerateMatches(in: text, options: [], range: range) { m, _, _ in
          if let r = m?.range { expected.append(r) }
        }
        let actual = SQLSyntaxHighlighter.scanBlockSpans(in: ns, range: range)
        #expect(actual.map(\.range) == expected, "text \(text.debugDescription) range \(range)")
        for block in actual {
          let first = ns.character(at: block.range.location)
          #expect(block.isComment == (first == 0x2D || first == 0x2F))
        }
      }
    }
  }

  @Test("number regex matches the original on a table and on random inputs")
  func numberRegexMatchesOld() {
    let table = ["12abc", "1.", "1.5.3", "1.a", "1.5a", "42", "t1", "1.5", "a1.5b", "0.", "7.7.7"]
    let random = randomStrings(
      count: 4000, alphabet: ["1", "2", ".", "a", "_", " ", "-"], maxLength: 14, seed: 3)
    for text in table + random {
      let full = NSRange(location: 0, length: (text as NSString).length)
      func matches(_ regex: NSRegularExpression) -> [NSRange] {
        regex.matches(in: text, options: [], range: full).map(\.range)
      }
      #expect(
        matches(SQLSyntaxHighlighter.numberRegex) == matches(Self.oldNumberRegex),
        "text \(text.debugDescription)")
    }
  }
}
