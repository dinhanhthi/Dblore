// MySQLCatalogTests.swift
// Pure MySQL catalog helpers, no server: the `mysql:` table identity keeps database and table
// apart even when either holds a dot or a backtick; columns by relation (primary key, unique,
// identity, generated); the primary key ignores functional key parts; foreign keys group
// composite keys in key order; display types; UPDATE / DELETE rules; the column ordinal cache
// refuses a write from a read started before it was cleared; MySQL's escaped expression text
// (every `\` and `'` escaped) is unescaped back to SQL, and MariaDB's plain SQL is kept; the
// next AUTO_INCREMENT and the table character set come from SHOW CREATE TABLE and the catalog.
// Against a scripted session: the table structure never needs SHOW CREATE TABLE and its refusal
// only leaves AUTO_INCREMENT unknown; MariaDB 10.10+ lists collations by full name per set.

import Foundation
import Testing

@testable import Dblore

@MainActor
struct MySQLCatalogTests {
  // MARK: - Table identity

  @Test("Database and table names with a dot or a backtick give distinct identities")
  func identityIsUnambiguous() {
    let pairs: [((String, String), (String, String))] = [
      (("a.b", "c"), ("a", "b.c")),
      (("dblore_test.dot", "c"), ("dblore_test", "dot.c")),
      (("a`", "b"), ("a", "`b")),
      (("a`.`b", "c"), ("a", "b`.`c")),
    ]
    for (first, second) in pairs {
      #expect(
        TableRef.mysql(database: first.0, table: first.1)
          != TableRef.mysql(database: second.0, table: second.1), "\(first) vs \(second)")
    }
    #expect(
      TableRef.mysql(database: "db", table: "t") == TableRef.mysql(database: "db", table: "t"))
    #expect(
      TableRef.mysql(database: "db", table: "t") != TableRef.mysql(database: "db", table: "T"))
  }

  @Test("A MySQL identity is not read as a SQLite one")
  func identityIsNotSQLite() {
    #expect(TableRef.mysql(database: "main", table: "t").sqliteComponents == nil)
  }

  // MARK: - Column ordinal cache

  @Test("Clearing the ordinal cache bumps its generation and rejects reads started before")
  func cacheGenerationRejectsStaleWrite() {
    let id = TableRef.mysql(database: "db", table: "t")
    let columns = MySQLTableColumns(database: "db", table: "t", ordinals: ["id": 1])
    var cache = MySQLTableColumnsCache()
    let before = cache.generation
    let stored = cache.store(columns, for: id, readAt: before)
    #expect(stored)
    #expect(cache[id] == columns)

    cache.removeAll()
    #expect(cache.generation != before)
    #expect(cache[id] == nil)
    // A catalog read started before the clear may hold pre-DDL ordinals.
    let staleStored = cache.store(columns, for: id, readAt: before)
    #expect(!staleStored)
    #expect(cache[id] == nil)
    let freshStored = cache.store(columns, for: id, readAt: cache.generation)
    #expect(freshStored)
    #expect(cache[id] == columns)
  }

  // MARK: - Columns by relation

  @Test("Primary key, unique, identity and generated flags from literal rows")
  func columnsByRelationFlags() throws {
    let rows = [
      column("t", "id", "int", extra: "auto_increment"),
      column("t", "email", "varchar(50)"),
      column("t", "code", "varchar(255)"),
      column("t", "pair_a", "int"),
      column("t", "pair_b", "int"),
      column("t", "created", "datetime", extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"),
      column("t", "v", "int", extra: "VIRTUAL GENERATED"),
      column("t", "s", "int", extra: "STORED GENERATED"),
      column("t", "p", "int", extra: "PERSISTENT GENERATED"),
      column("u", "id", "int"),
      column("u", "kind", "enum('A','b')"),
    ]
    let keys = [
      key("t", "PRIMARY", "id"),
      key("t", "uq_email", "email"),
      key("t", "uq_code", "code", isPrefix: true),
      key("t", "uq_pair", "pair_a"),
      key("t", "uq_pair", "pair_b"),
      key("t", "uq_id", "id"),
      key("t", "uq_expr", nil),
      key("u", "uq_id", "id"),
    ]
    let byRelation = MySQLCatalog.columnsByRelation(rows, keys: keys, database: "db")
    #expect(Set(byRelation.keys) == ["db.t", "db.u"])
    let t = try #require(byRelation["db.t"])
    #expect(t.map(\.name) == rows.filter { $0.table == "t" }.map(\.name))
    let flags = Dictionary(uniqueKeysWithValues: t.map { ($0.name, $0) })
    #expect(flags["id"]?.isPrimaryKey == true)
    #expect(flags["id"]?.isIdentity == true)
    // Part of the primary key: never also unique.
    #expect(flags["id"]?.isUnique == false)
    #expect(flags["email"]?.isUnique == true)
    // Prefix and multi-column UNIQUE indexes do not make a column unique.
    #expect(flags["code"]?.isUnique == false)
    #expect(flags["pair_a"]?.isUnique == false)
    #expect(flags["pair_b"]?.isUnique == false)
    #expect(flags["created"]?.isGenerated == false)
    #expect(flags["v"]?.isGenerated == true)
    #expect(flags["s"]?.isGenerated == true)
    #expect(flags["p"]?.isGenerated == true)
    #expect(flags["email"]?.type == "VARCHAR(50)")

    let u = try #require(byRelation["db.u"])
    #expect(u.map(\.isPrimaryKey) == [false, false])
    #expect(u.first?.isUnique == true)
    #expect(u.last?.type == "enum('A','b')")
  }

  // MARK: - Primary key

  @Test("The primary key is the PRIMARY index of the table, in key order")
  func primaryKeyOrder() {
    let keys = [
      key("t", "PRIMARY", "b"),
      key("t", "PRIMARY", "a"),
      key("t", "uq", "c"),
      key("other", "PRIMARY", "x"),
    ]
    #expect(MySQLCatalog.primaryKey(keys, table: "t") == ["b", "a"])
    #expect(MySQLCatalog.primaryKey(keys, table: "other") == ["x"])
    // A table with only a UNIQUE index has no primary key.
    #expect(MySQLCatalog.primaryKey([key("t", "uq", "c")], table: "t").isEmpty)
    #expect(MySQLCatalog.primaryKey(keys, table: "T").isEmpty)
  }

  @Test("A functional key part has no column and is skipped")
  func primaryKeyFunctionalPart() {
    let keys = [key("t", "PRIMARY", "a"), key("t", "PRIMARY", nil)]
    #expect(MySQLCatalog.primaryKey(keys, table: "t") == ["a"])
  }

  // MARK: - Foreign keys

  @Test("Composite foreign keys keep key order; runs split by table and constraint")
  func foreignKeyGrouping() {
    let parts = [
      fk("fk_ab", "child", "b", "parent", "y", update: "CASCADE", delete: "RESTRICT"),
      fk("fk_ab", "child", "a", "parent", "x", update: "CASCADE", delete: "RESTRICT"),
      fk("fk_ab", "other", "c", "parent", "x", update: "NO ACTION", delete: "SET NULL"),
      fk("fk_d", "child", "d", "ref", "id", targetSchema: "elsewhere"),
    ]
    let keys = MySQLCatalog.foreignKeys(parts, database: "db")
    #expect(keys.count == 3)
    #expect(keys.map(\.constraintName) == ["fk_ab", "fk_ab", "fk_d"])
    #expect(keys.map(\.sourceTable) == ["child", "other", "child"])
    #expect(keys.allSatisfy { $0.sourceSchema == "db" })
    #expect(keys[0].sourceColumns == ["b", "a"])
    #expect(keys[0].targetColumns == ["y", "x"])
    #expect(keys[0].targetTable == "parent")
    #expect(keys[0].onUpdate == .cascade)
    #expect(keys[0].onDelete == .restrict)
    #expect(keys[1].onUpdate == .noAction)
    #expect(keys[1].onDelete == .setNull)
    #expect(keys[2].targetSchema == "elsewhere")
    #expect(MySQLCatalog.foreignKeys([], database: "db").isEmpty)
  }

  @Test("RESTRICT and NO ACTION stay apart; unknown rules read as NO ACTION")
  func foreignKeyRules() {
    #expect(ForeignKeyAction(mysqlRule: "RESTRICT") == .restrict)
    #expect(ForeignKeyAction(mysqlRule: "NO ACTION") == .noAction)
    #expect(ForeignKeyAction(mysqlRule: "CASCADE") == .cascade)
    #expect(ForeignKeyAction(mysqlRule: "set null") == .setNull)
    #expect(ForeignKeyAction(mysqlRule: "SET DEFAULT") == .setDefault)
    #expect(ForeignKeyAction(mysqlRule: "") == .noAction)
  }

  // MARK: - Generated and display type

  @Test("DEFAULT_GENERATED is an expression default, not a generated column")
  func generatedExtra() {
    #expect(!MySQLCatalog.isGenerated(extra: "DEFAULT_GENERATED"))
    #expect(!MySQLCatalog.isGenerated(extra: "auto_increment"))
    #expect(!MySQLCatalog.isGenerated(extra: ""))
    #expect(MySQLCatalog.isGenerated(extra: "virtual generated"))
    #expect(MySQLCatalog.isGenerated(extra: "STORED GENERATED"))
    #expect(MySQLCatalog.isGenerated(extra: "PERSISTENT GENERATED"))
  }

  // MARK: - Expression unescaping

  @Test(
    "Escaped quotes and backslashes are undone; text not in the escaped form is kept",
    arguments: [
      // An escaped literal holding a quote: _latin1'it\'s'
      (#"concat(_latin1\'it\\\'s\',_latin1\' \')"#, #"concat(_latin1'it\'s',_latin1' ')"#),
      // A check clause as CHECK_CONSTRAINTS prints it
      (#"(`a` <> _latin1\'it\\\'s\')"#, #"(`a` <> _latin1'it\'s')"#),
      // An escaped backslash: 'a\\b'
      (#"concat(_utf8mb4\'a\\\\b\')"#, #"concat(_utf8mb4'a\\b')"#),
      // A bare quote: already SQL
      (#"concat('it\'s', \'x\')"#, #"concat('it\'s', \'x\')"#),
      // A trailing backslash: not the escaped form
      (#"concat(\'x\')\"#, #"concat(\'x\')\"#),
      // Another escape passes through
      (#"concat(\'a\nb\')"#, #"concat('a\nb')"#),
      // No quotes or backslashes
      ("(`m` + 1)", "(`m` + 1)"),
    ])
  func unescapedExpression(printed: String, expected: String) {
    #expect(MySQLCatalog.unescapedExpression(printed) == expected)
  }

  @Test("MariaDB expression defaults are never unescaped")
  func mariaDBKept() {
    let printed = #"concat('it\'s','z')"#
    #expect(
      MySQLCatalog.defaultExpression(
        printed, dataType: "varchar", extra: "DEFAULT_GENERATED", isMariaDB: true) == printed)
    #expect(
      MySQLCatalog.defaultExpression(
        #"concat(_utf8mb4\'x\')"#, dataType: "varchar", extra: "DEFAULT_GENERATED",
        isMariaDB: true) == #"concat(_utf8mb4\'x\')"#)
  }

  // MARK: - Table options

  @Test("The next AUTO_INCREMENT is the table option of SHOW CREATE TABLE; none without it")
  func nextAutoIncrement() {
    let columns = """
      CREATE TABLE `t` (
        `id` int NOT NULL AUTO_INCREMENT COMMENT 'AUTO_INCREMENT=7',
        PRIMARY KEY (`id`)
      ) ENGINE=InnoDB
      """
    #expect(
      MySQLCatalog.nextAutoIncrement(
        createTable: columns
          + " AUTO_INCREMENT=1000 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci") == 1000)
    // The column attribute and a comment holding the text are not the table option
    #expect(
      MySQLCatalog.nextAutoIncrement(
        createTable: columns + " DEFAULT CHARSET=latin1 COMMENT='AUTO_INCREMENT=5'") == nil)
  }

  @Test("Table options: the collation's character set, else its name prefix")
  func tableOptionsFromRows() {
    #expect(
      MySQLCatalog.tableOptions(collation: "utf8mb4_bin", characterSet: "utf8mb4")
        == .init(characterSet: "utf8mb4", collation: "utf8mb4_bin"))
    // MariaDB lists UCA 14 collations without a set
    #expect(
      MySQLCatalog.tableOptions(collation: "utf8mb4_uca1400_ai_ci", characterSet: nil)
        == .init(characterSet: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci"))
  }

  @Test("A refused SHOW CREATE TABLE leaves AUTO_INCREMENT unknown and the structure readable")
  func refusedShowCreateTable() async throws {
    let session = ScriptedCatalogSession(
      answers: [
        (
          "FROM information_schema.TABLES t",
          [[.string(""), .string("latin1_bin"), .string("latin1")]]
        ),
        ("VERSION()", [[.string("8.4.3")]]),
      ], failing: ["SHOW CREATE TABLE"])
    let introspector = MySQLSchemaIntrospector(database: "db")
    let structure = try await introspector.tableStructure(schema: "db", table: "t", in: session)
    #expect(structure.tableOptions == .init(characterSet: "latin1", collation: "latin1_bin"))
    #expect(!session.statements.contains { $0.contains("SHOW CREATE TABLE") })
    #expect(try await introspector.nextAutoIncrement(schema: "db", table: "t", in: session) == nil)
  }

  @Test("MariaDB 10.10+ lists UCA 14 collations per set; COLLATIONS when that read fails")
  func mariaDBFullCollationNames() async throws {
    let answers: [(String, [[CellValue]])] = [
      ("VERSION()", [[.string("11.4.2-MariaDB")]]),
      ("CHARACTER_SETS", [[.string("utf8mb4"), .string("utf8mb4_general_ci")]]),
      (
        "COLLATION_CHARACTER_SET_APPLICABILITY",
        [
          [.string("utf8mb4_general_ci"), .string("utf8mb4")],
          [.string("utf8mb4_uca1400_ai_ci"), .string("utf8mb4")],
        ]
      ),
      (
        "information_schema.COLLATIONS",
        [[.string("utf8mb4_general_ci"), .string("utf8mb4")], [.string("uca1400_ai_ci"), .null]]
      ),
    ]
    let introspector = MySQLSchemaIntrospector(database: "db")
    let full = try await introspector.characterSets(in: ScriptedCatalogSession(answers: answers))
    #expect(full.contains(charset: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci"))
    let fallback = try await introspector.characterSets(
      in: ScriptedCatalogSession(
        answers: answers, failing: ["COLLATION_CHARACTER_SET_APPLICABILITY"]))
    #expect(fallback.characterSet(named: "utf8mb4")?.collations == ["utf8mb4_general_ci"])
  }

  // MARK: - Helpers

  private func column(
    _ table: String, _ name: String, _ type: String, nullable: Bool = true, extra: String = ""
  ) -> MySQLCatalog.ColumnRow {
    MySQLCatalog.ColumnRow(
      table: table, name: name, type: type, isNullable: nullable, extra: extra)
  }

  private func key(
    _ table: String, _ index: String, _ column: String?, isPrefix: Bool = false
  ) -> MySQLCatalog.KeyPart {
    MySQLCatalog.KeyPart(table: table, index: index, column: column, isPrefix: isPrefix)
  }

  private func fk(
    _ constraint: String, _ table: String, _ column: String, _ targetTable: String,
    _ targetColumn: String, targetSchema: String = "db", update: String = "NO ACTION",
    delete: String = "NO ACTION"
  ) -> MySQLCatalog.ForeignKeyPart {
    MySQLCatalog.ForeignKeyPart(
      constraint: constraint, table: table, column: column, targetSchema: targetSchema,
      targetTable: targetTable, targetColumn: targetColumn, updateRule: update,
      deleteRule: delete)
  }
}

/// A MySQL catalog session: each read answers the rows of the first entry its SQL contains (none
/// otherwise); a read containing a `failing` text throws `FakeQueryError`
private final class ScriptedCatalogSession: DatabaseSession, @unchecked Sendable {
  private let inner = FakeDatabaseSession(
    capabilities: .contract(), columns: [], rows: [], slowQueries: false)
  private let answers: [(String, [[CellValue]])]
  private let failing: [String]

  init(answers: [(String, [[CellValue]])], failing: [String] = []) {
    self.answers = answers
    self.failing = failing
  }

  /// Every read, in order
  var statements: [String] { inner.queries }

  var capabilities: DatabaseCapabilities { inner.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { inner.closeEvents }

  func open() async throws { try await inner.open() }
  func close() async { await inner.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    _ = try await inner.query(sql, binds: binds)
    if failing.contains(where: sql.contains) { throw FakeQueryError() }
    let rows = answers.first { sql.contains($0.0) }?.1 ?? []
    return SessionRowSource(
      columns: [],
      rows: AsyncThrowingStream { continuation in
        for row in rows { continuation.yield(row) }
        continuation.finish()
      })
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await inner.command(sql, binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await inner.openCursor(sql, binds: binds)
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    try await inner.fetch(cursor, maxRows: maxRows)
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    try await inner.closeCursor(cursor)
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await inner.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async { await inner.interrupt() }
  func formatError(_ error: Error) -> String { inner.formatError(error) }
}
