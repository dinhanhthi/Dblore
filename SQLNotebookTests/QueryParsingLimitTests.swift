// QueryParsingLimitTests.swift
// Tests for LIMIT extraction and wrapping functionality

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Query Parsing - LIMIT Tests")
@MainActor
struct QueryParsingLimitTests {

  // MARK: - extractLimitValue Tests

  @Suite("extractLimitValue - Detecting LIMIT")
  struct ExtractLimitValueTests {

    @Test("Query without LIMIT returns nil")
    func queryWithoutLimitReturnsNil() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users"
      let result = manager.extractLimitValue(query)
      #expect(result == nil, "Should return nil for query without LIMIT")
    }

    @Test("Query with LIMIT returns value")
    func queryWithLimitReturnsValue() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users LIMIT 50"
      let result = manager.extractLimitValue(query)
      #expect(result == 50, "Should extract LIMIT 50")
    }

    @Test("LIMIT in comment is ignored")
    func limitInCommentIsIgnored() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 100\nSELECT * FROM users"
      let result = manager.extractLimitValue(query)
      #expect(result == nil, "Should ignore LIMIT in comment")
    }

    @Test("LIMIT in string literal is NOT ignored (known limitation)")
    func limitInStringLiteralNotIgnored() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT 'LIMIT 50' FROM users"
      let result = manager.extractLimitValue(query)
      #expect(result == 50, "Current implementation detects LIMIT in strings (known limitation)")
    }

    @Test("Query with actual LIMIT after comment")
    func queryWithLimitAfterComment() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- comment\nSELECT * FROM users LIMIT 25"
      let result = manager.extractLimitValue(query)
      #expect(result == 25, "Should extract actual LIMIT 25")
    }

    @Test("LIMIT with large value")
    func limitWithLargeValue() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users LIMIT 999999"
      let result = manager.extractLimitValue(query)
      #expect(result == 999999, "Should extract large LIMIT value")
    }

    @Test("LIMIT with value 0")
    func limitWithZeroValue() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users LIMIT 0"
      let result = manager.extractLimitValue(query)
      #expect(result == 0, "Should extract LIMIT 0")
    }

    @Test("LIMIT case insensitive")
    func limitCaseInsensitive() throws {
      let manager = DatabaseConnectionManager()
      let query = "select * from users limit 42"
      let result = manager.extractLimitValue(query)
      #expect(result == 42, "Should extract LIMIT regardless of case")
    }

    @Test("LIMIT with trailing semicolon")
    func limitWithTrailingSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users LIMIT 30;"
      let result = manager.extractLimitValue(query)
      #expect(result == 30, "Should extract LIMIT before semicolon")
    }

    @Test("Multiple LIMIT in comments ignored, only actual LIMIT extracted")
    func multipleLimitInCommentsIgnored() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 100\n/* LIMIT 200 */ SELECT * FROM users LIMIT 15"
      let result = manager.extractLimitValue(query)
      #expect(result == 15, "Should extract only actual LIMIT 15")
    }

    @Test("LIMIT without trailing semicolon is extracted")
    func limitWithoutTrailingSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot LIMIT 10"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 without semicolon")
    }

    @Test("LIMIT in multi-statement query (first statement)")
    func limitInMultiStatementFirst() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot LIMIT 10;\nSELECT * FROM users"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 from first statement")
    }

    @Test("LIMIT in multi-statement query (second statement)")
    func limitInMultiStatementSecond() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM autoupdate;\nSELECT * FROM bot LIMIT 10"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 from second statement")
    }

    @Test("LIMIT in multi-statement query (second statement with semicolon)")
    func limitInMultiStatementSecondWithSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM autoupdate;\nSELECT * FROM bot LIMIT 10;"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 from second statement with semicolon")
    }
  }

  // MARK: - extractLimitValue Edge Cases for Pagination Bug

  @Suite("extractLimitValue - Pagination Bug Scenarios")
  struct ExtractLimitValuePaginationBugTests {

    @Test("Single SELECT with LIMIT and semicolon")
    func singleSelectWithLimitAndSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot LIMIT 10;"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 with semicolon")
    }

    @Test("Single SELECT with LIMIT without semicolon")
    func singleSelectWithLimitWithoutSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot LIMIT 10"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 without semicolon")
    }

    @Test("Split statement loses semicolon but keeps LIMIT")
    func splitStatementKeepsLimit() throws {
      let manager = DatabaseConnectionManager()
      let originalQuery = "SELECT * FROM bot LIMIT 10;"

      let statements = manager.splitSQLStatements(originalQuery)
      #expect(statements.count == 1, "Should have 1 statement")

      let statement = statements[0]
      #expect(!statement.hasSuffix(";"), "Split statement should not have trailing semicolon")

      let result = manager.extractLimitValue(statement)
      #expect(result == 10, "Should extract LIMIT 10 from split statement")
    }

    @Test("Multi-statement: second statement with LIMIT (no semicolon)")
    func multiStatementSecondWithLimitNoSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let fullQuery = "SELECT * FROM autoupdate;\nSELECT * FROM bot LIMIT 10"

      let statements = manager.splitSQLStatements(fullQuery)
      #expect(statements.count == 2, "Should have 2 statements")

      let secondStatement = statements[1]
      let result = manager.extractLimitValue(secondStatement)
      #expect(result == 10, "Should extract LIMIT 10 from second statement")
    }

    @Test("Multi-statement: second statement with LIMIT (with semicolon)")
    func multiStatementSecondWithLimitWithSemicolon() throws {
      let manager = DatabaseConnectionManager()
      let fullQuery = "SELECT * FROM autoupdate;\nSELECT * FROM bot LIMIT 10;"

      let statements = manager.splitSQLStatements(fullQuery)
      #expect(statements.count == 2, "Should have 2 statements")

      let secondStatement = statements[1]
      let result = manager.extractLimitValue(secondStatement)
      #expect(result == 10, "Should extract LIMIT 10 from second statement")
    }

    @Test("Complex query: LIMIT with WHERE and ORDER BY")
    func complexQueryWithLimit() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot WHERE id > 100 ORDER BY name LIMIT 10"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 from complex query")
    }

    @Test("Complex query with whitespace before LIMIT")
    func complexQueryWithWhitespaceBeforeLimit() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot WHERE id > 100    \n   LIMIT    10"
      let result = manager.extractLimitValue(query)
      #expect(result == 10, "Should extract LIMIT 10 with extra whitespace")
    }

    @Test("Query with LIMIT and trailing semicolon for COUNT")
    func queryWithLimitAndSemicolonForCount() throws {
      let query = "SELECT * FROM bot LIMIT 10;"

      var result = query
      result = result.replacingOccurrences(
        of: "\\s+LIMIT\\s+\\d+", with: "", options: [.regularExpression, .caseInsensitive])
      result = result.trimmingCharacters(in: .whitespacesAndNewlines)

      if result.hasSuffix(";") {
        result = String(result.dropLast())
      }
      result = result.trimmingCharacters(in: .whitespacesAndNewlines)

      #expect(result == "SELECT * FROM bot", "Should remove both LIMIT and semicolon")
      #expect(!result.contains(";"), "Result should not contain semicolon")

      let countQuery = "SELECT COUNT(*) FROM (\(result)) AS _count_query"
      #expect(
        countQuery == "SELECT COUNT(*) FROM (SELECT * FROM bot) AS _count_query",
        "COUNT query should be valid SQL")
    }
  }

  // MARK: - wrapQueryWithLimit Tests - Comment Stripping

  @Suite("wrapQueryWithLimit - Comment Stripping (CRITICAL)")
  struct WrapQueryWithLimitCommentStrippingTests {

    @Test("Query with leading comments has NO comments in result")
    func leadingCommentsRemoved() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 3\nSELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("--"), "Result should not contain single-line comment marker")
      #expect(!result.contains("/*"), "Result should not contain multi-line comment marker")
      #expect(result.contains("SELECT * FROM bot"), "Should preserve SQL")
      #expect(result.contains("LIMIT 4"), "Should append LIMIT 4")

      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with trailing comments has NO comments in result")
    func trailingCommentsRemoved() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot -- comment"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("--"), "Result should not contain comment marker")
      #expect(!result.contains("comment"), "Result should not contain comment text")
      #expect(result.contains("SELECT * FROM bot"), "Should preserve SQL")
      #expect(result.contains("LIMIT 4"), "Should append LIMIT 4")
    }

    @Test("Query with multiple comments has NO comments in result")
    func multipleCommentsRemoved() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- c1\n-- c2\nSELECT * FROM bot\n-- c3"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("--"), "Result should not contain any comment markers")
      #expect(!result.contains("c1"), "Should remove c1 comment")
      #expect(!result.contains("c2"), "Should remove c2 comment")
      #expect(!result.contains("c3"), "Should remove c3 comment")
      #expect(result.contains("SELECT * FROM bot"), "Should preserve SQL")
      #expect(result.contains("LIMIT 4"), "Should append LIMIT 4")

      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with LIMIT in comment should add actual LIMIT")
    func limitInCommentShouldAddActualLimit() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 100\nSELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("--"), "Result should not contain comment marker")
      #expect(!result.contains("LIMIT 100"), "Should not preserve LIMIT from comment")
      #expect(result.contains("LIMIT 4"), "Should add actual LIMIT 4")

      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with actual LIMIT should replace it")
    func actualLimitShouldBeReplaced() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot LIMIT 100"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(result.contains("LIMIT 4"), "Should replace with LIMIT 4")
      #expect(!result.contains("LIMIT 100"), "Should not keep original LIMIT 100")
    }

    @Test("Query with both comment LIMIT and no actual LIMIT")
    func commentLimitAndNoActualLimit() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 3\n-- LIMIT 5\nSELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("--"), "Result should not contain comment markers")
      #expect(!result.contains("LIMIT 3"), "Should remove LIMIT 3 from comment")
      #expect(!result.contains("LIMIT 5"), "Should remove LIMIT 5 from comment")
      #expect(result.contains("LIMIT 4"), "Should add actual LIMIT 4")

      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with multi-line comment containing LIMIT")
    func multiLineCommentContainingLimit() async throws {
      let manager = DatabaseConnectionManager()
      let query = "/* LIMIT 50 */ SELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("/*"), "Result should not contain multi-line comment marker")
      #expect(!result.contains("*/"), "Result should not contain multi-line comment closer")
      #expect(!result.contains("LIMIT 50"), "Should not preserve LIMIT from comment")
      #expect(result.contains("LIMIT 4"), "Should add actual LIMIT 4")
    }

    @Test("Query with inline comments between keywords")
    func inlineCommentsBetweenKeywords() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT /* c1 */ * /* c2 */ FROM /* c3 */ bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      #expect(!result.contains("/*"), "Result should not contain comment markers")
      #expect(!result.contains("c1"), "Should remove c1 comment")
      #expect(!result.contains("c2"), "Should remove c2 comment")
      #expect(!result.contains("c3"), "Should remove c3 comment")
      #expect(result.contains("SELECT"), "Should preserve SELECT")
      #expect(result.contains("FROM"), "Should preserve FROM")
      #expect(result.contains("bot"), "Should preserve table name")
      #expect(result.contains("LIMIT 4"), "Should append LIMIT 4")
    }
  }

  // MARK: - hasLimitClause Tests

  @Suite("hasLimitClause - Detection")
  struct HasLimitClauseTests {

    @Test("Query without LIMIT returns false")
    func queryWithoutLimitReturnsFalse() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users"
      let result = await manager.hasLimitClause(query)
      #expect(result == false, "Should return false for query without LIMIT")
    }

    @Test("Query with LIMIT returns true")
    func queryWithLimitReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users LIMIT 50"
      let result = await manager.hasLimitClause(query)
      #expect(result == true, "Should return true for query with LIMIT")
    }

    @Test("LIMIT in comment only returns false")
    func limitInCommentOnlyReturnsFalse() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 50\nSELECT * FROM users"
      let result = await manager.hasLimitClause(query)
      #expect(result == false, "Should not detect LIMIT that only appears in comment")
    }

    @Test("LIMIT in string returns true (limitation)")
    func limitInStringReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT 'LIMIT 50' FROM users"
      let result = await manager.hasLimitClause(query)
      #expect(result == true, "Current implementation detects LIMIT in strings (known limitation)")
    }

    @Test("LIMIT case insensitive")
    func limitCaseInsensitive() async throws {
      let manager = DatabaseConnectionManager()
      let query = "select * from users limit 10"
      let result = await manager.hasLimitClause(query)
      #expect(result == true, "Should detect LIMIT regardless of case")
    }

    @Test("Word boundary detection - 'LIMITED' should not match")
    func wordBoundaryDetection() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM limited_users"
      let result = await manager.hasLimitClause(query)
      #expect(result == false, "Should not match LIMIT in 'limited_users' due to word boundary")
    }
  }
}
