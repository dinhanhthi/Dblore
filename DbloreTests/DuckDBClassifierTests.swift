// DuckDBClassifierTests.swift
// DuckDB classification: extension, file, catalog and setting commands are writes the gate and
// the Safe Mode confirmation stop; reads (including file table functions) stay reads.

import Foundation
import Testing

@testable import Dblore

private let readOnly = ProtectionPolicy(protectionLevel: .readOnly)
private let schemaOnly = ProtectionPolicy(protectionLevel: .schemaOnly)

private func duckdbStatements(_ sql: String) -> [ClassifiedStatement] {
  SQLStatementClassifier.classify(sql, dialect: .duckdb)
}

/// DuckDB statements that may write: a file, the catalog, an extension, a secret or a setting.
private let writeCases: [(String, StatementKind)] =
  [
    ("INSTALL httpfs", .utility),
    ("FORCE INSTALL httpfs", .utility),
    ("LOAD httpfs", .utility),
    ("load 'ext.duckdb_extension'", .utility),
    ("ATTACH 'other.duckdb' AS other", .utility),
    ("ATTACH 'other.duckdb' AS other (READ_ONLY)", .utility),
    ("DETACH other", .utility),
    ("COPY t TO 'out.csv'", .utility),
    ("COPY (SELECT * FROM t) TO 'out.parquet' (FORMAT parquet)", .utility),
    ("COPY t FROM 'in.csv'", .utility),
    ("COPY FROM DATABASE a TO b", .utility),
    ("EXPORT DATABASE 'target_dir'", .utility),
    ("IMPORT DATABASE 'source_dir'", .utility),
    ("CHECKPOINT", .utility),
    ("CHECKPOINT other", .utility),
    ("FORCE CHECKPOINT", .utility),
    ("SET threads = 4", .utility),
    ("SET GLOBAL memory_limit = '1GB'", .utility),
    ("SET SESSION enable_progress_bar = false", .utility),
    ("SET VARIABLE x = 1", .utility),
    ("RESET threads", .utility),
    ("RESET ALL", .utility),
    ("PRAGMA version", .utility),
    ("PRAGMA table_info('t')", .utility),
    ("PRAGMA enable_profiling", .utility),
    ("PRAGMA memory_limit = '1GB'", .utility),
    ("CALL pragma_version()", .utility),
    ("CALL duckdb_secrets()", .utility),
    ("CREATE SECRET (TYPE s3, KEY_ID 'k', SECRET 's')", .ddl),
    ("CREATE PERSISTENT SECRET s3_secret (TYPE s3)", .ddl),
    ("DROP SECRET s3_secret", .ddl),
    ("DROP PERSISTENT SECRET s3_secret", .ddl),
    ("INSERT INTO t VALUES (1)", .dml),
    ("UPDATE t SET a = 1 WHERE id = 1", .dml),
    ("CREATE TABLE t AS SELECT * FROM read_csv('in.csv')", .ddl),
    ("UPDATE EXTENSIONS", .utility),
    ("UPDATE EXTENSIONS (httpfs)", .utility),
  ] + sideEffectReadCases.map { ($0, .utility) }

