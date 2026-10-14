// DatabaseQueryExecutionTests.swift
// Unit tests for Database Query Execution Logic
// Tests statement splitting and comment-only detection

import Foundation
import Testing

@testable import Dblore

@Suite("Database Query Execution Tests")
@MainActor
struct DatabaseQueryExecutionTests {

  // MARK: - Multiple Statement Parsing Tests

  @Test("Split simple two statements")
  func splitSimpleTwoStatements() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT 1; SELECT 2"

    // Act
    let statements = manager.splitSQLStatementsPublic(query)

    // Assert
    #expect(statements.count == 2, "Should split into 2 statements")
    #expect(statements[0] == "SELECT 1", "First statement should be 'SELECT 1'")
    #expect(statements[1] == "SELECT 2", "Second statement should be 'SELECT 2'")
  }

  @Test("Split ignores semicolon in string literal")
  func splitIgnoresSemicolonInString() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "INSERT INTO test (data) VALUES ('Hello; World'); SELECT 1"

    // Act
    let statements = manager.splitSQLStatementsPublic(query)

    // Assert
    #expect(statements.count == 2, "Should split into 2 statements (semicolon in string ignored)")
    #expect(
      statements[0].contains("Hello; World"), "First statement should preserve semicolon in string")
    #expect(statements[1] == "SELECT 1", "Second statement should be SELECT 1")
  }

  @Test("Split handles single line comments")
  func splitHandlesSingleLineComments() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = """
      -- This is a comment; with semicolon
      SELECT 1;
      SELECT 2;
      """

    // Act
    let statements = manager.splitSQLStatementsPublic(query)

    // Assert
    #expect(statements.count == 2, "Should split into 2 statements")
    #expect(
      statements[0].contains("-- This is a comment"),
      "Comment should be preserved in first statement")
    #expect(statements[0].contains("SELECT 1"), "First statement should contain SELECT 1")
    #expect(statements[1] == "SELECT 2", "Second statement should be SELECT 2")
  }

  @Test("Empty query returns empty array")
  func emptyQueryReturnsEmptyArray() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = ""

    // Act
    let statements = manager.splitSQLStatementsPublic(query)

    // Assert
    #expect(statements.isEmpty, "Empty query should return empty array")
  }

  @Test("Query with only semicolons returns empty array")
  func queryWithOnlySemicolonsReturnsEmpty() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = ";;; ;"

    // Act
    let statements = manager.splitSQLStatementsPublic(query)

    // Assert
    #expect(statements.isEmpty, "Query with only semicolons should return empty array")
  }

  @Test("hasMultipleStatements detects multiple statements")
  func hasMultipleStatementsDetectsMultiple() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT 1; SELECT 2"

    // Act
    let hasMultiple = manager.hasMultipleStatementsPublic(query)

    // Assert
    #expect(hasMultiple == true, "Should detect multiple statements")
  }

  @Test("hasMultipleStatements ignores semicolon in string")
  func hasMultipleStatementsIgnoresSemicolonInString() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT 'Hello; World' AS message"

    // Act
    let hasMultiple = manager.hasMultipleStatementsPublic(query)

    // Assert
    #expect(hasMultiple == false, "Should ignore semicolon in string literal")
  }

  // MARK: - Comment-Only Statement Detection Tests

  @Test("isCommentOnlyStatement detects single-line comment")
  func isCommentOnlyStatementDetectsSingleLineComment() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "-- This is a comment"

    // Act
    let isCommentOnly = manager.isCommentOnlyStatementPublic(query)

    // Assert
    #expect(isCommentOnly == true, "Should detect single-line comment as comment-only")
  }

  @Test("isCommentOnlyStatement returns false for SQL with comment")
  func isCommentOnlyStatementReturnsFalseForSQLWithComment() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users; -- Get all users"

    // Act
    let isCommentOnly = manager.isCommentOnlyStatementPublic(query)

    // Assert
    #expect(isCommentOnly == false, "Should return false when SQL code is present")
  }

  @Test("isCommentOnlyStatement handles whitespace only")
  func isCommentOnlyStatementHandlesWhitespaceOnly() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = "   \n\t  \n  "

    // Act
    let isCommentOnly = manager.isCommentOnlyStatementPublic(query)

    // Assert
    #expect(isCommentOnly == true, "Should return true for whitespace-only statement")
  }

  @Test("isCommentOnlyStatement handles mixed comments and whitespace")
  func isCommentOnlyStatementHandlesMixedCommentsAndWhitespace() async throws {
    // Arrange
    let manager = DatabaseConnectionManager()
    let query = """
      -- First comment
      /* Second comment */
      -- Third comment
      """

    // Act
    let isCommentOnly = manager.isCommentOnlyStatementPublic(query)

    // Assert
    #expect(isCommentOnly == true, "Should return true for multiple comments with whitespace")
  }
}

// MARK: - Test Helper Extension

extension DatabaseConnectionManager {
  /// Public wrapper for splitSQLStatements (for testing)
  nonisolated func splitSQLStatementsPublic(_ sql: String) -> [String] {
    return splitSQLStatements(sql, dialect: .postgresql)
  }

  /// Public wrapper for hasMultipleStatements (for testing)
  nonisolated func hasMultipleStatementsPublic(_ sql: String) -> Bool {
    return hasMultipleStatements(sql, dialect: .postgresql)
  }

  /// Public wrapper for isCommentOnlyStatement (for testing)
  nonisolated func isCommentOnlyStatementPublic(_ sql: String) -> Bool {
    return isCommentOnlyStatement(sql, dialect: .postgresql)
  }
}
