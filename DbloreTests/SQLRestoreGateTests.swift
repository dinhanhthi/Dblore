// SQLRestoreGateTests.swift
// `SQLRestorePlan` and `executeGatedRestore`: the 64 MiB cap, the dump header, the statements a
// dump may hold (per-kind counts, server-version options, triggers), the gate before anything
// is sent, the PostgreSQL / SQLite batch and the MySQL one-by-one path with its session cleanup,
// the SQLite deferred foreign key COMMIT failure that must not leave the transaction open, and a
// version 2 dump's DROPs (only of objects it creates later; on SQLite never one that fires an
// ON DELETE action of a table outside the dump).

import Foundation
import Testing

@testable import Dblore

@Suite("SQL restore gate")
struct SQLRestoreGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  // MARK: - Fixtures

  private static func header(_ engine: DatabaseType, version: Int = 1) -> String {
    SQLDumpAssembler.header(
      engine: engine, created: Date(timeIntervalSince1970: 1_760_000_000), version: version)
  }

  /// A header (version 2 by default), then `statements`, one per line
  private static func script(
    _ engine: DatabaseType, version: Int = 2, _ statements: [String]
  ) -> String {
    ([header(engine, version: version)] + statements).map { $0 + "\n" }.joined()
  }

  private static let postgresDump = [
    header(.postgresql),
    "-- Not dumped: functions, procedures, extensions, roles, ownership, grants",
    "CREATE SCHEMA IF NOT EXISTS \"app\";",
    "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok', 'sad');",
    "CREATE DOMAIN \"public\".\"pos\" AS integer;",
    "CREATE SEQUENCE \"public\".\"items_id_seq\" AS integer START WITH 1 INCREMENT BY 1;",
    "CREATE TABLE \"public\".\"items\" (\"id\" integer DEFAULT"
      + " nextval('public.items_id_seq'::regclass) NOT NULL, \"n\" \"public\".\"pos\","
      + " PRIMARY KEY (\"id\"));",
    "INSERT INTO \"public\".\"items\" (\"id\", \"n\") VALUES\n('1', '2'),\n('2', NULL);",
    "CREATE INDEX items_n ON public.items USING btree (n);",
    "ALTER DOMAIN \"public\".\"pos\" ADD CONSTRAINT \"pos_check\" CHECK ((VALUE > 0)) NOT VALID;",
    "ALTER TABLE \"public\".\"items\" ADD CONSTRAINT \"items_n_check\" CHECK ((n < 10)) NOT VALID;",
    "ALTER SEQUENCE \"public\".\"items_id_seq\" OWNED BY \"public\".\"items\".\"id\";",
    "SELECT pg_catalog.setval('\"public\".\"items_id_seq\"', 2, true);",
    "CREATE VIEW \"public\".\"v\" AS SELECT 1;",
  ].map { $0 + "\n" }.joined()

  private static func sqliteDump(childParent: Int = 1) -> String {
    [
      header(.sqlite),
      "PRAGMA defer_foreign_keys = ON;",
      "CREATE TABLE parent (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);",
      "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent (id));",
      "CREATE TABLE log (msg TEXT);",
      "INSERT INTO \"child\" (\"id\", \"parent_id\") VALUES\n(1, \(childParent));",
      "INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(1, 'a;b'),\n(2, 'c');",
      "CREATE INDEX child_parent ON child (parent_id);",
      "CREATE TRIGGER parent_log AFTER INSERT ON parent BEGIN\n"
        + "  INSERT INTO log VALUES ('added; ' || new.name);\n"
        + "  UPDATE log SET msg = CASE WHEN msg IS NULL THEN '' ELSE msg END;\nEND;",
      "DELETE FROM sqlite_sequence WHERE name = 'parent';",
      "INSERT INTO sqlite_sequence (name, seq) VALUES ('parent', 2);",
    ].map { $0 + "\n" }.joined()
  }

  private static func mysqlScript(_ body: [String]) -> String {
    ([header(.mysql)] + SQLDumpAssembler.mysqlSessionSettings + ["SET FOREIGN_KEY_CHECKS=0;"]
      + body + ["SET FOREIGN_KEY_CHECKS=1;"]).map { $0 + "\n" }.joined()
  }

  private static func plan(_ script: String, _ engine: DatabaseType) throws -> SQLRestorePlan {
    try SQLRestorePlan(script: script, engine: engine)
  }

  private static func planError(_ script: String, _ engine: DatabaseType) -> SQLRestoreError? {
    do {
      _ = try SQLRestorePlan(script: script, engine: engine)
      return nil
    } catch let error as SQLRestoreError {
      return error
    } catch {
      Issue.record("Unexpected error \(error)")
      return nil
    }
  }

  // MARK: - Size and header

  @Test("A script over 64 MiB is refused before it is split")
  func tooLarge() {
    let limit = SQLRestorePlan.maxScriptBytes
    #expect(limit == 64 * 1024 * 1024)
    let head = Self.header(.postgresql) + "\n-- "
    let script = head + String(repeating: "x", count: limit + 1 - head.utf8.count)
    #expect(Self.planError(script, .postgresql) == .tooLarge(bytes: limit + 1))
  }

  @Test("The header must be the first line and name the connection's engine")
  func headerChecks() {
    #expect(
      SQLDumpAssembler.header(engine: .mysql, created: Date()).hasPrefix(
        SQLRestorePlan.headerPrefix + "MySQL "))
    #expect(Self.planError("CREATE TABLE a (id int);\n", .postgresql) == .headerMissing)
    #expect(
      Self.planError("\n" + Self.header(.postgresql) + "\nSELECT 1;", .postgresql)
        == .headerMissing)
    #expect(
      SQLDumpAssembler.header(engine: .mysql, created: Date(), version: 2).hasPrefix(
        SQLRestorePlan.dropHeaderPrefix + "MySQL "))
    // Version 2 is read (a dump that drops); any other version is refused at the header, a
    // later one as made by a newer Dblore
    #expect(
      Self.planError(
        "-- Dblore SQL dump 2 engine=PostgreSQL\nCREATE TABLE a (id int);", .postgresql)
        == nil)
    for newer in ["3", "10", "003", "99999999999999999999999"] {
      #expect(
        Self.planError(
          "-- Dblore SQL dump \(newer) engine=PostgreSQL\nCREATE TABLE a (id int);", .postgresql)
          == .newerDumpVersion, "\(newer)")
    }
    #expect(
      SQLRestoreError.newerDumpVersion.localizedDescription
        == "This dump was made by a newer Dblore; update Dblore to restore it. Nothing was "
        + "executed.")
    for other in ["0", "02", "", "3x", "-3"] {
      #expect(
        Self.planError(
          "-- Dblore SQL dump \(other) engine=PostgreSQL\nCREATE TABLE a (id int);", .postgresql)
          == .headerMissing, "\(other)")
    }
    #expect(Self.planError("-- Dblore SQL dump 3 engine\nSELECT 1;", .postgresql) == .headerMissing)
    #expect(
      Self.planError("-- Dblore SQL dump 2 engine=MySQL\nCREATE TABLE a (id int);", .postgresql)
        == .engineMismatch(dump: "MySQL", connection: "PostgreSQL"))
    #expect(
      Self.planError(Self.header(.mysql) + "\nCREATE TABLE a (id int);", .postgresql)
        == .engineMismatch(dump: "MySQL", connection: "PostgreSQL"))
    #expect(
      Self.planError("-- Dblore SQL dump 1 engine=PostgreSQLX\nSELECT 1;", .postgresql)
        == .engineMismatch(dump: "PostgreSQLX", connection: "PostgreSQL"))
    #expect(
      Self.planError(Self.header(.mongodb) + "\ndb.a.find()", .mongodb)
        == .unsupportedEngine("MongoDB"))
    // A DuckDB dump restores only into DuckDB, and only a DuckDB dump into DuckDB
    #expect(
      Self.planError(Self.header(.duckdb) + "\nCREATE TABLE a (id int);", .sqlite)
        == .engineMismatch(dump: "DuckDB", connection: "SQLite"))
    #expect(
      Self.planError(Self.header(.duckdb) + "\nCREATE TABLE a (id int);", .postgresql)
        == .engineMismatch(dump: "DuckDB", connection: "PostgreSQL"))
    #expect(
      Self.planError(Self.header(.sqlite) + "\nCREATE TABLE a (id int);", .duckdb)
        == .engineMismatch(dump: "SQLite", connection: "DuckDB"))
    #expect(
      Self.planError(Self.header(.postgresql) + "\nCREATE TABLE a (id int);", .duckdb)
        == .engineMismatch(dump: "PostgreSQL", connection: "DuckDB"))
  }

  @Test("A header alone is an empty restore")
  func headerOnly() throws {
    let plan = try Self.plan(Self.header(.sqlite) + "\n-- nothing\n", .sqlite)
    #expect(plan.statements.isEmpty)
    #expect(plan.summary.statementCount == 0)
  }

  // MARK: - Accepted statements

  @Test("A PostgreSQL dump: schema, data and sequence values")
  func postgresKinds() throws {
    let plan = try Self.plan(Self.postgresDump, .postgresql)
    #expect(plan.summary.statementCount == 12)
    #expect(plan.summary.count(.schema) == 10)
    #expect(plan.summary.count(.data) == 1)
    #expect(plan.summary.count(.sequenceValue) == 1)
    #expect(plan.summary.changesSchema)
    #expect(plan.kinds.last == .schema)
    #expect(plan.kinds[plan.kinds.count - 2] == .sequenceValue)
    // The comment lines ride on the first statement; every statement is sent as split
    #expect(plan.statements[0].text.hasPrefix("-- Dblore SQL dump 1 engine=PostgreSQL"))
    #expect(plan.statements[0].text.hasSuffix("CREATE SCHEMA IF NOT EXISTS \"app\""))
  }

  @Test("A SQLite dump: the trigger is one schema statement, the PRAGMA a session setting")
  func sqliteKinds() throws {
    let plan = try Self.plan(Self.sqliteDump(), .sqlite)
    #expect(plan.summary.statementCount == 10)
    #expect(plan.summary.count(.sessionSetting) == 1)
    #expect(plan.summary.count(.schema) == 4)
    #expect(plan.summary.count(.trigger) == 1)
    #expect(plan.summary.count(.data) == 4)
    let trigger = try #require(plan.kinds.firstIndex(of: .trigger))
    #expect(plan.statements[trigger].text.hasPrefix("CREATE TRIGGER parent_log"))
    #expect(plan.statements[trigger].text.hasSuffix("END"))
    // The classifier fails closed on the body's `;`; restore classifies the trigger as DDL
    #expect(
      SQLStatementClassifier.classifyStatement(plan.statements[trigger].text, dialect: .sqlite)?
        .kind == .unknown)
    #expect(plan.statements[trigger].kind == .ddl)
  }

  @Test("A MySQL dump: its session settings and server-version options in CREATE TABLE")
  func mysqlKinds() throws {
    let create =
      "CREATE TABLE `t` (\n  `id` int NOT NULL,\n  `v` int /*!80023 INVISIBLE */,\n"
      + "  PRIMARY KEY (`id`)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4\n"
      + "/*!50100 PARTITION BY HASH (`id`) PARTITIONS 2 */;"
    let plan = try Self.plan(
      Self.mysqlScript([create, "INSERT INTO `t` (`id`, `v`) VALUES\n('1', '\\\\;''x');"]),
      .mysql)
    #expect(plan.summary.statementCount == 7)
    #expect(plan.summary.count(.sessionSetting) == 5)
    #expect(plan.summary.count(.schema) == 1)
    #expect(plan.summary.count(.data) == 1)
    #expect(
      plan.summary.serverVersionOptions == [
        "/*!80023 INVISIBLE */", "/*!50100 PARTITION BY HASH (`id`) PARTITIONS 2 */",
      ])
    #expect(plan.statements[4].kind == .ddl)
  }

  @Test(
    "Statements a dump never writes are refused with their index",
    arguments: [
      (DatabaseType.postgresql, "SELECT 1;"),
      (.postgresql, "BEGIN;"),
      (.postgresql, "COMMIT;"),
      (.postgresql, "DO $$ BEGIN PERFORM 1; END $$;"),
      (.postgresql, "SET search_path = app;"),
      (.postgresql, "COPY t FROM STDIN;"),
      (.postgresql, "SELECT pg_catalog.setval('s', 2, true), pg_sleep(1);"),
      (.postgresql, "SELECT setval('s', 2, true);"),
      (.mysql, "SET autocommit = 0;"),
      (.mysql, "SET @x = 1;"),
      (.mysql, "SET SESSION sql_mode = '';"),
      (.mysql, "SET FOREIGN_KEY_CHECKS = 2;"),
      (.mysql, "/*!40101 SET NAMES latin1 */;"),
      (.mysql, "INSERT INTO t VALUES (1) /*!50000 , (2) */;"),
      (.mysql, "CREATE TABLE t (id int) /*!50100 ; DROP TABLE u */;"),
      (.mysql, "ALTER TABLE t ADD c int /*!50100 FIRST */;"),
      (.mysql, "CREATE TABLE t (id int) /*!50100 ENGINE=InnoDB */ /*!50000 SELECT SLEEP(1) */;"),
      (.mysql, "START TRANSACTION;"),
      (.sqlite, "PRAGMA writable_schema = ON;"),
      (.sqlite, "PRAGMA defer_foreign_keys = OFF;"),
      (.sqlite, "ATTACH 'other.db' AS other;"),
      (.sqlite, "SELECT 1;"),
      (.sqlite, "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1;"),
    ])
  func refusedStatements(engine: DatabaseType, statement: String) {
    expectRefusedAtIndex1(engine, statement)
  }

  @Test(
    "SET NAMES utf8, utf8mb3 or utf8mb4 as Dblore and mysqldump write it runs as utf8mb4",
    arguments: [
      "SET NAMES utf8;", "SET NAMES utf8mb3;", "/*!40101 SET NAMES utf8 */;",
      "/*!40101 SET NAMES utf8mb4 */;", "/*!50503 SET NAMES utf8mb4 */;",
      "-- charset note\n# legacy\n/* old */ SET NAMES utf8;",
    ])
  func setNamesUTF8Accepted(statement: String) throws {
    let script = Self.header(.mysql) + "\nCREATE TABLE a (id int);\n" + statement + "\n"
    let plan = try Self.plan(script, .mysql)
    #expect(plan.statements.count == 2)
    #expect(plan.statements[1].text == "SET NAMES utf8mb4")
    #expect(plan.kinds[1] == .sessionSetting)
  }

  @Test(
    "A SET NAMES in another form or character set is refused with its statement number and text",
    arguments: [
      ("set names 'utf8mb4';", "set names 'utf8mb4'"),
      ("SET NAMES utf8mb4 COLLATE utf8mb4_bin;", "SET NAMES utf8mb4 COLLATE utf8mb4_bin"),
      ("SET\tNAMES\n  \"utf8mb4\";", "SET NAMES \"utf8mb4\""),
      ("SET NAMES latin1;", "SET NAMES latin1"),
      ("/*!40101 SET NAMES latin1 */;", "/*!40101 SET NAMES latin1 */"),
      ("/*!40101 SET NAMES gbk */;", "/*!40101 SET NAMES gbk */"),
      ("-- charset note\n# legacy\n/* old */ SET NAMES latin1;", "SET NAMES latin1"),
    ])
  func setNamesRefused(statement: String, shown: String) {
    let script = Self.header(.mysql) + "\nCREATE TABLE a (id int);\n" + statement + "\n"
    let error = Self.planError(script, .mysql)
    guard case .statementRefused(let index, _)? = error else {
      Issue.record("Expected \(statement) to be refused")
      return
    }
    #expect(index == 1)
    #expect(
      error?.localizedDescription
        == "Statement 2 is not part of a SQL dump: \"\(shown)\" sets the connection's character "
        + "set, but Dblore restores only SET NAMES utf8mb4, utf8 or utf8mb3 as its own dumps and "
        + "mysqldump write them (run as utf8mb4, the character set of this session); for another "
        + "character set, make the dump again with --default-character-set=utf8mb4. "
        + "Nothing was executed.")
  }

  @Test(
    "DDL and DML a dump never writes are refused: roles, extensions, drops, unfiltered writes",
    arguments: [
      (DatabaseType.postgresql, "CREATE ROLE backdoor SUPERUSER LOGIN PASSWORD 'x';"),
      (.postgresql, "CREATE USER backdoor PASSWORD 'x';"),
      (.postgresql, "ALTER ROLE app SUPERUSER;"),
      (.postgresql, "ALTER USER app WITH PASSWORD 'x';"),
      (.postgresql, "ALTER SYSTEM SET archive_command = 'sh -c x';"),
      (.postgresql, "CREATE EXTENSION dblink;"),
      (.postgresql, "CREATE FUNCTION f() RETURNS int AS 'lib', 'f' LANGUAGE C;"),
      (.postgresql, "CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;"),
      (.postgresql, "DROP DATABASE prod;"),
      (.postgresql, "DROP SCHEMA public CASCADE;"),
      (.postgresql, "DROP TABLE a;"),
      (.postgresql, "GRANT ALL ON a TO PUBLIC;"),
      (.postgresql, "ALTER TABLE a OWNER TO postgres;"),
      (.postgresql, "ALTER TABLE a ADD COLUMN c int;"),
      (.postgresql, "CREATE SCHEMA s AUTHORIZATION postgres;"),
      (.postgresql, "CREATE TYPE t AS (a int);"),
      (.postgresql, "CREATE TEMP TABLE x (id int);"),
      (.postgresql, "CREATE TABLE x AS SELECT 1;"),
      (.postgresql, "CREATE OR REPLACE VIEW v AS SELECT 1;"),
      (.postgresql, "CREATE TRIGGER t AFTER INSERT ON a FOR EACH ROW EXECUTE FUNCTION f();"),
      (.postgresql, "DELETE FROM a;"),
      (.postgresql, "DELETE FROM a WHERE id = 1;"),
      (.postgresql, "UPDATE a SET id = 1;"),
      (.postgresql, "UPDATE a SET id = 1 WHERE id = 2;"),
      (.postgresql, "INSERT INTO a SELECT 1;"),
      (.postgresql, "INSERT INTO pg_catalog.pg_authid (rolname) VALUES ('x');"),
      (.postgresql, "INSERT INTO pg_authid (rolname) VALUES ('x');"),
      (.postgresql, "WITH d AS (DELETE FROM a) INSERT INTO a VALUES (1);"),
      (.mysql, "CREATE USER 'backdoor'@'%' IDENTIFIED BY 'x';"),
      (.mysql, "ALTER USER root IDENTIFIED BY 'x';"),
      (.mysql, "CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (HOST 'h');"),
      (.mysql, "CREATE FUNCTION f RETURNS STRING SONAME 'x.so';"),
      (.mysql, "DROP DATABASE prod;"),
      (.mysql, "DROP TABLE a;"),
      (.mysql, "GRANT ALL ON *.* TO 'backdoor'@'%';"),
      (.mysql, "ALTER TABLE a ADD c int;"),
      (.mysql, "CREATE DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1;"),
      (.mysql, "CREATE OR REPLACE VIEW `v` AS select 1;"),
      (.mysql, "CREATE TRIGGER t BEFORE INSERT ON a FOR EACH ROW SET NEW.id = 1;"),
      (.mysql, "CREATE EVENT e ON SCHEDULE EVERY 1 DAY DO DELETE FROM a;"),
      (.mysql, "DELETE FROM a;"),
      (.mysql, "UPDATE a SET id = 1;"),
      (.mysql, "INSERT INTO mysql.user (User) VALUES ('backdoor');"),
      (.mysql, "INSERT INTO a SELECT 1;"),
      (.sqlite, "DELETE FROM a;"),
      (.sqlite, "DELETE FROM sqlite_sequence WHERE name = 'a' OR 1 = 1;"),
      (.sqlite, "DELETE FROM a WHERE id = 1;"),
      (.sqlite, "UPDATE a SET id = 1;"),
      (.sqlite, "DROP TABLE a;"),
      (.sqlite, "ALTER TABLE a ADD COLUMN c;"),
      (.sqlite, "INSERT INTO a SELECT 1;"),
      (.sqlite, "CREATE TEMP VIEW v AS SELECT 1;"),
      (.sqlite, "CREATE TEMP TRIGGER t AFTER INSERT ON a BEGIN DELETE FROM b; END;"),
    ])
  func refusedWrites(engine: DatabaseType, statement: String) {
    expectRefusedAtIndex1(engine, statement)
  }

  @Test(
    "CREATE TABLE with a query, a remote or file engine or other clauses after it is refused",
    arguments: [
      (DatabaseType.postgresql, "CREATE TABLE x (a) AS SELECT 1;"),
      (.postgresql, "CREATE TABLE x (a int) AS SELECT set_config('role', 'postgres', false);"),
      (.postgresql, "CREATE TABLE x (a text) AS SELECT dblink_exec('host=h', 'DROP TABLE t');"),
      (.postgresql, "CREATE TABLE x (a int) AS EXECUTE p (1);"),
      (.postgresql, "CREATE TABLE x (a int) AS TABLE secret;"),
      (.postgresql, "CREATE TABLE x (a int) WITH (fillfactor = 10);"),
      (.postgresql, "CREATE TABLE x (a int) INHERITS (y);"),
      (.postgresql, "CREATE TABLE x (a int)) AS SELECT 1;"),
      (.postgresql, "CREATE TABLE x (a int;"),
      (.postgresql, "CREATE TABLE x (a int) PARTITION BY RANGE (a) AS SELECT 1;"),
      (.postgresql, "CREATE TABLE x PARTITION OF p FOR VALUES IN (1) AS SELECT 1;"),
      (.postgresql, "CREATE TABLE x PARTITION OF p DEFAULT AS SELECT 1;"),
      (.postgresql, "CREATE TABLE x PARTITION OF p FOR VALUES FROM (1) AS SELECT 1;"),
      (.mysql, "CREATE TABLE x (a int) SELECT 1;"),
      (.mysql, "CREATE TABLE x (a int) AS SELECT 1;"),
      (.mysql, "CREATE TABLE x (a int) IGNORE SELECT * FROM otherdb.secret;"),
      (.mysql, "CREATE TABLE x (a int) (SELECT 1);"),
      (.mysql, "CREATE TABLE x (SELECT 1 AS a);"),
      (.mysql, "CREATE TABLE x (LIKE otherdb.secret);"),
      (.mysql, "CREATE TABLE x (a int) LIKE y;"),
      (.mysql, "CREATE TABLE x (a int) TABLE otherdb.secret;"),
      (.mysql, "CREATE TABLE x (a int) VALUES ROW(1);"),
      (.mysql, "CREATE TABLE x (a int) ENGINE=FEDERATED CONNECTION='mysql://u:p@h:3306/db/t';"),
      (.mysql, "CREATE TABLE x (a int) ENGINE FEDERATED;"),
      (.mysql, "CREATE TABLE x (a int) ENGINE='federated';"),
      (.mysql, "CREATE TABLE x (a int) ENGINE=FEDERATEDX;"),
      (.mysql, "CREATE TABLE x (a int) ENGINE=CONNECT TABLE_TYPE=CSV FILE_NAME='/etc/passwd';"),
      (.mysql, "CREATE TABLE x (a int) ENGINE=SPIDER COMMENT='wrapper \"mysql\", srv \"s\"';"),
      (.mysql, "CREATE TABLE x (a int) ENGINE=InnoDB CONNECTION='s';"),
      (.mysql, "CREATE TABLE x (a int) DATA DIRECTORY='/tmp/x';"),
      (.mysql, "CREATE TABLE x (a int) INDEX DIRECTORY='/tmp/x';"),
      (
        .mysql,
        "CREATE TABLE x (a int) ENGINE=InnoDB\n/*!50100 PARTITION BY HASH (a)"
          + " (PARTITION p0 DATA DIRECTORY = '/tmp/x' ENGINE = InnoDB) */;"
      ),
      (.mysql, "CREATE TABLE x (a int) /*!50100 ENGINE=FEDERATED CONNECTION='mysql://h/d/t' */;"),
      (.mysql, "CREATE TABLE x (a int) /*!50100 SELECT 1 */;"),
      // Version comments opened: the statement a server that runs them sees
      (.mysql, "CREATE TABLE `otherdb`.`t` (a int) /*!40101 DEFAULT CHARSET=utf8mb4 */;"),
      (.mysql, "CREATE TABLE t /*!50100 ENGINE=InnoDB */ SELECT * FROM otherdb.secret;"),
      (.sqlite, "CREATE TABLE x AS SELECT 1;"),
      (.sqlite, "CREATE TABLE x (a) AS SELECT 1;"),
      (.sqlite, "CREATE TABLE x;"),
      (.sqlite, "CREATE TABLE x (a) WITHOUT ROWID AS SELECT 1;"),
      (.sqlite, "CREATE VIRTUAL TABLE x USING fts5(a) AS SELECT 1;"),
      (.sqlite, "CREATE VIRTUAL TABLE x AS SELECT 1;"),
    ])
  func refusedTrailingClauses(engine: DatabaseType, statement: String) {
    expectRefusedAtIndex1(engine, statement)
  }

  @Test(
    "Schema statements into a system schema or SQLite's temp schema are refused",
    arguments: [
      (DatabaseType.postgresql, "CREATE TABLE pg_catalog.x (a int);"),
      (.postgresql, "CREATE TABLE \"pg_catalog\".\"x\" (a int);"),
      (.postgresql, "CREATE TABLE information_schema.x (a int);"),
      (.postgresql, "CREATE TABLE pg_temp.x (a int);"),
      (.postgresql, "CREATE TABLE \"PG_TEMP\".x (a int);"),
      (.postgresql, "CREATE TABLE pg_temp_3.x (a int);"),
      (.postgresql, "CREATE TABLE pg_toast.x (a int);"),
      (.postgresql, "CREATE TABLE x PARTITION OF pg_catalog.y DEFAULT;"),
      (.postgresql, "CREATE VIEW pg_catalog.v AS SELECT 1;"),
      (.postgresql, "CREATE VIEW pg_temp.v AS SELECT 1;"),
      (.postgresql, "CREATE INDEX i ON pg_catalog.pg_class (relname);"),
      (.postgresql, "CREATE UNIQUE INDEX i ON ONLY pg_catalog.pg_class (relname);"),
      (.postgresql, "CREATE INDEX i ON pg_class USING btree (relname);"),
      (.postgresql, "CREATE SEQUENCE pg_temp.s AS integer;"),
      (.postgresql, "CREATE TYPE pg_temp.t AS ENUM ('a');"),
      (.postgresql, "CREATE DOMAIN pg_temp.d AS integer;"),
      (.postgresql, "CREATE SCHEMA IF NOT EXISTS pg_temp;"),
      (.postgresql, "CREATE SCHEMA IF NOT EXISTS information_schema;"),
      (.postgresql, "ALTER TABLE pg_catalog.pg_class ADD CHECK (true);"),
      (.postgresql, "ALTER TABLE pg_temp.x ADD CONSTRAINT c UNIQUE (a);"),
      (.postgresql, "ALTER DOMAIN pg_catalog.d ADD CONSTRAINT c CHECK (true);"),
      (.postgresql, "ALTER SEQUENCE pg_temp.s OWNED BY public.a.id;"),
      (.mysql, "CREATE TABLE `mysql`.`user2` (a int);"),
      (.mysql, "CREATE TABLE sys.x (a int);"),
      (.mysql, "CREATE TABLE performance_schema.x (a int);"),
      (.mysql, "CREATE TABLE `information_schema`.x (a int);"),
      (.mysql, "CREATE TABLE `mysql`.`x` (a int) /*!40101 DEFAULT CHARSET=utf8mb4 */;"),
      (.mysql, "CREATE VIEW `mysql`.`v` AS select 1;"),
      (.mysql, "CREATE ALGORITHM=UNDEFINED VIEW sys.v AS select 1;"),
      (.sqlite, "CREATE TABLE temp.x (a);"),
      (.sqlite, "CREATE TABLE \"TEMP\".x (a);"),
      (.sqlite, "CREATE TABLE temporary.x (a);"),
      (.sqlite, "CREATE TABLE IF NOT EXISTS temp.x (a);"),
      (.sqlite, "CREATE VIRTUAL TABLE temp.d USING fts5(b);"),
      (.sqlite, "CREATE VIEW temp.v AS SELECT 1;"),
      (.sqlite, "CREATE VIEW [Temp].v AS SELECT 1;"),
      (.sqlite, "CREATE INDEX temp.i ON a (id);"),
      (.sqlite, "CREATE UNIQUE INDEX temporary.i ON a (id);"),
      (.sqlite, "CREATE TRIGGER temp.x AFTER INSERT ON a BEGIN DELETE FROM a; END;"),
      (.sqlite, "CREATE TRIGGER \"temp\".x AFTER INSERT ON a BEGIN DELETE FROM a; END;"),
      (.sqlite, "CREATE TRIGGER `TEMPORARY`.x AFTER INSERT ON a BEGIN DELETE FROM a; END;"),
      (.sqlite, "CREATE TRIGGER IF NOT EXISTS temp.x AFTER INSERT ON a BEGIN DELETE FROM a; END;"),
      (.sqlite, "CREATE TRIGGER x AFTER INSERT ON temp.a BEGIN DELETE FROM a; END;"),
    ])
  func refusedSystemTargets(engine: DatabaseType, statement: String) {
    expectRefusedAtIndex1(engine, statement)
  }

  private static let notLiteral = "holds only literal values"
  private static let notAtEnd = "ends after its last VALUES row"
  private static let notColumns = "lists only column names"
  /// File and extension loaders classify as utility commands, refused before the VALUES check
  private static let utility = "Utility command"

  @Test(
    "An INSERT with VALUES other than a dump's literals, or more after them, is refused",
    arguments: [
      (
        DatabaseType.postgresql, "INSERT INTO a (id) VALUES (lo_export(16385, '/tmp/x'));",
        notLiteral
      ),
      (
        .postgresql, "INSERT INTO a (id) VALUES (set_config('role', 'postgres', false));",
        notLiteral
      ),
      (.postgresql, "INSERT INTO a (id) VALUES ('1'::int);", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES ('1' || '2');", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES (id);", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES (1);", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES (DEFAULT);", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES (X'01');", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES ();", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES ((SELECT '1'));", notLiteral),
      (.postgresql, "INSERT INTO a (id) VALUES ('1'), ('2', current_user);", notLiteral),
      (
        .postgresql, "INSERT INTO a (id) VALUES ('1') ON CONFLICT (id) DO UPDATE SET id = '2';",
        notAtEnd
      ),
      (.postgresql, "INSERT INTO a (id) VALUES ('1') RETURNING id;", notAtEnd),
      (.postgresql, "INSERT INTO a (lower(id)) VALUES ('1');", notColumns),
      (.mysql, "INSERT INTO a (id) VALUES (LOAD_FILE('/etc/passwd'));", utility),
      (.mysql, "INSERT INTO a (id) VALUES ('1' + 1);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1 + 1);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1 2);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (--1);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1.);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (.5);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1e);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1e5e5);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1e+);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1 DIV 2);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (0x);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (0xZZ);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (1x0A);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (b'012');", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (_binary 0x0A);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (_binary @x);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (_latin1'x');", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (@x);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (id);", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES (X'0G');", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES ((SELECT '1'));", notLiteral),
      (.mysql, "INSERT INTO a (id) VALUES ('1') ON DUPLICATE KEY UPDATE id = '2';", notAtEnd),
      (.sqlite, "INSERT INTO a (id) VALUES (load_extension('evil'));", utility),
      (.sqlite, "INSERT INTO a (id) VALUES (1 + 1);", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES (CAST('1' AS INTEGER));", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES (id);", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES (- -1);", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES (1e5);", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES (1.);", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES ((SELECT 1));", notLiteral),
      (.sqlite, "INSERT INTO a (id) VALUES (1) ON CONFLICT DO NOTHING;", notAtEnd),
      (.sqlite, "INSERT INTO a (id) VALUES (1) RETURNING id;", notAtEnd),
    ])
  func refusedInsertValues(engine: DatabaseType, statement: String, reason: String) {
    let script = Self.header(engine) + "\nCREATE TABLE a (id int);\n" + statement + "\n"
    guard case .statementRefused(let index, let refusal)? = Self.planError(script, engine) else {
      Issue.record("Expected \(statement) to be refused")
      return
    }
    #expect(index == 1)
    #expect(refusal.contains(reason), "\(statement): \(refusal)")
  }

  @Test("MySQL INSERT rows hold numbers, 0x / X'' / b'' / _binary values, text and NULL")
  func mysqlInsertLiterals() throws {
    let values =
      "(1, -2, 3.25, -0.001, 0.00000000015, -2.25e30, 1e30, 1.5e-10, 2E+5, 0x0A1b, "
      + "X'0a', b'0101', B'', _binary 'x\\'y', _binary'!', 'a', \"b\", NULL)"
    let script = [
      Self.header(.mysql), "CREATE TABLE a (id int);",
      "INSERT INTO `a` VALUES \(values),\n(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0, X'', b'1', B'0', "
        + "_binary '', '', '', '', NULL);",
    ].joined(separator: "\n")
    let plan = try Self.plan(script, .mysql)
    #expect(plan.kinds == [.schema, .data])
    // The other engines keep their own literals
    let sqlite = [Self.header(.sqlite), "INSERT INTO a VALUES (0x0A);"].joined(separator: "\n")
    #expect(Self.planError(sqlite, .sqlite) != nil)
    let postgres = [Self.header(.postgresql), "INSERT INTO a VALUES (1);"].joined(separator: "\n")
    #expect(Self.planError(postgres, .postgresql) != nil)
  }

  private func expectRefusedAtIndex1(_ engine: DatabaseType, _ statement: String) {
    let script = Self.header(engine) + "\nCREATE TABLE a (id int);\n" + statement + "\n"
    guard case .statementRefused(let index, _)? = Self.planError(script, engine) else {
      Issue.record("Expected \(statement) to be refused")
      return
    }
    #expect(index == 1)
  }

  private static let postgresShapes: [String] =
    [
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok');",
      "CREATE DOMAIN \"public\".\"pos\" AS integer DEFAULT 1 NOT NULL;",
      "CREATE SEQUENCE \"public\".\"s\" AS bigint START WITH 1 INCREMENT BY 1"
        + " MINVALUE 1 MAXVALUE 9 NO CYCLE;",
      "CREATE TABLE \"public\".\"p\" (\n  \"id\" integer NOT NULL\n) PARTITION BY RANGE (id);",
      "CREATE TABLE \"public\".\"p1\" PARTITION OF \"public\".\"p\""
        + " FOR VALUES FROM (1) TO (10);",
      "ALTER TABLE \"public\".\"p1\" ADD PRIMARY KEY (\"id\");",
      "CREATE TABLE \"public\".\"h1\" PARTITION OF \"public\".\"h\""
        + " FOR VALUES WITH (modulus 2, remainder 0);",
      "CREATE TABLE \"public\".\"pd\" PARTITION OF \"public\".\"p\" DEFAULT;",
      "CREATE TABLE \"public\".\"l1\" PARTITION OF \"public\".\"l\" FOR VALUES IN ('a', 'b')"
        + " PARTITION BY RANGE (lower((id)::text));",
      "CREATE TABLE \"app\".\"g\" (\n  \"id\" integer GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME"
        + " \"app\".\"g_id_seq\" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9 NO CYCLE),"
        + "\n  \"d\" integer GENERATED ALWAYS AS ((id * 2)) STORED,\n  CHECK ((id > 0))\n);",
      "CREATE TABLE \"public\".\"e\" ();",
      "INSERT INTO \"public\".\"e\" DEFAULT VALUES;",
      "INSERT INTO \"public\".\"p1\" (\"id\") OVERRIDING SYSTEM VALUE VALUES\n('1');",
      // Every value form the writer emits on PostgreSQL: text (bytea as its `\\x` text)
      "INSERT INTO \"public\".\"p1\" (\"id\", \"b\", \"t\") VALUES\n('1', E'\\\\x0102', 'it''s'),"
        + "\n(NULL, E'a\\\\b''c', '');",
      "CREATE UNIQUE INDEX p1_id ON public.p1 USING btree (id);",
      "ALTER TABLE \"public\".\"p1\" ADD CONSTRAINT \"x\" EXCLUDE USING gist (id WITH =);",
      "ALTER TABLE \"public\".\"p1\" ADD FOREIGN KEY (\"id\") REFERENCES \"public\".\"q\""
        + " (\"id\");",
      "ALTER TABLE \"public\".\"p1\" ADD CHECK ((id > 0));",
      "ALTER TABLE \"public\".\"p1\" ADD UNIQUE (\"id\");",
      "ALTER SEQUENCE \"public\".\"s\" OWNED BY \"public\".\"p1\".\"id\";",
      "SELECT pg_catalog.setval('\"public\".\"s\"', -3, false);",
      "CREATE VIEW \"app\".\"v\" AS\nSELECT 1;",
      // Catalog text with a backslash in a plain string (standard_conforming_strings on)
      "ALTER TABLE \"public\".\"p1\" ADD CONSTRAINT \"p1_code\" CHECK ((code ~ '^\\d+$'::text));",
      "CREATE TABLE \"public\".\"pat\" (\n  \"note\" text DEFAULT 'a\\b'::text\n);",
      "CREATE VIEW \"public\".\"lines\" AS\n SELECT (pat.note || '\\n'::text) AS line\n   FROM pat;",
      "ALTER DOMAIN \"public\".\"pos\" ADD CONSTRAINT \"pos_digits\" CHECK ((VALUE ~ '\\d'::text));",
      "CREATE INDEX pat_note ON public.pat USING btree (note) WHERE (note <> 'a\\b'::text);",
    ]

  private static let mysqlShapes: [String] =
    SQLDumpAssembler.mysqlSessionSettings + [
      "SET FOREIGN_KEY_CHECKS=0;",
      "CREATE TABLE `t` (\n  `id` int NOT NULL\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;",
      // `SHOW CREATE TABLE` options: checks with LIKE, generated columns, comments, partitions
      "CREATE TABLE `u` (\n  `id` int NOT NULL AUTO_INCREMENT,\n  `name` varchar(20)"
        + " COMMENT 'as; select',\n  `d` int GENERATED ALWAYS AS ((`id` * 2)) VIRTUAL,\n"
        + "  PRIMARY KEY (`id`),\n  CONSTRAINT `c` CHECK ((`name` like _utf8mb4'a%'))\n"
        + ") ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci"
        + " ROW_FORMAT=DYNAMIC STATS_PERSISTENT=0 COMMENT='a table'\n/*!50100 PARTITION BY"
        + " RANGE (`id`)\n(PARTITION p0 VALUES LESS THAN (10) ENGINE = InnoDB,\n PARTITION p1"
        + " VALUES LESS THAN MAXVALUE ENGINE = InnoDB) */;",
      "CREATE TABLE `w` (\n  `id` int NOT NULL\n) ENGINE=MyISAM DEFAULT CHARSET=latin1\n"
        + "/*!50100 PARTITION BY LIST (`id`)\n(PARTITION p0 VALUES IN (1,2) ENGINE = MyISAM) */;",
      // MySQL 8.4: a parser in a version comment
      "CREATE TABLE `f` (\n  `id` int DEFAULT NULL,\n  `body` text,\n  FULLTEXT KEY `ft` (`body`)"
        + " /*!50100 WITH PARSER `ngram` */ \n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
        + " COLLATE=utf8mb4_0900_ai_ci;",
      // MariaDB 11.4: partitions without a version comment
      "CREATE TABLE `m` (\n  `id` int(11) NOT NULL AUTO_INCREMENT,\n  `name` varchar(20)"
        + " DEFAULT NULL COMMENT 'as; select',\n  `d` int(11) GENERATED ALWAYS AS (`id` * 2)"
        + " VIRTUAL,\n  PRIMARY KEY (`id`),\n  FULLTEXT KEY `ft` (`name`),\n  CONSTRAINT `c`"
        + " CHECK (`name` like 'a%')\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
        + " COLLATE=utf8mb4_uca1400_ai_ci STATS_PERSISTENT=0 ROW_FORMAT=DYNAMIC COMMENT='a table'"
        + "\n PARTITION BY RANGE (`id`)\n(PARTITION `p0` VALUES LESS THAN (10) ENGINE = InnoDB,"
        + "\n PARTITION `p1` VALUES LESS THAN MAXVALUE ENGINE = InnoDB);",
      "CREATE TABLE `l` (\n  `id` int(11) NOT NULL,\n  `k` int(11) DEFAULT NULL,\n  PRIMARY KEY"
        + " (`id`),\n  KEY `k` (`k`) USING BTREE\n) ENGINE=InnoDB DEFAULT CHARSET=latin1"
        + " COLLATE=latin1_swedish_ci\n PARTITION BY LIST (`id`)\n(PARTITION `a` VALUES IN (1,2)"
        + " ENGINE = InnoDB,\n PARTITION `b` VALUES IN (3) ENGINE = InnoDB);",
      "INSERT INTO `t` (`id`) VALUES\n('1');",
      "INSERT INTO `t` (`id`, `b`, `v`) VALUES\n('1', X'0102', 'a\\\\b''c'),\n(NULL, X'', '');",
      "SET FOREIGN_KEY_CHECKS=1;",
      "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1 AS `1`;",
      "CREATE ALGORITHM=MERGE SQL SECURITY INVOKER VIEW `w` AS select `t`.`id` AS `id`"
        + " from `t`;",
      "CREATE VIEW `x` AS select 1 AS `1`;",
    ]

  /// What `SQLDumpDDL.duckdb` and the writer emit, with the catalog's own table, index and
  /// view text (`duckdb_tables().sql`, `duckdb_indexes().sql`, `duckdb_views().sql`)
  private static let duckdbShapes: [String] =
    [
      "CREATE SCHEMA IF NOT EXISTS \"s2\";",
      "CREATE TYPE \"main\".\"mood\" AS ENUM ('sad', 'it''s');",
      "CREATE TYPE \"s2\".\"none\" AS ENUM ();",
      "CREATE SEQUENCE \"main\".\"seq1\" START WITH 9 INCREMENT BY 2 MINVALUE 1"
        + " MAXVALUE 9223372036854775807 NO CYCLE;",
      "CREATE SEQUENCE \"s2\".\"d\" START WITH -2 INCREMENT BY -1"
        + " MINVALUE -9223372036854775808 MAXVALUE -1 CYCLE;",
      "CREATE TABLE t1(id INTEGER DEFAULT(nextval('seq1')) PRIMARY KEY, m ENUM('sad', 'it''s'),"
        + " b BLOB DEFAULT('\\xAA'), g INTEGER GENERATED ALWAYS AS((id * 2)),"
        + " ts TIMESTAMP DEFAULT(current_timestamp), CHECK((length(CAST(id AS VARCHAR)) < 9)),"
        + " UNIQUE(m));",
      "CREATE TABLE s2.\"we\"\"ird\"(x INTEGER, FOREIGN KEY (x) REFERENCES s2.p(id));",
      "INSERT INTO \"main\".\"t1\" (\"id\", \"b\") VALUES\n('1', '\\xAB\\x00'),\n(NULL, ''),"
        + "\n('3', 'it''s a \\ path');",
      "INSERT INTO \"s2\".\"e\" DEFAULT VALUES;",
      "CREATE UNIQUE INDEX idx2 ON t1(((id + 1)), b);",
      "CREATE INDEX \"i x\" ON s2.\"we\"\"ird\"(x);",
      "CREATE VIEW v1 AS SELECT id FROM t1 WHERE (id > 1);",
      "CREATE VIEW s2.v2 (a) AS SELECT * FROM v1;",
      "CREATE VIEW v3 AS (SELECT 1) UNION (SELECT 2);",
      "CREATE VIEW v4 AS WITH c AS (SELECT id FROM t1)SELECT * FROM c;",
      "CREATE VIEW v5 AS SELECT log10(id), list_transform([1], x -> x + 1) FROM t1;",
      // Object names that look like refused functions are names, not calls
      "CREATE TABLE query_log(id INTEGER PRIMARY KEY);", "CREATE TABLE \"checkpoint\"(x INTEGER);",
      "CREATE TABLE s2.secrets(id INTEGER, q INTEGER REFERENCES query_log(id),"
        + " FOREIGN KEY (id) REFERENCES main.read_receipts(id));",
      "CREATE TABLE nextval(id INTEGER REFERENCES nextval(id));",
      "CREATE INDEX i ON duckdb_stats(x);", "CREATE UNIQUE INDEX glob ON s2.parquet_files(x);",
      "CREATE VIEW read_summary (a) AS SELECT 1;",
      "CREATE VIEW query_summary (query) AS SELECT * FROM query_log;",
    ]

  @Test(
    "DuckDB: statements a dump never writes are refused before anything is sent",
    arguments: [
      "DROP TABLE a;", "ATTACH '/tmp/other.duckdb' AS other;", "DETACH other;",
      "INSTALL httpfs;", "LOAD httpfs;", "COPY a TO '/tmp/out.csv';", "EXPORT DATABASE '/tmp/x';",
      "SET enable_external_access = true;", "PRAGMA enable_profiling;", "CALL pragma_version();",
      "CHECKPOINT;", "SELECT 1;", "BEGIN TRANSACTION;", "USE other;",
      "CREATE MACRO m(a) AS a + 1;", "CREATE SECRET s (TYPE s3, KEY_ID 'k');",
      "UPDATE a SET id = 1;", "DELETE FROM a;", "ALTER TABLE a ADD COLUMN c INTEGER;",
      // Tables: only the catalog's `CREATE TABLE <name>(...)`
      "CREATE TABLE x AS SELECT * FROM read_csv('/etc/hosts');", "CREATE TABLE x(a) AS SELECT 1;",
      "CREATE OR REPLACE TABLE a(id INTEGER);", "CREATE TEMP TABLE x(a INTEGER);",
      "CREATE TABLE IF NOT EXISTS x(a INTEGER);", "CREATE TABLE temp.x(a INTEGER);",
      "CREATE TABLE system.x(a INTEGER);", "CREATE TABLE temp.main.x(a INTEGER);",
      "CREATE TABLE x(a INTEGER) WITH (x = 1);",
      // Types and sequences: only the exact forms the writer builds
      "CREATE TYPE t AS STRUCT(a INTEGER);", "CREATE TYPE t AS ENUM (SELECT 'a');",
      "CREATE TYPE t AS ENUM ('a', getenv('HOME'));",
      "CREATE TYPE temp.t AS ENUM ('a');", "CREATE OR REPLACE TYPE t AS ENUM ('a');",
      "CREATE SEQUENCE s;",
      "CREATE SEQUENCE s START WITH 1 INCREMENT BY 1 MINVALUE 1"
        + " MAXVALUE 9 NO CYCLE OWNED BY a.id;",
      "CREATE SEQUENCE s START WITH (1) INCREMENT BY 1 MINVALUE 1 MAXVALUE 9 NO CYCLE;",
      "CREATE TEMP SEQUENCE s START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9 NO CYCLE;",
      "CREATE SCHEMA temp;", "CREATE SCHEMA IF NOT EXISTS system;",
      "CREATE SCHEMA IF NOT EXISTS a.b;",
      // Views: a read the classifier accepts as one
      "CREATE VIEW v AS SELECT getenv('HOME');",
      "CREATE VIEW v AS SELECT * FROM read_csv('https://example.com/x.csv');",
      "CREATE VIEW v AS SELECT * FROM query('SELECT 1');",
      "CREATE VIEW v AS SELECT nextval('seq1');", "CREATE OR REPLACE VIEW v AS SELECT 1;",
      // Functions that run SQL text, read files, settings or secrets, or write logs, whatever the
      // name's case, in a view, a table expression or an index key
      "CREATE VIEW v AS SELECT * FROM json_execute_serialized_sql(json_serialize_sql("
        + "'SELECT nextval(''main.victim'')'));",
      "CREATE VIEW v AS SELECT * FROM Query_Table('t');",
      "CREATE VIEW v AS SELECT * FROM pragma_table_info('t');",
      "CREATE VIEW v AS SELECT * FROM duckdb_settings();",
      "CREATE VIEW v AS SELECT * FROM \"truncate_duckdb_logs\"();",
      "CREATE VIEW v AS SELECT enable_logging();", "CREATE VIEW v AS SELECT disable_logging();",
      "CREATE VIEW v AS SELECT write_log('x');", "CREATE VIEW v AS SELECT create_secret('x');",
      "CREATE VIEW v AS SELECT * FROM read_parquet('/Users/me/picked.parquet');",
      "CREATE VIEW v AS SELECT * FROM glob('/Users/*');",
      "CREATE VIEW v AS SELECT * FROM sniff_csv('/etc/hosts');",
      "CREATE VIEW v AS SELECT * FROM parquet_metadata('/tmp/x.parquet');",
      "CREATE VIEW v AS SELECT * FROM arrow_scan(1, 2, 3);",
      "CREATE VIEW v AS SELECT * FROM sqlite_scan('/tmp/x.db', 't');",
      "CREATE TABLE x(a VARCHAR DEFAULT(read_text('/etc/hosts')));",
      "CREATE TABLE x(a VARCHAR, CHECK((a NOT IN (SELECT file FROM glob('/x')))));",
      "CREATE INDEX i ON a((length(postgres_query('db', 'SELECT 1'))));",
      "CREATE TABLE query_log(a VARCHAR DEFAULT(read_text('/etc/hosts')));",
      "CREATE TABLE x(a INTEGER REFERENCES p(id), CHECK((a <> length(read_text('/x')))));",
      "CREATE INDEX query_idx ON query_log((read_text('/x')));",
      "CREATE VIEW read_summary (a) AS SELECT * FROM a JOIN b ON read_text('/etc/passwd') IS NOT NULL;",
      "CREATE VIEW v AS SELECT * FROM main.query_table('t');",
      "CREATE VIEW v AS SELECT * FROM scan_arrow_ipc([]);",
      "CREATE VIEW v AS SELECT * FROM st_readosm('/tmp/x.pbf');",
      "CREATE VIEW v AS SELECT * FROM from_substrait('x'::BLOB);",
      "CREATE VIEW v AS SELECT setseed(0.5);", "CREATE VIEW v AS SELECT * FROM sqlsmith();",
      "CREATE VIEW v AS SELECT * FROM ducklake_snapshots('x');",
      "CREATE VIEW v AS SELECT md_user_info();",
      // nextval only as a column DEFAULT of a sequence created earlier in the file
      "CREATE TABLE x(a INTEGER DEFAULT(nextval('victim')));",
      "CREATE TABLE x(a INTEGER DEFAULT(nextval('main.victim')));",
      "CREATE INDEX i ON a((nextval('seq1')));",
      "CREATE TEMP VIEW v AS SELECT 1;", "CREATE VIEW temp.v AS SELECT 1;",
      "CREATE VIEW v;",
      // Indexes: name, table and key list only
      "CREATE INDEX i ON a(id) WHERE id > 0;", "CREATE INDEX i ON a USING ART (id);",
      "CREATE INDEX i ON temp.a(id);", "CREATE INDEX s.i ON a(id);",
      "CREATE INDEX i ON a(getenv('HOME'));",
      // Rows: quoted text and NULL only, into a qualified table outside the system catalogs
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES (1);",
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES ('1'::INTEGER);",
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES (CAST('1' AS INTEGER));",
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES (getenv('HOME'));",
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES (X'00');",
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES (DATE '2024-01-01');",
      "INSERT INTO \"main\".\"a\" (\"id\") SELECT 1;",
      "INSERT INTO \"main\".\"a\" (\"id\") VALUES ('1') RETURNING *;",
      "INSERT INTO a (id) VALUES ('1');", "INSERT INTO \"temp\".\"a\" (\"id\") VALUES ('1');",
      "INSERT INTO system.main.a (id) VALUES ('1');",
      "INSERT OR REPLACE INTO \"main\".\"a\" (\"id\") VALUES ('1');",
    ])
  func duckdbRefusedStatements(statement: String) {
    expectRefusedAtIndex1(.duckdb, statement)
  }

  @Test("DuckDB: nextval only as a column DEFAULT of a sequence the file created first")
  func duckdbNextvalNeedsTheFilesOwnSequence() throws {
    let sequence =
      "CREATE SEQUENCE \"s2\".\"own\" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9 NO CYCLE;"
    func script(_ statements: String...) -> String {
      ([Self.header(.duckdb)] + statements).joined(separator: "\n") + "\n"
    }
    // A one-part name is the table's schema's sequence; the catalog writes DEFAULT(...)
    for table in [
      "CREATE TABLE s2.t(id INTEGER DEFAULT(nextval('own')));",
      "CREATE TABLE t(id INTEGER DEFAULT nextval('s2.own'), n INTEGER DEFAULT(nextval('s2.own')));",
      "CREATE TABLE t(id INTEGER DEFAULT(nextval('\"S2\".\"OWN\"')));",
    ] {
      #expect(try Self.plan(script(sequence, table), .duckdb).kinds == [.schema, .schema])
    }
    for table in [
      // A one-part name in `main` could reach a `main.own` already in the database
      "CREATE TABLE t(id INTEGER DEFAULT(nextval('own')));",
      "CREATE TABLE s2.t(id INTEGER DEFAULT(nextval('s2.other')));",
      "CREATE TABLE s2.t(id INTEGER DEFAULT(nextval('memory.s2.own')));",
      "CREATE TABLE s2.t(id INTEGER DEFAULT(nextval('own' || '')));",
      "CREATE TABLE s2.t(id INTEGER DEFAULT(nextval('own') + 1));",
      "CREATE TABLE s2.t(id VARCHAR DEFAULT(CAST(nextval('own') AS VARCHAR)));",
      "CREATE TABLE s2.t(id INTEGER, CHECK((nextval('own') > 0)));",
      "CREATE TABLE s2.t(id INTEGER GENERATED ALWAYS AS(nextval('own')));",
    ] {
      guard
        case .statementRefused(let index, _)? = Self.planError(
          script(sequence, table), .duckdb)
      else {
        Issue.record("Expected \(table) to be refused")
        continue
      }
      #expect(index == 1)
    }
    // The sequence must come first
    guard
      case .statementRefused(let index, _)? = Self.planError(
        script("CREATE TABLE s2.t(id INTEGER DEFAULT(nextval('own')));", sequence), .duckdb)
    else {
      Issue.record("Expected a table before its sequence to be refused")
      return
    }
    #expect(index == 0)
  }

  @Test("A DuckDB script with a NUL character is refused (DuckDB would cut the text there)")
  func duckdbNULRefused() {
    #expect(
      Self.planError(
        Self.header(.duckdb) + "\nINSERT INTO \"main\".\"a\" (\"x\") VALUES ('x\u{0}');",
        .duckdb) == .containsNUL)
  }

  private static let sqliteShapes: [String] =
    [
      "PRAGMA defer_foreign_keys = ON;",
      "CREATE TABLE \"a\" (id INTEGER PRIMARY KEY AUTOINCREMENT);",
      "CREATE VIRTUAL TABLE docs USING fts5(body);",
      "CREATE VIRTUAL TABLE r USING rtree(id, minx, maxx);",
      "CREATE VIRTUAL TABLE m USING mod;",
      "CREATE TABLE s(a INTEGER PRIMARY KEY, b TEXT) WITHOUT ROWID, STRICT;",
      "CREATE TABLE [b] (x DEFAULT (abs(-1)) CHECK (x > 0));",
      "INSERT INTO \"a\" (\"id\") VALUES\n(1);",
      "INSERT INTO \"a\" (\"id\", \"r\", \"b\", \"t\") VALUES\n(-2, 1.5, X'0102', 'it''s'),"
        + "\n(NULL, 9.0e+999, X'', ''),\n(3, -9.0e+999, NULL, 'x'),\n(4, 1.0e-05, NULL, NULL);",
      "DELETE FROM sqlite_sequence WHERE name = 'a';",
      "INSERT INTO sqlite_sequence (name, seq) VALUES ('a', 1);",
      "CREATE INDEX i ON a (id);",
      "CREATE UNIQUE INDEX u ON a (id);",
      "CREATE VIEW v AS SELECT id FROM a;",
      "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  INSERT INTO a VALUES (2);\nEND;",
    ]

  @Test(
    "Every statement shape a dump writes is accepted",
    arguments: [
      (DatabaseType.postgresql, postgresShapes), (.mysql, mysqlShapes),
      (.sqlite, sqliteShapes), (.duckdb, duckdbShapes),
    ])
  func acceptedDumpShapes(engine: DatabaseType, statements: [String]) throws {
    let script = ([Self.header(engine)] + statements).joined(separator: "\n") + "\n"
    let plan = try Self.plan(script, engine)
    #expect(plan.summary.statementCount == statements.count)
  }

  @Test(
    "A plain backslash string is read standard-conforming only in the dump's schema statements",
    arguments: [
      "INSERT INTO a (id) VALUES ('a\\b');",
      "SELECT pg_catalog.setval('a\\b', 2, true);",
      "CREATE TABLE x (a text DEFAULT 'a\\b') INHERITS (y);",
      "CREATE FUNCTION f() RETURNS text AS 'a\\b' LANGUAGE sql;",
      "UPDATE a SET id = 'a\\b' WHERE id = '1';",
      "ALTER TABLE a ADD COLUMN c text DEFAULT 'a\\b';",
    ])
  func backslashStringsOutsideDumpSchemaRefused(statement: String) {
    expectRefusedAtIndex1(.postgresql, statement)
  }

  @Test("The plan records its first statement that needs standard_conforming_strings on")
  func standardStringsStatementRecorded() throws {
    #expect(try Self.plan(Self.postgresDump, .postgresql).standardStringsStatement == nil)
    let plan = try Self.plan(Self.backslashDump, .postgresql)
    #expect(plan.standardStringsStatement == 12)
    #expect(plan.kinds.last == .schema)
    #expect(plan.statements.last?.kind == .ddl)
    // The editor's classifier still fails closed on the same text
    let text = try #require(plan.statements.last?.text)
    #expect(SQLStatementClassifier.classifyStatement(text, dialect: .postgresql)?.kind == .unknown)
  }

  @Test("A SQLite script with a NUL character is refused (SQLite would cut the text there)")
  func sqliteNULRefused() {
    #expect(
      Self.planError(Self.header(.sqlite) + "\nINSERT INTO a VALUES ('x\u{0}');", .sqlite)
        == .containsNUL)
  }

  // MARK: - DROP (version 2)

  private static let postgresDropDump = [
    "CREATE SCHEMA IF NOT EXISTS \"app\";",
    "DROP VIEW IF EXISTS \"app\".\"v\";",
    // An unquoted name folds to lowercase, as PostgreSQL reads it
    "DROP TABLE IF EXISTS \"app\".\"items\", app.Tags;",
    "DROP SEQUENCE IF EXISTS \"app\".\"items_id_seq\";",
    "DROP DOMAIN IF EXISTS \"app\".\"pos\";",
    "DROP TYPE IF EXISTS \"app\".\"mood\";",
    "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok', 'sad');",
    "CREATE DOMAIN \"app\".\"pos\" AS integer;",
    "CREATE SEQUENCE \"app\".\"items_id_seq\" AS integer START WITH 1 INCREMENT BY 1;",
    "CREATE TABLE \"app\".\"items\" (\"id\" integer NOT NULL, \"m\" \"app\".\"mood\");",
    "CREATE TABLE \"app\".\"tags\" (\"id\" integer);",
    "INSERT INTO \"app\".\"items\" (\"id\", \"m\") VALUES\n('1', 'ok');",
    "CREATE VIEW \"app\".\"v\" AS SELECT 1;",
  ]

  @Test("Version 2: DROP IF EXISTS of a view, tables, a sequence, a domain and an enum it creates")
  func postgresDropsAccepted() throws {
    let plan = try Self.plan(Self.script(.postgresql, Self.postgresDropDump), .postgresql)
    #expect(plan.kinds.firstIndex(of: .drop) == 1)
    #expect(plan.summary.count(.drop) == 5)
    #expect(plan.summary.count(.schema) == 7)
    #expect(plan.summary.count(.data) == 1)
    #expect(plan.summary.changesSchema)
    #expect(plan.droppedSQLiteTables.isEmpty)
    // Safe Mode lists each DROP as its own row
    let rows = DatabaseBackupModel.restoreConfirmation(plan)
    #expect(rows.filter { $0.kindLabel == "Drop" }.map(\.index) == [1, 2, 3, 4, 5])
    #expect(rows.count == 12)
  }

  @Test(
    "Version 2: DROP IF EXISTS of objects the dump creates, names compared as the engine does",
    arguments: [
      (
        DatabaseType.mysql,
        [
          "SET FOREIGN_KEY_CHECKS=0;", "DROP VIEW IF EXISTS `v`;", "DROP TABLE IF EXISTS `t`;",
          "CREATE TABLE `t` (`id` int) ENGINE=InnoDB"
            + " /*!50100 PARTITION BY HASH (`id`) PARTITIONS 2 */;",
          "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1 AS `x`;",
        ], 2
      ),
      (
        .sqlite,
        [
          "PRAGMA defer_foreign_keys = ON;", "DROP VIEW IF EXISTS \"V\";",
          "DROP TABLE IF EXISTS \"Parent\";", "DROP TABLE IF EXISTS [fts];",
          "CREATE TABLE parent (id INTEGER PRIMARY KEY);",
          "CREATE VIRTUAL TABLE fts USING fts5(body);", "CREATE VIEW v AS SELECT 1;",
        ], 3
      ),
      (
        .duckdb,
        [
          "CREATE SCHEMA IF NOT EXISTS \"s\";", "DROP VIEW IF EXISTS \"main\".\"v1\";",
          "DROP TABLE IF EXISTS \"s\".\"A\";", "DROP SEQUENCE IF EXISTS \"s\".\"seq\";",
          "DROP TYPE IF EXISTS \"s\".\"mood\";", "CREATE TYPE \"s\".\"mood\" AS ENUM ('ok');",
          "CREATE SEQUENCE \"s\".\"seq\" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9"
            + " NO CYCLE;",
          "CREATE TABLE s.a(id INTEGER DEFAULT(nextval('s.seq')));",
          // The catalog leaves `main` out
          "CREATE VIEW v1 AS SELECT 1;",
        ], 4
      ),
    ])
  func dropsAccepted(engine: DatabaseType, statements: [String], drops: Int) throws {
    let plan = try Self.plan(Self.script(engine, statements), engine)
    #expect(plan.summary.count(.drop) == drops)
    #expect(
      plan.droppedSQLiteTables
        == (engine == .sqlite ? [Array("parent".utf8), Array("fts".utf8)] : []))
  }

  @Test(
    "Version 2: a DROP of an object not created after it, or in another form, is refused",
    arguments: [
      // Never created, created only before the DROP, created as another kind
      (
        DatabaseType.postgresql,
        ["DROP TABLE IF EXISTS \"app\".\"other\";", "CREATE TABLE \"app\".\"items\" (id int);"], 0
      ),
      (
        .postgresql,
        ["CREATE TABLE \"app\".\"items\" (id int);", "DROP TABLE IF EXISTS \"app\".\"items\";"], 1
      ),
      (
        .postgresql,
        ["DROP TABLE IF EXISTS \"app\".\"v\";", "CREATE VIEW \"app\".\"v\" AS SELECT 1;"], 0
      ),
      (
        .postgresql,
        ["DROP TYPE IF EXISTS \"app\".\"pos\";", "CREATE DOMAIN \"app\".\"pos\" AS integer;"], 0
      ),
      // A multi-table DROP with one name the dump never creates
      (
        .postgresql,
        [
          "DROP TABLE IF EXISTS \"app\".\"items\", \"app\".\"other\";",
          "CREATE TABLE \"app\".\"items\" (id int);",
        ], 0
      ),
      // A quoted name is exact; unqualified and system names are never dropped
      (
        .postgresql,
        ["DROP TABLE IF EXISTS \"app\".\"Items\";", "CREATE TABLE \"app\".\"items\" (id int);"], 0
      ),
      (.postgresql, ["DROP TABLE IF EXISTS items;", "CREATE TABLE items (id int);"], 0),
      (
        .postgresql,
        ["DROP TABLE IF EXISTS pg_temp.items;", "CREATE TABLE \"app\".\"items\" (id int);"], 0
      ),
      // CASCADE, RESTRICT, no IF EXISTS, other kinds, a list on another kind
      (
        .postgresql,
        [
          "DROP TABLE IF EXISTS \"app\".\"items\" CASCADE;",
          "CREATE TABLE \"app\".\"items\" (id int);",
        ], 0
      ),
      (
        .postgresql,
        [
          "DROP TABLE IF EXISTS \"app\".\"items\" RESTRICT;",
          "CREATE TABLE \"app\".\"items\" (id int);",
        ], 0
      ),
      (
        .postgresql, ["DROP TABLE \"app\".\"items\";", "CREATE TABLE \"app\".\"items\" (id int);"],
        0
      ),
      (.postgresql, ["DROP SCHEMA IF EXISTS \"app\";", "CREATE SCHEMA IF NOT EXISTS \"app\";"], 0),
      (
        .postgresql,
        [
          "DROP MATERIALIZED VIEW IF EXISTS \"app\".\"v\";",
          "CREATE VIEW \"app\".\"v\" AS SELECT 1;",
        ], 0
      ),
      (
        .postgresql, ["DROP INDEX IF EXISTS \"app\".\"i\";", "CREATE INDEX i ON app.items (id);"], 0
      ),
      (
        .postgresql,
        [
          "DROP VIEW IF EXISTS \"app\".\"v\", \"app\".\"w\";",
          "CREATE VIEW \"app\".\"v\" AS SELECT 1;", "CREATE VIEW \"app\".\"w\" AS SELECT 1;",
        ], 0
      ),
      // MySQL: backquoted names, exact; one per statement; no TEMPORARY
      (.mysql, ["DROP TABLE IF EXISTS `T`;", "CREATE TABLE `t` (id int);"], 0),
      (.mysql, ["DROP TABLE IF EXISTS t;", "CREATE TABLE t (id int);"], 0),
      (.mysql, ["DROP TEMPORARY TABLE IF EXISTS `t`;", "CREATE TABLE `t` (id int);"], 0),
      (
        .mysql,
        [
          "DROP TABLE IF EXISTS `t`, `u`;", "CREATE TABLE `t` (id int);",
          "CREATE TABLE `u` (id int);",
        ], 0
      ),
      (.mysql, ["DROP TABLE IF EXISTS `t` CASCADE;", "CREATE TABLE `t` (id int);"], 0),
      // SQLite: one-part names, tables and views only
      (.sqlite, ["DROP TABLE IF EXISTS main.t;", "CREATE TABLE t (id);"], 0),
      (.sqlite, ["DROP TABLE IF EXISTS temp.t;", "CREATE TABLE t (id);"], 0),
      (
        .sqlite, ["DROP INDEX IF EXISTS i;", "CREATE TABLE t (id);", "CREATE INDEX i ON t (id);"], 0
      ),
      (.sqlite, ["DROP TRIGGER IF EXISTS tr;", "CREATE TABLE t (id);"], 0),
      (.sqlite, ["DROP TABLE t;", "CREATE TABLE t (id);"], 0),
      // DuckDB: qualified names, never a system schema
      (.duckdb, ["DROP TABLE IF EXISTS t;", "CREATE TABLE t(id INTEGER);"], 0),
      (.duckdb, ["DROP TABLE IF EXISTS \"temp\".\"t\";", "CREATE TABLE t(id INTEGER);"], 0),
      (
        .duckdb, ["DROP TABLE IF EXISTS \"main\".\"t\" CASCADE;", "CREATE TABLE t(id INTEGER);"], 0
      ),
      (.duckdb, ["DROP TABLE IF EXISTS \"s\".\"t\";", "CREATE TABLE t(id INTEGER);"], 0),
    ])
  func dropsRefused(engine: DatabaseType, statements: [String], index: Int) {
    guard
      case .statementRefused(let refused, _)? = Self.planError(
        Self.script(engine, statements), engine)
    else {
      Issue.record("Expected \(statements) to be refused")
      return
    }
    #expect(refused == index, "\(statements)")
  }

  @Test(
    "A DROP in a version 1 dump is refused as before",
    arguments: DatabaseType.allCases.filter { $0 != .mongodb })
  func dropInVersion1Refused(engine: DatabaseType) {
    let create =
      switch engine {
      case .mysql: "CREATE TABLE `t` (id int);"
      case .sqlite: "CREATE TABLE t (id);"
      case .duckdb: "CREATE TABLE t(id INTEGER);"
      default: "CREATE TABLE \"public\".\"t\" (id int);"
      }
    let drop =
      switch engine {
      case .mysql: "DROP TABLE IF EXISTS `t`;"
      case .sqlite: "DROP TABLE IF EXISTS \"t\";"
      case .duckdb: "DROP TABLE IF EXISTS \"main\".\"t\";"
      default: "DROP TABLE IF EXISTS \"public\".\"t\";"
      }
    #expect(
      Self.planError(Self.script(engine, version: 1, [drop, create]), engine)
        == .statementRefused(
          index: 0, reason: "a Dblore dump never writes this DROP TABLE statement"))
    #expect(throws: Never.self) { try Self.plan(Self.script(engine, [drop, create]), engine) }
  }

  @Test(
    "A SQLite dump written with Drop plans: each DROP names a table or view it creates after it")
  func sqliteWriterDropDumpPlans() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-restore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.sqlite")
    let handle = try SQLiteHandle(url: source)
    for sql in [
      "CREATE TABLE \"Parent\" (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
      "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES Parent (id))",
      "CREATE VIRTUAL TABLE notes_fts USING fts5(body)",
      "CREATE VIEW v_child AS SELECT * FROM child",
      "INSERT INTO \"Parent\" (name) VALUES ('a')", "INSERT INTO child VALUES (1, 1)",
    ] {
      try handle.execute(sql)
    }
    let destination = directory.appendingPathComponent("dump.sql")
    let writer = SQLDumpWriter(
      config: ConnectionConfig(databaseType: .sqlite, database: source.path, username: ""),
      material: nil, sshCredential: nil,
      sessionFactory: SQLDumpSessionFactory(inner: AppDatabaseSessionFactory()),
      temporaryDirectory: directory)
    _ = try await writer.write(
      to: destination,
      options: SQLDumpOptions(otherTables: SQLDumpOptions.TableOptions(drop: true)))
    let text = try String(contentsOf: destination, encoding: .utf8)
    #expect(text.hasPrefix(SQLRestorePlan.dropHeaderPrefix + "SQLite "))
    let plan = try Self.plan(text, .sqlite)
    let dropLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("DROP ") }
    // The view and the two tables; the virtual table is kept and created only when missing
    #expect(dropLines.count == 3)
    #expect(plan.summary.count(.drop) == 3)
    #expect(plan.droppedSQLiteTables == [Array("parent".utf8), Array("child".utf8)])
    #expect(text.contains("\nCREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(body);\n"))
  }

  // MARK: - Gate before anything is sent

  private static func config(
    _ type: DatabaseType, level: ConnectionProtectionLevel = .none, protectedMode: Bool = false
  ) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: type, host: "fake", port: type == .mysql ? 3306 : 5432, database: "db",
      username: "u", sslMode: .disable, protectionLevel: level, safeMode: .silent,
      protectedMode: protectedMode)
  }

  /// The answer to `restoreSessionQuery`: sql_mode, time_zone, unique_checks, sql_notes and
  /// the server version
  private static func mysqlSettingsRow(
    mode: String = "STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION", uniqueChecks: Int = 1,
    sqlNotes: Int = 1, version: String = "8.4.11"
  ) -> [CellValue] {
    [.string(mode), .string("+00:00"), .int(uniqueChecks), .int(sqlNotes), .string(version)]
  }

  /// What a MySQL restore sends after its statements, on every path
  private static func mysqlReset(
    mode: String = "STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION", uniqueChecks: Int = 1,
    sqlNotes: Int = 1, noteVerbosity: String? = nil
  ) -> [String] {
    [
      "UNLOCK TABLES", "SET NAMES utf8mb4", "SET FOREIGN_KEY_CHECKS=1",
      "SET SESSION unique_checks = \(uniqueChecks), sql_notes = \(sqlNotes)",
      "SET SESSION sql_mode = '\(mode)', time_zone = '+00:00'",
    ] + (noteVerbosity.map { ["SET SESSION note_verbosity = '\($0)'"] } ?? []) + [
      "SET @OLD_CHARACTER_SET_CLIENT = NULL, @OLD_CHARACTER_SET_RESULTS = NULL, "
        + "@OLD_COLLATION_CONNECTION = NULL, @OLD_TIME_ZONE = NULL, @OLD_UNIQUE_CHECKS = NULL, "
        + "@OLD_FOREIGN_KEY_CHECKS = NULL, @OLD_SQL_MODE = NULL, @OLD_SQL_NOTES = NULL, "
        + "@OLD_NOTE_VERBOSITY = NULL, @saved_cs_client = NULL"
    ]
  }

  private func connect(
    _ type: DatabaseType, level: ConnectionProtectionLevel = .none, protectedMode: Bool = false,
    rows: [[CellValue]] = [mysqlSettingsRow()], slowQueries: Bool = false,
    failingQuery: String? = nil
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: type.capabilities, rows: rows, slowQueries: slowQueries,
      failingQuery: failingQuery)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: Self.config(type, level: level, protectedMode: protectedMode))
    return (manager, factory)
  }

  private func restoreError(
    _ manager: DatabaseConnectionManager, _ script: String, policy: ProtectionPolicy? = nil,
    epoch: UInt64? = nil, caller: UUID? = nil,
    progress: @escaping @Sendable (SQLRestoreProgress) -> Void = { _ in }
  ) async -> Error? {
    let current = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedRestore(
        script: script, policy: policy ?? open, connectionEpoch: epoch ?? current, caller: caller,
        progress: progress)
      return nil
    } catch {
      return error
    }
  }

  @Test("A read-only connection refuses any restore, even a sequence-values-only file")
  func readOnlyRefuses() async throws {
    let (manager, factory) = try await connect(.postgresql, level: .readOnly)
    let script =
      Self.header(.postgresql) + "\nSELECT pg_catalog.setval('\"public\".\"s\"', 5, true);\n"
    #expect(try Self.plan(script, .postgresql).kinds == [.sequenceValue])
    guard case .blockedByProtection? = await restoreError(manager, script) as? DatabaseError
    else {
      Issue.record("Expected a read-only refusal")
      return
    }
    let (caller, callerFactory) = try await connect(.postgresql)
    let error = await restoreError(
      caller, script, policy: ProtectionPolicy(protectionLevel: .readOnly))
    guard case .blockedByProtection? = error as? DatabaseError else {
      Issue.record(
        "Expected a read-only refusal from the caller's policy, got \(String(describing: error))")
      return
    }
    #expect(factory.statements.isEmpty)
    #expect(callerFactory.statements.isEmpty)
  }

  @Test("A schema-only connection refuses DDL in a restore")
  func schemaOnlyRefusesDDL() async throws {
    let (manager, factory) = try await connect(.postgresql, level: .schemaOnly)
    let error = await restoreError(manager, Self.postgresDump)
    guard case .blockedByProtection(let index, let kind, _)? = error as? DatabaseError else {
      Issue.record("Expected blockedByProtection, got \(String(describing: error))")
      return
    }
    #expect(index == 0)
    #expect(kind == .ddl)
    #expect(factory.statements.isEmpty)
  }

  @Test("A schema-only SQLite connection refuses the dump's PRAGMA")
  func schemaOnlyRefusesSQLitePragma() async throws {
    let (manager, factory) = try await connect(.sqlite, level: .schemaOnly)
    let script =
      Self.header(.sqlite) + "\nPRAGMA defer_foreign_keys = ON;\nINSERT INTO a VALUES (1);\n"
    guard
      case .blockedByProtection(0, .ddl, _)? = await restoreError(manager, script)
        as? DatabaseError
    else {
      Issue.record("Expected the PRAGMA to be blocked")
      return
    }
    #expect(factory.statements.isEmpty)
  }

  @Test("A stale epoch, another engine's plan and another tab's transaction send nothing")
  func refusedBeforeSending() async throws {
    let (manager, factory) = try await connect(.postgresql, protectedMode: true)
    let epoch = await manager.connectionEpoch
    guard
      case .connectionChanged? = await restoreError(manager, Self.postgresDump, epoch: epoch &+ 1)
        as? SQLRestoreError
    else {
      Issue.record("Expected a stale epoch refusal")
      return
    }
    let sqlitePlan = try Self.plan(Self.sqliteDump(), .sqlite)
    await #expect(throws: SQLRestoreError.engineMismatch(dump: "SQLite", connection: "PostgreSQL"))
    {
      try await manager.executeGatedRestore(sqlitePlan, policy: open, connectionEpoch: epoch)
    }
    #expect(factory.statements.isEmpty)

    _ = try await manager.execute(
      userSQL: "UPDATE t SET v = 1 WHERE id = 1", policy: open, caller: UUID())
    let sent = factory.statements.count
    guard
      case .transactionPendingInAnotherTab? = await restoreError(
        manager, Self.postgresDump, caller: UUID()) as? DatabaseError
    else {
      Issue.record("Expected another tab's transaction to be refused")
      return
    }
    #expect(factory.statements.count == sent)
  }

  // MARK: - PostgreSQL and SQLite: one batch

  @Test("PostgreSQL without Protected mode: one BEGIN ... COMMIT, progress per statement")
  func postgresBatch() async throws {
    let (manager, factory) = try await connect(.postgresql)
    let plan = try Self.plan(Self.postgresDump, .postgresql)
    let log = ProgressLog()
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch,
      progress: { log.append($0) })
    let sent = factory.sessions.last?.statements ?? []
    #expect(sent.first == "BEGIN")
    #expect(sent.last == "COMMIT")
    let pin = DatabaseConnectionManager.SearchPathPin.self
    #expect(Array(sent.dropFirst().prefix(2)) == [pin.readSQL, pin.pinSQL])
    #expect(Array(sent.dropFirst(3).dropLast(2)) == plan.statements.map(\.text))
    #expect(sent.dropLast().last == pin.putBackSQL)
    #expect(summary.statementsRun == 12)
    #expect(!summary.pending)
    #expect(summary.counts == plan.summary.counts)
    #expect(log.values.map(\.statementsDone) == Array(1...12))
    #expect(log.values.allSatisfy { $0.statementCount == 12 })
    #expect(await manager.transactionSnapshot() == .idle)
  }

  @Test("PostgreSQL under Protected mode joins the app transaction (pending)")
  func postgresProtected() async throws {
    let (manager, _) = try await connect(.postgresql, protectedMode: true)
    let caller = UUID()
    let summary = try await manager.executeGatedRestore(
      script: Self.postgresDump, policy: open, connectionEpoch: await manager.connectionEpoch,
      caller: caller)
    #expect(summary.pending)
    #expect(await manager.transactionStatus().owner == caller)
    #expect(await manager.transactionSnapshot().pending.count == 12)
  }

  @Test("A restored table whose DDL holds a backslash string refreshes the sidebar")
  func backslashSchemaRefreshesTheSidebar() async throws {
    let (manager, _) = try await connect(.postgresql, rows: [[.string("on")]])
    // The only schema statement: unknown to the default classifier, DDL to the plan
    let script =
      Self.header(.postgresql)
      + "\nCREATE TABLE \"public\".\"pat\" (\"note\" text DEFAULT 'a\\b'::text);\n"
    let plan = try Self.plan(script, .postgresql)
    #expect(plan.statements.map(\.kind) == [.ddl])
    _ = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch)
    #expect(await manager.takeSchemaRefresh())
  }

  @Test("A COMMIT that fails without Protected mode is rolled back")
  func failedCommitRollsBack() async throws {
    let (manager, factory) = try await connect(.postgresql)
    factory.sessions.last?.failNextCommand(containing: "COMMIT")
    #expect(await restoreError(manager, Self.postgresDump) != nil)
    #expect(factory.sessions.last?.statements.suffix(2) == ["COMMIT", "ROLLBACK"])
  }

  @Test("A failed Protected-mode COMMIT is rolled back on the server too")
  func failedAppCommitRollsBack() async throws {
    let (manager, factory) = try await connect(.postgresql, protectedMode: true)
    _ = try await manager.executeGatedRestore(
      script: Self.postgresDump, policy: open, connectionEpoch: await manager.connectionEpoch)
    factory.sessions.last?.failNextCommand(containing: "COMMIT")
    let generation = await manager.transactionStatus().generation
    await #expect(throws: DatabaseError.self) {
      try await manager.commitAppTransaction(expectedGeneration: generation)
    }
    #expect(factory.sessions.last?.statements.suffix(2) == ["COMMIT", "ROLLBACK"])
    #expect(await manager.transactionSnapshot() == .idle)
  }

  /// `postgresDump` plus a column DEFAULT with a backslash in a plain string (statement 12)
  private static let backslashDump =
    postgresDump + "CREATE TABLE \"public\".\"pat\" (\"note\" text DEFAULT 'a\\b'::text);\n"

  @Test(
    "PostgreSQL: backslash strings run after the session reports standard_conforming_strings on")
  func standardStringsOn() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("on")]])
    let plan = try Self.plan(Self.backslashDump, .postgresql)
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch)
    #expect(summary.statementsRun == 13)
    let sent = factory.statements
    #expect(sent.first == DatabaseConnectionManager.standardStringsQuery)
    #expect(sent.dropFirst().first == "BEGIN")
    let pin = DatabaseConnectionManager.SearchPathPin.self
    #expect(Array(sent.dropFirst(2).prefix(2)) == [pin.readSQL, pin.pinSQL])
    #expect(Array(sent.dropFirst(4).dropLast(2)) == plan.statements.map(\.text))
    #expect(Array(sent.suffix(2)) == [pin.putBackSQL, "COMMIT"])
  }

  @Test("PostgreSQL: standard_conforming_strings off refuses before anything is changed")
  func standardStringsOff() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("off")]])
    let error = await restoreError(manager, Self.backslashDump)
    #expect(error as? SQLRestoreError == .standardStringsOff(index: 12, value: "off"))
    #expect(factory.statements == [DatabaseConnectionManager.standardStringsQuery])
  }

  @Test(
    "PostgreSQL: an unreadable standard_conforming_strings refuses before anything is changed",
    arguments: [[], [[CellValue.null]], [[CellValue.string("on"), .string("x")]]])
  func standardStringsUnreadable(rows: [[CellValue]]) async throws {
    let (manager, factory) = try await connect(.postgresql, rows: rows)
    let error = await restoreError(manager, Self.backslashDump)
    guard case .standardStringsUnreadable? = error as? SQLRestoreError else {
      Issue.record("Expected standardStringsUnreadable, got \(String(describing: error))")
      return
    }
    #expect(factory.statements == [DatabaseConnectionManager.standardStringsQuery])
  }

  /// The next query on `session` (the restore's first read) answers only after Cancel ran
  private static func cancelDuringNextQuery(
    _ manager: DatabaseConnectionManager, _ session: FakeDatabaseSession
  ) {
    session.onNextQuery { _ in
      let status = await manager.runningStatementStatus()
      let outcome = await manager.cancelRunningStatement(
        expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
        expectedEpoch: status.epoch)
      #expect(outcome == .cancelled)
    }
  }

  @Test("PostgreSQL: Cancel during the standard_conforming_strings read sends no BEGIN or dump")
  func standardStringsReadCancelled() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("on")]])
    let session = try #require(factory.sessions.last)
    Self.cancelDuringNextQuery(manager, session)
    let error = await restoreError(manager, Self.backslashDump)
    guard case .batchCancelled? = error as? DatabaseError else {
      Issue.record("Expected batchCancelled, got \(String(describing: error))")
      return
    }
    #expect(session.statements == [DatabaseConnectionManager.standardStringsQuery])
    // Cancel kept the session (cancelled from a side connection): nothing else reached it
    #expect(factory.sessions.count == 1)
    #expect(await manager.transactionSnapshot() == .idle)
  }

  @Test("PostgreSQL: Cancel, then the standard_conforming_strings read fails: cancelled, no BEGIN")
  func standardStringsReadFailsAfterCancel() async throws {
    let (manager, factory) = try await connect(
      .postgresql, rows: [[.string("on")]],
      failingQuery: DatabaseConnectionManager.standardStringsQuery)
    let session = try #require(factory.sessions.last)
    Self.cancelDuringNextQuery(manager, session)
    let error = await restoreError(manager, Self.backslashDump)
    guard case .batchCancelled? = error as? DatabaseError else {
      Issue.record("Expected batchCancelled, got \(String(describing: error))")
      return
    }
    #expect(session.statements == [DatabaseConnectionManager.standardStringsQuery])
    #expect(factory.sessions.count == 1)
    #expect(await manager.transactionSnapshot() == .idle)
  }

  @Test("PostgreSQL: a reconnect during the standard_conforming_strings read refuses the restore")
  func reconnectDuringStandardStringsRead() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("on")]])
    let session = try #require(factory.sessions.last)
    let config = Self.config(.postgresql)
    session.onNextQuery { _ in
      do {
        try await manager.connect(config: config)
      } catch {
        Issue.record("The reconnect during the SHOW failed: \(error)")
      }
    }
    let error = await restoreError(manager, Self.backslashDump)
    guard case .connectionChanged? = error as? SQLRestoreError else {
      Issue.record("Expected connectionChanged, got \(String(describing: error))")
      return
    }
    #expect(session.statements == [DatabaseConnectionManager.standardStringsQuery])
    #expect(factory.sessions.count == 2)
    #expect(factory.sessions.last?.statements == [])
    #expect(await manager.transactionSnapshot() == .idle)
  }

  /// `protectedConnection`: the connection's Protected mode. Another tab's app transaction
  /// refuses the restore; see `ownAppTransactionOpenedDuringStandardStringsRead` for the same tab.
  @Test(
    "PostgreSQL: another tab's app transaction opened during the SHOW refuses the restore",
    arguments: [true, false])
  func appTransactionOpenedDuringStandardStringsRead(protectedConnection: Bool) async throws {
    let (manager, factory) = try await connect(
      .postgresql, protectedMode: protectedConnection, rows: [[.string("on")]])
    let session = try #require(factory.sessions.last)
    let caller = UUID()
    let intruder = UUID()
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    session.onNextQuery { _ in
      do {
        _ = try await manager.execute(
          userSQL: "UPDATE t SET v = 1 WHERE id = 1", policy: protected, caller: intruder)
      } catch {
        Issue.record("The edit during the SHOW failed: \(error)")
      }
    }
    let plan = try Self.plan(Self.backslashDump, .postgresql)
    let error = await restoreError(manager, Self.backslashDump, caller: caller)
    guard case .transactionPendingInAnotherTab? = error as? DatabaseError else {
      Issue.record("Expected a refusal, got \(String(describing: error))")
      return
    }
    let sent = session.statements
    #expect(sent.first == DatabaseConnectionManager.standardStringsQuery)
    #expect(sent.filter { $0 == "BEGIN" }.count == 1)
    #expect(!sent.contains { $0.contains(DatabaseConnectionManager.batchSavepoint) })
    #expect(!sent.contains("COMMIT"))
    #expect(!sent.contains { plan.statements.map(\.text).contains($0) })
    #expect(await manager.transactionStatus().owner == intruder)
    #expect(await manager.transactionSnapshot().pending.count == 1)
  }

  @Test("PostgreSQL: the same tab's app transaction opened during the SHOW is joined (pending)")
  func ownAppTransactionOpenedDuringStandardStringsRead() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("on")]])
    let session = try #require(factory.sessions.last)
    let caller = UUID()
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
    session.onNextQuery { _ in
      do {
        _ = try await manager.execute(
          userSQL: "UPDATE t SET v = 1 WHERE id = 1", policy: protected, caller: caller)
      } catch {
        Issue.record("The edit during the SHOW failed: \(error)")
      }
    }
    let plan = try Self.plan(Self.backslashDump, .postgresql)
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch, caller: caller)
    // The restore saw the transaction it runs in: pending, not committed, not the user's
    #expect(summary.pending)
    #expect(!summary.insideUserTransaction)
    #expect(summary.statementsRun == plan.statements.count)
    let savepoint = DatabaseConnectionManager.batchSavepoint
    let sent = session.statements
    #expect(sent.first == DatabaseConnectionManager.standardStringsQuery)
    let pin = DatabaseConnectionManager.SearchPathPin.self
    #expect(
      Array(sent.suffix(plan.statements.count + 5))
        == ["SAVEPOINT \(savepoint)", pin.readSQL, pin.pinSQL] + plan.statements.map(\.text)
        + [pin.putBackSQL, "RELEASE SAVEPOINT \(savepoint)"])
    #expect(sent.filter { $0 == "BEGIN" }.count == 1)
    #expect(!sent.contains("COMMIT"))
    #expect(await manager.transactionStatus().owner == caller)
    #expect(await manager.transactionSnapshot().pending.count == 1 + plan.statements.count)
  }

  @Test(
    "PostgreSQL: a BEGIN from another tab during the SHOW is reported as the user's transaction")
  func userTransactionOpenedDuringStandardStringsRead() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("on")]])
    let session = try #require(factory.sessions.last)
    let policy = open
    session.onNextQuery { _ in
      do {
        _ = try await manager.execute(userSQL: "BEGIN", policy: policy, caller: UUID())
      } catch {
        Issue.record("The BEGIN during the SHOW failed: \(error)")
      }
    }
    let plan = try Self.plan(Self.backslashDump, .postgresql)
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch, caller: UUID())
    #expect(summary.insideUserTransaction)
    #expect(!summary.pending)
    let savepoint = DatabaseConnectionManager.batchSavepoint
    let pin = DatabaseConnectionManager.SearchPathPin.self
    #expect(
      session.statements
        == [DatabaseConnectionManager.standardStringsQuery, "BEGIN", "SAVEPOINT \(savepoint)"]
        + [pin.readSQL, pin.pinSQL] + plan.statements.map(\.text)
        + [pin.putBackSQL, "RELEASE SAVEPOINT \(savepoint)"])
    #expect(await manager.userTxOpen)
  }

  @Test("PostgreSQL: a COMMIT from another tab during the SHOW is reported as no user transaction")
  func userTransactionEndedDuringStandardStringsRead() async throws {
    let (manager, factory) = try await connect(.postgresql, rows: [[.string("on")]])
    let session = try #require(factory.sessions.last)
    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let policy = open
    session.onNextQuery { _ in
      do {
        _ = try await manager.execute(userSQL: "COMMIT", policy: policy, caller: UUID())
      } catch {
        Issue.record("The COMMIT during the SHOW failed: \(error)")
      }
    }
    let plan = try Self.plan(Self.backslashDump, .postgresql)
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch, caller: UUID())
    #expect(!summary.insideUserTransaction)
    #expect(!summary.pending)
    let pin = DatabaseConnectionManager.SearchPathPin.self
    #expect(
      session.statements
        == ["BEGIN", DatabaseConnectionManager.standardStringsQuery, "COMMIT", "BEGIN"]
        + [pin.readSQL, pin.pinSQL] + plan.statements.map(\.text) + [pin.putBackSQL, "COMMIT"])
    #expect(await manager.transactionSnapshot() == .idle)
  }

  // MARK: - MySQL: one by one, session settings restored

  @Test("MySQL under Protected mode is refused, also for a DML-only file")
  func mysqlProtectedRefused() async throws {
    let (manager, factory) = try await connect(.mysql, protectedMode: true)
    let script = Self.header(.mysql) + "\nINSERT INTO t (id) VALUES ('1');\n"
    guard
      case .sequentialBatchRefused(let reason)? = await restoreError(manager, script)
        as? DatabaseError
    else {
      Issue.record("Expected a Protected mode refusal")
      return
    }
    #expect(reason.contains("Protected mode"))
    #expect(factory.statements.isEmpty)
  }

  @Test("MySQL with the user's transaction open is refused")
  func mysqlOpenTransactionRefused() async throws {
    let (manager, factory) = try await connect(.mysql)
    _ = try await manager.execute(userSQL: "BEGIN", policy: open)
    let sent = factory.statements.count
    guard
      case .sequentialBatchRefused? = await restoreError(manager, Self.mysqlScript([]))
        as? DatabaseError
    else {
      Issue.record("Expected an open transaction refusal")
      return
    }
    #expect(factory.statements.count == sent)
  }

  @Test("MySQL: statement 3 of 5 fails and foreign key checks and sql_mode are still reset")
  func mysqlCleanupAfterFailure() async throws {
    let (manager, factory) = try await connect(.mysql)
    let script =
      [
        Self.header(.mysql), "SET FOREIGN_KEY_CHECKS=0;", "CREATE TABLE a (id int);",
        "INSERT INTO a VALUES ('1');", "INSERT INTO a VALUES ('2');", "SET FOREIGN_KEY_CHECKS=1;",
      ].joined(separator: "\n")
    let session = try #require(factory.sessions.last)
    session.failNextCommand(containing: "VALUES ('1')")
    let log = ProgressLog()
    let error = await restoreError(manager, script, progress: { log.append($0) })
    guard case .batchPartiallyApplied(let applied, let total, _, _)? = error as? DatabaseError
    else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(applied == 2)
    #expect(total == 5)
    #expect(log.values.map(\.statementsDone) == [1, 2])
    #expect(!session.statements.contains { $0.contains("VALUES ('2')") })
    #expect(Array(session.statements.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
  }

  @Test("MySQL: statement 3 fails and the reset fails too: the session is closed, both are told")
  func mysqlFailedResetAfterFailureClosesTheSession() async throws {
    let (manager, factory) = try await connect(.mysql)
    let script =
      [
        Self.header(.mysql), "SET FOREIGN_KEY_CHECKS=0;", "CREATE TABLE a (id int);",
        "INSERT INTO a VALUES ('1');", "INSERT INTO a VALUES ('2');", "SET FOREIGN_KEY_CHECKS=1;",
      ].joined(separator: "\n")
    let session = try #require(factory.sessions.last)
    session.failCommands(containing: ["VALUES ('1')", "FOREIGN_KEY_CHECKS=1"])
    let error = await restoreError(manager, script)
    guard case .restoreFailedSessionClosed(let failure, let reason)? = error as? SQLRestoreError
    else {
      Issue.record("Expected restoreFailedSessionClosed, got \(String(describing: error))")
      return
    }
    #expect(!failure.isEmpty)
    #expect(!reason.isEmpty)
    let message = try #require((error as? SQLRestoreError)?.errorDescription)
    #expect(message.contains("closed") && message.contains("Reconnect"))
    // Every reset statement was tried before the session was dropped
    #expect(Array(session.statements.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
    #expect(session.didClose)
    #expect(await manager.isConnected == false)
    #expect(await manager.lastSessionLoss != nil)
    #expect(factory.sessions.count == 1)
  }

  @Test("MySQL: a full restore whose reset fails closes the session")
  func mysqlFailedResetAfterSuccessClosesTheSession() async throws {
    let (manager, factory) = try await connect(.mysql)
    let session = try #require(factory.sessions.last)
    session.failCommands(containing: ["SET SESSION sql_mode = 'STRICT"])
    let error = await restoreError(manager, Self.mysqlScript(["INSERT INTO a VALUES ('1');"]))
    guard case .sessionNotReset(let count, _)? = error as? SQLRestoreError else {
      Issue.record("Expected sessionNotReset, got \(String(describing: error))")
      return
    }
    #expect(count == 6)
    #expect(session.didClose)
    #expect(await manager.isConnected == false)
    #expect(await manager.lastSessionLoss != nil)
  }

  @Test("MySQL: the session settings are read first and restored after success")
  func mysqlCleanupAfterSuccess() async throws {
    let (manager, factory) = try await connect(.mysql)
    let script = Self.mysqlScript(["CREATE TABLE a (id int);", "INSERT INTO a VALUES ('1');"])
    let session = try #require(factory.sessions.last)
    let before = session.statements.count
    let summary = try await manager.executeGatedRestore(
      script: script, policy: open, connectionEpoch: await manager.connectionEpoch)
    #expect(summary.statementsRun == 7)
    #expect(summary.count(.sessionSetting) == 5)
    let sent = Array(session.statements.dropFirst(before))
    #expect(sent.first == DatabaseConnectionManager.restoreSessionQuery)
    #expect(sent.count == 1 + 7 + Self.mysqlReset().count)
    #expect(!sent.contains("BEGIN") && !sent.contains("START TRANSACTION"))
    #expect(Array(sent.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
  }

  @Test("MySQL: unexpected session settings refuse the restore before any change")
  func mysqlUnreadableSettings() async throws {
    let (manager, factory) = try await connect(
      .mysql, rows: [Self.mysqlSettingsRow(mode: "STRICT'; DROP TABLE x; --")])
    let error = await restoreError(manager, Self.mysqlScript(["INSERT INTO a VALUES ('1');"]))
    guard case .sessionSettingsUnreadable? = error as? SQLRestoreError else {
      Issue.record("Expected sessionSettingsUnreadable, got \(String(describing: error))")
      return
    }
    #expect(factory.statements == [DatabaseConnectionManager.restoreSessionQuery])
  }

  @Test(
    "MySQL: unexpected unique_checks, sql_notes or server version refuse before any change",
    arguments: [
      mysqlSettingsRow(uniqueChecks: 2), mysqlSettingsRow(sqlNotes: -1),
      mysqlSettingsRow(version: "unknown"),
      [
        .string("STRICT_TRANS_TABLES"), .string("+00:00"), .string("1; DROP"), .int(1),
        .string("8.4.11"),
      ],
      [.string("STRICT_TRANS_TABLES"), .string("+00:00")],
    ])
  func mysqlUnreadableNewSettings(row: [CellValue]) async throws {
    let (manager, factory) = try await connect(.mysql, rows: [row])
    let error = await restoreError(manager, MySQLDumpFixtures.mysqlDump)
    guard case .sessionSettingsUnreadable? = error as? SQLRestoreError else {
      Issue.record("Expected sessionSettingsUnreadable, got \(String(describing: error))")
      return
    }
    #expect(factory.statements == [DatabaseConnectionManager.restoreSessionQuery])
  }

  // MARK: - MySQL: mysqldump files

  /// A MySQL fake whose `restoreSessionQuery` reports `version`, and whose note_verbosity read
  /// answers `basic,explain`
  private func connectServer(
    version: String, uniqueChecks: Int = 1, sqlNotes: Int = 1
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSession) {
    let settings = Self.mysqlSettingsRow(
      uniqueChecks: uniqueChecks, sqlNotes: sqlNotes, version: version)
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mysql.capabilities,
      queryAnswer: { sql, _ in
        switch sql {
        case DatabaseConnectionManager.restoreSessionQuery:
          FakeQueryAnswer(columns: [], rows: [settings])
        case DatabaseConnectionManager.restoreNoteVerbosityQuery:
          FakeQueryAnswer(columns: [], rows: [[.string("basic,explain")]])
        default: nil
        }
      })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: Self.config(.mysql))
    return (manager, try #require(factory.sessions.last))
  }

  @Test("MySQL: a mysqldump file runs its statements, then the reset in order")
  func mysqldumpResetOrder() async throws {
    let (manager, session) = try await connectServer(
      version: "8.4.11", uniqueChecks: 0, sqlNotes: 0)
    let plan = try Self.plan(MySQLDumpFixtures.mysqlDump, .mysql)
    let before = session.statements.count
    let log = ProgressLog()
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch,
      progress: { log.append($0) })
    #expect(summary.statementsRun == plan.statements.count)
    #expect(log.values.last?.statementsDone == plan.statements.count)
    let sent = Array(session.statements.dropFirst(before))
    #expect(
      sent
        == [DatabaseConnectionManager.restoreSessionQuery] + plan.statements.map(\.text)
        + Self.mysqlReset(uniqueChecks: 0, sqlNotes: 0))
    #expect(!sent.contains { $0.contains("UNIQUE_CHECKS=0") })
  }

  @Test("MySQL: a mariadb-dump file's /*M!100616 ...*/ lines are dropped on a MySQL server")
  func mariaDBLinesDroppedOnMySQL() async throws {
    let (manager, session) = try await connectServer(version: "8.4.11")
    let plan = try Self.plan(MySQLDumpFixtures.mariaDBDump, .mysql)
    let noteLines = plan.statements.map(\.text).filter { $0.contains("NOTE_VERBOSITY") }
    #expect(noteLines.count == 2)
    let before = session.statements.count
    let log = ProgressLog()
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch,
      progress: { log.append($0) })
    #expect(summary.statementsRun == plan.statements.count)
    #expect(log.values.last?.statementsDone == plan.statements.count)
    let sent = Array(session.statements.dropFirst(before))
    // Only the reset's clearing of the user variables names it
    #expect(
      !sent.dropLast(Self.mysqlReset().count).contains {
        $0.contains("NOTE_VERBOSITY") || $0.contains("note_verbosity")
      })
    #expect(sent.count == 1 + plan.statements.count - 2 + Self.mysqlReset().count)
    #expect(Array(sent.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
  }

  @Test("MySQL: on MariaDB 10.6.16+ the note_verbosity lines run and it is reset afterwards")
  func mariaDBNoteVerbosityReset() async throws {
    let (manager, session) = try await connectServer(version: "11.4.13-MariaDB-ubu2404")
    let plan = try Self.plan(MySQLDumpFixtures.mariaDBDump, .mysql)
    let before = session.statements.count
    _ = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch)
    let sent = Array(session.statements.dropFirst(before))
    #expect(
      sent
        == [
          DatabaseConnectionManager.restoreSessionQuery,
          DatabaseConnectionManager.restoreNoteVerbosityQuery,
        ] + plan.statements.map(\.text) + Self.mysqlReset(noteVerbosity: "basic,explain"))
  }

  @Test("MySQL: before MariaDB 10.6.16 the note_verbosity lines are dropped and not reset")
  func oldMariaDBDropsNoteVerbosity() async throws {
    let (manager, session) = try await connectServer(version: "10.6.15-MariaDB")
    let plan = try Self.plan(MySQLDumpFixtures.mariaDBDump, .mysql)
    let before = session.statements.count
    _ = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch)
    let sent = Array(session.statements.dropFirst(before))
    // Only the reset's clearing of the user variables names it
    #expect(
      !sent.dropLast(Self.mysqlReset().count).contains {
        $0.contains("NOTE_VERBOSITY") || $0.contains("note_verbosity")
      })
    #expect(Array(sent.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
  }

  @Test("MySQL: a mysqldump restore that fails partway still unlocks and resets everything")
  func mysqldumpResetAfterFailure() async throws {
    let (manager, session) = try await connectServer(version: "8.4.11")
    session.failNextCommand(containing: "INSERT INTO `tags`")
    let error = await restoreError(manager, MySQLDumpFixtures.mysqlDump)
    guard case .batchPartiallyApplied? = error as? DatabaseError else {
      Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
      return
    }
    #expect(Array(session.statements.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
    #expect(await manager.isConnected)
  }

  @Test(
    "MySQL: a mysqldump restore stopped partway still unlocks and resets everything",
    .timeLimit(.minutes(1)))
  func mysqldumpResetAfterStop() async throws {
    let (manager, session) = try await connectServer(version: "8.4.11")
    session.holdNextCommand(containing: "INSERT INTO `items`")
    let plan = try Self.plan(MySQLDumpFixtures.mysqlDump, .mysql)
    let epoch = await manager.connectionEpoch
    let policy = open
    let restore = Task {
      try await manager.executeGatedRestore(plan, policy: policy, connectionEpoch: epoch)
    }
    while session.heldCommandCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    session.releaseHeldCommands()
    await #expect(throws: (any Error).self) { try await restore.value }
    #expect(!session.statements.contains { $0.hasPrefix("INSERT INTO `tags`") })
    #expect(Array(session.statements.suffix(Self.mysqlReset().count)) == Self.mysqlReset())
  }

  @Test("MySQL: Safe Mode confirms a mysqldump restore, and its session lines block nothing")
  func safeModeRestoresMySQLDump() async throws {
    let (manager, _) = try await connectServer(version: "8.4.11")
    let plan = try Self.plan(MySQLDumpFixtures.mysqlDump, .mysql)
    let policy = ProtectionPolicy(protectionLevel: .none, safeMode: .safeAll)
    #expect(DatabaseBackupModel.restoreBlockReason(plan, policy: policy) == nil)
    let rows = DatabaseBackupModel.restoreConfirmation(plan)
    #expect(rows.count == plan.statements.count - plan.summary.count(.data))
    #expect(rows.contains { $0.kindLabel == "Session setting" && $0.preview == "UNLOCK TABLES" })
    let summary = try await manager.executeGatedRestore(
      plan, policy: policy, connectionEpoch: await manager.connectionEpoch)
    #expect(summary.statementsRun == plan.statements.count)
  }

  @Test("MySQL: Cancel during the session settings read sends no dump statement and no reset")
  func mysqlSettingsReadCancelled() async throws {
    let (manager, factory) = try await connect(.mysql)
    let session = try #require(factory.sessions.last)
    Self.cancelDuringNextQuery(manager, session)
    let error = await restoreError(manager, Self.mysqlScript(["INSERT INTO a VALUES ('1');"]))
    guard case .batchCancelled? = error as? DatabaseError else {
      Issue.record("Expected batchCancelled, got \(String(describing: error))")
      return
    }
    #expect(factory.statements == [DatabaseConnectionManager.restoreSessionQuery])
    #expect(factory.sessions.count == 1)
    #expect(await manager.isConnected)
  }

  @Test(
    "MySQL: Cancel interrupts the session settings read: cancelled, no dump and no reset",
    .timeLimit(.minutes(1)))
  func mysqlSettingsReadInterrupted() async throws {
    let (manager, factory) = try await connect(.mysql, slowQueries: true)
    let session = try #require(factory.sessions.last)
    let script = Self.mysqlScript(["INSERT INTO a VALUES ('1');"])
    let running = Task { await restoreError(manager, script) }
    await session.waitUntilQueryStarted()
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    let error = await running.value
    guard case .batchCancelled? = error as? DatabaseError else {
      Issue.record("Expected batchCancelled, got \(String(describing: error))")
      return
    }
    #expect(session.interruptCount == 1)
    #expect(factory.statements == [DatabaseConnectionManager.restoreSessionQuery])
    #expect(factory.sessions.count == 1)
    #expect(await manager.isConnected)
  }
}

