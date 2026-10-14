// MySQLCatalogTests.swift
// Pure MySQL catalog helpers, no server: the `mysql:` table identity keeps database and table
// apart even when either holds a dot or a backtick; columns by relation (primary key, unique,
// identity, generated); the primary key ignores functional key parts; foreign keys group
// composite keys in key order; display types; UPDATE / DELETE rules; the column ordinal cache
// refuses a write from a read started before it was cleared; MySQL's escaped expression text
// (every `\` and `'` escaped) is unescaped back to SQL, and MariaDB's plain SQL is kept.

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
