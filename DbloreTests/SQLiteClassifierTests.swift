// SQLiteClassifierTests.swift
// SQLite classification: PRAGMA, fail-closed commands, and writes the gate must block

import Foundation
import Testing

@testable import Dblore

private let readOnly = ProtectionPolicy(protectionLevel: .readOnly)
private let schemaOnly = ProtectionPolicy(protectionLevel: .schemaOnly)

private func sqliteStatements(_ sql: String) -> [ClassifiedStatement] {
  SQLStatementClassifier.classify(sql, dialect: .sqlite)
}

@Suite("SQLite Classifier")
struct SQLiteClassifierTests {

  @Test(
    "PRAGMA name is a read",
    arguments: [
      "PRAGMA foreign_keys",
      "pragma journal_mode",
      "PRAGMA writable_schema",
      "PRAGMA main.cache_size",
      "/* header */ PRAGMA table_info",
    ])
  func pragmaNameIsRead(sql: String) throws {
    let statements = sqliteStatements(sql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .read)
    #expect(statement.isReadOnlySafe)
    #expect(DatabaseConnectionManager.evaluate(statements, policy: readOnly) == .allowed)
    #expect(DatabaseConnectionManager.evaluate(statements, policy: schemaOnly) == .allowed)
  }

  @Test(
    "PRAGMA assignment is a schema-changing write",
    arguments: [
      "PRAGMA journal_mode = WAL",
      "PRAGMA writable_schema = ON",
      "PRAGMA foreign_keys = ON",
      "PRAGMA cache_size = 1000",
      "PRAGMA main.journal_mode=DELETE",
      "PRAGMA foreign_keys(1)",
      "PRAGMA \"journal_mode\" = wal",
    ])
  func pragmaAssignmentIsSchemaChange(sql: String) throws {
    let statements = sqliteStatements(sql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .ddl)
    #expect(!statement.isReadOnlySafe)
    #expect(SQLStatementClassifier.summary(statements).hasSchemaChange)
    #expect(blocked(statements, readOnly))
    #expect(blocked(statements, schemaOnly))
  }

  @Test(
    "ATTACH, DETACH, VACUUM INTO, and load_extension fail closed",
    arguments: [
      "ATTACH DATABASE 'other.db' AS other",
      "ATTACH 'other.db' AS other",
      "DETACH DATABASE other",
      "DETACH other",
      "VACUUM INTO 'backup.db'",
      "SELECT load_extension('ext')",
      "SELECT \"load_extension\"('ext')",
      "SELECT `load_extension`('ext')",
      "SELECT [load_extension]('ext')",
      "EXPLAIN SELECT load_extension('ext')",
    ])
  func failClosedCommand(sql: String) throws {
    let statements = sqliteStatements(sql)
    let statement = try #require(statements.first)
    #expect(!statement.isReadOnlySafe)
    #expect(blocked(statements, readOnly))
    #expect(blocked(statements, schemaOnly))
    let alert = NotebookViewModel.statementsNeedingConfirmation(statements, safeMode: .alertRead)
    let safe = NotebookViewModel.statementsNeedingConfirmation(statements, safeMode: .safeRead)
    #expect(alert?.isEmpty == false)
    #expect(safe?.isEmpty == false)
  }

  @Test("A load_extension mention that is not a call stays a read")
  func loadExtensionMentionStaysRead() throws {
    for sql in ["SELECT 'load_extension('", "SELECT 1 -- load_extension(", "SELECT load_extension"]
    {
      let statement = try #require(sqliteStatements(sql).first)
      #expect(statement.kind == .read, "\(sql)")
      #expect(statement.isReadOnlySafe)
    }
  }

  @Test(
    "REPLACE INTO, INSERT OR, and UPSERT are writes",
    arguments: [
      "REPLACE INTO t VALUES (1)",
      "INSERT OR REPLACE INTO t VALUES (1)",
      "INSERT OR IGNORE INTO t VALUES (1)",
      "INSERT OR ABORT INTO t VALUES (1)",
      "INSERT INTO t(a) VALUES (1) ON CONFLICT(a) DO UPDATE SET a = excluded.a",
    ])
  func recognizedWrites(sql: String) throws {
    let statement = try #require(sqliteStatements(sql).first)
    #expect(statement.kind == .dml)
    #expect(!statement.isReadOnlySafe)
  }

  @Test("WITH ... DELETE stays a write")
  func withDeleteStaysWrite() throws {
    let sql = "WITH d AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM d"
    let statement = try #require(sqliteStatements(sql).first)
    #expect(statement.kind == .dml)
    #expect(statement.hasReturning)
    #expect(!statement.isReadOnlySafe)
  }

  @Test("A later fail-closed statement blocks the script")
  func laterAttachBlocks() throws {
    let statements = sqliteStatements("PRAGMA foreign_keys; ATTACH 'other.db' AS other")
    #expect(statements.map(\.kind) == [.read, .utility])
    guard
      case .blocked(let index, _, _) = DatabaseConnectionManager.evaluate(
        statements, policy: readOnly)
    else {
      Issue.record("Expected the ATTACH to block")
      return
    }
    #expect(index == 1)
  }

  @Test("PostgreSQL classification does not gain the SQLite rules")
  func postgresRulesStay() throws {
    #expect(SQLStatementClassifier.classify("PRAGMA foreign_keys").first?.kind == .unknown)
    #expect(SQLStatementClassifier.classify("REPLACE INTO t VALUES (1)").first?.kind == .unknown)
    #expect(SQLStatementClassifier.classify("ATTACH 'other.db' AS other").first?.kind == .unknown)
    let call = try #require(
      SQLStatementClassifier.classify("SELECT load_extension('ext')").first)
    #expect(call.kind == .read)
    #expect(call.isReadOnlySafe)
  }

  @Test("The gate classifies with the connection dialect")
  func gateUsesConnectionDialect() {
    let sqlite = ConnectionConfig(databaseType: .sqlite, database: "test.db")
    let postgres = ConnectionConfig(databaseType: .postgresql)
    #expect(
      DatabaseConnectionManager.classifyUserSQL("PRAGMA foreign_keys", config: sqlite).first?.kind
        == .read)
    #expect(
      DatabaseConnectionManager.classifyUserSQL("PRAGMA foreign_keys = ON", config: sqlite).first?
        .kind == .ddl)
    #expect(
      DatabaseConnectionManager.classifyUserSQL("PRAGMA foreign_keys", config: postgres).first?
        .kind == .unknown)
    #expect(
      DatabaseConnectionManager.classifyUserSQL("PRAGMA foreign_keys", config: nil).first?.kind
        == .unknown)

    let call = [BoundStatement(sql: "SELECT load_extension('ext')", values: [])]
    #expect(
      DatabaseConnectionManager.evaluateBatch(call, policy: readOnly, dialect: .sqlite)
        != .allowed)
    #expect(DatabaseConnectionManager.evaluateBatch(call, policy: readOnly) == .allowed)
  }

  private func blocked(_ statements: [ClassifiedStatement], _ policy: ProtectionPolicy) -> Bool {
    if case .blocked = DatabaseConnectionManager.evaluate(statements, policy: policy) {
      return true
    }
    return false
  }
}
