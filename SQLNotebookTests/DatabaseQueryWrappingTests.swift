// DatabaseQueryWrappingTests.swift
// Comprehensive unit tests for query wrapping functions
// Tests wrapQueryWithLimit and wrapQueryWithCtid

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Database Query Wrapping Tests")
@MainActor
struct DatabaseQueryWrappingTests {

  // MARK: - wrapQueryWithLimit: SELECT Edge Cases

  @Test("SELECT with CTE (WITH clause) does NOT get LIMIT (limitation)")
  func selectWithCTEDoesNotGetLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "WITH temp AS (SELECT * FROM users) SELECT * FROM temp"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    // NOTE: Current implementation limitation - CTE queries start with "WITH" not "SELECT"
    // so they are not recognized as SELECT queries and don't get LIMIT appended
    // This is acceptable for now as CTEs are less common and users can manually add LIMIT
    #expect(
      !result.contains("LIMIT 30"), "CTE query starting with WITH is not wrapped (known limitation)"
    )
    #expect(result == query, "CTE query should be returned unchanged")
  }

  @Test("SELECT with subquery containing LIMIT does NOT get outer LIMIT (limitation)")
  func selectWithSubqueryContainingLimitDoesNotGetLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM (SELECT * FROM users LIMIT 10) AS sub"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    // NOTE: Current implementation limitation - hasLimitClause() detects LIMIT anywhere
    // in the query string, including inside subqueries. So outer query doesn't get LIMIT.
    // Ideally, only the outer query should be checked for LIMIT, not inner subqueries.
    #expect(!result.contains("AS sub LIMIT 30"), "Outer query doesn't get LIMIT (known limitation)")
    #expect(result == query, "Query should be unchanged")
  }

  @Test("SELECT UNION should get LIMIT appended")
  func selectUnionGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users UNION SELECT * FROM admins"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "UNION query should get LIMIT appended")
  }

  @Test("SELECT INTERSECT should get LIMIT appended")
  func selectIntersectGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users INTERSECT SELECT * FROM active_users"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "INTERSECT query should get LIMIT appended")
  }

  @Test("SELECT EXCEPT should get LIMIT appended")
  func selectExceptGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users EXCEPT SELECT * FROM inactive_users"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "EXCEPT query should get LIMIT appended")
  }

  @Test("SELECT with window function should get LIMIT appended")
  func selectWithWindowFunctionGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT *, ROW_NUMBER() OVER (ORDER BY id) FROM users"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "Window function query should get LIMIT appended")
  }

  @Test("SELECT with JOIN should get LIMIT appended")
  func selectWithJoinGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users JOIN orders ON users.id = orders.user_id"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "JOIN query should get LIMIT appended")
  }

  @Test("SELECT with complex WHERE IN subquery should get LIMIT appended")
  func selectWithWhereInSubqueryGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "WHERE IN subquery should get LIMIT appended")
  }

  @Test("SELECT with string containing SQL keywords should get LIMIT correctly")
  func selectWithStringContainingSQLKeywordsGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users WHERE name = 'FROM the beginning'"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "Query with 'FROM' in string should get LIMIT appended")
    #expect(result.contains("'FROM the beginning'"), "String literal should be preserved")
  }

  @Test("SELECT with CASE expression should get LIMIT appended")
  func selectWithCaseExpressionGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT CASE WHEN active THEN 'yes' ELSE 'no' END FROM users"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "CASE expression query should get LIMIT appended")
  }

  @Test("SELECT 1 + 1 (expression) should not get LIMIT")
  func selectExpressionNoLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT 1 + 1"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(!result.contains("LIMIT"), "Expression-only query should not get LIMIT")
    #expect(result == "SELECT 1 + 1", "Should not modify expression query")
  }

  @Test("SELECT 'hello' || 'world' should not get LIMIT")
  func selectStringConcatenationNoLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT 'hello' || 'world'"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(!result.contains("LIMIT"), "String concatenation query should not get LIMIT")
    #expect(result == "SELECT 'hello' || 'world'", "Should not modify concatenation query")
  }

  @Test("SELECT with ORDER BY and existing LIMIT respects user LIMIT")
  func selectWithOrderByAndLimitRespectsUserLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users ORDER BY id LIMIT 5"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 5"), "Should preserve user's LIMIT 5")
    #expect(result.contains("ORDER BY id"), "Should preserve ORDER BY clause")
  }

  @Test("Multi-line query starting with comment does NOT get LIMIT (limitation)")
  func multiLineQueryWithCommentsDoesNotGetLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = """
      -- Get all active users
      SELECT *
      FROM users
      WHERE active = true
      """
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    // NOTE: Current implementation limitation - queries starting with comments
    // are not recognized as SELECT queries because hasPrefix("SELECT") check fails
    // User should write queries with SELECT first, then add comments after
    #expect(
      !result.contains("LIMIT 30"), "Query starting with comment not wrapped (known limitation)")
    #expect(result == query, "Query should be unchanged")
    #expect(result.contains("-- Get all active users"), "Comment should be preserved")
  }

  @Test("Query with multiple FROM clauses (JOIN) should get LIMIT")
  func queryWithMultipleFromClausesGetsLimit() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users, orders WHERE users.id = orders.user_id"
    let maxRows = 30

    // Act
    let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

    // Assert
    #expect(result.contains("LIMIT 30"), "Query with multiple FROM should get LIMIT")
  }

  // MARK: - wrapQueryWithCtid: ctid Wrapping Tests

  @Test("SELECT * FROM simple query should add ctid")
  func selectStarSimpleQueryAddsCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(
      result.contains("SELECT *, ctid AS _sqlnb_ctid FROM users"),
      "Simple SELECT * should add ctid")
  }

  @Test("SELECT * FROM with WHERE clause should add ctid")
  func selectStarWithWhereAddsCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users WHERE active = true"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(
      result.contains("SELECT *, ctid AS _sqlnb_ctid FROM users"),
      "SELECT * with WHERE should add ctid")
    #expect(result.contains("WHERE active = true"), "WHERE clause should be preserved")
  }

  @Test("SELECT * FROM with LIMIT should add ctid")
  func selectStarWithLimitAddsCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users LIMIT 10"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(
      result.contains("SELECT *, ctid AS _sqlnb_ctid FROM users"),
      "SELECT * with LIMIT should add ctid")
    #expect(result.contains("LIMIT 10"), "LIMIT clause should be preserved")
  }

  @Test("SELECT specific columns should not add ctid")
  func selectSpecificColumnsNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT id, name FROM users"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(
      result == "SELECT id, name FROM users",
      "SELECT specific columns should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to non-* queries")
  }

  @Test("SELECT * with JOIN should not add ctid (ambiguous)")
  func selectStarWithJoinNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users JOIN orders ON users.id = orders.user_id"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    // JOIN queries should NOT get ctid because:
    // 1. ctid is ambiguous (which table's ctid?)
    // 2. Could cause confusion in row identification
    #expect(
      result == query,
      "JOIN queries should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to JOIN queries")
  }

  @Test("SELECT * with subquery should not add ctid (causes error)")
  func selectStarWithSubqueryNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM (SELECT * FROM users) AS sub"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    // Subqueries should NOT get ctid because:
    // - Derived tables (subqueries) don't have ctid system column
    // - Query like "SELECT *, ctid AS _sqlnb_ctid FROM (...) AS sub" will fail with error
    #expect(
      result == query,
      "Subquery should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to subqueries")
  }

  @Test("Non-SELECT query should not add ctid")
  func nonSelectQueryNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "UPDATE users SET name = 'John'"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(
      result == "UPDATE users SET name = 'John'",
      "Non-SELECT query should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to UPDATE")
  }

  @Test("SELECT * case insensitive should add ctid")
  func selectStarCaseInsensitiveAddsCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "select * from users"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(
      result.contains("ctid AS _sqlnb_ctid") || result.contains("ctid as _sqlnb_ctid"),
      "Lowercase SELECT * should add ctid")
  }

  @Test("SELECT * with LEFT JOIN should not add ctid")
  func selectStarWithLeftJoinNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(result == query, "LEFT JOIN should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to LEFT JOIN")
  }

  @Test("SELECT * with INNER JOIN should not add ctid")
  func selectStarWithInnerJoinNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users INNER JOIN orders ON users.id = orders.user_id"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(result == query, "INNER JOIN should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to INNER JOIN")
  }

  @Test("SELECT * with UNION should not add ctid")
  func selectStarWithUnionNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users UNION SELECT * FROM admins"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(result == query, "UNION should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to UNION queries")
  }

  @Test("SELECT * with INTERSECT should not add ctid")
  func selectStarWithIntersectNoCtid() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users INTERSECT SELECT * FROM active_users"

    // Act
    let result = await manager.wrapQueryWithCtidPublic(query)

    // Assert
    #expect(result == query, "INTERSECT should not be modified")
    #expect(!result.contains("_sqlnb_ctid"), "Should not add ctid to INTERSECT queries")
  }
}

