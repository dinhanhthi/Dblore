// DialectThreadingTests.swift
// Execution splitting, comment-only checks, statement routing, the cursor check, transaction
// tracking and inline edit relations use the connection's dialect; PostgreSQL behaviour is
// unchanged.

import Foundation
import Testing

@testable import Dblore

@Suite("DialectThreadingTests")
@MainActor
struct DialectThreadingTests {
  @Test("A SQLite script splits with SQLite rules: a [bracket] identifier keeps its semicolon")
  func sqliteScriptSplitsWithSQLiteRules() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }

    let detailed = try await manager.executeInternalStatementsDetailed(
      "SELECT 1 AS [a;b]; SELECT 2 AS c")
    #expect(detailed.results.map(\.queryText) == ["SELECT 1 AS [a;b]", "SELECT 2 AS c"])

    let single = try await manager.executeInternal("SELECT 1 AS [a;b]")
    #expect(single.columns.map(\.name) == ["a;b"])
    #expect(single.rows == [[.int(1)]])
  }

  @Test("The connection dialect: SQLite and DuckDB configs, PostgreSQL only without a config")
  func dialectOfConfig() {
    #expect(DatabaseConnectionManager.dialect(of: sqliteConfig(path: "/tmp/x.sqlite")) == .sqlite)
    var duckdb = sqliteConfig(path: "/tmp/x.duckdb")
    duckdb.databaseType = .duckdb
    #expect(DatabaseConnectionManager.dialect(of: duckdb) == .duckdb)
    #expect(DatabaseConnectionManager.dialect(of: nil) == .postgresql)
  }

  @Test("MySQL splits after a # comment that holds a semicolon; PostgreSQL does not")
  func mysqlSplitAndCommentOnly() {
    let manager = DatabaseConnectionManager()
    let script = "# a; b\nSELECT 1; SELECT 2"
    #expect(
      manager.splitSQLStatements(script, dialect: .mysql) == ["# a; b\nSELECT 1", "SELECT 2"])
    #expect(manager.splitSQLStatements(script, dialect: .postgresql).count == 3)
    #expect(manager.hasMultipleStatements("# a; b\nSELECT 1", dialect: .mysql) == false)
    #expect(manager.hasMultipleStatements("# a; b\nSELECT 1", dialect: .postgresql))
    #expect(manager.isCommentOnlyStatement("# only a comment", dialect: .mysql))
    #expect(!manager.isCommentOnlyStatement("# only a comment", dialect: .postgresql))
  }

  @Test("PostgreSQL keeps E-strings and dollar quotes; DuckDB keeps dollar quotes")
  func postgresAndDuckDBSplitUnchanged() {
    let manager = DatabaseConnectionManager()
    #expect(
      manager.splitSQLStatements("SELECT E'a\\';b'; SELECT 2", dialect: .postgresql)
        == ["SELECT E'a\\';b'", "SELECT 2"])
    #expect(
      manager.splitSQLStatements("SELECT $$a;b$$; SELECT 2", dialect: .duckdb)
        == ["SELECT $$a;b$$", "SELECT 2"])
  }

  @Test("Routing reads the first keyword with the dialect: MySQL WITH after a # comment")
  func routeUsesDialect() {
    let sql = "# x\nWITH s AS (SELECT 1) UPDATE t SET a = 1"
    let statement = SQLStatementClassifier.classifyStatement(sql, dialect: .mysql)
    #expect(statement?.kind == .dml)
    #expect(StatementRoute.route(for: statement, dialect: .mysql) == .unwrappedRows)
    #expect(StatementRoute.route(for: statement, dialect: .postgresql) == .command)
  }

  @Test("The cursor check lexes with the dialect: FOR UPDATE and a call inside # comments")
  func usesCursorUsesDialect() throws {
    let locking = try #require(
      SQLStatementClassifier.classifyStatement("SELECT a FROM t # FOR UPDATE", dialect: .mysql))
    #expect(DatabaseConnectionManager.usesCursor(locking, dialect: .mysql))
    #expect(!DatabaseConnectionManager.usesCursor(locking, dialect: .postgresql))

    let call = try #require(
      SQLStatementClassifier.classifyStatement("# f(x)\nSELECT a FROM t", dialect: .mysql))
    #expect(DatabaseConnectionManager.usesCursor(call, dialect: .mysql))
    #expect(!DatabaseConnectionManager.usesCursor(call, dialect: .postgresql))
  }

  private func mysql(_ sql: String) throws -> ClassifiedStatement {
    try #require(SQLStatementClassifier.classifyStatement(sql, dialect: .mysql))
  }

  @Test("User transaction words lex with the dialect: MySQL # comment hides AND CHAIN")
  func userTransactionWordsUseDialect() throws {
    let rules = ProtectedTransactionRules.self
    let commit = try mysql("COMMIT # AND CHAIN")
    #expect(!rules.userTxOpen(after: commit, current: true, succeeded: true, dialect: .mysql))
    #expect(rules.userTxOpen(after: commit, current: true, succeeded: true, dialect: .postgresql))
    let commented = try mysql("# note\nCOMMIT")
    #expect(rules.committedUserTransaction(commented, dialect: .mysql))
    #expect(!rules.committedUserTransaction(commented, dialect: .postgresql))
  }

  @Test(
    "MySQL: a successful implicit-commit statement closes the user transaction",
    arguments: [
      "CREATE TABLE t (id INT)", "LOCK TABLES t WRITE", "TRUNCATE t",
      "CREATE TABLE t2 AS SELECT 1", "GRANT SELECT ON t TO u",
    ])
  func mysqlImplicitCommitClosesUserTransaction(_ sql: String) throws {
    let rules = ProtectedTransactionRules.self
    let statement = try mysql(sql)
    #expect(statement.nonTransactional)
    #expect(!rules.userTxOpen(after: statement, current: true, succeeded: true, dialect: .mysql))
    #expect(rules.committedUserTransaction(statement, dialect: .mysql))
    // A failed statement changes nothing
    #expect(rules.userTxOpen(after: statement, current: true, succeeded: false, dialect: .mysql))
  }

  @Test(
    "MySQL: a statement that may not commit (gate fails closed) keeps the user transaction",
    arguments: [
      "CREATE TEMPORARY TABLE t (id INT)", "DROP TEMPORARY TABLE t", "CALL p()", "EXECUTE s",
      "PREPARE s FROM 'x'", "/*!40101 SET NAMES utf8 */", "FROBNICATE t", "SET autocommit = 0",
      "LOCK INSTANCE FOR BACKUP",
      // Commit only conditionally (autocommit was 0 / tables are locked); phase 7 will ask
      // the server via @@in_transaction
      "SET autocommit = 1", "SET autocommit = ON", "UNLOCK TABLES",
    ])
  func mysqlPossibleCommitKeepsUserTransaction(_ sql: String) throws {
    let rules = ProtectedTransactionRules.self
    let statement = try mysql(sql)
    #expect(rules.userTxOpen(after: statement, current: true, succeeded: true, dialect: .mysql))
    #expect(!rules.committedUserTransaction(statement, dialect: .mysql))
  }

  @Test("MySQL DML keeps the user transaction; other engines keep it after DDL")
  func implicitCommitIsMySQLOnly() throws {
    let rules = ProtectedTransactionRules.self
    let update = try mysql("UPDATE t SET a = 1")
    #expect(rules.userTxOpen(after: update, current: true, succeeded: true, dialect: .mysql))
    #expect(!rules.committedUserTransaction(update, dialect: .mysql))
    for dialect in [SQLDialect.postgresql, .sqlite, .duckdb] {
      let ddl = try #require(
        SQLStatementClassifier.classifyStatement("CREATE TABLE t (id INT)", dialect: dialect))
      #expect(rules.userTxOpen(after: ddl, current: true, succeeded: true, dialect: dialect))
      #expect(!rules.committedUserTransaction(ddl, dialect: dialect))
    }
  }

  @Test("SQLite: CREATE TABLE inside the user's BEGIN keeps the transaction tracked")
  func sqliteDDLKeepsUserTransaction() async throws {
    let url = try makeDatabase()
    defer { removeDatabase(url) }
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: sqliteConfig(path: url.path))
    defer { Task { await manager.disconnect() } }
    let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)

    _ = try await manager.executeDetailed(
      userSQL: "BEGIN; CREATE TABLE extra (id INTEGER)", policy: open)
    #expect(await manager.userTxOpen)
    _ = try await manager.executeDetailed(userSQL: "ROLLBACK", policy: open)
    #expect(await manager.userTxOpen == false)
  }

  @Test("The edit relation lexes and re-quotes with the dialect")
  func singleRelationUsesDialect() {
    let backticked = "SELECT a FROM `my table` WHERE id = 1"
    #expect(CellUpdateStatement.singleRelation(in: backticked, dialect: .mysql) == "`my table`")
    #expect(CellUpdateStatement.singleRelation(in: backticked, dialect: .postgresql) == nil)
    let commented = "SELECT a FROM t # , u\nWHERE id = 1"
    #expect(CellUpdateStatement.singleRelation(in: commented, dialect: .mysql) == "T")
    #expect(CellUpdateStatement.singleRelation(in: commented, dialect: .postgresql) == nil)
    #expect(
      CellUpdateStatement.singleRelation(in: "SELECT a FROM [notes]", dialect: .sqlite)
        == "\"notes\"")
    #expect(
      CellUpdateStatement.singleRelation(in: "SELECT a FROM \"s\".\"t\"", dialect: .postgresql)
        == "\"s\".\"t\"")
  }

  @Test("Identifier quoting follows the dialect; the NUL fallback is unchanged")
  func quoteIdentifierUsesDialect() {
    #expect(CellUpdateStatement.quoteIdentifier("a`b", dialect: .mysql) == "`a``b`")
    #expect(CellUpdateStatement.quoteIdentifier("a\"b", dialect: .postgresql) == "\"a\"\"b\"")
    #expect(CellUpdateStatement.quoteIdentifier("a\"b") == "\"a\"\"b\"")
    #expect(CellUpdateStatement.quoteIdentifier("a\0b", dialect: .postgresql) == "\"a\0b\"")
  }

  private func sqliteConfig(path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      host: "",
      port: 0,
      database: path,
      username: "",
      rememberConnection: false,
      protectionLevel: .none,
      safeMode: .silent,
      protectedMode: false
    )
  }

  private func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-dialect-threading-\(UUID().uuidString).sqlite")
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY)")
    return url
  }

  private func removeDatabase(_ url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }
}
