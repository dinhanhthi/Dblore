// QueryParsingCommentTests.swift
// Tests for SQL comment stripping functionality

import Foundation
import Testing

@testable import Dblore

@Suite("Query Parsing - Comment Stripping Tests")
@MainActor
struct QueryParsingCommentTests {

  // MARK: - stripAllComments - Single-line Comments

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
      #expect(result == "SELECT * FROM users ", "Should remove trailing comment")
    }

    @Test("Multiple single-line comments are removed")
    func removeMultipleSingleLineComments() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- c1\n-- c2\nSELECT * FROM users -- c3"
      let result = manager.stripAllComments(query)
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

  // MARK: - stripAllComments - Multi-line Comments

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

  // MARK: - stripAllComments - String Literals

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
      #expect(
        result == "SELECT '-- not a comment' FROM users ",
        "Should preserve string but remove comment")
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

  // MARK: - stripAllComments - Complex Cases

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
      #expect(result == "", "Should result in empty string when only comment exists")
    }
  }
}
