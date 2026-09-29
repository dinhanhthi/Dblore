// ProtectionGateTests.swift
// Tests for the execution gate in DatabaseConnectionManager (statement-level protection)

import Foundation
import Testing

@testable import Dblore

// MARK: - Helpers

private let readOnly = ProtectionPolicy(protectionLevel: .readOnly)
private let schemaOnly = ProtectionPolicy(protectionLevel: .schemaOnly)
private let unprotected = ProtectionPolicy(protectionLevel: .none)

private func decide(_ sql: String, _ policy: ProtectionPolicy) -> GateDecision {
  DatabaseConnectionManager.evaluate(SQLStatementClassifier.classify(sql), policy: policy)
}

private func blockedIndex(_ sql: String, _ policy: ProtectionPolicy) -> Int? {
  guard case .blocked(let index, _, _) = decide(sql, policy) else { return nil }
  return index
}

// MARK: - Pure gate evaluation

@Suite("Protection Gate - evaluate")
struct ProtectionGateTests {

  // MARK: Read-only

  @Test("readOnly blocks the hidden DROP in 'SELECT 1; DROP TABLE t' at index 1")
  func readOnlyBlocksHiddenDrop() {
    guard
      case .blocked(let index, let kind, let reason) = decide("SELECT 1; DROP TABLE t", readOnly)
    else {
      Issue.record("Expected blocked")
      return
    }
    #expect(index == 1)
    #expect(kind == .ddl)
    #expect(!reason.isEmpty)
  }

  @Test(
    "readOnly blocks anything that is not read-only safe",
    arguments: [
      "INSERT INTO t VALUES (1)",
      "UPDATE t SET a = 1 WHERE id = 1",
      "DELETE FROM t WHERE id = 1",
      "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE",
      "CREATE TABLE t (id int)",
      "DROP TABLE t",
      "ALTER TABLE t ADD COLUMN b int",
      "TRUNCATE t",
      "FROBNICATE t",
      "DO $$ BEGIN DROP TABLE t; END $$",
      "CALL p()",
      "COPY t FROM '/tmp/x'",
      "EXPLAIN ANALYZE DELETE FROM t",
      "EXPLAIN ANALYZE SELECT * FROM t",
      "EXPLAIN FROBNICATE t",
      "SET statement_timeout = 0",
      "SET ROLE admin",
      "RESET ALL",
      "SET search_path = x",
      "BEGIN",
      "COMMIT",
      "SELECT * INTO new_t FROM t",
    ])
  func readOnlyBlocks(sql: String) {
    #expect(blockedIndex(sql, readOnly) == 0, "\(sql)")
  }

  @Test(
    "readOnly allows reads",
    arguments: [
      "SELECT 1",
      "select * from t where a = 1",
      "EXPLAIN SELECT * FROM t",
      "EXPLAIN DELETE FROM t",
      "SHOW statement_timeout",
      "TABLE t",
      "VALUES (1), (2)",
      "WITH x AS (SELECT 1) SELECT * FROM x",
      "SELECT 1; SELECT 2",
      "-- comment only; SELECT 1",
    ])
  func readOnlyAllows(sql: String) {
    #expect(decide(sql, readOnly) == .allowed, "\(sql)")
  }

  @Test("readOnly reports the first violating statement")
  func readOnlyFirstViolation() {
    #expect(blockedIndex("SELECT 1; SELECT 2; UPDATE t SET a = 1; DROP TABLE t", readOnly) == 2)
  }

  // MARK: Schema-only

  @Test(
    "schemaOnly blocks schema changes, non-transactional, utility, unknown and table creation",
    arguments: [
      "CREATE TABLE t (id int)",
      "DROP TABLE t",
      "ALTER TABLE t ADD COLUMN b int",
      "TRUNCATE t",
      "COMMENT ON TABLE t IS 'x'",
      "CREATE INDEX CONCURRENTLY i ON t (a)",
      "VACUUM t",
      "DO $$ BEGIN DROP TABLE t; END $$",
      "CALL p()",
      "GRANT SELECT ON t TO u",
      "FROBNICATE t",
      "SELECT * INTO new_t FROM t",
      "(SELECT * INTO new_t FROM t)",
      "WITH x AS (SELECT 1) SELECT * INTO y FROM x",
      "EXPLAIN ANALYZE CREATE TABLE t2 AS SELECT 1",
      "EXPLAIN ANALYZE SELECT * INTO new_t FROM t",
      "EXPLAIN FROBNICATE t",
    ])
  func schemaOnlyBlocks(sql: String) {
    #expect(blockedIndex(sql, schemaOnly) == 0, "\(sql)")
  }

  @Test(
    "schemaOnly allows reads and data modification",
    arguments: [
      "SELECT 1",
      "INSERT INTO t VALUES (1)",
      "UPDATE t SET a = 1",
      "DELETE FROM t",
      "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x",
      "WITH a AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM a",
      "EXPLAIN ANALYZE DELETE FROM t WHERE id = 1",
      "EXPLAIN CREATE TABLE t2 AS SELECT 1",
      "SET statement_timeout = 0",
      "BEGIN",
      "SHOW search_path",
    ])
  func schemaOnlyAllows(sql: String) {
    #expect(decide(sql, schemaOnly) == .allowed, "\(sql)")
  }