extension SQLRestoreGateTests {
  // MARK: - DuckDB: one batch, no savepoint

  private static let duckdbDump = [
    header(.duckdb),
    "CREATE TYPE \"main\".\"mood\" AS ENUM ('ok');",
    "CREATE TABLE t(id INTEGER, m ENUM('ok'));",
    "INSERT INTO \"main\".\"t\" (\"id\", \"m\") VALUES\n('1', 'ok'),\n(NULL, NULL);",
  ].map { $0 + "\n" }.joined()

  private func connectDuckDB(
    protectedMode: Bool = false, database: String = DuckDBSession.inMemoryPath,
    readOnlyFile: Bool = false
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.duckdb.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .duckdb, database: database, sslMode: .disable, protectionLevel: .none,
        safeMode: .silent, protectedMode: protectedMode, readOnlyFile: readOnlyFile))
    return (manager, factory)
  }

  @Test("DuckDB: one BEGIN TRANSACTION ... COMMIT with no savepoint")
  func duckdbBatch() async throws {
    let (manager, factory) = try await connectDuckDB()
    let plan = try Self.plan(Self.duckdbDump, .duckdb)
    #expect(plan.kinds == [.schema, .schema, .data])
    let summary = try await manager.executeGatedRestore(
      plan, policy: open, connectionEpoch: await manager.connectionEpoch)
    let sent = factory.sessions.last?.statements ?? []
    #expect(sent.first == "BEGIN TRANSACTION")
    #expect(sent.last == "COMMIT")
    #expect(Array(sent.dropFirst().dropLast()) == plan.statements.map(\.text))
    #expect(!sent.contains { $0.contains("SAVEPOINT") })
    #expect(summary.statementsRun == 3)
    #expect(!summary.pending)
  }

  @Test("DuckDB under Protected mode or with the user's transaction open is refused")
  func duckdbRefusesTransactions() async throws {
    let (protected, protectedFactory) = try await connectDuckDB(protectedMode: true)
    guard
      case .sequentialBatchRefused(let reason)? = await restoreError(protected, Self.duckdbDump)
        as? DatabaseError
    else {
      Issue.record("Expected Protected mode to be refused")
      return
    }
    #expect(reason.contains("Protected mode"))
    #expect(reason.contains("savepoint"))
    #expect(protectedFactory.statements.isEmpty)

    let (manager, factory) = try await connectDuckDB()
    _ = try await manager.execute(userSQL: "BEGIN TRANSACTION", policy: open)
    let sent = factory.statements.count
    guard
      case .sequentialBatchRefused(let open)? = await restoreError(manager, Self.duckdbDump)
        as? DatabaseError
    else {
      Issue.record("Expected the open transaction to be refused")
      return
    }
    #expect(open == "Commit or roll back the open transaction first, then restore the dump.")
    #expect(factory.statements.count == sent)
  }

  @Test("DuckDB: a file opened read-only is refused with how to reopen it writable")
  func duckdbReadOnlyFile() async throws {
    let (manager, factory) = try await connectDuckDB(
      database: "/tmp/dblore-restore-\(UUID().uuidString).duckdb", readOnlyFile: true)
    guard
      case .blockedByProtection(_, _, let reason)? = await restoreError(manager, Self.duckdbDump)
        as? DatabaseError
    else {
      Issue.record("Expected a read-only refusal")
      return
    }
    #expect(reason == SQLRestorePlan.duckdbReadOnlyFileMessage)
    #expect(reason.contains("turn off Read-only"))
    #expect(factory.statements.isEmpty)
  }

  /// DuckDB's interrupt aborts the batch's own transaction; no user or app transaction owes the
  /// cancel's ROLLBACK, so the batch's own ROLLBACK must still be sent
  @Test("DuckDB: a restore cancelled mid-batch still sends its ROLLBACK", .timeLimit(.minutes(1)))
  func duckdbCancelledRestoreRollsBack() async throws {
    let (manager, factory) = try await connectDuckDB()
    let session = try #require(factory.sessions.last)
    session.holdNextCommand(containing: "INSERT")
    let plan = try Self.plan(Self.duckdbDump, .duckdb)
    let epoch = await manager.connectionEpoch
    let policy = open
    let restore = Task {
      try await manager.executeGatedRestore(plan, policy: policy, connectionEpoch: epoch)
    }
    while session.heldCommandCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
    let status = await manager.runningStatementStatus()
    let outcome = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: status.epoch)
    #expect(outcome == .cancelled)
    session.releaseHeldCommands()

    await #expect(throws: (any Error).self) { try await restore.value }
    #expect(session.statements.last == "ROLLBACK")
    #expect(!session.statements.contains("COMMIT"))
  }

  // MARK: - SQLite file

  private static func makeDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-restore-\(UUID().uuidString).sqlite")
    _ = try SQLiteHandle(url: url)
    return url
  }

  private static func removeDatabase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    for suffix in ["-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
  }

  private static func sqliteFile(
    _ url: URL, protectedMode: Bool
  ) async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
        rememberConnection: false, protectionLevel: .none, safeMode: .silent,
        protectedMode: protectedMode))
    return manager
  }

  private static func int(_ handle: SQLiteHandle, _ sql: String) throws -> Int64? {
    let statement = try handle.prepare(sql)
    guard try statement.step() else { return nil }
    return statement.columnInt(0)
  }

  /// No transaction is left open on the manager's connection: its next statement autocommits,
  /// so a second connection sees it, and nothing of the failed restore is there
  private static func expectAutocommit(
    _ manager: DatabaseConnectionManager, _ url: URL
  ) async throws {
    _ = try await manager.executeInternal("CREATE TABLE probe (x)")
    let handle = try SQLiteHandle(url: url)
    #expect(try int(handle, "SELECT count(*) FROM sqlite_master WHERE name = 'probe'") == 1)
    #expect(try int(handle, "SELECT count(*) FROM sqlite_master WHERE name = 'child'") == 0)
  }

  @Test("A SQLite dump restores into an empty file: rows, counter and a working trigger")
  func sqliteRoundTrip() async throws {
    let url = try Self.makeDatabase()
    defer { Self.removeDatabase(url) }
    let manager = try await Self.sqliteFile(url, protectedMode: false)
    let summary = try await manager.executeGatedRestore(
      script: Self.sqliteDump(), policy: open, connectionEpoch: await manager.connectionEpoch)
    await manager.disconnect()
    #expect(summary.statementsRun == 10)
    let handle = try SQLiteHandle(url: url)
    #expect(try Self.int(handle, "SELECT count(*) FROM parent") == 2)
    #expect(try Self.int(handle, "SELECT count(*) FROM log") == 0)
    #expect(try Self.int(handle, "SELECT seq FROM sqlite_sequence WHERE name = 'parent'") == 2)
    try handle.execute("INSERT INTO parent (name) VALUES ('d')")
    #expect(try Self.int(handle, "SELECT id FROM parent WHERE name = 'd'") == 3)
    #expect(try Self.int(handle, "SELECT count(*) FROM log WHERE msg = 'added; d'") == 1)
  }

  @Test("SQLite without Protected mode: an orphan row fails COMMIT, which is rolled back")
  func sqliteOrphanUnprotected() async throws {
    let url = try Self.makeDatabase()
    defer { Self.removeDatabase(url) }
    let manager = try await Self.sqliteFile(url, protectedMode: false)
    let error = await restoreError(manager, Self.sqliteDump(childParent: 99))
    #expect(error != nil)
    try await Self.expectAutocommit(manager, url)
    await manager.disconnect()
  }

  @Test("SQLite under Protected mode: an orphan row fails the app COMMIT, which is rolled back")
  func sqliteOrphanProtected() async throws {
    let url = try Self.makeDatabase()
    defer { Self.removeDatabase(url) }
    let manager = try await Self.sqliteFile(url, protectedMode: true)
    let summary = try await manager.executeGatedRestore(
      script: Self.sqliteDump(childParent: 99), policy: open,
      connectionEpoch: await manager.connectionEpoch)
    #expect(summary.pending)
    let generation = await manager.transactionStatus().generation
    do {
      try await manager.commitAppTransaction(expectedGeneration: generation)
      Issue.record("Expected the COMMIT to fail")
    } catch DatabaseError.transactionAborted(let message) {
      #expect(message.contains("Commit failed"))
    }
    #expect(await manager.transactionSnapshot() == .idle)
    try await Self.expectAutocommit(manager, url)
    await manager.disconnect()
  }

  /// `parent` and `child`, whose foreign key to it has ON DELETE `action`, one row each
  private static func makeCascadeDatabase(_ action: String) throws -> URL {
    let url = try makeDatabase()
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)")
    try handle.execute(
      "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER DEFAULT 1"
        + " REFERENCES Parent (id) ON DELETE \(action))")
    try handle.execute("INSERT INTO parent VALUES (1, 'old')")
    try handle.execute("INSERT INTO child VALUES (1, 1)")
    return url
  }

  /// Drops and recreates `tables` (`parent`, and `child` when asked) with one new parent row
  private static func sqliteDropDump(_ tables: [String]) -> String {
    script(
      .sqlite,
      ["PRAGMA defer_foreign_keys = ON;"] + tables.map { "DROP TABLE IF EXISTS \"\($0)\";" }
        + ["CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT);"]
        + (tables.contains("child")
          ? [
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent (id));"
          ]
          : [])
        + ["INSERT INTO \"parent\" (\"id\", \"name\") VALUES\n(1, 'new');"])
  }

  @Test(
    "SQLite: a Drop restore is refused when a table outside it reacts to a dropped table",
    arguments: ["CASCADE", "SET NULL", "SET DEFAULT"])
  func sqliteDropRefusedWhenAKeptTableReacts(action: String) async throws {
    let url = try Self.makeCascadeDatabase(action)
    defer { Self.removeDatabase(url) }
    let manager = try await Self.sqliteFile(url, protectedMode: false)
    let error = await restoreError(manager, Self.sqliteDropDump(["parent"]))
    #expect(
      error as? SQLRestoreError
        == .dropFiresForeignKeyAction(table: "child", dropped: "Parent", action: action))
    let message = error?.localizedDescription ?? ""
    #expect(message.contains("\"child\"") && message.contains("\"Parent\""))
    #expect(message.contains("Nothing was executed"))
    try await Self.expectNothingRestored(manager, url)
    await manager.disconnect()
  }

  /// The two rows of `makeCascadeDatabase` are still there, and the connection autocommits
  private static func expectNothingRestored(
    _ manager: DatabaseConnectionManager, _ url: URL
  ) async throws {
    _ = try await manager.executeInternal("CREATE TABLE probe (x)")
    let handle = try SQLiteHandle(url: url)
    #expect(try int(handle, "SELECT count(*) FROM sqlite_master WHERE name = 'probe'") == 1)
    #expect(try int(handle, "SELECT count(*) FROM parent WHERE name = 'old'") == 1)
    #expect(try int(handle, "SELECT count(*) FROM child WHERE parent_id = 1") == 1)
  }

  @Test("SQLite: a Drop restore that drops the reacting table too, or meets NO ACTION, runs")
  func sqliteDropRunsWithoutAReactingKeptTable() async throws {
    let both = try Self.makeCascadeDatabase("CASCADE")
    defer { Self.removeDatabase(both) }
    let manager = try await Self.sqliteFile(both, protectedMode: false)
    let summary = try await manager.executeGatedRestore(
      script: Self.sqliteDropDump(["parent", "child"]), policy: open,
      connectionEpoch: await manager.connectionEpoch)
    await manager.disconnect()
    #expect(summary.count(.drop) == 2)
    let handle = try SQLiteHandle(url: both)
    #expect(try Self.int(handle, "SELECT count(*) FROM parent WHERE name = 'new'") == 1)
    #expect(try Self.int(handle, "SELECT count(*) FROM child") == 0)

    let noAction = try Self.makeCascadeDatabase("NO ACTION")
    defer { Self.removeDatabase(noAction) }
    let other = try await Self.sqliteFile(noAction, protectedMode: false)
    // The new parent keeps id 1, so the deferred check passes at COMMIT
    _ = try await other.executeGatedRestore(
      script: Self.sqliteDropDump(["parent"]), policy: open,
      connectionEpoch: await other.connectionEpoch)
    await other.disconnect()
    let kept = try SQLiteHandle(url: noAction)
    #expect(try Self.int(kept, "SELECT count(*) FROM parent WHERE name = 'new'") == 1)
    #expect(try Self.int(kept, "SELECT count(*) FROM child WHERE parent_id = 1") == 1)
  }

  // MARK: - MySQL / MariaDB server

  private static func text(_ value: CellValue?) -> String? {
    switch value {
    case .string(let text): text
    case .int(let number): String(number)
    default: nil
    }
  }

  @Test(
    "MySQL live: foreign key checks and sql_mode are back after a failed and a full restore",
    .requiresMySQL, .timeLimit(.minutes(1)),
    arguments: [MySQLSessionTests.Server.mysql, .mariadb])
  @MainActor
  func mysqlLive(server: MySQLSessionTests.Server) async throws {
    try await TestMySQLDatabase.primeAuthCache()
    let name = "restore_\(UUID().uuidString.prefix(8).lowercased())"
    let admin = DatabaseConnectionManager()
    try await admin.connect(config: MySQLManagerTests.rootConfig(server))
    let manager = DatabaseConnectionManager()
    do {
      _ = try await admin.executeInternal("CREATE DATABASE \(name) CHARACTER SET utf8mb4")
      var config = MySQLManagerTests.rootConfig(server)
      config.database = name
      config.protectedMode = false
      try await manager.connect(config: config)
      func value(_ sql: String) async throws -> String? {
        Self.text(try await manager.executeInternal(sql).rows.first?.first)
      }
      let modeBefore = try await value("SELECT @@SESSION.sql_mode")
      #expect(modeBefore?.contains("NO_AUTO_VALUE_ON_ZERO") == false)

      let child =
        "CREATE TABLE `child` (`id` int PRIMARY KEY, `parent_id` int, FOREIGN KEY (`parent_id`)"
        + " REFERENCES `parent` (`id`)) ENGINE=InnoDB /*!40101 DEFAULT CHARSET=utf8mb4 */;"
      let failing = Self.mysqlScript([child, "INSERT INTO `missing` VALUES ('1');"])
      let error = await restoreError(manager, failing)
      guard case .batchPartiallyApplied(let applied, _, _, _)? = error as? DatabaseError else {
        Issue.record("Expected batchPartiallyApplied, got \(String(describing: error))")
        throw error ?? CancellationError()
      }
      #expect(applied == 5)
      #expect(try await value("SELECT @@FOREIGN_KEY_CHECKS") == "1")
      #expect(try await value("SELECT @@SESSION.sql_mode") == modeBefore)

      let full = Self.mysqlScript([
        "CREATE TABLE `parent` (`id` int NOT NULL AUTO_INCREMENT PRIMARY KEY) ENGINE=InnoDB;",
        "INSERT INTO `child` (`id`, `parent_id`) VALUES\n('1', '0');",
        "INSERT INTO `parent` (`id`) VALUES\n('0');",
      ])
      let summary = try await manager.executeGatedRestore(
        script: full, policy: open, connectionEpoch: await manager.connectionEpoch)
      #expect(summary.statementsRun == 8)
      #expect(try await value("SELECT @@FOREIGN_KEY_CHECKS") == "1")
      #expect(try await value("SELECT @@SESSION.sql_mode") == modeBefore)
      // NO_AUTO_VALUE_ON_ZERO from the dump kept the 0 id during the restore
      #expect(try await value("SELECT count(*) FROM `parent` WHERE `id` = 0") == "1")
    } catch {
      await Self.dropMySQL(admin, manager, name)
      throw error
    }
    await Self.dropMySQL(admin, manager, name)
  }

  @MainActor
  private static func dropMySQL(
    _ admin: DatabaseConnectionManager, _ manager: DatabaseConnectionManager, _ name: String
  ) async {
    await manager.disconnect()
    _ = try? await admin.executeInternal("DROP DATABASE IF EXISTS \(name)")
    await admin.disconnect()
  }
}

/// Progress callbacks, in the order they arrived
private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [SQLRestoreProgress] = []

  func append(_ progress: SQLRestoreProgress) {
    lock.withLock { stored.append(progress) }
  }

  var values: [SQLRestoreProgress] { lock.withLock { stored } }
}
