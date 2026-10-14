// SimpleModeTests.swift
// Unit tests for Editor Simple Mode feature
// Tests query extraction logic based on cursor line position

import Foundation
import Testing

@testable import Dblore

@Suite("Simple Mode Tests")
@MainActor
struct SimpleModeTests {

  // MARK: - AppSettings Tests

  // MARK: - Comment-Only Detection Tests (via DatabaseConnectionManager)

  @Test("isCommentOnlyStatement detects single-line comment")
  func detectsSingleLineComment() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement("-- this is a comment", dialect: .postgresql))
    #expect(
      manager.isCommentOnlyStatement("  -- comment with leading spaces", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("-- SELECT * FROM users", dialect: .postgresql))
  }

  @Test("isCommentOnlyStatement detects multi-line comment")
  func detectsMultiLineComment() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement("/* this is a comment */", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("  /* comment */  ", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("/* SELECT * FROM users */", dialect: .postgresql))
  }

  @Test("isCommentOnlyStatement returns false for executable SQL")
  func returnsFalseForExecutableSQL() async {
    let manager = DatabaseConnectionManager()

    #expect(!manager.isCommentOnlyStatement("SELECT * FROM users", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("SELECT 1", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("INSERT INTO users VALUES (1)", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("UPDATE users SET name = 'John'", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("DELETE FROM users", dialect: .postgresql))
  }

  @Test("isCommentOnlyStatement returns false for SQL with inline comments")
  func returnsFalseForSQLWithInlineComments() async {
    let manager = DatabaseConnectionManager()

    #expect(
      !manager.isCommentOnlyStatement("SELECT * FROM users -- get all users", dialect: .postgresql))
    #expect(!manager.isCommentOnlyStatement("SELECT 1 /* test */", dialect: .postgresql))
    #expect(
      !manager.isCommentOnlyStatement("/* comment */ SELECT * FROM users", dialect: .postgresql))
  }

  @Test("isCommentOnlyStatement returns true for whitespace only")
  func returnsTrueForWhitespaceOnly() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement("   ", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("\t\t", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("  \n  ", dialect: .postgresql))
  }

  // MARK: - Line Extraction Helper Tests

  // MARK: - getEditorQueryText Behavior Tests (without actual NSTextView)

  @Test("Simple Mode OFF returns entire content when no selection")
  func simpleModeOffReturnsEntireContent() {
    // Arrange
    AppSettings.shared.editorSimpleMode = false
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.editorContent = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    // Act - Since we don't have a real NSTextView, test the fallback behavior
    let result = viewModel.getEditorQueryText()

    // Assert - Should return entire content (no textView means no selection)
    #expect(result == "SELECT 1;\nSELECT 2;\nSELECT 3;")

    // Cleanup
    AppSettings.shared.editorSimpleMode = false
  }

  // MARK: - runEditorQuery Behavior Tests

  @Test("Simple Mode clears results when no executable query")
  func simpleModeOnClearsResultsWhenNoExecutableQuery() async {
    // Arrange
    AppSettings.shared.editorSimpleMode = true
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor

    // Set some existing results
    viewModel.editorResult = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")],
      rows: [[.int(1)]],
      executionTime: 0.1,
      timestamp: Date(),
      error: nil
    )

    // Act - run query when getEditorQueryText returns nil
    await viewModel.runEditorQuery()

    // Assert - Results should be cleared
    #expect(viewModel.editorResult == nil)
    #expect(viewModel.editorStatementResults.isEmpty)
    #expect(viewModel.selectedStatementIndex == 0)
    #expect(viewModel.totalExecutionTime == 0)

    // Cleanup
    AppSettings.shared.editorSimpleMode = false
  }

  // MARK: - Edge Cases

  // MARK: - Test Cases from Requirements

  // MARK: - hasMultipleStatements Tests (for multiple statements on same line)

  @Test("hasMultipleStatements detects two statements")
  func hasMultipleStatementsDetectsTwoStatements() async {
    let manager = DatabaseConnectionManager()
    let query = "SELECT 1; SELECT 2"
    #expect(manager.hasMultipleStatements(query, dialect: .postgresql) == true)
  }

  @Test("hasMultipleStatements handles semicolon in string literal")
  func hasMultipleStatementsHandlesSemicolonInStringLiteral() async {
    let manager = DatabaseConnectionManager()
    let query = "SELECT 'hello; world' FROM users"
    #expect(manager.hasMultipleStatements(query, dialect: .postgresql) == false)
  }
}
