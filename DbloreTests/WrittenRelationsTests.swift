// WrittenRelationsTests.swift
// The tables a statement that ran writes, per dialect (quoting, schema qualification and the
// default schema), the shapes that write none, and what a run's transaction control does to them.

import Foundation
import Testing

@testable import Dblore

@Suite("Written relations")
struct WrittenRelationsTests {
  private typealias Relation = WrittenRelations.Relation

  private func written(
    _ sql: String, _ dialect: SQLDialect = .postgresql, defaultSchema: String = "public"
  ) -> [Relation] {
    WrittenRelations.relations(writtenBy: sql, dialect: dialect, defaultSchema: defaultSchema)
  }

  private func relation(_ schema: String, _ name: String) -> Relation {
    Relation(schema: schema, name: name)
  }

  // MARK: - PostgreSQL

  @Test("PostgreSQL: each write shape names its target in the default schema")
  func postgresShapes() {
    let users = [relation("public", "users")]
    #expect(written("INSERT INTO users (id) VALUES (1)") == users)
    #expect(written("UPDATE users SET name = 'a' WHERE id = 1") == users)
    #expect(
      written("UPDATE ONLY users AS u SET name = 'a' FROM teams t WHERE t.id = u.id") == users)
    #expect(written("DELETE FROM users WHERE id = 1") == users)
    #expect(written("DELETE FROM ONLY users USING teams, roles WHERE true") == users)
    #expect(
      written("MERGE INTO users u USING src s ON u.id = s.id WHEN MATCHED THEN DELETE") == users)
    #expect(written("ALTER TABLE IF EXISTS ONLY users ADD COLUMN x int") == users)
  }

  @Test("PostgreSQL: unquoted names fold to lower case, quoted names keep theirs")
  func postgresQuoting() {
    #expect(written("UPDATE Sales.Orders SET x = 1") == [relation("sales", "orders")])
    #expect(
      written(#"UPDATE "Sales"."Order ""Items""" SET x = 1"#) == [
        relation("Sales", "Order \"Items\"")
      ])
    #expect(written(#"INSERT INTO db.app."Users" VALUES (1)"#) == [relation("app", "Users")])
  }

  @Test("PostgreSQL: TRUNCATE and DROP TABLE name every table")
  func postgresSeveralTables() {
    #expect(
      written("TRUNCATE TABLE ONLY a, b * RESTART IDENTITY CASCADE")
        == [relation("public", "a"), relation("public", "b")])
    #expect(written("TRUNCATE a") == [relation("public", "a")])
    #expect(
      written("DROP TABLE IF EXISTS a, s.b CASCADE")
        == [relation("public", "a"), relation("s", "b")])
  }

  @Test("WITH: the main statement's target, not a table the CTEs read")
  func withMainStatement() {
    #expect(
      written("WITH src AS (SELECT * FROM a) INSERT INTO b SELECT * FROM src")
        == [relation("public", "b")])
    #expect(
      written("WITH RECURSIVE r (n) AS (SELECT 1) UPDATE c SET v = 1 FROM r")
        == [relation("public", "c")])
    #expect(written("WITH d AS (SELECT 1) DELETE FROM e") == [relation("public", "e")])
    #expect(written("WITH s AS (SELECT * FROM a) SELECT * FROM s").isEmpty)
  }

  @Test("EXPLAIN ANALYZE runs the statement; plain EXPLAIN writes nothing")
  func explain() {
    #expect(written("EXPLAIN ANALYZE UPDATE t SET v = 1") == [relation("public", "t")])
    #expect(written("EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t") == [relation("public", "t")])
    #expect(written("EXPLAIN UPDATE t SET v = 1").isEmpty)
  }

  @Test("CALL, DO, SELECT, a function call and transaction control write no relation")
  func shapesWithoutTarget() {
    #expect(written("CALL refresh_totals()").isEmpty)
    #expect(written("DO $$ BEGIN UPDATE t SET v = 1; END $$").isEmpty)
    #expect(written("SELECT * FROM t").isEmpty)
    #expect(written("SELECT archive_rows('t')").isEmpty)
    #expect(written("COMMIT").isEmpty)
    #expect(written("CREATE TABLE t (id int)").isEmpty)
    #expect(written("CALL p()", .mysql, defaultSchema: "shop").isEmpty)
  }

  // MARK: - MySQL

  @Test("MySQL: backticks, ANSI quotes, modifiers, optional INTO and the connected database")
  func mysqlShapes() {
    let orders = [relation("shop", "orders")]
    #expect(written("INSERT IGNORE orders VALUES (1)", .mysql, defaultSchema: "shop") == orders)
    #expect(written("REPLACE INTO `orders` VALUES (1)", .mysql, defaultSchema: "shop") == orders)
    #expect(
      written("UPDATE LOW_PRIORITY `shop`.`orders` SET x = 1", .mysql, defaultSchema: "other")
        == orders)
    #expect(
      written(#"DELETE QUICK FROM "orders" WHERE id = 1"#, .mysql, defaultSchema: "shop")
        == orders)
    #expect(
      written("ALTER IGNORE TABLE orders ADD COLUMN x INT", .mysql, defaultSchema: "shop")
        == orders)
    #expect(
      written("DROP TEMPORARY TABLE IF EXISTS orders, `b`", .mysql, defaultSchema: "shop")
        == orders + [relation("shop", "b")])
  }

  @Test("MySQL: multi-table UPDATE and DELETE name no target")
  func mysqlMultiTable() {
    #expect(written("UPDATE a, b SET a.x = b.x", .mysql, defaultSchema: "shop").isEmpty)
    #expect(
      written("UPDATE a JOIN b ON a.id = b.id SET a.x = 1", .mysql, defaultSchema: "shop")
        .isEmpty)
    #expect(written("DELETE a FROM a JOIN b ON a.id = b.id", .mysql, defaultSchema: "s").isEmpty)
    #expect(written("DELETE FROM a, b USING a JOIN b", .mysql, defaultSchema: "s").isEmpty)
    #expect(written("DELETE FROM a USING a JOIN b", .mysql, defaultSchema: "s").isEmpty)
  }

  // MARK: - SQLite and DuckDB

  @Test("SQLite: OR clauses, quoting styles and the main schema")
  func sqliteShapes() {
    let items = [relation("main", "items")]
    #expect(
      written("INSERT OR REPLACE INTO items VALUES (1)", .sqlite, defaultSchema: "main") == items)
    #expect(written("REPLACE INTO [items] VALUES (1)", .sqlite, defaultSchema: "main") == items)
    #expect(written("UPDATE OR IGNORE `items` SET x = 1", .sqlite, defaultSchema: "main") == items)
    #expect(
      written(#"DELETE FROM "temp"."items""#, .sqlite, defaultSchema: "main")
        == [relation("temp", "items")])
  }

  @Test("DuckDB: qualified and unqualified targets")
  func duckdbShapes() {
    #expect(
      written("INSERT OR IGNORE INTO t BY NAME SELECT 1 AS id", .duckdb, defaultSchema: "main")
        == [relation("main", "t")])
    #expect(
      written("TRUNCATE lake.sales.t", .duckdb, defaultSchema: "main")
        == [relation("sales", "t")])
  }

  // MARK: - Matching a data viewer

  @Test("PostgreSQL matches case for case; other engines ignore case")
  func matching() {
    let folded = relation("public", "orders")
    #expect(folded.matches(schema: "public", name: "orders", dialect: .postgresql))
    #expect(!folded.matches(schema: "public", name: "Orders", dialect: .postgresql))
    #expect(!folded.matches(schema: "sales", name: "orders", dialect: .postgresql))
    let mysql = relation("shop", "ORDERS")
    #expect(mysql.matches(schema: "Shop", name: "orders", dialect: .mysql))
    #expect(relation("main", "items").matches(schema: "MAIN", name: "Items", dialect: .sqlite))
    #expect(!relation("main", "items").matches(schema: "main", name: "item", dialect: .duckdb))
  }

  // MARK: - Transaction outcome

  private func outcome(
    _ statements: [String], dialect: SQLDialect = .postgresql, defaultSchema: String = "public",
    openBefore: Bool = false, openAfter: Bool
  ) async -> WrittenRelations.Outcome {
    WrittenRelations.outcome(
      of: await WrittenRelations.steps(
        of: statements, dialect: dialect, defaultSchema: defaultSchema),
      transactionOpenBefore: openBefore, transactionOpenAfter: openAfter)
  }

  @Test("Autocommitted writes are committed; writes in an open transaction are pending")
  func outcomeOpenOrIdle() async {
    let idle = await outcome(["UPDATE a SET v = 1"], openAfter: false)
    #expect(idle.committed == [relation("public", "a")])
    #expect(idle.pending.isEmpty)
    #expect(idle.earlier == .committed)
    let open = await outcome(["UPDATE a SET v = 1"], openAfter: true)
    #expect(open.committed.isEmpty)
    #expect(open.pending == [relation("public", "a")])
    #expect(open.earlier == .pending)
  }

  @Test("Transaction control decides for what ran before it")
  func outcomeBoundaries() async {
    let begun = await outcome(
      ["UPDATE a SET v = 1", "BEGIN", "UPDATE b SET v = 1"], openAfter: true)
    #expect(begun.committed == [relation("public", "a")])
    #expect(begun.pending == [relation("public", "b")])

    let rolledBack = await outcome(["BEGIN", "UPDATE a SET v = 1", "ROLLBACK"], openAfter: false)
    #expect(rolledBack.committed.isEmpty && rolledBack.pending.isEmpty)
    #expect(rolledBack.earlier == .committed)

    let committed = await outcome(["UPDATE a SET v = 1", "COMMIT"], openAfter: false)
    #expect(committed.committed == [relation("public", "a")])
    #expect(committed.earlier == .committed)

    let earlierDropped = await outcome(["ROLLBACK"], openBefore: true, openAfter: false)
    #expect(earlierDropped.earlier == .rolledBack)

    let afterCommit = await outcome(
      ["BEGIN", "UPDATE a SET v = 1", "COMMIT", "UPDATE b SET v = 1"], openAfter: false)
    #expect(afterCommit.committed == [relation("public", "a"), relation("public", "b")])
  }

  @Test("A ROLLBACK drops writes only back to a transaction known open")
  func outcomeRollbackScope() async {
    // No transaction: the UPDATE autocommitted, the ROLLBACK undid nothing
    let noTransaction = await outcome(["UPDATE a SET v = 1", "ROLLBACK"], openAfter: false)
    #expect(noTransaction.committed == [relation("public", "a")])

    let openBefore = await outcome(
      ["UPDATE a SET v = 1", "ROLLBACK"], openBefore: true, openAfter: false)
    #expect(openBefore.committed.isEmpty)
    #expect(openBefore.earlier == .rolledBack)

    let backToBegin = await outcome(
      ["UPDATE a SET v = 1", "BEGIN", "UPDATE b SET v = 1", "ROLLBACK", "UPDATE c SET v = 1"],
      openAfter: false)
    #expect(backToBegin.committed == [relation("public", "a"), relation("public", "c")])
  }

  @Test("ROLLBACK TO SAVEPOINT keeps the transaction open")
  func outcomeSavepoint() async {
    let open = await outcome(["UPDATE a SET v = 1", "ROLLBACK TO SAVEPOINT s"], openAfter: true)
    #expect(open.pending == [relation("public", "a")])

    let thenRolledBack = await outcome(
      ["BEGIN", "UPDATE a SET v = 1", "ROLLBACK TO SAVEPOINT s", "ROLLBACK"], openAfter: false)
    #expect(thenRolledBack.committed.isEmpty && thenRolledBack.pending.isEmpty)
  }

  @Test("A MySQL implicit commit commits what ran before it, and itself")
  func outcomeImplicitCommit() async {
    let result = await outcome(
      ["UPDATE a SET v = 1", "ALTER TABLE b ADD COLUMN c INT"], dialect: .mysql,
      defaultSchema: "shop", openAfter: false)
    #expect(result.committed == [relation("shop", "a"), relation("shop", "b")])
    #expect(result.earlier == .committed)

    // The ALTER committed the transaction: the ROLLBACK after it undoes nothing
    let inTransaction = await outcome(
      ["BEGIN", "UPDATE a SET v = 1", "ALTER TABLE b ADD COLUMN c INT", "ROLLBACK"],
      dialect: .mysql, defaultSchema: "shop", openAfter: false)
    #expect(inTransaction.committed == [relation("shop", "a"), relation("shop", "b")])
  }

  @Test("A MySQL implicit commit's own target is committed while a transaction stays open")
  func outcomeImplicitCommitNeverPending() async {
    let alone = await outcome(
      ["ALTER TABLE b ADD COLUMN c INT"], dialect: .mysql, defaultSchema: "shop", openAfter: true)
    #expect(alone.committed == [relation("shop", "b")])
    #expect(alone.pending.isEmpty)

    let afterBegin = await outcome(
      ["BEGIN", "UPDATE a SET v = 1", "TRUNCATE TABLE b", "UPDATE c SET v = 1"],
      dialect: .mysql, defaultSchema: "shop", openAfter: true)
    #expect(afterBegin.committed == [relation("shop", "a"), relation("shop", "b")])
    #expect(afterBegin.pending == [relation("shop", "c")])
  }

  // MARK: - Failed scripts

  @Test("A failed script: one statement wrote nothing; a script counts its writes")
  func failedScripts() async {
    let failure = DatabaseError.queryFailed("boom", 0)
    #expect(
      await WrittenRelations.statementsMaybeRun(
        failedScript: "UPDATE a SET v = 1", error: failure, dialect: .postgresql
      ).isEmpty)
    #expect(
      await WrittenRelations.statementsMaybeRun(
        failedScript: "UPDATE a SET v = 1; ROLLBACK; UPDATE b SET v = 1", error: failure,
        dialect: .postgresql) == ["UPDATE a SET v = 1", "UPDATE b SET v = 1"])
    let refused = DatabaseError.blockedByProtection(statementIndex: 1, kind: .dml, reason: "no")
    #expect(
      await WrittenRelations.statementsMaybeRun(
        failedScript: "UPDATE a SET v = 1; UPDATE b SET v = 1", error: refused,
        dialect: .postgresql
      ).isEmpty)
  }

  @Test("A failed script keeps its BEGIN: the writes before it were committed")
  func failedScriptKeepsBegin() async {
    let ran = await WrittenRelations.statementsMaybeRun(
      failedScript: "UPDATE a SET v = 1; BEGIN; UPDATE b SET v = 1; SELECT 1/0",
      error: DatabaseError.queryFailed("division by zero", 0), dialect: .postgresql)
    #expect(ran == ["UPDATE a SET v = 1", "BEGIN", "UPDATE b SET v = 1", "SELECT 1/0"])
    // The session is left in the aborted, still open transaction
    let result = await outcome(ran, openAfter: true)
    #expect(result.committed == [relation("public", "a")])
    #expect(result.pending == [relation("public", "b")])
  }

  // MARK: - Large statements

  @Test("A multi-MB statement is read from its head: same target")
  func largeStatement() {
    let rows = Array(repeating: "(1, 'x')", count: 200_000).joined(separator: ", ")
    #expect(written("INSERT INTO big (id, v) VALUES \(rows)") == [relation("public", "big")])
    #expect(written("UPDATE big SET v = 'x' WHERE id IN (\(rows))") == [relation("public", "big")])
  }

  @Test("A long script has the outcome of its short form; reads give no step")
  func longScript() async {
    let tail = ["BEGIN", "UPDATE b SET v = 1", "ROLLBACK"]
    let long = await outcome(
      Array(repeating: "UPDATE a SET v = 1", count: 20_000) + tail, openAfter: false)
    #expect(long == (await outcome(["UPDATE a SET v = 1"] + tail, openAfter: false)))
    #expect(long.committed == [relation("public", "a")])
    let reads = await WrittenRelations.steps(
      of: Array(repeating: "SELECT * FROM t LIMIT 100", count: 1_000), dialect: .postgresql,
      defaultSchema: "public")
    #expect(reads.isEmpty)
  }

  @Test("A target past the head is read from the whole statement")
  func targetPastHead() {
    let padding = String(repeating: "x", count: WrittenRelations.headLength)
    // A WITH whose CTE bodies are longer than the head
    #expect(
      written("WITH v AS (SELECT '\(padding)' AS p) INSERT INTO t SELECT p FROM v")
        == [relation("public", "t")])
    #expect(
      written("EXPLAIN ANALYZE WITH v AS (SELECT '\(padding)') DELETE FROM t")
        == [relation("public", "t")])
    #expect(written("/* \(padding) */ UPDATE t SET v = 1") == [relation("public", "t")])
    let names = (0..<2_000).map { "table_\($0)" }
    #expect(written("DROP TABLE " + names.joined(separator: ", ")).count == 2_000)
    // The head ends right after `a.b.`: the name goes on past it
    let lead = "INSERT INTO /*" + String(repeating: "x", count: WrittenRelations.headLength - 21)
    let cut = lead + "*/ a.b."
    #expect(cut.unicodeScalars.count == WrittenRelations.headLength)
    #expect(written(cut + "c VALUES (1)") == [relation("b", "c")])
  }
}