/// Reads that call a side-effecting or environment function, or name a remote URL: DuckDB
/// would reach outside the sandboxed files, so they fail closed.
private let sideEffectReadCases: [String] = [
  "SELECT getenv('HOME')",
  #"SELECT "GetEnv"('HOME')"#,
  "SELECT * FROM checkpoint()",
  "SELECT * FROM force_checkpoint()",
  "SELECT nextval('seq')",
  "SELECT setval('seq', 1)",
  "SELECT * FROM load_aws_credentials()",
  "SELECT * FROM query('SELECT 1')",
  "SELECT * FROM t WHERE a = getenv('X')",
  "WITH x AS (SELECT nextval('seq')) SELECT * FROM x",
  "FROM t SELECT nextval('seq')",
  "SELECT * FROM read_parquet('http://h/a.parquet')",
  "SELECT * FROM read_parquet('https://h/a.parquet')",
  "SELECT * FROM read_csv('s3://b/a.csv')",
  "SELECT * FROM read_csv('s3a://b/a.csv')",
  "SELECT * FROM read_csv('s3n://b/a.csv')",
  "SELECT * FROM read_json('gs://b/a.json')",
  "SELECT * FROM read_json('gcs://b/a.json')",
  "SELECT * FROM read_parquet('r2://b/a.parquet')",
  "SELECT * FROM read_parquet('az://c/a.parquet')",
  "SELECT * FROM read_parquet('azure://c/a.parquet')",
  "SELECT * FROM read_parquet('abfss://c@a.dfs.core.windows.net/a.parquet')",
  "SELECT * FROM read_parquet('hf://datasets/x/a.parquet')",
  "SELECT * FROM read_csv('ftp://h/a.csv')",
  "SELECT * FROM read_csv('HTTPS://H/A.CSV')",
  "SELECT * FROM 's3://b/a.parquet'",
  #"SELECT * FROM "s3://b/a.parquet""#,
  "SELECT * FROM read_csv($$https://h/a.csv$$)",
  "SELECT * FROM read_csv($u$https://h/a.csv$u$)",
  "FROM 'https://h/a.parquet'",
  "WITH x AS (SELECT * FROM read_csv('https://h/a.csv')) SELECT * FROM x",
  "EXPLAIN SELECT * FROM read_parquet('s3://b/a.parquet')",
  "EXPLAIN SELECT getenv('HOME')",
  // Remote databases (postgres, mysql, sqlite scanners) and lakehouse formats.
  "SELECT * FROM postgres_scan('dbname=x', 'public', 't')",
  "SELECT * FROM postgres_scan_pushdown('dbname=x', 'public', 't')",
  "SELECT * FROM Postgres_Query('pg', 'SELECT 1')",
  "SELECT * FROM postgres_execute('pg', 'DROP TABLE t')",
  "SELECT * FROM postgres_attach('dbname=x')",
  "SELECT * FROM main.mysql_scan('host=h', 'db', 't')",
  "SELECT * FROM mysql_query('my', 'SELECT 1')",
  "SELECT * FROM mysql_execute('my', 'DROP TABLE t')",
  #"SELECT * FROM "sqlite_scan"('other.db', 't')"#,
  "SELECT * FROM sqlite_attach('other.db')",
  "SELECT * FROM iceberg_scan('data/iceberg')",
  "SELECT * FROM ICEBERG_METADATA('data/iceberg')",
  "SELECT * FROM iceberg_snapshots('data/iceberg')",
  "SELECT * FROM delta_scan('data/delta')",
  // Every function of the sqlite, iceberg and delta extensions is blocked by prefix.
  "SELECT * FROM iceberg_foo('data/iceberg')",
  "SELECT * FROM delta_foo('data/delta')",
  "SELECT * FROM sqlite_foo('other.db')",
  // Secrets and session configuration.
  "SELECT * FROM duckdb_secrets()",
  "SELECT * FROM which_secret('s3://b/a', 's3')",
  "SELECT current_setting('enable_external_access')",
  "SELECT getvariable('x')",
  "SELECT * FROM t WHERE a = system.main.GetVariable('x')",
  // DuckDB decodes `E'...'` escapes like PostgreSQL's scanner (`scan.l`: `\x` hex, octal,
  // `\u` / `\U`, and `\c` for any other `c`), so these all name `https://`.
  #"SELECT * FROM read_parquet(E'\x68ttps://h/a.parquet')"#,
  #"SELECT * FROM read_parquet(E'\150ttps://h/a.parquet')"#,
  #"SELECT * FROM read_parquet(E'\u0068ttps://h/a.parquet')"#,
  #"SELECT * FROM read_parquet(e'\U00000068ttps://h/a.parquet')"#,
  #"SELECT * FROM read_parquet(E'\https://h/a.parquet')"#,
  #"SELECT * FROM read_parquet(E'\x73\x33://b/a.parquet')"#,
  // Octal keeps the low 8 bits (`strtoul` into an `unsigned char`): `\550` (0x168) is `h`.
  #"SELECT * FROM read_parquet(E'\550ttps://h/a.parquet')"#,
  // A plain string has no escapes in DuckDB, so this is the local path `\x68ttps://...`.
  // The classifier does not tell `E'...'` from `'...'` apart and fails closed on both.
  #"SELECT * FROM read_parquet('\x68ttps://h/a.parquet')"#,
]

