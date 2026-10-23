// MCPWriteToolTests.swift
// MCP execute_write: listed only while write tools are on and a connection has a write scope;
// a statement outside the scope or the connection's protection, or that the approval could not
// show as it runs, a non-ASCII keyword or unquoted name, or a schema change on an object kind
// schema scope does not cover (a CREATE, ALTER or DROP of a function, procedure or trigger; on
// MongoDB a database, account or validation change, a `system.*` collection, or a `$out` /
// `$merge` or `$lookup` / `$graphLookup` / `$unionWith` naming another database), is refused
// before any approval; an allowed one (emoji joiners and unusual spaces in a literal, the
// covered object kinds) reaches it; a denied or timed-out call executes nothing, and so does an approved one whose settings or saved
// connection changed during the wait; an approved one runs once on the writable manager,
// recorded as `.mcp`, even if the client disconnects meanwhile (a cancelled run is an unknown
// outcome), while the read tools keep the read-only manager.

import Foundation
import Testing

@testable import Dblore

/// Answers every approval with `answer` and keeps what it was asked.
private final class FakeApprover: MCPWriteApproving, @unchecked Sendable {
  private let lock = NSLock()
  private var asked: [MCPWriteApprovalRequest] = []
  let answer: Bool

  init(answer: Bool) {
    self.answer = answer
  }

  var requests: [MCPWriteApprovalRequest] { lock.withLock { asked } }

  func approve(_ request: MCPWriteApprovalRequest) async throws -> Bool {
    lock.withLock { asked.append(request) }
    return answer
  }

  func denyWaiting(connections: Set<UUID>) async {}
  func denyAllWaiting() async {}
}

/// The settings and saved connections a test changes while a write waits for approval.
private final class WriteSettings: @unchecked Sendable {
  private let lock = NSLock()
  private var state:
    (
      enabled: Bool, scopes: [UUID: MCPWriteScope], allowed: Set<UUID>,
      entries: [ConnectionHistoryEntry]
    )

  init(
    enabled: Bool, scopes: [UUID: MCPWriteScope], allowed: Set<UUID>,
    entries: [ConnectionHistoryEntry]
  ) {
    state = (enabled, scopes, allowed, entries)
  }

  var enabled: Bool {
    get { lock.withLock { state.enabled } }
    set { lock.withLock { state.enabled = newValue } }
  }
  var scopes: [UUID: MCPWriteScope] {
    get { lock.withLock { state.scopes } }
    set { lock.withLock { state.scopes = newValue } }
  }
  var allowed: Set<UUID> {
    get { lock.withLock { state.allowed } }
    set { lock.withLock { state.allowed = newValue } }
  }
  var entries: [ConnectionHistoryEntry] {
    get { lock.withLock { state.entries } }
    set { lock.withLock { state.entries = newValue } }
  }
}

/// Runs `change` while the user is asked, then approves.
private struct ChangingApprover: MCPWriteApproving {
  let change: @Sendable () -> Void

  func approve(_ request: MCPWriteApprovalRequest) async throws -> Bool {
    change()
    return true
  }

  func denyWaiting(connections: Set<UUID>) async {}
  func denyAllWaiting() async {}
}

/// Records the writes that reached it.
private final class FakeWriteSource: MCPWriteSource, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [String] = []

  var statements: [String] { lock.withLock { sent } }

  func runWrite(_ request: MCPWriteRequest) async throws -> MCPWriteResult {
    lock.withLock { sent.append(request.sql) }
    return MCPWriteResult(affectedRows: 1)
  }
}

/// Holds each write until `release()`, noting whether its task was cancelled by then; throws
/// `error` if set.
private final class SlowWriteSource: MCPWriteSource, @unchecked Sendable {
  private let lock = NSLock()
  private var state = (started: false, released: false, cancelled: false)
  private let error: (any Error)?

  init(error: (any Error)? = nil) {
    self.error = error
  }

  var started: Bool { lock.withLock { state.started } }
  var sawCancellation: Bool { lock.withLock { state.cancelled } }

  func release() {
    lock.withLock { state.released = true }
  }

  func runWrite(_ request: MCPWriteRequest) async throws -> MCPWriteResult {
    lock.withLock { state.started = true }
    while !lock.withLock({ state.released }) {
      try? await Task.sleep(for: .milliseconds(5))
    }
    lock.withLock { state.cancelled = Task.isCancelled }
    if let error { throw error }
    return MCPWriteResult(affectedRows: 1)
  }
}

/// A read source no write may reach.
private struct UnusedReadSource: MCPReadSource {
  func listTables(connectionID: UUID, schema: String?) async throws -> [MCPTableName] { [] }

  func describeTable(
    connectionID: UUID, schema: String?, table: String
  ) async throws -> [MCPColumnDescription] { [] }

