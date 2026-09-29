// SQLStatementClassifierTests.swift
// Tests for SQLStatementClassifier statement kinds and safety flags

import Foundation
import Testing

@testable import Dblore

struct ClassifierCase: Sendable, CustomTestStringConvertible {
  let sql: String
  let kind: StatementKind
  var returning = false
  var allRows = false
  var nonTx = false

  var testDescription: String {
    sql.replacingOccurrences(of: "\n", with: " ")
  }
}

@Suite("SQL Statement Classifier")
struct SQLStatementClassifierTests {
  // MARK: - Single statement kinds and flags

  static let cases: [ClassifierCase] = [
    // Read
    ClassifierCase(sql: "SELECT 1", kind: .read),
    ClassifierCase(sql: "select * from t", kind: .read),
    ClassifierCase(sql: "SeLeCt a FrOm t WhErE b = 1", kind: .read),
    ClassifierCase(sql: "select 'DROP TABLE t'", kind: .read),
    ClassifierCase(sql: "SELECT \"into\" FROM t", kind: .read),
    ClassifierCase(sql: "SELECT 'x INTO y' FROM t", kind: .read),
    ClassifierCase(sql: "SELECT * FROM t FOR UPDATE", kind: .read),
    ClassifierCase(sql: "(SELECT 1)", kind: .read),
    ClassifierCase(sql: "((SELECT 1) UNION (SELECT 2))", kind: .read),
    ClassifierCase(sql: "TABLE t", kind: .read),
    ClassifierCase(sql: "VALUES (1)", kind: .read),
    ClassifierCase(sql: "SHOW ALL", kind: .read),
    ClassifierCase(sql: "show statement_timeout", kind: .read),
    ClassifierCase(sql: "WITH x AS (SELECT 1) SELECT * FROM x", kind: .read),
    ClassifierCase(
      sql: "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT * FROM r",
      kind: .read
    ),
    ClassifierCase(sql: "WITH x AS (SELECT * FROM t FOR UPDATE) SELECT * FROM x", kind: .read),
    ClassifierCase(sql: "/* header */ -- line\n  SELECT 1", kind: .read),
    // DML
    ClassifierCase(sql: "/*x*/ DELETE FROM t", kind: .dml, allRows: true),
    ClassifierCase(sql: "DELETE FROM t WHERE id = 1", kind: .dml),
    ClassifierCase(sql: "delete from t", kind: .dml, allRows: true),
    ClassifierCase(sql: "DELETE FROM t USING u", kind: .dml, allRows: true),
    ClassifierCase(sql: "DELETE FROM t WHERE CURRENT OF c", kind: .dml),
    ClassifierCase(sql: "UPDATE t SET a = (SELECT 1 WHERE true)", kind: .dml, allRows: true),
    ClassifierCase(sql: "UPDATE t SET a = 1 WHERE id = 2", kind: .dml),
    ClassifierCase(sql: "UPDATE t SET \"where\" = 1", kind: .dml, allRows: true),
    ClassifierCase(sql: "UPDATE t SET a = 'WHERE x'", kind: .dml, allRows: true),
    ClassifierCase(sql: "UPDATE t SET a = 1 -- WHERE id = 1", kind: .dml, allRows: true),
    ClassifierCase(
      sql: "UPDATE t SET a = 1 RETURNING *", kind: .dml, returning: true, allRows: true
    ),
    ClassifierCase(sql: "INSERT INTO t VALUES (1)", kind: .dml),
    ClassifierCase(sql: "INSERT INTO t (a) VALUES (1) RETURNING id", kind: .dml, returning: true),
    ClassifierCase(sql: "INSERT INTO t SELECT * FROM u", kind: .dml),
    ClassifierCase(sql: "insert into t values ('RETURNING')", kind: .dml),
    ClassifierCase(
      sql: "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a", kind: .dml
    ),
    ClassifierCase(sql: "SELECT * INTO new_t FROM t", kind: .dml),
    ClassifierCase(sql: "(SELECT * INTO new_t FROM t)", kind: .dml),
    ClassifierCase(
      sql: "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", kind: .dml, returning: true,
      allRows: true
    ),
    ClassifierCase(
      sql: "WITH d AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM d", kind: .dml,
      returning: true
    ),
    ClassifierCase(
      sql: "WITH a AS (SELECT 1), b AS NOT MATERIALIZED (INSERT INTO t VALUES (1)) SELECT 1",
      kind: .dml
    ),
    ClassifierCase(
      sql: "WITH x AS (SELECT * FROM u WHERE y) UPDATE t SET a = 1", kind: .dml, allRows: true
    ),
    ClassifierCase(sql: "WITH x AS (SELECT 1) DELETE FROM t WHERE id IN (SELECT 1)", kind: .dml),
    ClassifierCase(sql: "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", kind: .dml),
    ClassifierCase(sql: "WITH x AS (SELECT 1) SELECT * INTO y FROM x", kind: .dml),
    // DDL
    ClassifierCase(sql: "-- c\nDROP TABLE t", kind: .ddl),
    ClassifierCase(sql: "-- c\r\nDROP TABLE t", kind: .ddl),
    ClassifierCase(sql: "CREATE TABLE t (id int)", kind: .ddl),
    ClassifierCase(sql: "ALTER TABLE t ADD COLUMN b int", kind: .ddl),
    ClassifierCase(sql: "TRUNCATE t", kind: .ddl),
    ClassifierCase(sql: "COMMENT ON TABLE t IS 'x'", kind: .ddl),
    ClassifierCase(sql: "CREATE INDEX CONCURRENTLY i ON t (a)", kind: .ddl, nonTx: true),
    ClassifierCase(sql: "DROP INDEX CONCURRENTLY i", kind: .ddl, nonTx: true),
    ClassifierCase(sql: "CREATE DATABASE d", kind: .ddl, nonTx: true),
    ClassifierCase(sql: "DROP DATABASE IF EXISTS d", kind: .ddl, nonTx: true),
    ClassifierCase(sql: "CREATE TABLESPACE ts LOCATION '/x'", kind: .ddl, nonTx: true),
    ClassifierCase(sql: "ALTER SYSTEM SET work_mem = '1MB'", kind: .ddl, nonTx: true),
    ClassifierCase(
      sql:
        "CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ DELETE FROM t; SELECT 1 $$ LANGUAGE sql",
      kind: .ddl
    ),
    // TCL
    ClassifierCase(sql: "BEGIN", kind: .tcl),
    ClassifierCase(sql: "START TRANSACTION", kind: .tcl),
    ClassifierCase(sql: "COMMIT", kind: .tcl),
    ClassifierCase(sql: "END", kind: .tcl),
    ClassifierCase(sql: "ROLLBACK", kind: .tcl),
    ClassifierCase(sql: "ABORT", kind: .tcl),
    ClassifierCase(sql: "SAVEPOINT a", kind: .tcl),
    ClassifierCase(sql: "RELEASE SAVEPOINT a", kind: .tcl),
    ClassifierCase(sql: "PREPARE TRANSACTION 'x'", kind: .tcl),
    ClassifierCase(sql: "COMMIT PREPARED 'x'", kind: .tcl),
    ClassifierCase(sql: "ROLLBACK PREPARED 'x'", kind: .tcl),
    // Session SET
    ClassifierCase(sql: "SET statement_timeout = 0", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(sql: "set LOCAL lock_timeout TO '1s'", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(
      sql: "SET SESSION idle_in_transaction_session_timeout = 0",
      kind: .sessionSet(touchesBrake: true)
    ),
    ClassifierCase(sql: "SET transaction_read_only = off", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(
      sql: "SET default_transaction_read_only = off", kind: .sessionSet(touchesBrake: true)
    ),
    ClassifierCase(sql: "SET \"statement_timeout\" = 0", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(
      sql: "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
      kind: .sessionSet(touchesBrake: true)
    ),
    ClassifierCase(
      sql: "SET SESSION SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
      kind: .sessionSet(touchesBrake: true)
    ),
    ClassifierCase(
      sql: "SET LOCAL SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
      kind: .sessionSet(touchesBrake: true)
    ),
    ClassifierCase(sql: "SET TRANSACTION READ WRITE", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(sql: "RESET ALL", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(sql: "RESET statement_timeout", kind: .sessionSet(touchesBrake: true)),
    ClassifierCase(sql: "SET search_path TO x", kind: .sessionSet(touchesBrake: false)),
    ClassifierCase(sql: "RESET search_path", kind: .sessionSet(touchesBrake: false)),
    // Utility
    ClassifierCase(sql: "DO $$ BEGIN DELETE FROM t; END $$", kind: .utility),
    ClassifierCase(sql: "GRANT SELECT ON t TO u", kind: .utility),
    ClassifierCase(sql: "REVOKE SELECT ON t FROM u", kind: .utility),
    ClassifierCase(sql: "COPY t FROM STDIN", kind: .utility),
    ClassifierCase(sql: "CALL p()", kind: .utility),
    ClassifierCase(sql: "VACUUM", kind: .utility, nonTx: true),
    ClassifierCase(sql: "vacuum full t", kind: .utility, nonTx: true),
    ClassifierCase(sql: "ANALYZE t", kind: .utility),
    ClassifierCase(sql: "REINDEX TABLE CONCURRENTLY t", kind: .utility, nonTx: true),
    ClassifierCase(sql: "REINDEX TABLE t", kind: .utility),
    ClassifierCase(sql: "CLUSTER t", kind: .utility),
    ClassifierCase(sql: "LOCK TABLE t IN ACCESS EXCLUSIVE MODE", kind: .utility),
    ClassifierCase(sql: "NOTIFY ch", kind: .utility),
    ClassifierCase(sql: "LISTEN ch", kind: .utility),
    ClassifierCase(sql: "DISCARD ALL", kind: .utility),
    ClassifierCase(sql: "CHECKPOINT", kind: .utility),
    ClassifierCase(sql: "REFRESH MATERIALIZED VIEW mv", kind: .utility),
    ClassifierCase(sql: "SECURITY LABEL ON TABLE t IS 'x'", kind: .utility),
    // Explain
    ClassifierCase(sql: "EXPLAIN SELECT 1", kind: .explain(inner: .read, analyze: false)),
    ClassifierCase(sql: "EXPLAIN DELETE FROM t", kind: .explain(inner: .dml, analyze: false)),
    ClassifierCase(
      sql: "EXPLAIN ANALYZE DELETE FROM t", kind: .explain(inner: .dml, analyze: true),
      allRows: true
    ),
    ClassifierCase(
      sql: "explain analyse verbose select 1", kind: .explain(inner: .read, analyze: true)
    ),
    ClassifierCase(
      sql: "EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET a = 1 WHERE id = 1",
      kind: .explain(inner: .dml, analyze: true)
    ),
    ClassifierCase(
      sql: "EXPLAIN (ANALYZE true) DELETE FROM t WHERE id = 1",
      kind: .explain(inner: .dml, analyze: true)
    ),
    ClassifierCase(
      sql: "EXPLAIN (ANALYZE off, COSTS) DELETE FROM t", kind: .explain(inner: .dml, analyze: false)
    ),
    ClassifierCase(
      sql: "EXPLAIN (FORMAT JSON) SELECT 1", kind: .explain(inner: .read, analyze: false)
    ),
    ClassifierCase(sql: "EXPLAIN (SELECT 1)", kind: .explain(inner: .read, analyze: false)),
    // Unknown
    ClassifierCase(sql: "FOOBAR", kind: .unknown),
    ClassifierCase(sql: "EXECUTE stmt(1)", kind: .unknown),
  ]

  @Test("Classifies single statement", arguments: cases)
  func classifySingle(_ testCase: ClassifierCase) throws {
    let result = SQLStatementClassifier.classify(testCase.sql)
    try #require(result.count == 1)
    let statement = result[0]
    #expect(statement.kind == testCase.kind)
    #expect(statement.hasReturning == testCase.returning)
    #expect(statement.affectsAllRows == testCase.allRows)
    #expect(statement.nonTransactional == testCase.nonTx)
  }

  // MARK: - Splitting and empty input

  @Test("Multiple statements are classified independently")
  func multipleStatements() {
    let result = SQLStatementClassifier.classify("SELECT 1; DROP TABLE t")
    #expect(result.map(\.kind) == [.read, .ddl])
    #expect(result.map(\.text) == ["SELECT 1", "DROP TABLE t"])
  }

  @Test("Dollar-quoted DO body stays a single utility statement")
  func doBlockSingleStatement() {
    let result = SQLStatementClassifier.classify("DO $$ BEGIN DELETE FROM t; END $$; SELECT 1")
    #expect(result.map(\.kind) == [.utility, .read])
  }

  @Test(
    "Empty and comment-only input yields no statements",
    arguments: ["", "   \n", "-- c", "/* x */", "-- a\n/* b */ ;"]
  )
  func emptyInput(_ sql: String) {
    #expect(SQLStatementClassifier.classify(sql).isEmpty)
  }

  // MARK: - Convenience

  @Test("isReadOnlySafe only for reads and plain EXPLAIN")
  func readOnlySafe() {
    let safe = SQLStatementClassifier.classify("SELECT 1; EXPLAIN DELETE FROM t; SHOW ALL")
    #expect(safe.allSatisfy { $0.isReadOnlySafe })
    let unsafe = SQLStatementClassifier.classify(
      "EXPLAIN ANALYZE SELECT 1; DELETE FROM t; SET a = 1; BEGIN; VACUUM; FOOBAR; CREATE TABLE x ()"
    )
    #expect(unsafe.allSatisfy { !$0.isReadOnlySafe })
  }

  @Test("Summary aggregates statements")
  func summary() {
    let read = SQLStatementClassifier.summary(SQLStatementClassifier.classify("SELECT 1; TABLE t"))
    #expect(
      !read.hasModification && !read.hasSchemaChange && !read.hasUnknown && !read.affectsAllRows
    )

    let mixed = SQLStatementClassifier.summary(
      SQLStatementClassifier.classify("SELECT 1; DELETE FROM t; DROP TABLE u; FOOBAR")
    )
    #expect(
      mixed.hasModification && mixed.hasSchemaChange && mixed.hasUnknown && mixed.affectsAllRows
    )

    let explained = SQLStatementClassifier.summary(
      SQLStatementClassifier.classify("EXPLAIN ANALYZE UPDATE t SET a = 1 WHERE id = 1")
    )
    #expect(explained.hasModification && !explained.hasSchemaChange && !explained.affectsAllRows)

    let plainExplain = SQLStatementClassifier.summary(
      SQLStatementClassifier.classify("EXPLAIN DROP TABLE t")
    )
    #expect(!plainExplain.hasModification && !plainExplain.hasSchemaChange)
  }

  // MARK: - Session brakes and privilege context

  static let brakeResetCases: [(String, Bool)] = [
    ("SET statement_timeout = 0", true),
    ("RESET ALL", true),
    ("SET TRANSACTION READ WRITE", true),
    ("SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", true),
    ("SET SESSION SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", true),
    ("SET LOCAL SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", true),
    ("DISCARD ALL", true),
    ("discard all", true),
    ("DISCARD TEMP", false),
    ("DISCARD PLANS", false),
    ("BEGIN READ WRITE", true),
    ("START TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ WRITE", true),
    ("BEGIN WORK READ ONLY, READ WRITE", true),
    ("BEGIN", false),
    ("BEGIN READ ONLY", false),
    ("BEGIN ISOLATION LEVEL READ COMMITTED", false),
    ("SET search_path TO x", false),
    ("SET SESSION search_path TO x", false),
    ("SET SESSION AUTHORIZATION admin", false),
    ("SELECT 'READ WRITE'", false),
  ]

  @Test(
    "resetsSessionBrakes flags statements that can undo the session brakes",
    arguments: brakeResetCases
  )
  func resetsSessionBrakes(_ sql: String, _ expected: Bool) {
    let result = SQLStatementClassifier.classify(sql)
    #expect(result.map(\.resetsSessionBrakes) == [expected])
    #expect(SQLStatementClassifier.summary(result).touchesBrake == expected)
  }

  static let privilegeCases: [(String, Bool)] = [
    ("SET ROLE admin", true),
    ("set role none", true),
    ("SET SESSION ROLE admin", true),
    ("SET LOCAL ROLE admin", true),
    ("SET SESSION AUTHORIZATION admin", true),
    ("SET LOCAL SESSION AUTHORIZATION DEFAULT", true),
    ("SET SESSION SESSION AUTHORIZATION admin", true),
    ("RESET ROLE", true),
    ("RESET SESSION AUTHORIZATION", true),
    ("SET role = 'admin'", true),
    ("SET \"Role\" TO admin", true),
    ("SET session_authorization = 'admin'", true),
    ("DISCARD ALL", true),
    ("SET search_path TO x", false),
    ("SET SESSION search_path TO x", false),
    ("RESET ALL", false),
    ("SELECT 1", false),
  ]

  @Test(
    "changesPrivileges flags statements that switch the privilege context",
    arguments: privilegeCases
  )
  func changesPrivileges(_ sql: String, _ expected: Bool) {
    let result = SQLStatementClassifier.classify(sql)
    #expect(result.map(\.changesPrivileges) == [expected])
    #expect(SQLStatementClassifier.summary(result).changesPrivileges == expected)
    #expect(result.allSatisfy { !$0.isReadOnlySafe } || !expected)
  }
}
