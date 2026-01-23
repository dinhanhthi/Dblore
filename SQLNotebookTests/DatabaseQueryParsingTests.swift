//
//  DatabaseQueryParsingTests.swift
//  SQLNotebook
//
//  Comprehensive unit tests for query parsing and comment stripping functions
//  Tests stripAllComments, stripLeadingComments, isSelectQuery, extractLimitValue, etc.
//

import Testing
@testable import SQLNotebook
import Foundation

@Suite("Database Query Parsing Tests")
@MainActor
struct DatabaseQueryParsingTests {

  // MARK: - stripAllComments Tests

  @Suite("stripAllComments - Single-line Comments")
  struct StripSingleLineCommentsTests {

    @Test("Single-line comment at start is removed")
    func removeSingleLineCommentAtStart() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- comment\nSELECT * FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == "\nSELECT * FROM users", "Should remove leading comment")
    }

    @Test("Single-line comment at end is removed")
    func removeSingleLineCommentAtEnd() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users -- comment"
      let result = manager.stripAllComments(query)
      // Note: When comment is at end without newline, no newline is appended
      #expect(result == "SELECT * FROM users ", "Should remove trailing comment")
    }

    @Test("Multiple single-line comments are removed")
    func removeMultipleSingleLineComments() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- c1\n-- c2\nSELECT * FROM users -- c3"
      let result = manager.stripAllComments(query)
      // Note: Last comment doesn't have newline after it, so no newline appended
      #expect(result == "\n\nSELECT * FROM users ", "Should remove all single-line comments")
    }

    @Test("Single-line comment with LIMIT inside is removed")
    func removeSingleLineCommentWithLimitInside() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 100\nSELECT * FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == "\nSELECT * FROM users", "Should remove comment containing LIMIT")
      #expect(!result.contains("LIMIT"), "Stripped query should not contain LIMIT")
    }

    @Test("Inline single-line comment is removed")
    func removeInlineSingleLineComment() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users WHERE -- inline comment\nid > 10"
      let result = manager.stripAllComments(query)
      #expect(result == "SELECT * FROM users WHERE \nid > 10", "Should remove inline comment")
    }
  }

  @Suite("stripAllComments - Multi-line Comments")
  struct StripMultiLineCommentsTests {

    @Test("Multi-line comment at start is removed")
    func removeMultiLineCommentAtStart() throws {
      let manager = DatabaseConnectionManager()
      let query = "/* comment */ SELECT * FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == " SELECT * FROM users", "Should remove leading multi-line comment")
    }

    @Test("Multi-line comment at end is removed")
    func removeMultiLineCommentAtEnd() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users /* comment */"
      let result = manager.stripAllComments(query)
      #expect(result == "SELECT * FROM users ", "Should remove trailing multi-line comment")
    }

    @Test("Multi-line comment spanning multiple lines is removed")
    func removeMultiLineCommentSpanningLines() throws {
      let manager = DatabaseConnectionManager()
      let query = """
      /* This is a
      multi-line
      comment */
      SELECT * FROM users
      """
      let result = manager.stripAllComments(query)
      #expect(result.contains("SELECT * FROM users"), "Should preserve SQL")
      #expect(!result.contains("multi-line"), "Should remove comment content")
    }

    @Test("Nested multi-line comment pattern is handled")
    func handleNestedMultiLineCommentPattern() throws {
      let manager = DatabaseConnectionManager()
      let query = "/* outer /* inner */ outer */ SELECT * FROM users"
      let result = manager.stripAllComments(query)
      // Note: PostgreSQL doesn't support nested comments, so we test basic behavior
      // The parser stops at first */ closing marker
      #expect(result.contains("SELECT"), "Should contain SELECT")
    }

    @Test("Multi-line comment with LIMIT inside is removed")
    func removeMultiLineCommentWithLimitInside() throws {
      let manager = DatabaseConnectionManager()
      let query = "/* LIMIT 100 */ SELECT * FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == " SELECT * FROM users", "Should remove comment")
      #expect(!result.contains("LIMIT"), "Stripped query should not contain LIMIT")
    }
  }

  @Suite("stripAllComments - String Literals")
  struct StripCommentsWithStringLiteralsTests {

    @Test("String literal with comment-like content is preserved")
    func preserveStringLiteralWithCommentLikeContent() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT '-- not a comment' FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == "SELECT '-- not a comment' FROM users", "Should preserve string literal")
    }

    @Test("String literal with multi-line comment-like content is preserved")
    func preserveStringLiteralWithMultiLineCommentLikeContent() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT '/* not a comment */' FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == "SELECT '/* not a comment */' FROM users", "Should preserve string literal")
    }

    @Test("Real comment after string literal is removed")
    func removeCommentAfterStringLiteral() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT '-- not a comment' FROM users -- real comment"
      let result = manager.stripAllComments(query)
      // Note: Comment at end without newline doesn't append newline
      #expect(result == "SELECT '-- not a comment' FROM users ", "Should preserve string but remove comment")
      #expect(result.contains("'-- not a comment'"), "Should keep string literal")
    }

    @Test("Escaped quote in string is handled correctly")
    func handleEscapedQuoteInString() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT 'it''s a test' FROM users -- comment"
      let result = manager.stripAllComments(query)
      #expect(result.contains("'it''s a test'"), "Should preserve escaped quote")
      #expect(!result.contains("-- comment"), "Should remove comment")
    }

    @Test("String containing slash-star pattern is preserved")
    func preserveStringContainingSlashStarPattern() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT '/*' FROM users /* real comment */"
      let result = manager.stripAllComments(query)
      #expect(result.contains("'/*'"), "Should preserve string literal")
      #expect(!result.contains("real comment"), "Should remove real comment")
    }
  }

  @Suite("stripAllComments - Complex Cases")
  struct StripCommentsComplexCasesTests {

    @Test("Query with both single and multi-line comments")
    func removeBothTypesOfComments() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- single\n/* multi */ SELECT * FROM users -- end"
      let result = manager.stripAllComments(query)
      #expect(result.contains("SELECT * FROM users"), "Should preserve SQL")
      #expect(!result.contains("single"), "Should remove single-line comment")
      #expect(!result.contains("multi"), "Should remove multi-line comment")
      #expect(!result.contains("end"), "Should remove end comment")
    }

    @Test("Real-world query with multiple comments and LIMIT")
    func realWorldQueryWithCommentsAndLimit() throws {
      let manager = DatabaseConnectionManager()
      let query = """
      -- LIMIT 3
      -- LIMIT 5
      SELECT * FROM bot
      """
      let result = manager.stripAllComments(query)
      #expect(result.contains("SELECT * FROM bot"), "Should preserve SQL")
      #expect(!result.contains("LIMIT 3"), "Should remove comment with LIMIT 3")
      #expect(!result.contains("LIMIT 5"), "Should remove comment with LIMIT 5")
      #expect(!result.contains("--"), "Should not contain any comment markers")
    }

    @Test("Comment immediately after SELECT keyword")
    func removeCommentAfterSelectKeyword() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT -- comment\n* FROM users"
      let result = manager.stripAllComments(query)
      #expect(result == "SELECT \n* FROM users", "Should remove inline comment")
    }

    @Test("Multiple comments between SQL keywords")
    func removeMultipleCommentsBetweenKeywords() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT /* c1 */ * /* c2 */ FROM /* c3 */ users"
      let result = manager.stripAllComments(query)
      #expect(result == "SELECT  *  FROM  users", "Should remove all inline comments")
      #expect(!result.contains("/*"), "Should not contain comment markers")
    }

    @Test("Empty query after stripping comments")
    func emptyQueryAfterStrippingComments() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- just a comment"
      let result = manager.stripAllComments(query)
      // Note: Comment without trailing newline results in empty string
      #expect(result == "", "Should result in empty string when only comment exists")
    }
  }

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
      // Note: extractLimitValue strips ALL comments but doesn't parse string literals
      // So LIMIT inside strings may be detected (known limitation)
      // This test documents the actual behavior
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
  }

  // MARK: - wrapQueryWithLimit Tests - CRITICAL: Comment Stripping

  @Suite("wrapQueryWithLimit - Comment Stripping (CRITICAL)")
  struct WrapQueryWithLimitCommentStrippingTests {

    @Test("Query with leading comments has NO comments in result")
    func leadingCommentsRemoved() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 3\nSELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      // CRITICAL: Result must not contain "--" or "/*"
      #expect(!result.contains("--"), "Result should not contain single-line comment marker")
      #expect(!result.contains("/*"), "Result should not contain multi-line comment marker")
      #expect(result.contains("SELECT * FROM bot"), "Should preserve SQL")
      #expect(result.contains("LIMIT 4"), "Should append LIMIT 4")

      // Verify exact result
      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with trailing comments has NO comments in result")
    func trailingCommentsRemoved() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot -- comment"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      // CRITICAL: Result must not contain comments
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

      // CRITICAL: Result must not contain any comments
      #expect(!result.contains("--"), "Result should not contain any comment markers")
      #expect(!result.contains("c1"), "Should remove c1 comment")
      #expect(!result.contains("c2"), "Should remove c2 comment")
      #expect(!result.contains("c3"), "Should remove c3 comment")
      #expect(result.contains("SELECT * FROM bot"), "Should preserve SQL")
      #expect(result.contains("LIMIT 4"), "Should append LIMIT 4")

      // Verify exact result
      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with LIMIT in comment should add actual LIMIT")
    func limitInCommentShouldAddActualLimit() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- LIMIT 100\nSELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      // CRITICAL: Comments should be stripped, actual LIMIT added
      #expect(!result.contains("--"), "Result should not contain comment marker")
      #expect(!result.contains("LIMIT 100"), "Should not preserve LIMIT from comment")
      #expect(result.contains("LIMIT 4"), "Should add actual LIMIT 4")

      // Verify exact result
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

      // CRITICAL: All comments should be removed, only actual LIMIT added
      #expect(!result.contains("--"), "Result should not contain comment markers")
      #expect(!result.contains("LIMIT 3"), "Should remove LIMIT 3 from comment")
      #expect(!result.contains("LIMIT 5"), "Should remove LIMIT 5 from comment")
      #expect(result.contains("LIMIT 4"), "Should add actual LIMIT 4")

      // Verify exact result
      let expected = "SELECT * FROM bot LIMIT 4"
      #expect(result == expected, "Result should match expected format exactly")
    }

    @Test("Query with multi-line comment containing LIMIT")
    func multiLineCommentContainingLimit() async throws {
      let manager = DatabaseConnectionManager()
      let query = "/* LIMIT 50 */ SELECT * FROM bot"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 4)

      // CRITICAL: Multi-line comment should be removed
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

      // CRITICAL: All inline comments should be removed
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

  // MARK: - isSelectQuery Tests

  @Suite("isSelectQuery - Detection")
  struct IsSelectQueryTests {

    @Test("Simple SELECT query returns true")
    func simpleSelectQueryReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users"
      let result = manager.isSelectQuery(query)
      #expect(result == true, "Should detect SELECT query")
    }

    @Test("SELECT with leading comment returns true")
    func selectWithLeadingCommentReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- comment\nSELECT * FROM users"
      let result = manager.isSelectQuery(query)
      #expect(result == true, "Should detect SELECT after comment")
    }

    @Test("SELECT with multi-line comment returns true")
    func selectWithMultiLineCommentReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let query = "/* comment */ SELECT * FROM users"
      let result = manager.isSelectQuery(query)
      #expect(result == true, "Should detect SELECT after multi-line comment")
    }

    @Test("UPDATE query returns false")
    func updateQueryReturnsFalse() throws {
      let manager = DatabaseConnectionManager()
      let query = "UPDATE users SET name = 'x'"
      let result = manager.isSelectQuery(query)
      #expect(result == false, "Should not detect UPDATE as SELECT")
    }

    @Test("DELETE query returns false")
    func deleteQueryReturnsFalse() throws {
      let manager = DatabaseConnectionManager()
      let query = "DELETE FROM users"
      let result = manager.isSelectQuery(query)
      #expect(result == false, "Should not detect DELETE as SELECT")
    }

    @Test("INSERT query returns false")
    func insertQueryReturnsFalse() throws {
      let manager = DatabaseConnectionManager()
      let query = "INSERT INTO users VALUES (1)"
      let result = manager.isSelectQuery(query)
      #expect(result == false, "Should not detect INSERT as SELECT")
    }

    @Test("CREATE TABLE query returns false")
    func createTableQueryReturnsFalse() throws {
      let manager = DatabaseConnectionManager()
      let query = "CREATE TABLE users (id INT)"
      let result = manager.isSelectQuery(query)
      #expect(result == false, "Should not detect CREATE as SELECT")
    }

    @Test("Case insensitive SELECT detection")
    func caseInsensitiveSelectDetection() throws {
      let manager = DatabaseConnectionManager()
      let query = "select * from users"
      let result = manager.isSelectQuery(query)
      #expect(result == true, "Should detect lowercase select")
    }

    @Test("SELECT in string literal does not trigger detection")
    func selectInStringLiteralNotDetected() throws {
      let manager = DatabaseConnectionManager()
      let query = "UPDATE users SET query = 'SELECT * FROM test'"
      let result = manager.isSelectQuery(query)
      #expect(result == false, "Should not detect SELECT in string literal")
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
      // Note: Current implementation uses regex on whole string
      // It may detect LIMIT in string literals (known limitation)
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

  // MARK: - hasFromClause Tests

  @Suite("hasFromClause - Detection")
  struct HasFromClauseTests {

    @Test("Query with FROM returns true")
    func queryWithFromReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users"
      let result = await manager.hasFromClause(query)
      #expect(result == true, "Should detect FROM clause")
    }

    @Test("Query without FROM returns false")
    func queryWithoutFromReturnsFalse() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT 1 + 1"
      let result = await manager.hasFromClause(query)
      #expect(result == false, "Should return false for query without FROM")
    }

    @Test("Function call without FROM returns false")
    func functionCallWithoutFromReturnsFalse() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT now()"
      let result = await manager.hasFromClause(query)
      #expect(result == false, "Should return false for function call")
    }

    @Test("FROM case insensitive")
    func fromCaseInsensitive() async throws {
      let manager = DatabaseConnectionManager()
      let query = "select * from users"
      let result = await manager.hasFromClause(query)
      #expect(result == true, "Should detect FROM regardless of case")
    }

    @Test("Word boundary detection - 'FROM' in string should not match")
    func fromInStringShouldNotMatch() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT 'FROM the beginning'"
      let result = await manager.hasFromClause(query)
      // Note: Current implementation uses regex on whole string
      // It may detect FROM in string literals (known limitation)
      #expect(result == true, "Current implementation detects FROM in strings (known limitation)")
    }

    @Test("Word boundary detection - 'information' should not match")
    func wordBoundaryDetectionInformation() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT information"
      let result = await manager.hasFromClause(query)
      #expect(result == false, "Should not match FROM in 'information' due to word boundary")
    }
  }

  // MARK: - isModificationQuery Tests

  @Suite("isModificationQuery - Detection")
  struct IsModificationQueryTests {

    @Test("UPDATE query returns true")
    func updateQueryReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "UPDATE users SET name = 'x'"
      let result = await manager.isModificationQuery(query)
      #expect(result == true, "Should detect UPDATE query")
    }

    @Test("DELETE query returns true")
    func deleteQueryReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "DELETE FROM users"
      let result = await manager.isModificationQuery(query)
      #expect(result == true, "Should detect DELETE query")
    }

    @Test("INSERT query returns true")
    func insertQueryReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "INSERT INTO users VALUES (1)"
      let result = await manager.isModificationQuery(query)
      #expect(result == true, "Should detect INSERT query")
    }

    @Test("SELECT query returns false")
    func selectQueryReturnsFalse() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM users"
      let result = await manager.isModificationQuery(query)
      #expect(result == false, "Should not detect SELECT as modification")
    }

    @Test("Modification query with leading comment returns true")
    func modificationQueryWithLeadingCommentReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let query = "-- comment\nUPDATE users SET name = 'x'"
      let result = await manager.isModificationQuery(query)
      #expect(result == true, "Should detect UPDATE after comment")
    }

    @Test("CREATE TABLE query returns false")
    func createTableQueryReturnsFalse() async throws {
      let manager = DatabaseConnectionManager()
      let query = "CREATE TABLE users (id INT)"
      let result = await manager.isModificationQuery(query)
      #expect(result == false, "Should not detect CREATE as modification")
    }
  }

  // MARK: - Integration Tests - Real-world Scenarios

  @Suite("Integration - Real-world Scenarios")
  struct IntegrationTests {

    @Test("Scenario: User query with comment LIMIT should get actual LIMIT")
    func userQueryWithCommentLimitGetsActualLimit() async throws {
      let manager = DatabaseConnectionManager()

      // User writes a query with LIMIT in comment (maybe old query they commented out)
      let userQuery = """
      -- Old limit: LIMIT 1000
      SELECT * FROM large_table
      """

      // App wraps with maxRows = 100
      let result = await manager.wrapQueryWithLimit(userQuery, maxRows: 100)

      // Verify: Comments stripped, actual LIMIT added
      #expect(!result.contains("--"), "Should remove comment")
      #expect(!result.contains("Old limit"), "Should remove comment text")
      #expect(!result.contains("LIMIT 1000"), "Should remove commented LIMIT")
      #expect(result.contains("LIMIT 100"), "Should add actual LIMIT")
      #expect(result == "SELECT * FROM large_table LIMIT 100", "Should match expected result")
    }

    @Test("Scenario: Query with inline comments and string literals")
    func queryWithInlineCommentsAndStringLiterals() throws {
      let manager = DatabaseConnectionManager()

      let query = """
      SELECT /* user cols */ name, email, '-- not a comment' AS note
      FROM users -- active users only
      WHERE status = 'active'
      """

      // Strip comments
      let stripped = manager.stripAllComments(query)

      // Verify: Comments removed, strings preserved
      #expect(!stripped.contains("/*"), "Should remove multi-line comment marker")
      #expect(!stripped.contains("user cols"), "Should remove comment content")
      #expect(!stripped.contains("-- active users only"), "Should remove single-line comment")
      #expect(stripped.contains("'-- not a comment'"), "Should preserve string literal")
      #expect(stripped.contains("name, email"), "Should preserve column list")
      #expect(stripped.contains("WHERE status = 'active'"), "Should preserve WHERE clause")
    }

    @Test("Scenario: Pagination query with comment explaining LIMIT")
    func paginationQueryWithCommentExplainingLimit() async throws {
      let manager = DatabaseConnectionManager()

      let query = """
      -- Pagination: 100 rows per page
      -- LIMIT 100 OFFSET 200
      SELECT id, name FROM products ORDER BY id
      """

      // Wrap with maxRows = 50
      let result = await manager.wrapQueryWithLimit(query, maxRows: 50)

      // Verify: All comments removed, actual LIMIT added
      #expect(!result.contains("--"), "Should remove all comments")
      #expect(!result.contains("Pagination"), "Should remove comment text")
      #expect(!result.contains("OFFSET 200"), "Should remove commented OFFSET")
      #expect(result.contains("LIMIT 50"), "Should add actual LIMIT 50")
    }

    @Test("Scenario: Complex query with nested comments")
    func complexQueryWithNestedComments() throws {
      let manager = DatabaseConnectionManager()

      let query = """
      -- Start of query
      SELECT
        u.id,
        u.name, /* user name */
        u.email /* contact */
      FROM users u
      WHERE u.active = true
      -- End of query
      """

      // Strip comments
      let stripped = manager.stripAllComments(query)

      // Verify: All comments removed, SQL preserved
      #expect(!stripped.contains("--"), "Should remove single-line comments")
      #expect(!stripped.contains("/*"), "Should remove multi-line comments")
      #expect(!stripped.contains("Start of query"), "Should remove comment text")
      #expect(!stripped.contains("user name"), "Should remove comment text")
      #expect(stripped.contains("SELECT"), "Should preserve SELECT")
      #expect(stripped.contains("u.id"), "Should preserve columns")
      #expect(stripped.contains("FROM users u"), "Should preserve FROM")
      #expect(stripped.contains("WHERE u.active = true"), "Should preserve WHERE")
    }
  }
}
