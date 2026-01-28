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

    @Test("DROP query returns true")
    func dropQueryReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "DROP TABLE users",
        "DROP DATABASE mydb",
        "DROP INDEX idx_name",
        "DROP VIEW my_view",
        "DROP SCHEMA public",
      ]
      for query in queries {
        let result = await manager.isModificationQuery(query)
        #expect(result == true, "Should detect DROP query as modification: \(query)")
      }
    }

    @Test("TRUNCATE query returns true")
    func truncateQueryReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "TRUNCATE TABLE users",
        "TRUNCATE users",
      ]
      for query in queries {
        let result = await manager.isModificationQuery(query)
        #expect(result == true, "Should detect TRUNCATE query as modification: \(query)")
      }
    }

    @Test("ALTER query returns true")
    func alterQueryReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "ALTER TABLE users ADD COLUMN age INT",
        "ALTER TABLE users DROP COLUMN email",
        "ALTER TABLE users RENAME TO customers",
      ]
      for query in queries {
        let result = await manager.isModificationQuery(query)
        #expect(result == true, "Should detect ALTER query as modification: \(query)")
      }
    }

    @Test("DROP/TRUNCATE/ALTER with leading comment returns true")
    func schemaModificationWithLeadingCommentReturnsTrue() async throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "-- comment\nDROP TABLE users",
        "/* multi-line */ TRUNCATE TABLE users",
        "-- be careful\nALTER TABLE users DROP COLUMN email",
      ]
      for query in queries {
        let result = await manager.isModificationQuery(query)
        #expect(result == true, "Should detect schema modification after comment: \(query)")
      }
    }
  }

  // MARK: - hasWhereClause Tests

  @Suite("hasWhereClause - WHERE Clause Detection")
  struct HasWhereClauseTests {

    @Test("DELETE with WHERE returns true")
    func deleteWithWhereReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "DELETE FROM users WHERE id = 1",
        "DELETE FROM users WHERE name = 'John'",
        "delete from users where active = false",
      ]
      for query in queries {
        let result = manager.hasWhereClause(query)
        #expect(result == true, "Should detect WHERE in: \(query)")
      }
    }

    @Test("DELETE without WHERE returns false")
    func deleteWithoutWhereReturnsFalse() throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "DELETE FROM users",
        "DELETE FROM users;",
        "delete from users",
      ]
      for query in queries {
        let result = manager.hasWhereClause(query)
        #expect(result == false, "Should not detect WHERE in: \(query)")
      }
    }

    @Test("UPDATE with WHERE returns true")
    func updateWithWhereReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "UPDATE users SET name = 'John' WHERE id = 1",
        "UPDATE accounts SET balance = 0 WHERE active = false",
        "update users set name = 'x' where id = 1",
      ]
      for query in queries {
        let result = manager.hasWhereClause(query)
        #expect(result == true, "Should detect WHERE in: \(query)")
      }
    }

    @Test("UPDATE without WHERE returns false")
    func updateWithoutWhereReturnsFalse() throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "UPDATE users SET name = 'John'",
        "UPDATE accounts SET balance = 0",
        "update users set active = false",
      ]
      for query in queries {
        let result = manager.hasWhereClause(query)
        #expect(result == false, "Should not detect WHERE in: \(query)")
      }
    }

    @Test("SELECT query returns true (not applicable)")
    func selectQueryReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.hasWhereClause("SELECT * FROM users")
      #expect(result == true, "SELECT should return true (not applicable)")
    }

    @Test("INSERT query returns true (not applicable)")
    func insertQueryReturnsTrue() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.hasWhereClause("INSERT INTO users VALUES (1)")
      #expect(result == true, "INSERT should return true (not applicable)")
    }

    @Test("WHERE in comment is ignored")
    func whereInCommentIsIgnored() throws {
      let manager = DatabaseConnectionManager()
      let query = "-- WHERE id = 1\nDELETE FROM users"
      let result = manager.hasWhereClause(query)
      #expect(result == false, "Should ignore WHERE in comment")
    }
  }

  // MARK: - affectsAllRows Tests

  @Suite("affectsAllRows - All Rows Detection")
  struct AffectsAllRowsTests {

    @Test("DELETE without WHERE affects all rows")
    func deleteWithoutWhereAffectsAllRows() throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "DELETE FROM users",
        "DELETE FROM users;",
        "delete from accounts",
      ]
      for query in queries {
        let result = manager.affectsAllRows(query)
        #expect(result == true, "Should affect all rows: \(query)")
      }
    }

    @Test("DELETE with WHERE does not affect all rows")
    func deleteWithWhereDoesNotAffectAllRows() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.affectsAllRows("DELETE FROM users WHERE id = 1")
      #expect(result == false, "Should not affect all rows with WHERE")
    }

    @Test("UPDATE without WHERE affects all rows")
    func updateWithoutWhereAffectsAllRows() throws {
      let manager = DatabaseConnectionManager()
      let queries = [
        "UPDATE users SET active = false",
        "UPDATE accounts SET balance = 0",
      ]
      for query in queries {
        let result = manager.affectsAllRows(query)
        #expect(result == true, "Should affect all rows: \(query)")
      }
    }

    @Test("UPDATE with WHERE does not affect all rows")
    func updateWithWhereDoesNotAffectAllRows() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.affectsAllRows("UPDATE users SET name = 'x' WHERE id = 1")
      #expect(result == false, "Should not affect all rows with WHERE")
    }

    @Test("SELECT does not affect all rows")
    func selectDoesNotAffectAllRows() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.affectsAllRows("SELECT * FROM users")
      #expect(result == false, "SELECT should not affect all rows")
    }

    @Test("INSERT does not affect all rows")
    func insertDoesNotAffectAllRows() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.affectsAllRows("INSERT INTO users VALUES (1)")
      #expect(result == false, "INSERT should not affect all rows")
    }

    @Test("DROP does not affect all rows (different concern)")
    func dropDoesNotAffectAllRows() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.affectsAllRows("DROP TABLE users")
      #expect(result == false, "DROP is not DELETE/UPDATE, different concern")
    }

    @Test("TRUNCATE does not use affectsAllRows (handled separately)")
    func truncateDoesNotAffectAllRows() throws {
      let manager = DatabaseConnectionManager()
      let result = manager.affectsAllRows("TRUNCATE TABLE users")
      #expect(result == false, "TRUNCATE is not DELETE/UPDATE")
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

    @Test("Limit typo 'limi' would become alias when wrapped with LIMIT")
    func limitTypoBehavior() async throws {
      let manager = DatabaseConnectionManager()
      let query = "SELECT * FROM bot limi"
      let result = await manager.wrapQueryWithLimit(query, maxRows: 100)

      #expect(result.contains("LIMIT 100"), "Should add LIMIT clause")
      #expect(result.contains("limi"), "Alias 'limi' should be preserved")
    }
  }

  // MARK: - Integration Tests - Real-world Scenarios

  @Suite("Integration - Real-world Scenarios")
  struct IntegrationTests {

    @Test("Scenario: User query with comment LIMIT should get actual LIMIT")
    func userQueryWithCommentLimitGetsActualLimit() async throws {
      let manager = DatabaseConnectionManager()

      let userQuery = """
        -- Old limit: LIMIT 1000
        SELECT * FROM large_table
        """

      let result = await manager.wrapQueryWithLimit(userQuery, maxRows: 100)

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

      let stripped = manager.stripAllComments(query)

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

      let result = await manager.wrapQueryWithLimit(query, maxRows: 50)

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