  func runRead(_ request: MCPReadRequest) async throws -> MCPReadResult {
    MCPReadResult(columns: [], rows: [], rowsTruncated: false)
  }
}

private actor RecordedHistory: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

@MainActor
@Suite("MCP write tool")
struct MCPWriteToolTests {
  private let history = RecordedHistory()
  private let gate = AIAccessGate()

  /// A connection whose commit style is Immediate, with no protection level.
  private static func entry(
    _ type: DatabaseType = .postgresql, change: (inout ConnectionConfig) -> Void = { _ in }
  ) -> ConnectionHistoryEntry {
    var config = ConnectionConfig(
      databaseType: type, host: "fake", port: 1, database: "db", username: "u",
      password: "secret", sslMode: .disable, protectionLevel: .none, name: "Orders",
      safeMode: .silent, protectedMode: false)
    change(&config)
    var entry = ConnectionHistoryEntry(config: config)
    entry.config.password = config.password
    return entry
  }

  private func service(
    _ entries: [ConnectionHistoryEntry], scopes: [UUID: MCPWriteScope], enabled: Bool = true,
    approver: any MCPWriteApproving, writes: any MCPWriteSource,
    reads: any MCPReadSource = UnusedReadSource()
  ) -> MCPToolService {
    let allowed = Set(entries.map(\.id))
    return MCPToolService(
      connections: { entries }, allowlist: { allowed }, aiSettings: { .empty }, source: reads,
      recorder: history, historyEnabled: { true }, gate: gate,
      writes: MCPWriteAccess(
        enabled: { enabled }, scopes: { scopes }, defaultCommitStyle: { .review },
        approver: approver, source: writes))
  }

  private func write(
    _ service: MCPToolService, _ id: UUID, _ sql: String
  ) async -> MCPToolResult {
    await service.call(
      "execute_write", arguments: ["connection_id": .string(id.uuidString), "sql": .string(sql)])
  }

