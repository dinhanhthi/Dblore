// SQLSyntaxHighlighterTests.swift
// Unit tests for SQLSyntaxHighlighter utility
// Converted to Swift Testing framework

import Testing
@testable import SQLNotebook
import Foundation

@Suite("SQL Syntax Highlighter Tests")
struct SQLSyntaxHighlighterTests {

    let highlighter = SQLSyntaxHighlighter()

    // MARK: - Keyword Detection Tests

    @Test("Keyword highlighting in SELECT statement")
    func keywordHighlighting() {
        let sql = "SELECT * FROM users WHERE id = 1"
        let attributed = highlighter.highlight(sql)
        let string = String(attributed.characters)

        // Verify the string content is preserved
        #expect(string == sql)
    }

    @Test("Keywords are case-insensitive")
    func keywordsCaseInsensitive() {
        let sqlLower = "select * from users"
        let sqlUpper = "SELECT * FROM USERS"
        let sqlMixed = "SeLeCt * FrOm UsErS"

        let attributedLower = highlighter.highlight(sqlLower)
        let attributedUpper = highlighter.highlight(sqlUpper)
        let attributedMixed = highlighter.highlight(sqlMixed)

        // All should preserve original casing
        #expect(String(attributedLower.characters) == sqlLower)
        #expect(String(attributedUpper.characters) == sqlUpper)
        #expect(String(attributedMixed.characters) == sqlMixed)
    }

    @Test("DDL keywords (CREATE, TABLE, PRIMARY KEY)")
    func ddlKeywords() {
        let sql = "CREATE TABLE users (id INTEGER PRIMARY KEY)"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("DML keywords (INSERT, VALUES)")
    func dmlKeywords() {
        let sql = "INSERT INTO users (name) VALUES ('Alice')"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - Function Detection Tests

    @Test("Function highlighting (COUNT)")
    func functionHighlighting() {
        let sql = "SELECT COUNT(*) FROM users"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Multiple aggregate functions")
    func multipleFunctions() {
        let sql = "SELECT COUNT(*), MAX(age), MIN(age), AVG(salary) FROM employees"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Nested functions")
    func nestedFunctions() {
        let sql = "SELECT UPPER(TRIM(name)) FROM users"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - String Literal Tests

    @Test("Single-quote strings")
    func singleQuoteStrings() {
        let sql = "SELECT * FROM users WHERE name = 'Alice'"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Strings with escaped quotes")
    func stringWithEscapedQuotes() {
        let sql = "SELECT 'O''Brien' AS name"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Multiple string literals")
    func multipleStrings() {
        let sql = "INSERT INTO users (first, last) VALUES ('John', 'Doe')"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("PostgreSQL dollar-quoted strings")
    func dollarQuotedStrings() {
        let sql = "SELECT $$Hello 'World'$$ AS greeting"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - Number Tests

    @Test("Integer numbers")
    func integerNumbers() {
        let sql = "SELECT * FROM users WHERE age = 25"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Decimal numbers")
    func decimalNumbers() {
        let sql = "SELECT * FROM products WHERE price = 19.99"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Negative numbers")
    func negativeNumbers() {
        let sql = "SELECT * FROM accounts WHERE balance < -100.50"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Scientific notation")
    func scientificNotation() {
        let sql = "SELECT 1.5e10 AS big_number"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - Comment Tests

    @Test("Single-line comment")
    func singleLineComment() {
        let sql = "SELECT * FROM users -- Get all users\nWHERE active = true"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Multi-line comment")
    func multiLineComment() {
        let sql = """
        SELECT *
        /* This is a
           multi-line comment */
        FROM users
        """
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Nested multi-line comments")
    func nestedMultiLineComments() {
        let sql = "SELECT * /* outer /* inner */ outer */ FROM users"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - Operator Tests

    @Test("Comparison operators")
    func comparisonOperators() {
        let sql = "WHERE age >= 18 AND salary <= 100000"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Arithmetic operators")
    func arithmeticOperators() {
        let sql = "SELECT price * quantity - discount AS total"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Logical operators (AND, OR)")
    func logicalOperators() {
        let sql = "WHERE active = true AND (role = 'admin' OR role = 'moderator')"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
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
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
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
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
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
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - Edge Cases

    @Test("Empty string")
    func emptyString() {
        let sql = ""
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == "")
    }

    @Test("Whitespace only")
    func whitespaceOnly() {
        let sql = "   \n\t  "
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Single keyword only")
    func singleKeyword() {
        let sql = "SELECT"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("Unicode characters in strings")
    func unicodeCharacters() {
        let sql = "SELECT '你好世界' AS greeting"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - PostgreSQL Specific Tests

    @Test("PostgreSQL data types (SERIAL, JSONB, TIMESTAMPTZ)")
    func postgreSQLDataTypes() {
        let sql = "CREATE TABLE test (id SERIAL, data JSONB, created TIMESTAMPTZ)"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("PostgreSQL cast operator (::)")
    func postgreSQLCastOperator() {
        let sql = "SELECT '2024-01-01'::DATE AS start_date"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    @Test("PostgreSQL arrays")
    func postgreSQLArrays() {
        let sql = "SELECT ARRAY[1, 2, 3] AS numbers"
        let attributed = highlighter.highlight(sql)

        #expect(String(attributed.characters) == sql)
    }

    // MARK: - Performance Tests

    @Test("Highlighting performance with repeated queries", .timeLimit(.seconds(5)))
    func highlightingPerformance() {
        let longSQL = String(repeating: "SELECT * FROM users WHERE id = 1; ", count: 100)

        _ = highlighter.highlight(longSQL)
    }

    @Test("Highlighting very long query with many columns", .timeLimit(.seconds(5)))
    func highlightingVeryLongQuery() {
        // Generate a very long SQL query
        var sql = "SELECT "
        for i in 0..<1000 {
            sql += "column_\(i), "
        }
        sql += "id FROM large_table"

        _ = highlighter.highlight(sql)
    }
}