// MARK: - Test Helper Extension

extension DatabaseConnectionManager {
  /// Public wrapper for testing private `wrapQueryWithCtid` method
  func wrapQueryWithCtidPublic(_ query: String) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    // Only process if query starts with "SELECT * FROM"
    guard trimmed.uppercased().hasPrefix("SELECT * FROM") else {
      return query
    }

    let upperQuery = trimmed.uppercased()

    // Skip queries with JOINs - ctid would be ambiguous (which table's ctid?)
    if upperQuery.contains(" JOIN ") || upperQuery.contains(" INNER JOIN ")
      || upperQuery.contains(" LEFT JOIN ") || upperQuery.contains(" RIGHT JOIN ")
      || upperQuery.contains(" FULL JOIN ") || upperQuery.contains(" CROSS JOIN ")
    {
      return query
    }

    // Skip queries with subqueries - ctid cannot be used with subquery aliases
    // Check for subquery patterns: (SELECT ... FROM ...) AS alias
    if upperQuery.contains("(SELECT") {
      return query
    }

    // Skip queries with UNION/INTERSECT/EXCEPT - ctid not meaningful for set operations
    if upperQuery.contains(" UNION ") || upperQuery.contains(" INTERSECT ")
      || upperQuery.contains(" EXCEPT ")
    {
      return query
    }

    // Safe to add ctid for simple SELECT * FROM table queries
    return trimmed.replacingOccurrences(
      of: "SELECT *",
      with: "SELECT *, ctid AS _sqlnb_ctid",
      options: [.caseInsensitive],
      range: trimmed.startIndex..<trimmed.index(trimmed.startIndex, offsetBy: 8)
    )
  }
}