  @Test("A statement outside the scope or the connection's protection is refused before approval")
  func outOfScopeRefusedBeforeApproval() async {
    let approver = FakeApprover(answer: true)
    let source = FakeWriteSource()
    let data = Self.entry()
    let readScope = Self.entry()
    let readOnly = Self.entry { $0.protectionLevel = .readOnly }
    let review = Self.entry { $0.protectedMode = true }
    let password = Self.entry { $0.commitStyle = .password }
    let mongo = Self.entry(.mongodb)
    let schema = Self.entry()
    let mysql = Self.entry(.mysql)
    let sqlite = Self.entry(.sqlite)
    let duckdb = Self.entry(.duckdb)
    let sqliteSchema = Self.entry(.sqlite)
    let mongoSchema = Self.entry(.mongodb)
    let service = service(
      [
        data, readScope, readOnly, review, password, mongo, schema, mysql, sqlite, duckdb,
        sqliteSchema, mongoSchema,
      ],
      scopes: [
        data.id: .data, readOnly.id: .schema, review.id: .data, password.id: .data,
        mongo.id: .data, schema.id: .schema, mysql.id: .schema, sqlite.id: .data,
        duckdb.id: .data, sqliteSchema.id: .schema, mongoSchema.id: .schema,
      ], approver: approver, writes: source)
    let longLiteral = String(repeating: "x", count: MCPToolService.maxWriteBytes)
    let manyLines = String(repeating: "\n", count: MCPToolService.maxWriteLines)
    let cases: [(ConnectionHistoryEntry, String, MCPToolError)] = [
      (data, "DROP TABLE t", .writeOutOfScope(needed: .schema)),
      (data, "CREATE TABLE t2 AS SELECT 1", .writeOutOfScope(needed: .schema)),
      (data, "UPDATE t SET a = 1 WHERE id = 1; DELETE FROM t", .writeMultipleStatements),
      (data, "SELECT 1", .writeIsRead),
      (data, "BEGIN", .writeNotVerifiable),
      (data, "SET statement_timeout = 0", .writeNotVerifiable),
      (data, "CALL p()", .writeNotVerifiable),
      (data, "UPDATE t SET a = pg_sleep(10) WHERE id = 1", .sideEffectFunction),
      (readScope, "UPDATE t SET a = 1 WHERE id = 1", .writeNotAllowed),
      (readOnly, "UPDATE t SET a = 1 WHERE id = 1", .writeBlockedByProtection("")),
      (review, "UPDATE t SET a = 1 WHERE id = 1", .writeCommitStyle),
      (password, "UPDATE t SET a = 1 WHERE id = 1", .writeCommitStyle),
      (mongo, "db.users.drop()", .writeOutOfScope(needed: .schema)),
      (mongo, "db.c.aggregate([{$out: \"local_coll\"}])", .writeOutOfScope(needed: .schema)),
      // MongoDB schema scope covers collections and indexes of the connection's database only
      (mongoSchema, "db.dropDatabase()", .writeNotVerifiable),
      (mongoSchema, "db.getSiblingDB(\"other\").createCollection(\"c\")", .writeNotVerifiable),
      (mongoSchema, "db.getSiblingDB(\"admin\").users.drop()", .writeNotVerifiable),
      (mongoSchema, "db.createUser({user: \"u\", pwd: \"p\", roles: []})", .writeNotVerifiable),
      (
        mongoSchema, "db.runCommand({collMod: \"c\", validationLevel: \"off\"})",
        .writeNotVerifiable
      ),
      (
        mongoSchema, "db.c.aggregate([{$out: {db: \"other\", coll: \"x\"}}])",
        .writeNotVerifiable
      ),
      (
        mongo, "db.c.aggregate([{$merge: {into: {db: \"other\", coll: \"x\"}}}])",
        .writeNotVerifiable
      ),
      // The server's own collections, in every scope and as any target
      (mongoSchema, "db.getCollection(\"system.views\").drop()", .writeNotVerifiable),
      (mongo, "db.getCollection(\"system.js\").insertOne({_id: \"f\"})", .writeNotVerifiable),
      (mongoSchema, "db.c.renameCollection(\"system.js\")", .writeNotVerifiable),
      (mongoSchema, "db.c.aggregate([{$out: \"system.js\"}])", .writeNotVerifiable),
      (mongo, "db.c.aggregate([{$merge: {into: \"system.views\"}}])", .writeNotVerifiable),
      (mongo, "db.c.aggregate([{$merge: \"system.js\"}])", .writeNotVerifiable),
      // Reads from another database, at any depth, or of a shape the check cannot verify
      (
        mongo,
        "db.c.aggregate([{$lookup: {from: {db: \"other\", coll: \"u\"}, localField: \"a\", "
          + "foreignField: \"b\", as: \"y\"}}, {$merge: \"x\"}])",
        .writeNotVerifiable
      ),
      (
        mongo,
        "db.c.aggregate([{$facet: {f: [{$graphLookup: {from: {db: \"other\", coll: \"u\"}, "
          + "startWith: \"$a\", connectFromField: \"a\", connectToField: \"b\", as: \"y\"}}]}}, "
          + "{$merge: \"x\"}])",
        .writeNotVerifiable
      ),
      (
        mongo, "db.c.aggregate([{$unionWith: {db: \"other\", coll: \"u\"}}, {$merge: \"x\"}])",
        .writeNotVerifiable
      ),
      (
        mongo, "db.c.aggregate([{$lookup: {from: [\"u\"], as: \"y\"}}, {$merge: \"x\"}])",
        .writeNotVerifiable
      ),
      // What the approval shows must be what runs
      (data, "UPDATE t SET a = 'x\u{202E}y' WHERE id = 1", .writeHiddenCharacters),
      (data, "UPDATE t SET a = 1 WHERE id = 1\u{200B}", .writeHiddenCharacters),
      // Emoji joiners are shown only inside a string literal; private use and blank braille
      // nowhere
      (data, "UPDATE t SET a = 1 WHERE id = 1\u{200D}", .writeHiddenCharacters),
      (data, "UPDATE t SET \"a\u{200D}\" = 1 WHERE id = 1", .writeHiddenCharacters),
      (data, "UPDATE t SET a = '\u{E000}' WHERE id = 1", .writeHiddenCharacters),
      (data, "UPDATE t SET a = '\u{2800}' WHERE id = 1", .writeHiddenCharacters),
      // Spaces other than U+0020 only inside a string literal
      (data, "UPDATE t SET a = 1 WHERE\u{00A0}id = 1", .writeHiddenCharacters),
      (data, "UPDATE\u{3000}t SET a = 1 WHERE id = 1", .writeHiddenCharacters),
      (mongo, "db.t.insertOne({a: 'x\u{200D}y'})", .writeHiddenCharacters),
      (data, "UPDATE t SET a = '\(longLiteral)' WHERE id = 1", .writeTooLong),
      (data, "UPDATE t SET a = 1\(manyLines) WHERE id = 1", .writeTooLong),
      (data, "EXPLAIN ANALYZE DELETE FROM t WHERE id = 1", .writeNotVerifiable),
      (schema, "EXPLAIN ANALYZE CREATE TABLE t2 AS SELECT 1", .writeNotVerifiable),
      // Accounts and server settings are not schema changes
      (schema, "CREATE ROLE agent LOGIN SUPERUSER", .writeNotVerifiable),
      (schema, "DROP USER someone", .writeNotVerifiable),
      (schema, "ALTER GROUP staff ADD USER agent", .writeNotVerifiable),
      (schema, "ALTER SYSTEM SET statement_timeout = 0", .writeNotVerifiable),
      (schema, "ALTER DATABASE db SET statement_timeout = 0", .writeNotVerifiable),
      (schema, "ALTER DATABASE db RESET ALL", .writeNotVerifiable),
      (mysql, "ALTER USER u IDENTIFIED BY 'x'", .writeNotVerifiable),
      (mysql, "CREATE USER u", .writeNotVerifiable),
      (mysql, "RENAME USER a TO b", .writeNotVerifiable),
      (mysql, "SET PASSWORD = 'x'", .writeNotVerifiable),
      (mysql, "CREATE OR REPLACE USER u IDENTIFIED BY 'x'", .writeNotVerifiable),
      (mysql, "CREATE OR REPLACE ROLE r", .writeNotVerifiable),
      // Privileges and access control are not schema changes
      (schema, "DROP OWNED BY someone", .writeNotVerifiable),
      (schema, "REASSIGN OWNED BY someone TO agent", .writeNotVerifiable),
      (schema, "ALTER TABLE t ENABLE ROW LEVEL SECURITY", .writeNotVerifiable),
      (schema, "ALTER TABLE IF EXISTS t NO FORCE ROW LEVEL SECURITY", .writeNotVerifiable),
      (schema, "CREATE POLICY p ON t USING (true)", .writeNotVerifiable),
      (schema, "ALTER POLICY p ON t USING (true)", .writeNotVerifiable),
      (schema, "DROP POLICY IF EXISTS p ON t", .writeNotVerifiable),
      // Code that runs outside SQL, extensions, replication and foreign data
      (schema, "CREATE FUNCTION f() RETURNS int LANGUAGE c AS 'lib', 'f'", .writeNotVerifiable),
      (
        schema, "CREATE OR REPLACE PROCEDURE p() LANGUAGE plpython3u AS $$ pass $$",
        .writeNotVerifiable
      ),
      (schema, "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1 $$", .writeNotVerifiable),
      (schema, "CREATE TRUSTED PROCEDURAL LANGUAGE plperl", .writeNotVerifiable),
      (schema, "CREATE EXTENSION IF NOT EXISTS dblink", .writeNotVerifiable),
      (schema, "ALTER EXTENSION dblink UPDATE", .writeNotVerifiable),
      (
        schema, "CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION p",
        .writeNotVerifiable
      ),
      (schema, "CREATE PUBLICATION p FOR ALL TABLES", .writeNotVerifiable),
      (schema, "CREATE FOREIGN DATA WRAPPER w", .writeNotVerifiable),
      (schema, "CREATE FOREIGN TABLE f (a int) SERVER s", .writeNotVerifiable),
      (
        schema, "CREATE EVENT TRIGGER e ON ddl_command_start EXECUTE FUNCTION f()",
        .writeNotVerifiable
      ),
      (mysql, "CREATE AGGREGATE FUNCTION f RETURNS STRING SONAME 'udf.so'", .writeNotVerifiable),
      (
        mysql, "CREATE TABLE t (a int) ENGINE=FEDERATED CONNECTION='mysql://u@h/db/t'",
        .writeNotVerifiable
      ),
      (mysql, "ALTER TABLE t ENGINE = CONNECT TABLE_TYPE=CSV", .writeNotVerifiable),
      (
        mysql, "CREATE TABLE t (a int) PARTITION BY HASH (a) (PARTITION p0 ENGINE = FEDERATED)",
        .writeNotVerifiable
      ),
      // Files placed outside the server's data directory, tablespaces
      (mysql, "CREATE TABLE t (a int) DATA DIRECTORY = '/tmp/x'", .writeNotVerifiable),
      (
        mysql,
        "CREATE TABLE t (a int) PARTITION BY HASH (a) (PARTITION p0 INDEX DIRECTORY = '/tmp/x')",
        .writeNotVerifiable
      ),
      (schema, "CREATE TABLE t (a int) TABLESPACE ts", .writeNotVerifiable),
      (
        schema, "CREATE TABLE t (a int, PRIMARY KEY (a) USING INDEX TABLESPACE ts)",
        .writeNotVerifiable
      ),
      // MySQL executable comments, side effects and files
      (mysql, "DELETE FROM t WHERE id = 1 /*!OR 1=1*/", .writeNotVerifiable),
      (mysql, "UPDATE t SET a = SLEEP(10) WHERE id = 1", .writeNotVerifiable),
      (mysql, "LOAD DATA INFILE '/etc/hosts' INTO TABLE t", .writeNotVerifiable),
      (mysql, "SELECT a FROM t INTO OUTFILE '/tmp/t.txt'", .writeNotVerifiable),
      (sqlite, "ATTACH DATABASE '/tmp/x.db' AS x", .writeNotVerifiable),
      (sqlite, "UPDATE t SET a = load_extension('x') WHERE id = 1", .writeNotVerifiable),
      (duckdb, "INSERT INTO t SELECT * FROM read_csv('/etc/hosts')", .writeNotVerifiable),
      (duckdb, "INSTALL httpfs", .writeNotVerifiable),
      // Schema scope covers listed object kinds only; anything else fails closed
      (schema, "ALTER SUBSCRIPTION s CONNECTION 'host=other'", .writeNotVerifiable),
      (schema, "ALTER PUBLICATION p ADD TABLE t", .writeNotVerifiable),
      (schema, "ALTER FOREIGN TABLE f OPTIONS (SET filename '/etc/hosts')", .writeNotVerifiable),
      (schema, "ALTER FOREIGN DATA WRAPPER w OPTIONS (ADD x 'y')", .writeNotVerifiable),
      (schema, "ALTER EVENT TRIGGER e ENABLE", .writeNotVerifiable),
      (schema, "ALTER LANGUAGE plperl RENAME TO p", .writeNotVerifiable),
      (schema, "CREATE ACCESS METHOD am TYPE TABLE HANDLER h", .writeNotVerifiable),
      (schema, "CREATE TABLESPACE ts LOCATION '/tmp/ts'", .writeNotVerifiable),
      (schema, "CREATE DATABASE other", .writeNotVerifiable),
      (schema, "CREATE RULE r AS ON INSERT TO t DO INSTEAD NOTHING", .writeNotVerifiable),
      (schema, "CREATE CAST (int AS text) WITH INOUT", .writeNotVerifiable),
      (schema, "CREATE OPERATOR === (LEFTARG = int, RIGHTARG = int)", .writeNotVerifiable),
      (schema, "CREATE FOOBAR x", .writeNotVerifiable),
      (schema, "ALTER TABLE t SET TABLESPACE ts", .writeNotVerifiable),
      (schema, "ALTER TABLE t ATTACH PARTITION p FOR VALUES IN (1)", .writeNotVerifiable),
      // Switching triggers or rules off or on (an audit trigger) is not a schema change
      (schema, "ALTER TABLE t DISABLE TRIGGER ALL", .writeNotVerifiable),
      (schema, "ALTER TABLE t ENABLE ALWAYS TRIGGER x", .writeNotVerifiable),
      (schema, "ALTER TABLE t DISABLE RULE r", .writeNotVerifiable),
      (schema, "ALTER FUNCTION f() SUPPORT s", .writeNotVerifiable),
      (mysql, "CREATE EVENT e ON SCHEDULE EVERY 1 HOUR DO DELETE FROM t", .writeNotVerifiable),
      (
        mysql, "CREATE DEFINER = 'root'@'%' PROCEDURE p() UPDATE t SET a = 1 WHERE id = 1",
        .writeNotVerifiable
      ),
      (sqliteSchema, "CREATE VIRTUAL TABLE v USING fts5(a)", .writeNotVerifiable),
      (sqliteSchema, "PRAGMA writable_schema = ON", .writeNotVerifiable),
      // Functions, procedures and triggers run code later that no check here sees, and dropping
      // one removes what it enforced (an audit trigger)
      (schema, "DROP FUNCTION f()", .writeNotVerifiable),
      (schema, "DROP TRIGGER t ON x", .writeNotVerifiable),
      (schema, "DROP PROCEDURE p", .writeNotVerifiable),
      (
        schema,
        "CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END $$",
        .writeNotVerifiable
      ),
      (
        schema, "CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql AS 'SELECT 1'",
        .writeNotVerifiable
      ),
      (schema, "ALTER FUNCTION f() RENAME TO g", .writeNotVerifiable),
      (schema, "CREATE TRIGGER tr BEFORE INSERT ON t EXECUTE FUNCTION f()", .writeNotVerifiable),
      (
        schema,
        "CREATE CONSTRAINT TRIGGER tr AFTER INSERT ON t FOR EACH ROW EXECUTE FUNCTION f()",
        .writeNotVerifiable
      ),
      (
        mysql, "CREATE DEFINER = CURRENT_USER PROCEDURE p() UPDATE t SET a = 1 WHERE id = 1",
        .writeNotVerifiable
      ),
      (
        mysql,
        "DELIMITER $$\nCREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW BEGIN SET NEW.a = 1; END$$",
        .writeNotVerifiable
      ),
      (
        sqliteSchema, "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a = 1; END",
        .writeNotVerifiable
      ),
      (mysql, "CREATE SQL SECURITY DEFINER VIEW v AS SELECT 1", .writeNotVerifiable),
      // Keywords and unquoted names in plain ASCII (a Cyrillic letter in WHERE)
      (data, "DELETE FROM t W\u{041D}ERE id=1", .writeNonASCIIWord),
      // Privileges and ownership anywhere in a CREATE or ALTER
      (
        schema, "CREATE SCHEMA s GRANT SELECT ON TABLE public.secrets TO PUBLIC",
        .writeNotVerifiable
      ),
      (schema, "CREATE SCHEMA s AUTHORIZATION someone", .writeNotVerifiable),
      // Schema elements create objects the object word SCHEMA does not name (a trigger)
      (
        schema,
        "CREATE SCHEMA s CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION f()",
        .writeNotVerifiable
      ),
      (
        schema,
        "CREATE SCHEMA s CREATE TABLE t(a int) CREATE TRIGGER tr BEFORE INSERT ON t "
          + "FOR EACH ROW EXECUTE FUNCTION f()",
        .writeNotVerifiable
      ),
      (schema, "CREATE SCHEMA s CREATE VIEW v AS SELECT 1", .writeNotVerifiable),
      (schema, "ALTER FUNCTION f() SECURITY DEFINER", .writeNotVerifiable),
      (schema, "ALTER TABLE t OWNER TO someone", .writeNotVerifiable),
      // MySQL engines outside the local storage list
      (mysql, "CREATE TABLE t (a int) ENGINE=SPIDER", .writeNotVerifiable),
      (mysql, "CREATE TABLE t (a int) ENGINE = S3", .writeNotVerifiable),
    ]
    for (entry, sql, expected) in cases {
      let result = await write(service, entry.id, sql)
      #expect(result.isError, "\(sql)")
      if case .writeBlockedByProtection = expected {
        #expect(result.text.hasPrefix("Blocked by the connection's protection"), "\(sql)")
      } else {
        #expect(result.text == expected.localizedDescription, "\(sql)")
      }
    }
    #expect(approver.requests.isEmpty)
    #expect(source.statements.isEmpty)
  }