/// DuckDB reads, including table functions that read a file the sandbox lets the app open.
private let readCases: [String] = [
  "SELECT 1",
  "SELECT * FROM read_csv('data.csv')",
  "SELECT * FROM read_parquet('data.parquet')",
  "SELECT * FROM read_json('data.json')",
  "SELECT * FROM 'data.parquet'",
  "WITH x AS (SELECT * FROM read_csv('a.csv')) SELECT count(*) FROM x",
  "SHOW TABLES",
  "SHOW ALL TABLES",
  "DESCRIBE",
  "DESCRIBE t",
  "DESCRIBE main.t",
  "DESCRIBE SELECT * FROM t",
  "SUMMARIZE t",
  "SUMMARIZE SELECT * FROM read_parquet('data.parquet')",
  "SELECT currval('seq')",
  "SELECT 'see http://example.com'",
  "SELECT 'http'",
  "SELECT * FROM t WHERE url LIKE '%https://%'",
  "SELECT * FROM read_parquet('/data/https/a.parquet')",
  "SELECT postgres_scan FROM t",
  "SELECT mysql_count, t.postgres_x FROM t",
  "SELECT * FROM my_postgres_scan('x')",
  "SELECT * FROM my_iceberg_scan('x')",
  #"SELECT * FROM read_parquet(E'data\\https://a.parquet')"#,
  #"SELECT E'\thttps://h'"#,
]

@Suite("DuckDB Classifier")
struct DuckDBClassifierTests {

  @Test("DuckDB writes are classified as non-reads", arguments: writeCases)
  func writeKind(sql: String, expected: StatementKind) throws {
    let statement = try #require(duckdbStatements(sql).first)
    #expect(statement.kind == expected)
    #expect(!statement.isReadOnlySafe)
  }

  @Test(
    "DuckDB writes are blocked on read-only and schema-protected connections",
    arguments: writeCases)
  func writeIsBlockedByTheGate(sql: String, expected: StatementKind) {
    let statements = duckdbStatements(sql)
    #expect(blocked(statements, readOnly))
    if expected != .dml {
      #expect(blocked(statements, schemaOnly))
    }
  }

