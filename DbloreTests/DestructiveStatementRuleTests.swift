// DestructiveStatementRuleTests.swift
// The shared destructive-statement rule: which statements need the typed target name
// (`.confirm`), which are destructive with no single readable target (`.unnamed`), and which
// are not destructive (`.none`). Pure: classified text only, no database needed.
//
// `confirm` carries the target as written: unquoted words keep their case, quoted identifiers
// lose their quotes, and the parts of a qualified name are joined with "."
// (`DROP TABLE "s"."t"` confirms `s.t`), as the AI Run has always read DROP and TRUNCATE.

import Testing

@testable import Dblore

@Suite("Destructive statement rule")
struct DestructiveStatementRuleTests {
  typealias Verdict = DestructiveStatementRule.Verdict

  struct Case: Sendable, CustomTestStringConvertible {
    let text: String
    let dialect: SQLDialect
    let expected: Verdict

    init(_ text: String, _ dialect: SQLDialect, _ expected: Verdict) {
      self.text = text
      self.dialect = dialect
      self.expected = expected
    }

    /// PostgreSQL
    init(_ text: String, _ expected: Verdict) {
      self.init(text, .postgresql, expected)
    }

    var testDescription: String { "\(dialect): \(text)" }
  }

  static let cases: [Case] = [
    // DROP / TRUNCATE (unchanged)
    Case("DROP TABLE t", .confirm("t")),
    Case("DROP TABLE \"s\".\"t\"", .confirm("s.t")),
    Case("drop table if exists Public.\"Order Items\" cascade", .confirm("Public.Order Items")),
    Case("TRUNCATE t", .confirm("t")),
    Case("DROP TABLE a, b", .unnamed),
    Case("DO $$ BEGIN DELETE FROM t; END $$", .unnamed),
    Case("/*!40000 DROP TABLE users */", .mysql, .unnamed),
    // CREATE OR REPLACE of an object that holds data
    Case("CREATE OR REPLACE TABLE t AS SELECT 1", .duckdb, .confirm("t")),
    Case("CREATE OR REPLACE TEMP TABLE t AS SELECT 1", .duckdb, .confirm("t")),
    Case("CREATE OR REPLACE TEMPORARY TABLE t (a int)", .mysql, .confirm("t")),
    Case("CREATE OR REPLACE SCHEMA s", .duckdb, .confirm("s")),
    Case("CREATE OR REPLACE DATABASE d", .mysql, .confirm("d")),
    Case("CREATE OR REPLACE SEQUENCE q", .duckdb, .confirm("q")),
    Case("CREATE OR REPLACE VIEW v AS SELECT 1", .none),
    Case("CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql", .none),
    Case("CREATE TABLE t (a int)", .none),
    // ALTER TABLE with a DROP that removes data (fail closed)
    Case("ALTER TABLE t DROP c", .confirm("t")),
    Case("ALTER TABLE t DROP COLUMN c", .confirm("t")),
    Case("ALTER TABLE IF EXISTS ONLY s.t ADD x int, DROP c", .confirm("s.t")),
    Case("ALTER TABLE t ALTER COLUMN c DROP DEFAULT", .none),
    Case("ALTER TABLE t ALTER c DROP NOT NULL", .none),
    Case("ALTER TABLE t ALTER COLUMN c DROP IDENTITY IF EXISTS", .none),
    Case("ALTER TABLE t ALTER COLUMN c DROP EXPRESSION", .none),
    Case("ALTER TABLE t DROP CONSTRAINT k", .none),
    // A column named identity, not ALTER COLUMN ... DROP IDENTITY
    Case("ALTER TABLE t DROP identity", .confirm("t")),
    Case("ALTER TABLE t DROP PRIMARY KEY", .mysql, .none),
    Case("ALTER TABLE t DROP FOREIGN KEY fk", .mysql, .none),
    Case("ALTER TABLE t DROP INDEX i", .mysql, .none),
    Case("ALTER TABLE t DROP KEY k", .mysql, .none),
    Case("ALTER TABLE t DROP CHECK c", .mysql, .none),
    // PostgreSQL has no DROP INDEX in ALTER TABLE: this drops a column named index
    Case("ALTER TABLE t DROP index", .confirm("t")),
    Case("ALTER TABLE t DROP PARTITION p0", .mysql, .confirm("t")),
    Case("ALTER TABLE t TRUNCATE PARTITION p0", .mysql, .confirm("t")),
    Case("ALTER ONLINE TABLE t DROP c", .mysql, .confirm("t")),
    Case("ALTER IGNORE TABLE t DROP c", .mysql, .confirm("t")),
    Case("ALTER TABLE t ADD COLUMN c int", .none),
    Case("ALTER TABLE \"\" DROP c", .unnamed),
    // MERGE ... THEN DELETE
    Case(
      "MERGE INTO t USING s ON t.id = s.id WHEN NOT MATCHED BY SOURCE THEN DELETE", .confirm("t")),
    Case("MERGE INTO t AS x USING s ON x.id = s.id WHEN MATCHED THEN DELETE", .confirm("t")),
    Case("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a", .none),
    Case(
      "WITH s AS (SELECT 1) MERGE INTO t USING s ON false WHEN NOT MATCHED BY SOURCE THEN DELETE",
      .unnamed),
    // DELETE / UPDATE without WHERE: named only through the single-table allow-list
    Case("DELETE FROM t", .confirm("t")),
    Case("DELETE FROM ONLY t", .confirm("t")),
    Case("DELETE FROM t AS x RETURNING *", .confirm("t")),
    Case("DELETE FROM main.t", .sqlite, .confirm("main.t")),
    Case("DELETE FROM t WHERE id = 1", .none),
    Case("UPDATE t SET a = 1", .confirm("t")),
    Case("UPDATE ONLY s.t AS x SET a = 1 RETURNING a", .confirm("s.t")),
    Case("UPDATE t SET a = 1 WHERE id = 1", .none),
    Case("UPDATE t SET a = 1 FROM u", .unnamed),
    Case("WITH x AS (SELECT 1) DELETE FROM t", .unnamed),
    Case("DELETE FROM t USING u", .unnamed),
    Case("DELETE t1, t2 FROM t1 JOIN t2 ON t1.id = t2.id", .mysql, .unnamed),
    Case("DELETE FROM t1, t2 USING t1 JOIN t2 ON t1.id = t2.id", .mysql, .unnamed),
    Case("DELETE LOW_PRIORITY QUICK IGNORE FROM t", .mysql, .unnamed),
    Case("UPDATE LOW_PRIORITY t SET a = 1", .mysql, .unnamed),
    Case("UPDATE t1 JOIN t2 ON t1.id = t2.id SET t1.a = t2.a", .mysql, .unnamed),
    Case("UPDATE t1, t2 SET t1.a = t2.a", .mysql, .unnamed),
    Case("UPDATE OR REPLACE t SET a = 1", .sqlite, .unnamed),
    // EXPLAIN, read from the classifier's result
    Case("EXPLAIN ANALYZE DELETE FROM t", .unnamed),
    Case("EXPLAIN ANALYSE DELETE FROM t", .unnamed),
    Case("EXPLAIN (ANALYZE) UPDATE t SET a = 1 WHERE id = 1", .unnamed),
    Case("EXPLAIN (ANALYZE false) DELETE FROM t", .none),
    Case("EXPLAIN DELETE FROM t", .none),
    Case("EXPLAIN SELECT 1", .none),
    Case("EXPLAIN ANALYZE SELECT 1", .none),
    Case("EXPLAIN ANALYZE FROBNICATE t", .unnamed),
    Case("EXPLAIN MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE", .none),
    Case("EXPLAIN ANALYZE MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE", .unnamed),
    // ClickHouse statements the classifier marks destructive name their table
    Case("ALTER TABLE t DELETE WHERE 1", .clickhouse, .confirm("t")),
    Case("ALTER TABLE db.t ON CLUSTER c CLEAR COLUMN c", .clickhouse, .confirm("db.t")),
    Case("ALTER TABLE `t` REPLACE PARTITION 202401 FROM t2", .clickhouse, .confirm("t")),
    Case("REPLACE TABLE t (a UInt8) ENGINE = Memory", .clickhouse, .confirm("t")),
    Case("OPTIMIZE TABLE t FINAL DEDUPLICATE", .clickhouse, .confirm("t")),
    Case("ALTER TABLE t UPDATE c = 1 WHERE 1", .clickhouse, .none),
    Case("ALTER TABLE t (DELETE WHERE id < 3)", .clickhouse, .confirm("t")),
    Case("ALTER TABLE t (DROP COLUMN c)", .clickhouse, .confirm("t")),
    Case("ALTER TABLE t (CLEAR COLUMN c IN PARTITION p)", .clickhouse, .confirm("t")),
    Case("DETACH TABLE t", .clickhouse, .none),
    Case("ALTER TABLE t DELETE WHERE 1", .none),
    // A PARALLEL WITH chain, or a TRUNCATE of every table, names no single object
    Case("DROP TABLE scratch PARALLEL WITH DROP TABLE orders", .clickhouse, .unnamed),
    Case("SELECT 1 PARALLEL WITH DROP TABLE orders", .clickhouse, .unnamed),
    Case("(DROP TABLE scratch) PARALLEL WITH DROP TABLE orders", .clickhouse, .unnamed),
    Case("TRUNCATE TEMPORARY TABLE t", .clickhouse, .confirm("t")),
    Case("TRUNCATE ALL TABLES FROM db", .clickhouse, .unnamed),
    Case("TRUNCATE TABLES FROM db LIKE 'tmp%'", .clickhouse, .unnamed),
    Case("TRUNCATE DATABASE db", .clickhouse, .unnamed),
    Case("TRUNCATE TABLE t", .clickhouse, .confirm("t")),
    Case("TRUNCATE database", .confirm("database")),
    // MongoDB (unchanged)
    Case("db.orders.drop()", .mongodb, .confirm("orders")),
    Case("db.dropDatabase()", .mongodb, .confirm("db")),
    Case("db.logs.deleteMany({})", .mongodb, .confirm("logs")),
    Case("db.logs.dropIndex(\"a_1\")", .mongodb, .confirm("a_1")),
    Case("db.logs.dropIndex({a: 1})", .mongodb, .unnamed),
    Case("db.logs.deleteMany({level: \"debug\"})", .mongodb, .none),
    Case("db.logs.updateMany({}, {$set: {a: 1}})", .mongodb, .none),
  ]

  @Test("Each statement gets its verdict", arguments: cases)
  func verdict(_ testCase: Case) throws {
    let statement = try #require(
      SQLStatementClassifier.classifyStatement(testCase.text, dialect: testCase.dialect))
    #expect(
      DestructiveStatementRule.evaluate(statement, dialect: testCase.dialect, database: "db")
        == testCase.expected)
  }

  @Test("A statement the classifier cannot read (not an EXPLAIN) is left to the caller")
  func unknownStatement() throws {
    let statement = try #require(
      SQLStatementClassifier.classifyStatement("PREPARE p AS DELETE FROM t"))
    #expect(statement.kind == .unknown)
    #expect(DestructiveStatementRule.evaluate(statement, dialect: .postgresql) == .none)
  }
}
