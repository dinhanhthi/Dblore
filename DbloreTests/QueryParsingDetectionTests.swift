// QueryParsingDetectionTests.swift
// Tests for SQL query type detection (SELECT, modification queries, etc.)

import Foundation
import Testing

@testable import Dblore

@Suite("Query Parsing - Query Detection Tests")
@MainActor
struct QueryParsingDetectionTests {

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

    @Test("WHERE in comment is ignored")
    func whereInCommentIsIgnored() {
      #expect(affectsAllRows("-- WHERE id = 1\nDELETE FROM users"))
    }

    @Test("WHERE in a string literal is ignored")
    func whereInStringIsIgnored() {
      #expect(affectsAllRows("UPDATE users SET note = 'WHERE id = 1'"))
    }
  }

}
