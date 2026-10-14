// MySQLClassifierTests.swift
// MySQL classification: implicit commits, MySQL-only commands, executable comments,
// password literals and :name rewriting to bare ? placeholders

import Foundation
import Testing

@testable import Dblore

private let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
private let unprotected = ProtectionPolicy(protectionLevel: .none)

private func mysqlStatement(_ sql: String) throws -> ClassifiedStatement {
  let statements = SQLStatementClassifier.classify(sql, dialect: .mysql)
  #expect(statements.count == 1)
  return try #require(statements.first)
}

@Suite("MySQL Classifier")
struct MySQLClassifierTests {

  @Test(
    "Statements that commit implicitly cannot run in a transaction",
    arguments: [
      "CREATE TABLE t (id INT)",
      "CREATE TABLE t2 AS SELECT * FROM t",
      "CREATE TABLE t2 SELECT * FROM t",
      "ALTER TABLE t ADD COLUMN c INT",
      "DROP TABLE t",
      "RENAME TABLE t TO t2",
      "TRUNCATE TABLE t",
      "CREATE INDEX i ON t (c)",
      "LOCK TABLES t WRITE",
      "UNLOCK TABLES",
      "GRANT SELECT ON db.* TO 'u'@'%'",
      "REVOKE SELECT ON db.* FROM 'u'@'%'",
      "CREATE USER 'u'@'%'",
      "ALTER USER 'u'@'%' ACCOUNT LOCK",
      "DROP USER 'u'@'%'",
      "CREATE ROLE r",
      "DROP ROLE r",
      "RENAME USER 'u'@'%' TO 'v'@'%'",
      "SET PASSWORD FOR 'u'@'%' = 'x'",
      "SET autocommit = 1",
      "SET SESSION autocommit = 0",
      "SET @@autocommit = 1",
      "ANALYZE TABLE t",
      "OPTIMIZE TABLE t",
      "REPAIR TABLE t",
      "CHECK TABLE t",
      "LOAD INDEX INTO CACHE t",
      "FLUSH PRIVILEGES",
      "START REPLICA",
      "START SLAVE",
      "CALL p()",
      "EXECUTE s",
      "EXECUTE s USING @a",
      "PREPARE s FROM 'DROP TABLE t'",
      "DEALLOCATE PREPARE s",
      "CLONE LOCAL DATA DIRECTORY = '/tmp/c'",
      "IMPORT TABLE FROM '/tmp/t.sdi'",
      "BINLOG 'abc'",
      "SHUTDOWN",
      "FROBNICATE t",
      "`t` x",
      "SET `autocommit` = 1",
      "SET @@session.`autocommit`=1",
      "SET `AutoCommit` = 0",
      "SET GLOBAL autocommit = 1",
    ])
  func implicitCommitIsNonTransactional(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.nonTransactional)
    guard
      case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
        [statement], policy: protected, dialect: .mysql)
    else {
      Issue.record("\(sql) should be refused in Protected mode")
      return
    }
    #expect(reason.contains("commits implicitly"))
  }

  /// A DELIMITER-split piece can hold a `;` (a procedure body); it fails closed as unknown.
  @Test("A statement piece containing ; commits implicitly")
  func pieceWithSemicolonIsNonTransactional() throws {
    let statement = try #require(
      SQLStatementClassifier.classifyStatement(
        "CREATE PROCEDURE p() BEGIN SELECT 1; END", dialect: .mysql))
    #expect(statement.kind == .unknown)
    #expect(statement.nonTransactional)
    let select = try #require(
      SQLStatementClassifier.classifyStatement("SELECT 1; SELECT 2", dialect: .mysql))
    #expect(select.nonTransactional)
  }

  @Test("EXPLAIN ANALYZE of an unrecognized statement commits implicitly")
  func explainAnalyzeUnknownIsNonTransactional() throws {
    #expect(try mysqlStatement("EXPLAIN ANALYZE FROBNICATE t").nonTransactional)
  }

  @Test("PostgreSQL CALL still runs inside the Protected mode transaction")
  func postgresCallStaysTransactional() throws {
    let statement = try #require(SQLStatementClassifier.classify("CALL p()").first)
    #expect(statement.kind == .utility)
    #expect(!statement.nonTransactional)
    #expect(DatabaseConnectionManager.evaluate([statement], policy: protected) == .allowed)
  }

  @Test(
    "Statements that keep the transaction open stay transactional",
    arguments: [
      "SELECT 1",
      "INSERT INTO t VALUES (1)",
      "UPDATE t SET c = 1 WHERE id = 1",
      "DELETE FROM t WHERE id = 1",
      "REPLACE INTO t VALUES (1)",
      "SET @x = 1",
      "SET NAMES utf8mb4",
      "SHOW TABLES",
      "LOAD DATA INFILE 'f' INTO TABLE t",
      "START TRANSACTION",
    ])
  func otherStatementsStayTransactional(sql: String) throws {
    #expect(!(try mysqlStatement(sql)).nonTransactional)
  }

  @Test(
    "MySQL commands get their kind",
    arguments: [
      ("SHOW TABLES", StatementKind.read),
      ("SHOW CREATE TABLE `t`", .read),
      ("DESCRIBE t", .read),
      ("DESC `db`.`t`", .read),
      ("describe t c", .read),
      ("DESC SELECT 1", .unknown),
      ("DESCRIBE DELETE FROM t", .unknown),
      ("REPLACE INTO t VALUES (1)", .dml),
      ("USE db", .sessionSet(touchesBrake: false)),
      ("SELECT * FROM t INTO OUTFILE '/tmp/x'", .utility),
      ("SELECT a INTO DUMPFILE '/tmp/x' FROM t", .utility),
      ("LOAD DATA LOCAL INFILE 'f' INTO TABLE t", .utility),
      ("HANDLER t OPEN", .utility),
      ("DO SLEEP(1)", .utility),
      ("KILL 42", .utility),
      ("FLUSH TABLES", .utility),
      ("CALL p()", .utility),
      ("XA START 'x'", .tcl),
      ("XA COMMIT 'x'", .tcl),
      ("START TRANSACTION", .tcl),
      ("START REPLICA", .utility),
      ("RENAME TABLE a TO b", .ddl),
      ("UNLOCK TABLES", .utility),
      ("OPTIMIZE TABLE t", .utility),
      ("SET GLOBAL max_connections = 10", .utility),
      ("set global max_connections = 10", .utility),
      ("SET PERSIST max_connections = 10", .utility),
      ("SET PERSIST_ONLY max_connections = 10", .utility),
      ("SET @@global.max_connections = 10", .utility),
      ("SET @@persist.max_connections = 10", .utility),
      ("SET @@persist_only.max_connections = 10", .utility),
      ("SET @x = 1, @@GLOBAL.max_connections = 10", .utility),
      ("SET SESSION max_connections = 10", .sessionSet(touchesBrake: false)),
      ("SET @@session.wait_timeout = 10", .sessionSet(touchesBrake: true)),
      ("SET SESSION max_execution_time = 0", .sessionSet(touchesBrake: true)),
      ("SET LOCAL innodb_lock_wait_timeout = 1000", .sessionSet(touchesBrake: true)),
      ("SET max_statement_time = 0", .sessionSet(touchesBrake: true)),
      ("SET @x = 1, `Lock_Wait_Timeout` = 99", .sessionSet(touchesBrake: true)),
      ("SET @@SESSION.TX_READ_ONLY = 0", .sessionSet(touchesBrake: true)),
      ("SET SESSION TRANSACTION READ WRITE", .sessionSet(touchesBrake: true)),
      ("SET TRANSACTION READ WRITE", .sessionSet(touchesBrake: true)),
      (
        "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED, READ WRITE",
        .sessionSet(touchesBrake: true)
      ),
      ("SET DEFAULT ROLE ALL TO 'u'@'%'", .utility),
      ("SET DEFAULT ROLE NONE TO 'u'@'%'", .utility),
      ("SET DEFAULT ROLE r TO 'u'@'%'", .utility),
      ("SET DEFAULT ROLE r FOR u", .utility),
      ("SET @x = 'wait_timeout'", .sessionSet(touchesBrake: false)),
    ])
  func mysqlKinds(sql: String, expected: StatementKind) throws {
    #expect(try mysqlStatement(sql).kind == expected)
  }

  /// The session sql_mode is pinned so the lexer matches the server (no NO_BACKSLASH_ESCAPES or
  /// ANSI_QUOTES); changing it would reopen a lexer differential, so every form is a utility.
  @Test(
    "Setting sql_mode is a utility in any form",
    arguments: [
      "SET sql_mode = 'ANSI_QUOTES'",
      "set SQL_MODE='NO_BACKSLASH_ESCAPES'",
      "SET SESSION sql_mode = ''",
      "SET LOCAL sql_mode = ''",
      "SET @@sql_mode = ''",
      "SET @@session.sql_mode = ''",
      "SET @@SESSION.SQL_MODE = ''",
      "SET GLOBAL sql_mode = ''",
      "SET @@global.sql_mode = ''",
      "SET PERSIST sql_mode = ''",
      "SET PERSIST_ONLY sql_mode = ''",
      "SET @@persist.sql_mode = ''",
      "SET a = 1, sql_mode = 'ANSI'",
      "SET @x = 1, @@session.sql_mode = 'ANSI'",
      "SET /* c */ sql_mode /* c */ = ''",
      "SET\n  # note\n  sql_mode\t= ''",
      "SET `sql_mode` = ''",
      "SET @@session.`sql_mode` = ''",
    ])
  func sqlModeIsUtility(sql: String) throws {
    let statements = SQLStatementClassifier.classify(sql, dialect: .mysql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .utility)
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      #expect(
        DatabaseConnectionManager.evaluate(
          statements, policy: ProtectionPolicy(protectionLevel: level), dialect: .mysql)
          != .allowed)
    }
  }

  /// The session pins utf8mb4: GBK / BIG5 / SJIS let a multibyte character swallow a
  /// backslash, so the server would lex strings differently from the classifier.
  @Test(
    "Setting the connection charset is a utility in any form",
    arguments: [
      "SET NAMES gbk",
      "set names 'sjis' COLLATE 'sjis_bin'",
      "SET CHARACTER SET big5",
      "SET character set gbk",
      "SET CHARSET gbk",
      "SET character_set_client = gbk",
      "SET SESSION character_set_connection = gbk",
      "SET @@character_set_results = gbk",
      "SET @@session.collation_connection = 'gbk_bin'",
      "SET GLOBAL CHARACTER_SET_CLIENT = gbk",
      "SET @@global.character_set_client = gbk",
      "SET PERSIST character_set_client = gbk",
      "SET @x = 1, character_set_client = gbk",
      "SET /* c */ `character_set_client` # c\n = gbk",
    ])
  func charsetIsUtility(sql: String) throws {
    let statements = SQLStatementClassifier.classify(sql, dialect: .mysql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .utility)
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      #expect(
        DatabaseConnectionManager.evaluate(
          statements, policy: ProtectionPolicy(protectionLevel: level), dialect: .mysql)
          != .allowed)
    }
  }

  @Test("Other SET statements stay session settings")
  func otherSetStaysSessionSet() throws {
    #expect(try mysqlStatement("SET @x = 'sql_mode'").kind == .sessionSet(touchesBrake: false))
    #expect(try mysqlStatement("SET @x = 'names'").kind == .sessionSet(touchesBrake: false))
    #expect(try mysqlStatement("SET time_zone = '+00:00'").kind == .sessionSet(touchesBrake: false))
    #expect(try mysqlStatement("SET @x = 'SLEEP(1)'").kind == .sessionSet(touchesBrake: false))
    #expect(try mysqlStatement("SET @sleep = 1").kind == .sessionSet(touchesBrake: false))
  }

  /// MySQL runs these from a plain SELECT: they read server files, take or wait on locks, stall
  /// the session, run shell commands (UDFs) or advance a sequence.
  @Test(
    "A read that calls a side-effecting function or locks rows is a utility",
    arguments: [
      "SELECT LOAD_FILE('/etc/passwd')",
      "SELECT GET_LOCK('l', 10)",
      "SELECT release_lock('l')",
      "SELECT RELEASE_ALL_LOCKS()",
      "SELECT SLEEP(5)",
      "SELECT * FROM t WHERE id = 1 AND sleep (1) = 0",
      "SELECT BENCHMARK(1000000, MD5('x'))",
      "SELECT MASTER_POS_WAIT('f', 4)",
      "SELECT SOURCE_POS_WAIT('f', 4)",
      "SELECT WAIT_FOR_EXECUTED_GTID_SET('uuid:1')",
      "SELECT sys_exec('rm -rf /')",
      "SELECT SYS_EVAL('id')",
      "SELECT NEXTVAL(s)",
      "SELECT SETVAL(s, 10)",
      "SELECT NEXT VALUE FOR s",
      "SELECT `sleep`(1)",
      "SELECT * FROM (SELECT GET_LOCK('l', 1)) x",
      "WITH a AS (SELECT SLEEP(1)) SELECT * FROM a",
      "SELECT * FROM t FOR UPDATE",
      "SELECT * FROM t WHERE id = 1 FOR SHARE",
      "SELECT * FROM t FOR UPDATE NOWAIT",
      "SELECT * FROM t LOCK IN SHARE MODE",
      "SELECT * FROM (SELECT * FROM t FOR UPDATE) x",
      "SELECT MASTER_GTID_WAIT('0-1-100')",
      "SELECT WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS('uuid:1')",
      "SELECT group_replication_set_as_primary('uuid')",
      "SELECT asynchronous_connection_failover_add_source('ch', 'h', 3306)",
      "SELECT keyring_key_remove('k', 'u')",
      "SELECT audit_log_filter_flush()",
      "SELECT VERSION_TOKENS_SET('a=1')",
      "SET @x = LOAD_FILE('/etc/passwd')",
      "SET @x = SLEEP(3600)",
      "SET @x = GET_LOCK('l', 999)",
      "SET @x = sys_exec('id')",
      "SET @x = (SELECT a FROM t FOR UPDATE)",
      "SET @x = NEXTVAL(seq)",
      "SET SESSION wait_timeout = SLEEP(1)",
      "SELECT sys_exec('x')",
      "SELECT * FROM a JOIN b ON SLEEP(5) = 0",
      "SELECT keyring_aws_rotate_cmk()",
      "SELECT spider_direct_sql('SELECT 1', 't', 'srv')",
      "SELECT TRIM(FROM LOAD_FILE('/etc/passwd'))",
      "SELECT SUBSTRING('abc' FROM GET_LOCK('l', 1))",
      "SELECT TRIM(BOTH 'x' FROM SLEEP(3600))",
      "SELECT EXTRACT(YEAR FROM SYS_EXEC('id'))",
      "SELECT TRIM(LEADING 'x' FROM SLEEP(1))",
      "SELECT EXTRACT(YEAR FROM GET_LOCK('l', 9))",
    ])
  func sideEffectReadIsUtility(sql: String) throws {
    let statements = SQLStatementClassifier.classify(sql, dialect: .mysql)
    let statement = try #require(statements.first)
    #expect(statement.kind == .utility)
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      #expect(
        DatabaseConnectionManager.evaluate(
          statements, policy: ProtectionPolicy(protectionLevel: level), dialect: .mysql)
          != .allowed)
    }
  }

  @Test(
    "SET TRANSACTION ... READ WRITE touches the brake",
    arguments: [
      "SET TRANSACTION READ WRITE",
      "SET SESSION TRANSACTION READ WRITE",
      "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED, READ WRITE",
    ])
  func setTransactionReadWriteTouchesBrake(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.resetsSessionBrakes)
    #expect(SQLStatementClassifier.summary([statement]).touchesBrake)
  }

  /// `SET DEFAULT ROLE` changes an account for good (like `ALTER USER ... DEFAULT ROLE`), and
  /// `SET ROLE` switches the session's privileges.
  @Test(
    "SET DEFAULT ROLE and SET ROLE change privileges",
    arguments: [
      "SET DEFAULT ROLE ALL TO 'u'@'%'",
      "SET DEFAULT ROLE r FOR u",
      "SET ROLE r",
    ])
  func roleChangesPrivileges(sql: String) throws {
    #expect(try mysqlStatement(sql).changesPrivileges)
  }

  @Test(
    "SET DEFAULT ROLE is refused by read-only, schema-only and Protected mode",
    arguments: ["SET DEFAULT ROLE NONE TO 'u'@'%'", "SET DEFAULT ROLE r FOR u"])
  func setDefaultRoleIsRefused(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.nonTransactional)
    for policy in [
      ProtectionPolicy(protectionLevel: .readOnly), ProtectionPolicy(protectionLevel: .schemaOnly),
      protected,
    ] {
      #expect(
        DatabaseConnectionManager.evaluate([statement], policy: policy, dialect: .mysql)
          != .allowed)
    }
  }

  /// MariaDB `SET STATEMENT var = value FOR <statement>` runs the trailing statement.
  @Test(
    "SET STATEMENT ... FOR fails closed",
    arguments: [
      "SET STATEMENT sort_buffer_size = 1 FOR DROP TABLE t",
      "SET STATEMENT sort_buffer_size = 1 FOR DELETE FROM t",
      "SET STATEMENT max_statement_time = 1 FOR SELECT 1",
      "set statement sql_mode = '' for DROP TABLE t",
      "SET STATEMENT a = 1, b = 2 FOR UPDATE t SET c = 1",
    ])
  func setStatementIsUnknown(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .unknown)
    #expect(statement.nonTransactional)
    #expect(!statement.isReadOnlySafe)
    for policy in [
      ProtectionPolicy(protectionLevel: .readOnly), ProtectionPolicy(protectionLevel: .schemaOnly),
      protected,
    ] {
      #expect(
        DatabaseConnectionManager.evaluate([statement], policy: policy, dialect: .mysql)
          != .allowed)
    }
  }

  @Test(
    "A query with INTO @var that calls a side-effecting function is a utility",
    arguments: [
      "SELECT SYS_EXEC('x') INTO @v",
      "SELECT SLEEP(9) INTO @v",
      "SELECT GET_LOCK('l', 9) INTO @v",
      "SELECT NEXTVAL(s) INTO @v",
      "SELECT LOAD_FILE('/etc/passwd') INTO @v",
      "WITH c AS (SELECT 1) SELECT SLEEP(1) INTO @v",
      "(SELECT SLEEP(1) INTO @v)",
      "SELECT a INTO @v FROM t FOR UPDATE",
      "SELECT NEXT VALUE FOR s INTO @v",
    ])
  func sideEffectSelectIntoIsUtility(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .utility)
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      #expect(
        DatabaseConnectionManager.evaluate(
          [statement], policy: ProtectionPolicy(protectionLevel: level), dialect: .mysql)
          != .allowed)
    }
  }

  @Test("A plain SELECT ... INTO @var stays a data modification")
  func plainSelectIntoStaysDml() throws {
    #expect(try mysqlStatement("SELECT a INTO @v FROM t").kind == .dml)
  }

  @Test(
    "Reads that only mention a listed name stay reads",
    arguments: [
      "SELECT 'SLEEP(1)'",
      "SELECT sleep FROM t",
      "SELECT IS_FREE_LOCK('l')",
      "SELECT LASTVAL(s)",
      "SELECT * FROM t -- FOR UPDATE",
      "SELECT `for`, `update` FROM t",
      "SELECT group_replication_status FROM t",
    ])
  func mentionsStayReads(sql: String) throws {
    #expect(try mysqlStatement(sql).kind == .read)
  }

  @Test("SELECT ... INTO OUTFILE does not create a table")
  func outfileDoesNotCreateTable() throws {
    #expect(!(try mysqlStatement("SELECT * FROM t INTO OUTFILE '/tmp/x'")).createsTable)
  }

  @Test(
    "EXPLAIN FORMAT=JSON and EXPLAIN ANALYZE see the inner statement",
    arguments: [
      ("EXPLAIN FORMAT=JSON SELECT 1", StatementKind.explain(inner: .read, analyze: false)),
      ("EXPLAIN format = tree SELECT 1", .explain(inner: .read, analyze: false)),
      ("EXPLAIN SELECT * FROM `t`", .explain(inner: .read, analyze: false)),
      ("EXPLAIN ANALYZE SELECT 1", .explain(inner: .read, analyze: true)),
      ("EXPLAIN ANALYZE FORMAT=TREE SELECT 1", .explain(inner: .read, analyze: true)),
      ("EXPLAIN FORMAT=JSON DELETE FROM t", .explain(inner: .dml, analyze: false)),
    ])
  func explainFormat(sql: String, expected: StatementKind) throws {
    #expect(try mysqlStatement(sql).kind == expected)
  }

  /// Schema-only protection allows data changes, so a DML statement must not smuggle in a
  /// side-effecting function call.
  @Test(
    "A data change that calls a side-effecting function is a utility",
    arguments: [
      "INSERT INTO t SELECT LOAD_FILE('/etc/passwd')",
      "UPDATE t SET c = sys_exec('x')",
      "DELETE FROM t WHERE sys_eval('x')",
      "INSERT INTO t VALUES (GET_LOCK('l', 999))",
      "REPLACE INTO t VALUES (SLEEP(9))",
      "INSERT INTO t VALUES (NEXTVAL(s))",
      "INSERT INTO t VALUES (NEXT VALUE FOR s)",
      "UPDATE t SET c = SYS_GET('x')",
      "UPDATE t SET c = SYS_SET('x', 'y')",
      "UPDATE t SET c = SYS_BIN_EVAL('x')",
      "INSERT INTO t (a) VALUES (SLEEP(1))",
      "INSERT INTO audit_log_events (a) VALUES (audit_log_filter_set_user('x'))",
      "INSERT sleep (a) VALUES (SLEEP(1))",
      "UPDATE t SET c = TRIM(FROM sys_exec('x'))",
    ])
  func sideEffectDmlIsUtility(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .utility)
    for level in [ConnectionProtectionLevel.readOnly, .schemaOnly] {
      #expect(
        DatabaseConnectionManager.evaluate(
          [statement], policy: ProtectionPolicy(protectionLevel: level), dialect: .mysql)
          != .allowed)
    }
  }

  @Test(
    "A plain data change stays a data modification",
    arguments: ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 1 WHERE id = 2"])
  func plainDmlStaysDml(sql: String) throws {
    #expect(try mysqlStatement(sql).kind == .dml)
  }

  /// A table or index name followed by a column list is not a function call.
  @Test(
    "A table named like a side-effect function keeps its data-change kind",
    arguments: [
      "INSERT INTO audit_log_events (a) VALUES (1)",
      "REPLACE INTO benchmark (id) VALUES (1)",
      "INSERT INTO db.audit_log_entries (a) VALUES (1)",
      "INSERT sleep (id) VALUES (1)",
      "INSERT IGNORE benchmark (id) VALUES (1)",
    ])
  func sideEffectNamedTableStaysDml(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .dml)
    #expect(
      DatabaseConnectionManager.evaluate(
        [statement], policy: ProtectionPolicy(protectionLevel: .schemaOnly), dialect: .mysql)
        == .allowed)
  }

  @Test(
    "A table or index named like a side-effect function keeps its schema-change kind",
    arguments: [
      "CREATE TABLE sleep (id int)",
      "CREATE INDEX i ON benchmark (id)",
      "CREATE UNIQUE INDEX i ON sleep (id)",
      "CREATE TABLE t (id int, KEY sleep (id))",
      "CREATE TABLE t (id int, INDEX benchmark (id))",
      "CREATE TABLE t (id int, FOREIGN KEY (id) REFERENCES sleep (id))",
    ])
  func sideEffectNamedTableStaysDdl(sql: String) throws {
    #expect(try mysqlStatement(sql).kind == .ddl)
  }

  /// MySQL built-ins and UDFs live in the global namespace, so `db.name(` is a stored function.
  @Test("A schema-qualified call is not a side-effect built-in")
  func schemaQualifiedCallStaysRead() throws {
    #expect(try mysqlStatement("SELECT mysql.sys_exec('x')").kind == .read)
  }

  /// MySQL's optimizer evaluates cheap uncorrelated subqueries while explaining.
  @Test(
    "A plain EXPLAIN of a side-effecting statement is refused by read-only",
    arguments: [
      "EXPLAIN SELECT * FROM t WHERE id = (SELECT SLEEP(60))",
      "EXPLAIN FORMAT=JSON SELECT GET_LOCK('l', 0)",
      "EXPLAIN SELECT LOAD_FILE('/etc/passwd')",
      "EXPLAIN DELETE FROM t WHERE sys_eval('x')",
    ])
  func explainSideEffectIsRefused(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .utility)
    #expect(
      DatabaseConnectionManager.evaluate(
        [statement], policy: ProtectionPolicy(protectionLevel: .readOnly), dialect: .mysql)
        != .allowed)
  }

  @Test("A plain EXPLAIN of a read is allowed by read-only")
  func explainReadIsAllowed() throws {
    let statement = try mysqlStatement("EXPLAIN SELECT * FROM t")
    #expect(
      DatabaseConnectionManager.evaluate(
        [statement], policy: ProtectionPolicy(protectionLevel: .readOnly), dialect: .mysql)
        == .allowed)
  }

  @Test(
    "An executable comment anywhere fails closed",
    arguments: [
      "/*!50000 DROP TABLE t */",
      "/*!SELECT 1 */",
      "/*M!100000 SELECT 1 */",
      "SELECT /*!50000 x */ 1",
      "SELECT 1 /*!, (DELETE FROM t) */",
      "EXPLAIN SELECT /*! 1 */ 2",
      "SHOW /*!50000 FULL */ TABLES",
      "SELECT 1 /*!, 2 */",
      "/*!40101 SET NAMES utf8mb4 */",
    ])
  func executableCommentIsUnknown(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .unknown)
    #expect(!statement.isReadOnlySafe)
    #expect(statement.nonTransactional)
    guard
      case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
        [statement], policy: protected, dialect: .mysql)
    else {
      Issue.record("\(sql) should be refused in Protected mode")
      return
    }
    #expect(reason.contains("commits implicitly"))
  }

  @Test(
    "PostgreSQL reads /*! ... */ as a plain comment",
    arguments: ["/*!50000 DROP TABLE t */ SELECT 1", "SELECT 1 /*!, 2 */"])
  func postgresExecutableCommentIsComment(sql: String) throws {
    let statement = try #require(SQLStatementClassifier.classify(sql).first)
    #expect(statement.kind == .read)
    #expect(!statement.nonTransactional)
    #expect(DatabaseConnectionManager.evaluate([statement], policy: protected) == .allowed)
  }

  @Test("Plain comments do not fail closed")
  func plainCommentsAreIgnored() throws {
    #expect(try mysqlStatement("SELECT /* x */ 1 # note").kind == .read)
    #expect(try mysqlStatement("-- note\nSELECT 1").kind == .read)
  }

  @Test("Protected mode off lets implicit-commit statements through")
  func unprotectedAllowsImplicitCommit() throws {
    let statement = try mysqlStatement("CREATE TABLE t (id INT)")
    #expect(
      DatabaseConnectionManager.evaluate([statement], policy: unprotected, dialect: .mysql)
        == .allowed)
  }

  @Test(
    "Password literals include IDENTIFIED BY and SET PASSWORD",
    arguments: [
      ("CREATE USER 'u'@'%' IDENTIFIED BY 'secret'", true),
      ("ALTER USER u IDENTIFIED WITH caching_sha2_password BY 'secret'", true),
      ("create user u identified with mysql_native_password by 'x'", true),
      ("SET PASSWORD FOR 'u'@'%' = 'secret'", true),
      ("set password = 'secret'", true),
      ("SET password_encryption = 'scram-sha-256'", false),
      ("SELECT 'IDENTIFIED BY' FROM t", false),
      ("CREATE USER u", false),
      (#"CREATE USER 'o\'brien'@'%' IDENTIFIED BY 'secret'"#, true),
      ("CREATE USER u /*!IDENTIFIED BY 'secret'*/", true),
      ("CREATE USER u /*!80000 PASSWORD EXPIRE */", true),
      ("CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = 'secret'", true),
      ("change master to master_password='secret'", true),
      ("CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u', PASSWORD 'secret')", true),
      ("ALTER SERVER s OPTIONS (password 'secret')", true),
      ("SELECT password FROM users WHERE password = 'x'", false),
      ("UPDATE users SET password = 'x' WHERE id = 1", false),
      ("START REPLICA USER='u', PASSWORD='secret'", true),
      ("start slave user = 'u' password = 'secret'", true),
      ("START GROUP_REPLICATION USER='u', PASSWORD='secret'", true),
      ("CREATE USER u IDENTIFIED VIA mysql_native_password USING PASSWORD('secret')", true),
      ("GRANT SELECT ON *.* TO u IDENTIFIED VIA ed25519 USING PASSWORD('x')", true),
      ("ALTER USER u IDENTIFIED VIA ed25519 USING 'hash'", true),
      ("CREATE USER u IDENTIFIED WITH mysql_native_password AS '*2470C0C06DEE'", true),
      ("CREATE USER u IDENTIFIED WITH 'caching_sha2_password' AS 'hash'", true),
      ("CREATE USER u IDENTIFIED AS 'hash'", true),
      (
        "CREATE TABLE f (id INT) ENGINE=FEDERATED CONNECTION='mysql://u:secret@host:3306/db/t'",
        true
      ),
      ("ALTER TABLE f CONNECTION='mysql://u:secret@h/db/t'", true),
      (
        "CREATE TABLE f (id INT) ENGINE=CONNECT TABLE_TYPE=MYSQL CONNECTION 'mysql://u:secret@h/db/t'",
        true
      ),
      (
        "CREATE TABLE f (id INT) ENGINE=CONNECT TABLE_TYPE=MYSQL OPTION_LIST='user=u,password=secret'",
        true
      ),
      ("KILL CONNECTION 5", false),
      ("SELECT connection FROM t", false),
    ])
  func passwordLiterals(sql: String, expected: Bool) {
    #expect(SQLStatementClassifier.containsPasswordLiteral(sql, dialect: .mysql) == expected)
  }

  @Test("MySQL :name becomes ? per occurrence, with names repeated in order")
  func rewriteRepeatsNames() {
    let result = SQLParameterRewriter.rewrite(
      statement: "SELECT :b, `:no`, ':no', :a, :b # :no", dialect: .mysql)
    #expect(result.text == "SELECT ?, `:no`, ':no', ?, ? # :no")
    #expect(result.names == ["b", "a", "b"])
    #expect(
      SQLParameterRewriter.parameterNames(in: "SELECT :b, :a, :b", dialect: .mysql) == ["b", "a"])
  }

  @Test(
    "Only ? is a MySQL positional placeholder",
    arguments: [
      ("SELECT ?", true),
      ("SELECT :x, ?", true),
      ("SELECT @y", false),
      ("SELECT $y", false),
      ("SELECT '?'", false),
      ("SELECT 1 # ?", false),
      ("SELECT `?`", false),
    ])
  func positionalPlaceholder(sql: String, expected: Bool) {
    #expect(
      SQLParameterRewriter.containsPositionalPlaceholder(in: sql, dialect: .mysql) == expected)
  }

  /// MySQL applies `MAX_EXECUTION_TIME` and `SET_VAR(...)` optimizer hints for one statement,
  /// so a hint naming a brake setting touches the brake like `SET SESSION`.
  @Test(
    "An optimizer hint that lifts a brake touches the brake",
    arguments: [
      "SELECT /*+ MAX_EXECUTION_TIME(4294967295) */ * FROM t",
      "SELECT /*+ SET_VAR(max_execution_time=0) */ * FROM t",
      "SELECT /*+ SET_VAR(innodb_lock_wait_timeout=1) */ * FROM t",
      "select /*+ INDEX(t i) set_var(Lock_Wait_Timeout = 99) */ a from t",
    ])
  func optimizerHintTouchesBrake(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .read)
    #expect(statement.resetsSessionBrakes)
    #expect(SQLStatementClassifier.summary([statement]).touchesBrake)
    #expect(
      DatabaseConnectionManager.evaluate(
        [statement], policy: ProtectionPolicy(protectionLevel: .readOnly), dialect: .mysql)
        != .allowed)
  }

  @Test(
    "Read-only refuses a brake optimizer hint with a brake-specific reason",
    arguments: [
      "SELECT /*+ MAX_EXECUTION_TIME(0) */ * FROM t",
      "EXPLAIN SELECT /*+ SET_VAR(max_execution_time=0) */ 1",
    ])
  func optimizerHintReadOnlyReason(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.isReadOnlySafe)
    let decision = DatabaseConnectionManager.evaluate(
      [statement], policy: ProtectionPolicy(protectionLevel: .readOnly), dialect: .mysql)
    #expect(
      decision
        == .blocked(
          statementIndex: 0, kind: statement.kind,
          reason: "This statement lifts a session safety limit (a timeout or read-only setting, "
            + "for example through an optimizer hint), which is not allowed on a read-only "
            + "connection"))
  }

  @Test(
    "A write with a brake optimizer hint touches the brake",
    arguments: [
      "INSERT /*+ SET_VAR(max_execution_time=0) */ INTO t VALUES (1)",
      "UPDATE /*+ MAX_EXECUTION_TIME(0) */ t SET c = 1",
    ])
  func writeOptimizerHintTouchesBrake(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .dml)
    #expect(statement.resetsSessionBrakes)
    #expect(SQLStatementClassifier.summary([statement]).touchesBrake)
  }

  @Test(
    "Index and join optimizer hints stay allowed reads",
    arguments: [
      "SELECT /*+ INDEX(t i) */ * FROM t",
      "SELECT /*+ NO_ICP(t) */ * FROM t",
      "SELECT /*+ JOIN_ORDER(a, b) */ * FROM a JOIN b ON a.id = b.id",
    ])
  func indexOptimizerHintStaysRead(sql: String) throws {
    let statement = try mysqlStatement(sql)
    #expect(statement.kind == .read)
    #expect(!statement.resetsSessionBrakes)
    #expect(
      DatabaseConnectionManager.evaluate(
        [statement], policy: ProtectionPolicy(protectionLevel: .readOnly), dialect: .mysql)
        == .allowed)
  }

  @Test("A PostgreSQL /*+ comment is a plain comment")
  func postgresHintIsComment() throws {
    let statement = try #require(
      SQLStatementClassifier.classifyStatement("SELECT /*+ MAX_EXECUTION_TIME(0) */ 1"))
    #expect(!statement.resetsSessionBrakes)
  }
}
