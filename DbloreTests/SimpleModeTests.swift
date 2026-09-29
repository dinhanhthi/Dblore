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

  @Test("Simple Mode setting defaults to false")
  func simpleModeDefaultsToFalse() {
    // Reset to defaults first
    AppSettings.shared.resetToDefaults()

    // Assert
    #expect(AppSettings.shared.editorSimpleMode == false)
  }

  @Test("Simple Mode setting can be toggled")
  func simpleModeCanBeToggled() {
    // Arrange
    AppSettings.shared.editorSimpleMode = false

    // Act
    AppSettings.shared.editorSimpleMode = true

    // Assert
    #expect(AppSettings.shared.editorSimpleMode == true)

    // Cleanup
    AppSettings.shared.editorSimpleMode = false
  }

  @Test("Reset to defaults resets Simple Mode to false")
  func resetToDefaultsResetsSimpleMode() {
    // Arrange
    AppSettings.shared.editorSimpleMode = true
    #expect(AppSettings.shared.editorSimpleMode == true)

    // Act
    AppSettings.shared.resetToDefaults()

    // Assert
    #expect(AppSettings.shared.editorSimpleMode == false)
  }

  // MARK: - Comment-Only Detection Tests (via DatabaseConnectionManager)

  @Test("isCommentOnlyStatement detects single-line comment")
  func detectsSingleLineComment() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement("-- this is a comment"))
    #expect(manager.isCommentOnlyStatement("  -- comment with leading spaces"))
    #expect(manager.isCommentOnlyStatement("-- SELECT * FROM users"))
  }

  @Test("isCommentOnlyStatement detects multi-line comment")
  func detectsMultiLineComment() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement("/* this is a comment */"))
    #expect(manager.isCommentOnlyStatement("  /* comment */  "))
    #expect(manager.isCommentOnlyStatement("/* SELECT * FROM users */"))
  }

  @Test("isCommentOnlyStatement returns false for executable SQL")
  func returnsFalseForExecutableSQL() async {
    let manager = DatabaseConnectionManager()

    #expect(!manager.isCommentOnlyStatement("SELECT * FROM users"))
    #expect(!manager.isCommentOnlyStatement("SELECT 1"))
    #expect(!manager.isCommentOnlyStatement("INSERT INTO users VALUES (1)"))
    #expect(!manager.isCommentOnlyStatement("UPDATE users SET name = 'John'"))
    #expect(!manager.isCommentOnlyStatement("DELETE FROM users"))
  }

  @Test("isCommentOnlyStatement returns false for SQL with inline comments")
  func returnsFalseForSQLWithInlineComments() async {
    let manager = DatabaseConnectionManager()

    #expect(!manager.isCommentOnlyStatement("SELECT * FROM users -- get all users"))
    #expect(!manager.isCommentOnlyStatement("SELECT 1 /* test */"))
    #expect(!manager.isCommentOnlyStatement("/* comment */ SELECT * FROM users"))
  }

  @Test("isCommentOnlyStatement returns true for whitespace only")
  func returnsTrueForWhitespaceOnly() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement("   "))
    #expect(manager.isCommentOnlyStatement("\t\t"))
    #expect(manager.isCommentOnlyStatement("  \n  "))
  }

  @Test("isCommentOnlyStatement returns true for empty string")
  func returnsTrueForEmptyString() async {
    let manager = DatabaseConnectionManager()

    #expect(manager.isCommentOnlyStatement(""))
  }

  // MARK: - Line Extraction Helper Tests

  @Test("NSString lineRange extracts correct line")
  func lineRangeExtractsCorrectLine() {
    let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
    let nsString = text as NSString

    // Cursor at beginning of first line
    let range1 = nsString.lineRange(for: NSRange(location: 0, length: 0))
    let line1 = nsString.substring(with: range1)
    #expect(line1 == "SELECT 1;\n")

    // Cursor at beginning of second line
    let range2 = nsString.lineRange(for: NSRange(location: 10, length: 0))
    let line2 = nsString.substring(with: range2)
    #expect(line2 == "SELECT 2;\n")

    // Cursor at end of third line (no newline)
    let range3 = nsString.lineRange(for: NSRange(location: 29, length: 0))
    let line3 = nsString.substring(with: range3)
    #expect(line3 == "SELECT 3;")
  }

  @Test("NSString lineRange handles cursor at end of line with semicolon")
  func lineRangeHandlesCursorAtEndOfLineWithSemicolon() {
    // Case 2: cursor at end of first line after semicolon
    let text = "SELECT * from bot limit 10;\nSELECT * from autoupdate;"
    let nsString = text as NSString

    // Cursor right after semicolon on first line (position 27)
    let range = nsString.lineRange(for: NSRange(location: 27, length: 0))
    let line = nsString.substring(with: range)
    #expect(line == "SELECT * from bot limit 10;\n")
  }

  @Test("NSString lineRange handles cursor at end of last line")
  func lineRangeHandlesCursorAtEndOfLastLine() {
    // Case 3: cursor at end of second line
    let text = "SELECT * from bot limit 10;\nSELECT * from autoupdate;"
    let nsString = text as NSString

    // Cursor at the very end
    let range = nsString.lineRange(for: NSRange(location: text.count, length: 0))
    let line = nsString.substring(with: range)
    #expect(line == "SELECT * from autoupdate;")
  }

  @Test("NSString lineRange handles multiple statements on same line")
  func lineRangeHandlesMultipleStatementsOnSameLine() {
    // Case 4: multiple statements on same line
    let text = "SELECT * from bot limit 10; SELECT * from autoupdate;"
    let nsString = text as NSString

    // Cursor anywhere on the line should return the whole line
    let range = nsString.lineRange(for: NSRange(location: 28, length: 0))
    let line = nsString.substring(with: range)
    #expect(line == text)
  }

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

  @Test("Simple Mode ON returns nil when no textView")
  func simpleModeOnReturnsNilWhenNoTextView() {
    // Arrange
    AppSettings.shared.editorSimpleMode = true
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.editorContent = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    // Act - getQueryAtCursor() returns nil when no textView
    let result = viewModel.getEditorQueryText()

    // Assert - Should return nil (no textView to get cursor position from)
    #expect(result == nil)

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

  @Test("Simple Mode OFF does not clear results when no query")
  func simpleModeOffDoesNotClearResultsWhenNoQuery() async {
    // Arrange
    AppSettings.shared.editorSimpleMode = false
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.editorContent = ""  // Empty content

    // Set some existing results
    let existingResult = CellResult(
      columns: [ColumnInfo(name: "id", type: "integer")],
      rows: [[.int(1)]],
      executionTime: 0.1,
      timestamp: Date(),
      error: nil
    )
    viewModel.editorResult = existingResult

    // Act - run query when content is empty
    await viewModel.runEditorQuery()

    // Assert - Results should NOT be cleared (just returns early)
    // Note: This test relies on the fact that empty content returns early without clearing
    // The actual behavior keeps results because it returns early before any clearing
    #expect(viewModel.editorResult != nil)

    // Cleanup
    AppSettings.shared.editorSimpleMode = false
  }

  // MARK: - Edge Cases

  @Test("Comment line trimmed correctly")
  func commentLineTrimmedCorrectly() {
    let line = "  -- this is a comment  \n"
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed == "-- this is a comment")
  }

  @Test("SQL line with trailing newline trimmed correctly")
  func sqlLineWithTrailingNewlineTrimmedCorrectly() {
    let line = "SELECT * FROM users;\n"
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed == "SELECT * FROM users;")
  }

  @Test("Multiple statements trimmed correctly")
  func multipleStatementsTrimmedCorrectly() {
    let line = "  SELECT 1; SELECT 2;  \n"
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed == "SELECT 1; SELECT 2;")
  }

  // MARK: - Test Cases from Requirements

  @Test("Case 1: Comment-only line should return nil")
  func case1CommentOnlyLineReturnsNil() async {
    // "-- SELECT idetabotid, key <cursor> from bot limi"
    // Should run nothing (return nil for query)
    let manager = DatabaseConnectionManager()
    let line = "-- SELECT idetabotid, key from bot limi"
    #expect(manager.isCommentOnlyStatement(line) == true)
  }

  @Test("Case 2: Cursor at end of line after semicolon returns that line")
  func case2CursorAtEndOfLineAfterSemicolon() {
    // "SELECT * from bot limit 10; <cursor>"
    // "SELECT * from autoupdate;"
    // Should run "SELECT * from bot limit 10;"
    let text = "SELECT * from bot limit 10;\nSELECT * from autoupdate;"
    let nsString = text as NSString

    // Cursor at end of first line (position 27, right after semicolon)
    let range = nsString.lineRange(for: NSRange(location: 27, length: 0))
    let line = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(line == "SELECT * from bot limit 10;")
  }

  @Test("Case 3: Cursor at end of second line returns that line")
  func case3CursorAtEndOfSecondLine() {
    // "SELECT * from bot limit 10;"
    // "SELECT * from autoupdate;<cursor>"
    // Should run "SELECT * from autoupdate;"
    let text = "SELECT * from bot limit 10;\nSELECT * from autoupdate;"
    let nsString = text as NSString

    // Cursor at end of second line
    let cursorPos = text.count
    let range = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
    let line = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(line == "SELECT * from autoupdate;")
  }

  @Test("Case 4: Multiple statements on same line runs all")
  func case4MultipleStatementsOnSameLineRunsAll() {
    // "SELECT * from bot limit 10; <cursor> SELECT * from autoupdate;"
    // Should run both queries (entire line)
    let text = "SELECT * from bot limit 10; SELECT * from autoupdate;"
    let nsString = text as NSString

    // Cursor in middle of line
    let range = nsString.lineRange(for: NSRange(location: 28, length: 0))
    let line = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(line == "SELECT * from bot limit 10; SELECT * from autoupdate;")
  }

  // MARK: - hasMultipleStatements Tests (for multiple statements on same line)

  @Test("hasMultipleStatements detects two statements")
  func hasMultipleStatementsDetectsTwoStatements() async {
    let manager = DatabaseConnectionManager()
    let query = "SELECT 1; SELECT 2"
    #expect(manager.hasMultipleStatements(query) == true)
  }

  @Test("hasMultipleStatements returns false for single statement")
  func hasMultipleStatementsReturnsFalseForSingleStatement() async {
    let manager = DatabaseConnectionManager()
    let query = "SELECT * FROM users"
    #expect(manager.hasMultipleStatements(query) == false)
  }

  @Test("hasMultipleStatements handles semicolon in string literal")
  func hasMultipleStatementsHandlesSemicolonInStringLiteral() async {
    let manager = DatabaseConnectionManager()
    let query = "SELECT 'hello; world' FROM users"
    #expect(manager.hasMultipleStatements(query) == false)
  }
}
