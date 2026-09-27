// QueryParsingDetectionTests.swift
// Tests for SQL query type detection (SELECT, modification queries, etc.)

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Query Parsing - Query Detection Tests")
@MainActor
struct QueryParsingDetectionTests {

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

  // MARK: - Statement kind detection (classifier; replaces prefix-based isModificationQuery)

  @Suite("Statement kind - Detection")
  struct StatementKindTests {

    func kind(_ query: String) -> StatementKind? {
      SQLStatementClassifier.classify(query).first?.kind
    }

    @Test("UPDATE, DELETE and INSERT are DML")
    func dataModificationIsDML() {
      #expect(kind("UPDATE users SET name = 'x'") == .dml)
      #expect(kind("DELETE FROM users") == .dml)
      #expect(kind("INSERT INTO users VALUES (1)") == .dml)
    }

    @Test("SELECT is a read")
    func selectIsRead() {
      #expect(kind("SELECT * FROM users") == .read)
    }

    @Test("Modification query with leading comment is detected")
    func modificationWithLeadingComment() {
      #expect(kind("-- comment\nUPDATE users SET name = 'x'") == .dml)
    }

    @Test("CREATE, DROP, TRUNCATE and ALTER are DDL")
    func schemaModificationIsDDL() {
      let queries = [
        "CREATE TABLE users (id INT)",
        "DROP TABLE users",
        "DROP DATABASE mydb",
        "DROP INDEX idx_name",
        "DROP VIEW my_view",
        "DROP SCHEMA public",
        "TRUNCATE TABLE users",
        "TRUNCATE users",
        "ALTER TABLE users ADD COLUMN age INT",
        "ALTER TABLE users DROP COLUMN email",
        "ALTER TABLE users RENAME TO customers",
      ]
      for query in queries {
        #expect(kind(query) == .ddl, "Should detect DDL: \(query)")
      }
    }

    @Test("DROP/TRUNCATE/ALTER with leading comment are DDL")
    func schemaModificationWithLeadingComment() {
      let queries = [
        "-- comment\nDROP TABLE users",
        "/* multi-line */ TRUNCATE TABLE users",
        "-- be careful\nALTER TABLE users DROP COLUMN email",
      ]
      for query in queries {
        #expect(kind(query) == .ddl, "Should detect DDL after comment: \(query)")
      }
    }

    @Test("Every statement of a multi-statement query is classified")
    func multiStatementClassified() {
      let kinds = SQLStatementClassifier.classify("SELECT 1; DROP TABLE t").map(\.kind)
      #expect(kinds == [.read, .ddl])
    }
  }

  // MARK: - affectsAllRows Tests (classifier; replaces prefix-based hasWhereClause/affectsAllRows)

  @Suite("affectsAllRows - All Rows Detection")
  struct AffectsAllRowsTests {

    func affectsAllRows(_ query: String) -> Bool {
      SQLStatementClassifier.classify(query).first?.affectsAllRows ?? false
    }

    @Test("DELETE without WHERE affects all rows")
    func deleteWithoutWhereAffectsAllRows() {
      for query in ["DELETE FROM users", "DELETE FROM users;", "delete from accounts"] {
        #expect(affectsAllRows(query), "Should affect all rows: \(query)")
      }
    }

    @Test("DELETE with WHERE does not affect all rows")
    func deleteWithWhereDoesNotAffectAllRows() {
      for query in [
        "DELETE FROM users WHERE id = 1",
        "DELETE FROM users WHERE name = 'John'",
        "delete from users where active = false",
      ] {
        #expect(!affectsAllRows(query), "Should not affect all rows: \(query)")
      }
    }

    @Test("UPDATE without WHERE affects all rows")
    func updateWithoutWhereAffectsAllRows() {
      for query in [
        "UPDATE users SET active = false", "UPDATE accounts SET balance = 0",
        "update users set active = false",
      ] {
        #expect(affectsAllRows(query), "Should affect all rows: \(query)")
      }
    }

    @Test("UPDATE with WHERE does not affect all rows")
    func updateWithWhereDoesNotAffectAllRows() {
      for query in [
        "UPDATE users SET name = 'x' WHERE id = 1",
        "UPDATE accounts SET balance = 0 WHERE active = false",
      ] {
        #expect(!affectsAllRows(query), "Should not affect all rows: \(query)")
      }
    }

    @Test("SELECT, INSERT, DROP and TRUNCATE do not use affectsAllRows")
    func otherStatementsDoNotAffectAllRows() {
      for query in [
        "SELECT * FROM users", "INSERT INTO users VALUES (1)", "DROP TABLE users",
        "TRUNCATE TABLE users",
      ] {
        #expect(!affectsAllRows(query), "Not DELETE/UPDATE: \(query)")
      }
    }

    @Test("WHERE in comment is ignored")
    func whereInCommentIsIgnored() {
      #expect(affectsAllRows("-- WHERE id = 1\nDELETE FROM users"))
    }

    @Test("WHERE in a string literal is ignored")
    func whereInStringIsIgnored() {
      #expect(affectsAllRows("UPDATE users SET note = 'WHERE id = 1'"))
    }
  }

  // MARK: - SQL Syntax Behavior Tests

  @Suite("SQL Syntax Behavior - Alias and Typos")
  struct SQLSyntaxBehaviorTests {

    @Test("Trailing word after table name is treated as table alias by SQL")
    func trailingWordTreatedAsAlias() throws {
      let manager = DatabaseConnectionManager()

      let validQueries = [
        "SELECT * FROM users u",
        "SELECT * FROM users AS u",
        "SELECT * FROM bot limi",
        "SELECT * FROM bot whatever",
      ]

      for query in validQueries {
        #expect(manager.isSelectQuery(query) == true, "'\(query)' should be recognized as SELECT")
      }
    }
  }

  // MARK: - Integration Tests - Real-world Scenarios

  @Suite("Integration - Real-world Scenarios")
  struct IntegrationTests {

    @Test("Scenario: Query with inline comments and string literals")
    func queryWithInlineCommentsAndStringLiterals() throws {
      let manager = DatabaseConnectionManager()

      let query = """
        SELECT /* user cols */ name, email, '-- not a comment' AS note
        FROM users -- active users only
        WHERE status = 'active'
        """

      let stripped = manager.stripAllComments(query)

      #expect(!stripped.contains("/*"), "Should remove multi-line comment marker")
      #expect(!stripped.contains("user cols"), "Should remove comment content")
      #expect(!stripped.contains("-- active users only"), "Should remove single-line comment")
      #expect(stripped.contains("'-- not a comment'"), "Should preserve string literal")
      #expect(stripped.contains("name, email"), "Should preserve column list")
      #expect(stripped.contains("WHERE status = 'active'"), "Should preserve WHERE clause")
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

      let stripped = manager.stripAllComments(query)

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