  @Test("schemaOnly blocks the DDL hidden after DML")
  func schemaOnlyHiddenDDL() {
    #expect(blockedIndex("UPDATE t SET a = 1; DROP TABLE t", schemaOnly) == 1)
  }

  // MARK: None

  @Test(
    "none allows everything",
    arguments: [
      "DROP TABLE t", "DO $$ BEGIN END $$", "FROBNICATE", "SET ROLE admin",
      "SELECT * INTO new_t FROM t", "VACUUM", "SELECT 1; DELETE FROM t",
    ])
  func noneAllows(sql: String) {
    #expect(decide(sql, unprotected) == .allowed, "\(sql)")
  }

  @Test("Empty statement list is allowed (emptyQuery is reported by execution)")
  func emptyIsAllowed() {
    #expect(DatabaseConnectionManager.evaluate([], policy: readOnly) == .allowed)
  }

  // MARK: Policy

  @Test("Policy is built from ConnectionConfig; nil config is unprotected")
  @MainActor
  func policyFromConfig() {
    let config = ConnectionConfig(protectionLevel: .schemaOnly, safeMode: .alertAll)
    let policy = ProtectionPolicy(config: config)
    let expectedProtectedMode = config.protectedMode
    #expect(policy.protectionLevel == .schemaOnly)
    #expect(policy.safeMode == .alertAll)
    #expect(policy.protectedMode == expectedProtectedMode)
    #expect(ProtectionPolicy(config: nil).protectionLevel == .none)
  }

  // MARK: Error

  @Test("blockedByProtection has a user-facing message")
  func errorMessage() {
    let error = DatabaseError.blockedByProtection(
      statementIndex: 1, kind: .ddl, reason: "Schema change is not allowed")
    let message = error.localizedDescription
    #expect(message.contains("statement 2"))
    #expect(message.contains("Schema change is not allowed"))
    #expect(message.contains("Nothing was executed"))
  }

  // MARK: Actor entry point

  @Test("Actor gate throws blockedByProtection before checking the connection")
  func actorGateThrowsBeforeConnection() async {
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.execute(userSQL: "SELECT 1; DROP TABLE t", policy: readOnly)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, let kind, _) {
      #expect(index == 1)
      #expect(kind == .ddl)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("Detailed actor gate throws blockedByProtection before checking the connection")
  func detailedActorGateThrows() async {
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.executeDetailed(userSQL: "UPDATE t SET a = 1", policy: readOnly)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, _, _) {
      #expect(index == 0)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("Allowed SQL reaches the connection check")
  func allowedReachesConnection() async {
    let manager = DatabaseConnectionManager()
    do {
      _ = try await manager.execute(userSQL: "SELECT 1", policy: readOnly)
      Issue.record("Expected notConnected")
    } catch DatabaseError.notConnected {
      // expected
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

// MARK: - Classifier createsTable flag

@Suite("SQL Statement Classifier - createsTable")
struct ClassifierCreatesTableTests {

  @Test(
    "SELECT/WITH ... INTO creates a table",
    arguments: [
      "SELECT * INTO new_t FROM t",
      "(SELECT * INTO new_t FROM t)",
      "SELECT a INTO TEMP x FROM t",
      "WITH x AS (SELECT 1) SELECT * INTO y FROM x",
      "WITH x AS (SELECT 1) (SELECT * INTO t FROM x)",
      "WITH a AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * INTO y FROM a",
      "SELECT insert INTO y FROM t",
      "EXPLAIN ANALYZE SELECT * INTO new_t FROM t",
    ])
  func createsTable(sql: String) {
    #expect(SQLStatementClassifier.classify(sql).first?.createsTable == true, "\(sql)")
  }

  @Test(
    "INSERT/MERGE INTO and plain reads do not create a table",
    arguments: [
      "SELECT 1",
      "SELECT 'x INTO y' FROM t",
      "INSERT INTO t VALUES (1)",
      "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE",
      "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x",
      "WITH a AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM a",
      "EXPLAIN SELECT * INTO new_t FROM t",
      "CREATE TABLE t (id int)",
    ])
  func doesNotCreateTable(sql: String) {
    #expect(SQLStatementClassifier.classify(sql).first?.createsTable == false, "\(sql)")
  }
}

// MARK: - Integration (docker test DB)

@Suite("Protection Gate - Integration (Requires PostgreSQL)")
@MainActor
struct ProtectionGateIntegrationTests {
  static let testConfig = ConnectionConfig(
    host: TestDatabase.host,
    port: TestDatabase.port,
    database: TestDatabase.database,
    username: TestDatabase.username,
    password: TestDatabase.password,
    sslMode: .disable,
    timeoutSeconds: 30
  )

  @Test("A blocked cell sends nothing: CREATE TABLE before SELECT is not executed")
  func blockedCellSendsNothing() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.testConfig)
    defer { Task { await manager.disconnect() } }

    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s4_probe")

    do {
      _ = try await manager.execute(
        userSQL: "CREATE TABLE s4_probe(x int); SELECT 1", policy: readOnly)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection(let index, let kind, _) {
      #expect(index == 0)
      #expect(kind == .ddl)
    }

    let probe = try await manager.execute(
      userSQL: "SELECT to_regclass('s4_probe')::text AS probe", policy: readOnly)
    #expect(probe.rows.first?.first == .null, "s4_probe must not exist after a blocked cell")
  }
}