  @Test("DuckDB writes ask for Safe Mode confirmation", arguments: writeCases.map(\.0))
  func writeNeedsConfirmation(sql: String) throws {
    let statements = duckdbStatements(sql)
    for style in [CommitStyle.confirm, .password] {
      let listed = try #require(
        NotebookViewModel.statementsNeedingConfirmation(
          statements, commitStyle: style, dialect: .duckdb))
      #expect(listed.count == 1)
    }
  }

  @Test("DuckDB reads stay reads and pass every protection level", arguments: readCases)
  func readIsAllowed(sql: String) throws {
    let statements = duckdbStatements(sql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .read)
    #expect(statement.isReadOnlySafe)
    #expect(DatabaseConnectionManager.evaluate(statements, policy: readOnly) == .allowed)
    #expect(DatabaseConnectionManager.evaluate(statements, policy: schemaOnly) == .allowed)
    #expect(
      NotebookViewModel.statementsNeedingConfirmation(
        statements, commitStyle: .confirm, dialect: .duckdb) == nil)
  }

  /// Known limitation, kept on purpose: the URL check only sees one literal. A URL built at
  /// run time (`||`, `concat`, `format`, parameters, `getvariable` aside), one hidden in a
  /// macro or view, or split into adjacent literals across a newline (DuckDB's
  /// `quotecontinue`) still classifies as a read. The DuckDB session is the hard boundary:
  /// phase 15.1 (`DuckDBSessionTests`, plan "REQUIRED (phase 12 round-2 security review)")
  /// must show `read_csv('ht' || 'tps://x/y.csv')` and `concat('s3:', '//b/k')` fail with
  /// `enable_external_access=false` and `lock_configuration=true`.
  @Test(
    "Runtime-built remote URLs are not caught by the classifier",
    arguments: [
      "SELECT * FROM read_csv('ht' || 'tps://x/y.csv')",
      "SELECT * FROM read_parquet(concat('s3:', '//b/k'))",
      "SELECT * FROM read_csv('https:'\n'//h/x.csv')",
    ])
  func runtimeBuiltURLIsAKnownGap(sql: String) throws {
    #expect(try #require(duckdbStatements(sql).first).kind == .read)
  }

  @Test("An octal escape that wraps to NUL does not crash the URL check")
  func octalEscapeWrappingToNul() throws {
    let statement = try #require(duckdbStatements(#"SELECT E'\400https://h'"#).first)
    #expect(statement.kind == .read)
  }

  @Test(
    "DESCRIBE or SUMMARIZE of a write is not a read",
    arguments: [
      "DESCRIBE INSERT INTO t VALUES (1)",
      "SUMMARIZE COPY t TO 'out.csv'",
      "DESCRIBE ATTACH 'x.duckdb'",
    ])
  func describeOfWriteIsNotRead(sql: String) throws {
    let statements = duckdbStatements(sql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .unknown)
    #expect(blocked(statements, readOnly))
    #expect(blocked(statements, schemaOnly))
  }

  @Test("Plain EXPLAIN is a read; EXPLAIN ANALYZE runs its statement")
  func explain() throws {
    let plain = duckdbStatements("EXPLAIN SELECT * FROM read_parquet('data.parquet')")
    #expect(try #require(plain.first).kind == .explain(inner: .read, analyze: false))
    #expect(DatabaseConnectionManager.evaluate(plain, policy: readOnly) == .allowed)

    let analyzeRead = duckdbStatements("EXPLAIN ANALYZE SELECT 1")
    #expect(try #require(analyzeRead.first).kind == .explain(inner: .read, analyze: true))
    #expect(DatabaseConnectionManager.evaluate(analyzeRead, policy: schemaOnly) == .allowed)

    let analyzeWrite = duckdbStatements("EXPLAIN ANALYZE COPY t TO 'out.csv'")
    #expect(try #require(analyzeWrite.first).kind == .explain(inner: .utility, analyze: true))
    #expect(blocked(analyzeWrite, readOnly))
    #expect(blocked(analyzeWrite, schemaOnly))
  }

  @Test(
    "Plain EXPLAIN of a DuckDB utility fails closed",
    arguments: ["EXPLAIN INSTALL httpfs", "EXPLAIN ATTACH 'x.duckdb'", "EXPLAIN SET threads = 4"])
  func explainOfUtilityIsUtility(sql: String) throws {
    let statements = duckdbStatements(sql)
    #expect(try #require(statements.first).kind == .utility)
    #expect(blocked(statements, readOnly))
    #expect(blocked(statements, schemaOnly))
  }

  @Test("One DuckDB write blocks the whole script")
  func scriptWithOneWriteIsBlocked() {
    let statements = duckdbStatements("SELECT 1; INSTALL httpfs; SELECT 2")
    #expect(
      DatabaseConnectionManager.evaluate(statements, policy: readOnly)
        == .blocked(
          statementIndex: 1, kind: .utility,
          reason: "Utility command (DO, CALL, COPY, VACUUM, GRANT, ...) is not allowed on a "
            + "read-only connection"))
  }

  @Test("PostgreSQL and SQLite keep their own rules for the same commands")
  func otherDialectsUnchanged() throws {
    let set = try #require(SQLStatementClassifier.classify("SET search_path = x").first)
    #expect(set.kind == .sessionSet(touchesBrake: false))
    let install = try #require(SQLStatementClassifier.classify("INSTALL httpfs").first)
    #expect(install.kind == .unknown)
    let describe = try #require(SQLStatementClassifier.classify("DESCRIBE t").first)
    #expect(describe.kind == .unknown)
    let pragma = try #require(
      SQLStatementClassifier.classify("PRAGMA foreign_keys", dialect: .sqlite).first)
    #expect(pragma.kind == .read)
    let nextval = try #require(SQLStatementClassifier.classify("SELECT nextval('seq')").first)
    #expect(nextval.kind == .read)
    let remote = try #require(
      SQLStatementClassifier.classify("SELECT 's3://b/a.parquet'", dialect: .sqlite).first)
    #expect(remote.kind == .read)
  }

  @Test("UPDATE EXTENSIONS does not warn that it affects every row")
  func updateExtensionsHasNoAllRowsWarning() throws {
    let statement = try #require(duckdbStatements("UPDATE EXTENSIONS").first)
    #expect(!statement.affectsAllRows)
  }

  private func blocked(_ statements: [ClassifiedStatement], _ policy: ProtectionPolicy) -> Bool {
    if case .blocked = DatabaseConnectionManager.evaluate(statements, policy: policy) {
      return true
    }
    return false
  }
}