  @Test("Allowed writes reach the approval: emoji joiners in a literal, covered object kinds")
  func allowedWritesReachApproval() async {
    let approver = FakeApprover(answer: true)
    let source = FakeWriteSource()
    let data = Self.entry()
    let schema = Self.entry()
    let mysql = Self.entry(.mysql)
    let mysqlData = Self.entry(.mysql)
    let sqlite = Self.entry(.sqlite)
    let mongo = Self.entry(.mongodb)
    let mongoData = Self.entry(.mongodb)
    let service = service(
      [data, schema, mysql, mysqlData, sqlite, mongo, mongoData],
      scopes: [
        data.id: .data, schema.id: .schema, mysql.id: .schema, mysqlData.id: .data,
        sqlite.id: .schema, mongo.id: .schema, mongoData.id: .data,
      ], approver: approver, writes: source)
    let cases: [(ConnectionHistoryEntry, String)] = [
      (
        data,
        "INSERT INTO posts(body) VALUES ('Thanks \u{2764}\u{FE0F} \u{1F469}\u{200D}\u{1F4BB}')"
      ),
      (data, "UPDATE t SET name='\u{041D}\u{0438}\u{043D}\u{0430}' WHERE id=1"),
      (mysql, "CREATE TABLE t (a int) ENGINE=InnoDB"),
      (data, "UPDATE t SET a = 'x\u{00A0}y\u{3000}' WHERE id = 1"),
      // The object kinds schema scope covers
      (schema, "CREATE TABLE t (a int)"),
      (schema, "CREATE TEMP TABLE t (a int)"),
      (schema, "ALTER TABLE t ADD COLUMN b int"),
      (schema, "CREATE UNIQUE INDEX i ON t (a)"),
      (schema, "CREATE INDEX CONCURRENTLY i ON t (a)"),
      (schema, "CREATE VIEW v AS SELECT 1"),
      (schema, "CREATE MATERIALIZED VIEW m AS SELECT 1"),
      (schema, "CREATE SEQUENCE s"),
      (schema, "CREATE SCHEMA s"),
      (schema, "CREATE TYPE mood AS ENUM ('a', 'b')"),
      (schema, "CREATE DOMAIN d AS int CHECK (VALUE > 0)"),
      (schema, "COMMENT ON COLUMN t.a IS 'x'"),
      (schema, "DROP TABLE t"),
      (schema, "TRUNCATE t"),
      (mysql, "CREATE DATABASE d"),
      (mysql, "CREATE OR REPLACE DEFINER = CURRENT_USER VIEW v AS SELECT 1"),
      (mysql, "RENAME TABLE a TO b"),
      (mysql, "CREATE ALGORITHM = MERGE SQL SECURITY INVOKER VIEW v AS SELECT 1"),
      (mysql, "ALTER DATABASE d CHARACTER SET utf8mb4"),
      (mysql, "CREATE TABLE cars (id int, engine varchar(20))"),
      // Columns named data or directory are not a DATA or INDEX DIRECTORY
      (mysql, "ALTER TABLE files ADD INDEX (directory)"),
      (mysql, "CREATE INDEX i ON t (data, directory)"),
      (mysqlData, "UPDATE cars SET engine = 'connect' WHERE id = 1"),
      (sqlite, "CREATE TABLE t (a int)"),
      (mongo, "db.createCollection('c')"),
      (mongo, "db.users.createIndex({a: 1})"),
      (mongo, "db.users.drop()"),
      (mongo, "db.users.renameCollection(\"people\")"),
      (mongo, "db.users.aggregate([{$out: \"local_coll\"}])"),
      (mongo, "db.users.aggregate([{$out: {db: \"db\", coll: \"x\"}}])"),
      (mongoData, "db.c.insertOne({a: 1})"),
      (mongoData, "db.c.aggregate([{$merge: {into: \"x\"}}])"),
      (
        mongoData,
        "db.c.aggregate([{$lookup: {from: \"u\", localField: \"a\", foreignField: \"b\", "
          + "as: \"y\"}}, {$merge: {into: \"x\"}}])"
      ),
    ]
    for (entry, sql) in cases {
      let result = await write(service, entry.id, sql)
      #expect(!result.isError, "\(sql): \(result.text)")
      #expect(approver.requests.last?.statement == sql)
    }
    #expect(source.statements == cases.map(\.1))
    // The approval marks the invisible characters it lets through
    #expect(
      MCPToolService.markingInvisibles("'\u{2764}\u{FE0F}\u{1F469}\u{200D}\u{00AD}\u{200C}'")
        == "'\u{2764}[U+FE0F]\u{1F469}[U+200D][U+00AD][U+200C]'")
  }

  @Test("A denied or timed-out call executes nothing; an approved one runs once")
  func deniedOrTimedOutExecutesNothing() async throws {
    let entry = Self.entry()
    let sql = "UPDATE t SET a = 1 WHERE id = 1"
    let source = FakeWriteSource()
    let center = MCPWriteApprovalCenter(timeout: .milliseconds(50))
    for approver in [FakeApprover(answer: false) as any MCPWriteApproving, center] {
      let service = service(
        [entry], scopes: [entry.id: .data], approver: approver, writes: source)
      let result = await write(service, entry.id, sql)
      #expect(result.isError)
      #expect(result.text == MCPToolError.writeDenied.localizedDescription)
    }
    #expect(source.statements.isEmpty)
    #expect(center.queue.isEmpty)

    let approver = FakeApprover(answer: true)
    let service = service([entry], scopes: [entry.id: .data], approver: approver, writes: source)
    let result = await write(service, entry.id, sql)
    #expect(!result.isError)
    #expect(result.text == #"{"affected_rows":1}"#)
    #expect(source.statements == [sql])
    let asked = try #require(approver.requests.first)
    #expect(asked.statement == sql)
    #expect(asked.connectionName == "Orders")
    #expect(asked.classification == DatabaseConnectionManager.describe(.dml))

    let recorded = await history.entries
    #expect(recorded.map(\.status) == [.cancelled, .cancelled, .success])
    #expect(recorded.allSatisfy { $0.source == .mcp && $0.kind == .write })
  }

  @Test("A client that disconnects while an approved write runs does not stop the statement")
  func disconnectDuringWriteLetsItFinish() async throws {
    let entry = Self.entry()
    let source = SlowWriteSource()
    let service = service(
      [entry], scopes: [entry.id: .data], approver: FakeApprover(answer: true), writes: source)
    let call = Task { await write(service, entry.id, "UPDATE t SET a = 1 WHERE id = 1") }
    let deadline = ContinuousClock.now + .seconds(5)
    while !source.started, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    call.cancel()
    source.release()
    let result = await call.value
    #expect(!result.isError, "\(result.text)")
    #expect(!source.sawCancellation)
    #expect(await history.entries.map(\.status) == [.success])
  }

  @Test("A write cancelled while it ran is recorded as an unknown outcome, not as cancelled")
  func cancelledWhileRunningIsUnknown() async {
    let entry = Self.entry()
    let source = SlowWriteSource(
      error: DatabaseError.queryCancelled(pendingCount: 0, userTxRolledBack: false))
    source.release()
    let service = service(
      [entry], scopes: [entry.id: .data], approver: FakeApprover(answer: true), writes: source)
    let result = await write(service, entry.id, "UPDATE t SET a = 1 WHERE id = 1")
    let unknown = MCPToolError.writeOutcomeUnknown.localizedDescription
    #expect(result.isError)
    #expect(result.text == unknown)
    let recorded = await history.entries
    #expect(recorded.map(\.status) == [.error])
    #expect(recorded.first?.errorMessage == unknown)
  }

  @Test("A switch, scope, allowlist, connection or commit style changed while asking runs nothing")
  func narrowedDuringApprovalRunsNothing() async {
    let entry = Self.entry()
    let id = entry.id
    var edited = entry
    edited.config.host = "other"
    // Review needs the user in Dblore; set on the saved connection, as Settings does
    var review = entry
    review.config.applyCommitStyle(.review)
    let source = FakeWriteSource()
    let cases: [(String, MCPWriteScope, @Sendable (WriteSettings) -> Void, MCPToolError)] = [
      ("UPDATE t SET a = 1 WHERE id = 1", .data, { $0.enabled = false }, .writeToolsOff),
      ("UPDATE t SET a = 1 WHERE id = 1", .data, { $0.scopes = [id: .read] }, .writeNotAllowed),
      ("DROP TABLE t", .schema, { $0.scopes = [id: .data] }, .writeOutOfScope(needed: .schema)),
      ("UPDATE t SET a = 1 WHERE id = 1", .data, { $0.allowed = [] }, .connectionNotAvailable),
      (
        "UPDATE t SET a = 1 WHERE id = 1", .data, { [edited] in $0.entries = [edited] },
        .writeConnectionChanged
      ),
      (
        "UPDATE t SET a = 1 WHERE id = 1", .data, { [review] in $0.entries = [review] },
        .writeConnectionChanged
      ),
    ]
    for (sql, scope, change, expected) in cases {
      let settings = WriteSettings(
        enabled: true, scopes: [id: scope], allowed: [id], entries: [entry])
      let service = MCPToolService(
        connections: { settings.entries }, allowlist: { settings.allowed },
        aiSettings: { .empty }, source: UnusedReadSource(), recorder: history,
        historyEnabled: { true }, gate: gate,
        writes: MCPWriteAccess(
          enabled: { settings.enabled }, scopes: { settings.scopes },
          defaultCommitStyle: { .review },
          approver: ChangingApprover { change(settings) }, source: source))
      let result = await write(service, id, sql)
      #expect(result.isError, "\(sql)")
      #expect(result.text == expected.localizedDescription, "\(sql)")
    }
    #expect(source.statements.isEmpty)
  }

  @Test("Read tools keep the read-only manager; writes use a second, writable one")
  func readToolsRemainReadOnly() async throws {
    let entry = Self.entry()
    let id = entry.id
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let pool = MCPConnectionPool(
      entry: { $0 == id ? entry : nil }, sessionFactory: factory,
      certificates: InMemoryClientCertificateStore(),
      sshCredentials: InMemorySSHCredentialStore(), knownHosts: InMemorySSHKnownHostStore())
    let service = service(
      [entry], scopes: [entry.id: .data], approver: FakeApprover(answer: true),
      writes: MCPSQLWriteSource(pool: pool), reads: MCPSQLReadSource(pool: pool))

    let read = await service.call(
      "run_query",
      arguments: ["connection_id": .string(entry.id.uuidString), "sql": .string("SELECT 1")])
    #expect(!read.isError)
    #expect(factory.sessions.count == 1)
    let update = "UPDATE t SET a = 1 WHERE id = 1"
    let written = await write(service, entry.id, update)
    #expect(!written.isError, "\(written.text)")
    #expect(factory.sessions.count == 2)

    let readSession = factory.sessions[0]
    let writeSession = factory.sessions[1]
    #expect(readSession.statements.contains("BEGIN TRANSACTION READ ONLY"))
    #expect(!readSession.statements.contains(update))
    #expect(writeSession.statements.contains(update))
    #expect(!writeSession.statements.contains("BEGIN TRANSACTION READ ONLY"))

    let reader = try await pool.withManager(for: entry.id) { $0 }
    let writer = try await pool.withWritableManager(for: entry.id) { $0 }
    #expect(reader !== writer)
    // The read-only session refuses the command (the manager reports it as a failed query)
    await #expect(throws: (any Error).self) {
      _ = try await reader.execute(
        userSQL: update, policy: ProtectionPolicy(protectionLevel: .none))
    }
    #expect(!readSession.statements.contains(update))
    await pool.closeAll()
  }

  @Test("execute_write is listed only while write tools are on and a connection has a scope")
  func notListedWhenOff() async {
    let entry = Self.entry()
    let approver = FakeApprover(answer: true)
    let source = FakeWriteSource()
    let readTools = MCPToolService.tools.map(\.name)
    let off = service(
      [entry], scopes: [entry.id: .data], enabled: false, approver: approver, writes: source)
    #expect(await off.listedTools().map(\.name) == readTools)
    let refused = await write(off, entry.id, "UPDATE t SET a = 1 WHERE id = 1")
    #expect(refused.text == MCPToolError.writeToolsOff.localizedDescription)
    let unscoped = service([entry], scopes: [UUID(): .schema], approver: approver, writes: source)
    #expect(await unscoped.listedTools().map(\.name) == readTools)
    let id = entry.id
    let none = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: UnusedReadSource(), recorder: history, historyEnabled: { true }, gate: gate)
    #expect(await none.listedTools().map(\.name) == readTools)

    let on = service([entry], scopes: [entry.id: .data], approver: approver, writes: source)
    #expect(await on.listedTools().map(\.name) == readTools + ["execute_write"])
    #expect(approver.requests.isEmpty)
    #expect(source.statements.isEmpty)
  }
}
