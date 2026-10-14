// StructureDDLBuilderTests.swift
// StructureDDLBuilder: exact DDL per engine and change kind, PostgreSQL statement order, MySQL
// full-definition restating and version/flavor choices, SQLite version gates and refusals,
// DuckDB refusal, and rejection of injected names and expressions.

import Foundation
import Testing

@testable import Dblore

@Suite("StructureDDLBuilderTests")
struct StructureDDLBuilderTests {
  private typealias Column = TableStructure.Column
  private typealias Constraint = TableStructure.Constraint

  // MARK: - Fixtures

  private static func column(
    _ ordinal: Int, _ name: String, _ type: String, nullable: Bool = true,
    default defaultExpression: String? = nil
  ) -> Column {
    Column(
      ordinal: ordinal, name: name, dataType: type, isNullable: nullable,
      defaultExpression: defaultExpression, identity: nil, generated: nil, comment: nil,
      columnType: nil, extra: nil, characterSet: nil, collation: nil)
  }

  private static let postgres: TableStructure = {
    var id = column(1, "id", "integer", nullable: false)
    id.identity = .always
    var total = column(4, "total", "numeric")
    total.generated = TableStructure.Generated(expression: "price * 2", isStored: true)
    return TableStructure(
      tableID: .postgresql(oid: 1), schema: "public", name: "items",
      columns: [id, column(2, "name", "text"), column(3, "price", "numeric", default: "0"), total],
      indexes: [],
      constraints: [Constraint(name: "items_pkey", kind: .primaryKey, columns: ["id"])])
  }()

  private static let mysql: TableStructure = {
    var id = column(1, "id", "int", nullable: false)
    id.columnType = "int unsigned"
    id.identity = .autoIncrement
    id.extra = "auto_increment"
    var title = column(2, "title", "varchar", nullable: false, default: "'none'")
    title.columnType = "varchar(50)"
    title.characterSet = "utf8mb4"
    title.collation = "utf8mb4_bin"
    title.comment = "it's"
    var updated = column(3, "updated_at", "timestamp", default: "CURRENT_TIMESTAMP")
    updated.columnType = "timestamp"
    updated.extra = "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"
    var token = column(4, "token", "varchar", nullable: false, default: "uuid()")
    token.columnType = "varchar(36)"
    token.extra = "DEFAULT_GENERATED"
    token.characterSet = "utf8mb4"
    token.collation = "utf8mb4_0900_ai_ci"
    var total = column(5, "total", "int")
    total.columnType = "int"
    total.extra = "STORED GENERATED"
    total.generated = TableStructure.Generated(expression: "(`id` * 2)", isStored: true)
    return TableStructure(
      tableID: .mysql(database: "shop", table: "orders"), schema: "shop", name: "orders",
      columns: [id, title, updated, token, total], indexes: [],
      constraints: [
        Constraint(name: "PRIMARY", kind: .primaryKey, columns: ["id"]),
        Constraint(name: "orders_chk_1", kind: .check("(`id` > 0)"), columns: []),
      ])
  }()

  private static let sqlite: TableStructure = {
    var generated = column(6, "gen", "INTEGER")
    generated.generated = TableStructure.Generated(expression: nil, isStored: false)
    let parent = TableStructure.ForeignKeyReference(
      schema: "main", table: "notes", columns: ["id"], onUpdate: .noAction, onDelete: .noAction)
    return TableStructure(
      tableID: .sqlite(schema: "main", table: "notes"), schema: "main", name: "notes",
      columns: [
        column(1, "id", "INTEGER", nullable: false), column(2, "body", "TEXT"),
        column(3, "tag", "TEXT"), column(4, "parent_id", "INTEGER"), column(5, "u", "TEXT"),
        generated,
      ],
      indexes: [
        TableStructure.Index(
          name: "notes_tag", keys: [.column("tag")], isUnique: false, isPrimary: false,
          method: nil, isPartial: false, predicate: nil)
      ],
      constraints: [
        Constraint(name: nil, kind: .primaryKey, columns: ["id"]),
        Constraint(name: nil, kind: .foreignKey(parent), columns: ["parent_id"]),
        Constraint(name: "u_unique", kind: .unique, columns: ["u"]),
      ])
  }()

  private static let mysql80 = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)

  private static func newColumn(
    _ name: String, _ type: String, nullable: Bool = true, default defaultExpression: String? = nil
  ) -> StructureChange {
    .addColumn(
      StructureChange.NewColumn(
        name: name, type: type, isNullable: nullable, defaultExpression: defaultExpression))
  }

  private static func index(
    _ name: String, _ columns: [String], unique: Bool = false, method: String? = nil
  ) -> StructureChange {
    .createIndex(
      StructureChange.NewIndex(name: name, columns: columns, isUnique: unique, method: method))
  }

  private func build(
    _ changes: [StructureChange], _ structure: TableStructure, _ engine: StructureDDLBuilder.Engine
  ) throws -> [String] {
    try StructureDDLBuilder.build(changes: changes, structure: structure, engine: engine)
  }

  // MARK: - Gate

  @Test("Every built statement passes the schema-change gate as one DDL statement")
  func builtStatementsPassTheGate() throws {
    let columnChanges: [StructureChange] = [
      Self.newColumn("note", "varchar(20)", nullable: false, default: "'x'"),
      .setDefault(column: "title", expression: "'it''s'"),
      .dropNotNull(column: "token"),
      .renameColumn(column: "title", newName: "heading"),
      Self.index("note_idx", ["note"]),
    ]
    let built: [(DatabaseType, [String])] = [
      (
        .postgresql,
        try build(
          [
            Self.newColumn("note", "text", default: "'x'"),
            .alterColumnType(column: "price", type: "numeric(10, 2)"),
            .addConstraint(Constraint(name: "positive", kind: .check("price > 0"), columns: [])),
            .renameColumn(column: "name", newName: "title"),
            Self.index("name_idx", ["name"]), .dropIndex(name: "old_idx"),
          ], Self.postgres, .postgresql)
      ),
      (.mysql, try build(columnChanges, Self.mysql, .mysql(Self.mysql80))),
      (
        .sqlite,
        try build(
          [
            Self.newColumn("note", "TEXT", default: "'x'"),
            .renameColumn(column: "tag", newName: "label"), .dropColumn(column: "body"),
            Self.index("body_idx", ["body"]), .dropIndex(name: "notes_tag"),
          ], Self.sqlite, .sqlite(libraryVersion: 3_035_000))
      ),
    ]
    for (type, statements) in built {
      #expect(!statements.isEmpty)
      #expect(
        DatabaseConnectionManager.schemaChangeRefusal(
          statements, databaseType: type, transactionOpen: false) == nil,
        "\(type): \(statements)")
    }
  }

  // MARK: - PostgreSQL

  @Test(
    "PostgreSQL: one statement per change kind",
    arguments: [
      (
        newColumn("note", "varchar(20)", nullable: false, default: "'x'"),
        #"ALTER TABLE "public"."items" ADD COLUMN "note" varchar(20) NOT NULL DEFAULT 'x'"#
      ),
      // Identity column: the type change is allowed
      (
        .alterColumnType(column: "id", type: "bigint"),
        #"ALTER TABLE "public"."items" ALTER COLUMN "id" TYPE bigint"#
      ),
      (
        .setDefault(column: "price", expression: "1.5"),
        #"ALTER TABLE "public"."items" ALTER COLUMN "price" SET DEFAULT 1.5"#
      ),
      (
        .dropDefault(column: "price"),
        #"ALTER TABLE "public"."items" ALTER COLUMN "price" DROP DEFAULT"#
      ),
      (
        .setNotNull(column: "name"),
        #"ALTER TABLE "public"."items" ALTER COLUMN "name" SET NOT NULL"#
      ),
      (
        .dropNotNull(column: "id"),
        #"ALTER TABLE "public"."items" ALTER COLUMN "id" DROP NOT NULL"#
      ),
      (.dropColumn(column: "price"), #"ALTER TABLE "public"."items" DROP COLUMN "price""#),
      (
        .renameColumn(column: "name", newName: "title"),
        #"ALTER TABLE "public"."items" RENAME COLUMN "name" TO "title""#
      ),
      (
        .addConstraint(Constraint(name: "positive", kind: .check("price > 0"), columns: [])),
        #"ALTER TABLE "public"."items" ADD CONSTRAINT "positive" CHECK (price > 0)"#
      ),
      (
        .addConstraint(Constraint(name: nil, kind: .unique, columns: ["name", "price"])),
        #"ALTER TABLE "public"."items" ADD UNIQUE ("name", "price")"#
      ),
      (
        .addConstraint(Constraint(name: nil, kind: .primaryKey, columns: ["id"])),
        #"ALTER TABLE "public"."items" ADD PRIMARY KEY ("id")"#
      ),
      (
        .addConstraint(
          Constraint(
            name: "owner_fk",
            kind: .foreignKey(
              TableStructure.ForeignKeyReference(
                schema: "public", table: "owners", columns: ["id"], onUpdate: .noAction,
                onDelete: .cascade)),
            columns: ["price"])),
        #"ALTER TABLE "public"."items" ADD CONSTRAINT "owner_fk" FOREIGN KEY ("price") REFERENCES "public"."owners" ("id") ON DELETE CASCADE"#
      ),
      (
        .dropConstraint(name: "items_pkey", kind: .primaryKey),
        #"ALTER TABLE "public"."items" DROP CONSTRAINT "items_pkey""#
      ),
      (
        index("items_name_idx", ["name"], unique: true, method: "btree"),
        #"CREATE UNIQUE INDEX "items_name_idx" ON "public"."items" USING btree ("name")"#
      ),
      (.dropIndex(name: "items_name_idx"), #"DROP INDEX "public"."items_name_idx""#),
    ] as [(StructureChange, String)])
  func postgresChange(change: StructureChange, expected: String) throws {
    #expect(try build([change], Self.postgres, .postgresql) == [expected])
  }

  @Test("PostgreSQL: drop indexes, one ALTER, create indexes, then each rename on its own")
  func postgresBatchOrder() throws {
    let changes: [StructureChange] = [
      .renameColumn(column: "name", newName: "title"),
      Self.index("name_idx", ["name"]),
      .addConstraint(Constraint(name: nil, kind: .unique, columns: ["price"])),
      .setNotNull(column: "price"),
      .dropIndex(name: "old_idx"),
      Self.newColumn("note", "text"),
      .dropColumn(column: "total"),
      .dropConstraint(name: "chk", kind: .check),
      .renameColumn(column: "price", newName: "cost"),
    ]
    #expect(
      try build(changes, Self.postgres, .postgresql) == [
        #"DROP INDEX "public"."old_idx""#,
        #"ALTER TABLE "public"."items" DROP CONSTRAINT "chk", DROP COLUMN "total", "#
          + #"ADD COLUMN "note" text, ALTER COLUMN "price" SET NOT NULL, ADD UNIQUE ("price")"#,
        #"CREATE INDEX "name_idx" ON "public"."items" ("name")"#,
        #"ALTER TABLE "public"."items" RENAME COLUMN "name" TO "title""#,
        #"ALTER TABLE "public"."items" RENAME COLUMN "price" TO "cost""#,
      ])
  }

  @Test("A default cannot be set on an identity or generated column")
  func defaultOnIdentityRefused() {
    for name in ["id", "total"] {
      #expect(throws: StructureDDLError.self) {
        try build([.setDefault(column: name, expression: "1")], Self.postgres, .postgresql)
      }
    }
  }

  @Test("A change on a column the table does not have throws")
  func unknownColumn() {
    #expect(throws: StructureDDLError.unknownColumn("nope")) {
      try build([.dropColumn(column: "nope")], Self.postgres, .postgresql)
    }
  }

  // MARK: - Injection

  @Test("Quotes and backticks in names are escaped")
  func namesAreQuoted() throws {
    #expect(
      try build([Self.newColumn(#"we"ird"#, "int")], Self.postgres, .postgresql) == [
        #"ALTER TABLE "public"."items" ADD COLUMN "we""ird" int"#
      ])
    #expect(
      try build([.dropColumn(column: "id")], Self.mysql, .mysql(Self.mysql80)).first?.hasSuffix(
        "DROP COLUMN `id`") == true)
    #expect(
      try build([Self.newColumn("a`b", "int")], Self.mysql, .mysql(Self.mysql80)) == [
        "ALTER TABLE `shop`.`orders` ADD COLUMN `a``b` int NULL"
      ])
  }

  @Test(
    "Expressions and type text that could end or extend the statement are rejected",
    arguments: [
      "1); DROP TABLE x; --", "1; DROP TABLE x", "1, DROP COLUMN id", "0) , (1", "(1",
      "1)", "'unterminated", "1 -- trailing", "1 /* c */", "", "  ", "$$open",
    ])
  func postgresExpressionRejected(text: String) {
    #expect(throws: StructureDDLError.self) {
      try build([.setDefault(column: "price", expression: text)], Self.postgres, .postgresql)
    }
    #expect(throws: StructureDDLError.self) {
      try build([.alterColumnType(column: "price", type: text)], Self.postgres, .postgresql)
    }
    #expect(throws: StructureDDLError.self) {
      try build(
        [.addConstraint(Constraint(name: "c", kind: .check(text), columns: []))],
        Self.postgres, .postgresql)
    }
  }

  @Test("Strings, nested parentheses and commas inside them are accepted")
  func expressionAccepted() throws {
    #expect(
      try build(
        [.setDefault(column: "name", expression: "'a; b -- c'")], Self.postgres, .postgresql) == [
          #"ALTER TABLE "public"."items" ALTER COLUMN "name" SET DEFAULT 'a; b -- c'"#
        ])
    #expect(
      try build(
        [.alterColumnType(column: "price", type: "numeric(10, 2)")], Self.postgres, .postgresql)
        == [#"ALTER TABLE "public"."items" ALTER COLUMN "price" TYPE numeric(10, 2)"#])
  }

  @Test("MySQL: a # comment and a backslash-escaped unterminated string are rejected")
  func mysqlExpressionRejected() {
    for text in ["1 # x", #"'a\'"#] {
      #expect(throws: StructureDDLError.self) {
        try build(
          [.setDefault(column: "title", expression: text)], Self.mysql, .mysql(Self.mysql80))
      }
    }
  }

  @Test("NUL and other control characters are rejected; tab, newline and return are kept")
  func controlCharactersRejected() throws {
    for text in ["1\u{0}", "'a\u{0}b'", "1\u{1B}", "1\u{7}"] {
      #expect(throws: StructureDDLError.self) {
        try build([.setDefault(column: "price", expression: text)], Self.postgres, .postgresql)
      }
    }
    #expect(
      try build(
        [.setDefault(column: "price", expression: "1\t+\r\n2")], Self.postgres, .postgresql)
        == ["ALTER TABLE \"public\".\"items\" ALTER COLUMN \"price\" SET DEFAULT 1\t+\r\n2"])
  }

  @Test("An index method must be a single word")
  func indexMethodValidated() {
    #expect(throws: StructureDDLError.self) {
      try build([Self.index("i", ["name"], method: "btree (id); --")], Self.postgres, .postgresql)
    }
  }

  // MARK: - MySQL

  @Test(
    "MySQL: MODIFY restates the full loaded definition, changing only the edited part",
    arguments: [
      (
        .dropNotNull(column: "title"),
        "MODIFY COLUMN `title` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL "
          + "DEFAULT 'none' COMMENT 'it''s'"
      ),
      (
        .alterColumnType(column: "id", type: "bigint unsigned"),
        "MODIFY COLUMN `id` bigint unsigned NOT NULL AUTO_INCREMENT"
      ),
      (
        .dropDefault(column: "updated_at"),
        "MODIFY COLUMN `updated_at` timestamp NULL ON UPDATE CURRENT_TIMESTAMP"
      ),
      (
        .setDefault(column: "updated_at", expression: "'2020-01-01 00:00:00'"),
        "MODIFY COLUMN `updated_at` timestamp NULL DEFAULT '2020-01-01 00:00:00' "
          + "ON UPDATE CURRENT_TIMESTAMP"
      ),
      // An expression default reads back unparenthesized; it is restated in parentheses
      (
        .alterColumnType(column: "token", type: "varchar(64)"),
        "MODIFY COLUMN `token` varchar(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci "
          + "NOT NULL DEFAULT (uuid())"
      ),
      // A non-character type drops the character set and collation
      (
        .alterColumnType(column: "title", type: "int"),
        "MODIFY COLUMN `title` int NOT NULL DEFAULT 'none' COMMENT 'it''s'"
      ),
      (
        .setNotNull(column: "total"),
        "MODIFY COLUMN `total` int GENERATED ALWAYS AS ((`id` * 2)) STORED NOT NULL"
      ),
      (.dropConstraint(name: "PRIMARY", kind: .primaryKey), "DROP PRIMARY KEY"),
      (.dropConstraint(name: "uq", kind: .unique), "DROP INDEX `uq`"),
      (.dropConstraint(name: "fk", kind: .foreignKey), "DROP FOREIGN KEY `fk`"),
      (.dropConstraint(name: "orders_chk_1", kind: .check), "DROP CHECK `orders_chk_1`"),
      (
        .addConstraint(
          Constraint(
            name: "fk",
            kind: .foreignKey(
              TableStructure.ForeignKeyReference(
                schema: "shop", table: "users", columns: ["id"], onUpdate: .cascade,
                onDelete: .setNull)),
            columns: ["id"])),
        "ADD CONSTRAINT `fk` FOREIGN KEY (`id`) REFERENCES `shop`.`users` (`id`) "
          + "ON UPDATE CASCADE ON DELETE SET NULL"
      ),
      (
        index("i", ["title"], unique: true, method: "BTREE"),
        "ADD UNIQUE INDEX `i` (`title`) USING BTREE"
      ),
      (.dropIndex(name: "i"), "DROP INDEX `i`"),
    ] as [(StructureChange, String)])
  func mysqlChange(change: StructureChange, expected: String) throws {
    #expect(
      try build([change], Self.mysql, .mysql(Self.mysql80)) == [
        "ALTER TABLE `shop`.`orders` " + expected
      ])
  }

  @Test("MySQL: every change goes in one ALTER TABLE; a rename plus an edit is one CHANGE")
  func mysqlSingleAlter() throws {
    let changes: [StructureChange] = [
      .renameColumn(column: "title", newName: "name"),
      Self.index("idx_name", ["title"]),
      .addConstraint(Constraint(name: "uq", kind: .unique, columns: ["token"])),
      .dropColumn(column: "total"),
      .dropNotNull(column: "title"),
      Self.newColumn("note", "text"),
      .dropIndex(name: "idx_old"),
      .dropConstraint(name: "orders_chk_1", kind: .check),
    ]
    #expect(
      try build(changes, Self.mysql, .mysql(Self.mysql80)) == [
        "ALTER TABLE `shop`.`orders` DROP INDEX `idx_old`, DROP CHECK `orders_chk_1`, "
          + "DROP COLUMN `total`, ADD COLUMN `note` text NULL, CHANGE COLUMN `title` `name` "
          + "varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL DEFAULT 'none' "
          + "COMMENT 'it''s', ADD CONSTRAINT `uq` UNIQUE (`token`), ADD INDEX `idx_name` (`name`)"
      ])
  }

  @Test(
    "MySQL: RENAME COLUMN on MySQL 8+ and MariaDB 10.5.2+, else CHANGE with the full definition",
    arguments: [
      (MySQLServerInfo(flavor: .mysql, major: 5, minor: 7, patch: 44), false),
      (MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 0), true),
      (MySQLServerInfo(flavor: .mariadb, major: 10, minor: 4, patch: 34), false),
      (MySQLServerInfo(flavor: .mariadb, major: 10, minor: 5, patch: 2), true),
    ])
  func mysqlRename(server: MySQLServerInfo, usesRename: Bool) throws {
    let expected =
      usesRename
      ? "RENAME COLUMN `id` TO `key`"
      : "CHANGE COLUMN `id` `key` int unsigned NOT NULL AUTO_INCREMENT"
    #expect(
      try build([.renameColumn(column: "id", newName: "key")], Self.mysql, .mysql(server)) == [
        "ALTER TABLE `shop`.`orders` " + expected
      ])
  }

  @Test("MySQL: DROP CONSTRAINT for a MariaDB check; no checks before MySQL 8.0.16")
  func mysqlCheckByFlavor() throws {
    let drop: [StructureChange] = [.dropConstraint(name: "orders_chk_1", kind: .check)]
    let mariadb = MySQLServerInfo(flavor: .mariadb, major: 10, minor: 6, patch: 0)
    #expect(
      try build(drop, Self.mysql, .mysql(mariadb)) == [
        "ALTER TABLE `shop`.`orders` DROP CONSTRAINT `orders_chk_1`"
      ])
    let old = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 15)
    #expect(throws: StructureDDLError.self) { try build(drop, Self.mysql, .mysql(old)) }
    let add: [StructureChange] = [
      .addConstraint(Constraint(name: "c", kind: .check("id > 1"), columns: []))
    ]
    #expect(throws: StructureDDLError.self) { try build(add, Self.mysql, .mysql(old)) }
  }

  @Test("MySQL: MariaDB refuses NOT NULL on a generated column; other edits still build")
  func mariadbGeneratedNotNullRefused() throws {
    let mariadb = MySQLServerInfo(flavor: .mariadb, major: 11, minor: 4, patch: 0)
    for changes: [StructureChange] in [
      [.setNotNull(column: "total")],
      [.renameColumn(column: "total", newName: "sum"), .setNotNull(column: "total")],
    ] {
      #expect(
        throws: StructureDDLError.unsupported(
          "MariaDB does not allow NOT NULL on a generated column.")
      ) {
        try build(changes, Self.mysql, .mysql(mariadb))
      }
    }
    #expect(
      try build([.alterColumnType(column: "total", type: "bigint")], Self.mysql, .mysql(mariadb))
        == [
          "ALTER TABLE `shop`.`orders` MODIFY COLUMN `total` bigint "
            + "GENERATED ALWAYS AS ((`id` * 2)) STORED"
        ])
  }

  @Test("MySQL: an EXTRA attribute the builder cannot restate fails closed")
  func mysqlUnknownExtra() {
    var structure = Self.mysql
    structure.columns[0].extra = "auto_increment SOMETHING_NEW"
    #expect(throws: StructureDDLError.self) {
      try build([.setNotNull(column: "id")], structure, .mysql(Self.mysql80))
    }
  }

  @Test(
    "MySQL: a spatial column cannot be modified (its SRID is not loaded)",
    arguments: [
      "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring",
      "multipolygon", "geometrycollection", "geomcollection",
    ])
  func mysqlSpatialRefused(type: String) {
    var structure = Self.mysql
    structure.columns[4] = Self.column(5, "total", type)
    structure.columns[4].columnType = type
    for change in [
      StructureChange.setNotNull(column: "total"),
      .renameColumn(column: "total", newName: "shape"),
    ] {
      #expect(
        throws: StructureDDLError.unsupported(
          "Spatial columns cannot be modified here; the SRID is not loaded.")
      ) {
        try build(
          [change], structure,
          .mysql(MySQLServerInfo(flavor: .mysql, major: 5, minor: 7, patch: 44)))
      }
    }
  }

  @Test(
    "MySQL: loaded type, default, generated expression and ON UPDATE text is re-validated",
    arguments: [
      ("type", "int; DROP TABLE x"), ("default", "1 -- x"), ("generated", "1) STORED, DROP x ("),
      ("onUpdate", "CURRENT_TIMESTAMP;"), ("type", "int\u{0}"),
    ])
  func mysqlCatalogTextRevalidated(part: String, text: String) {
    var column = Self.column(5, "total", "int")
    column.columnType = "int"
    switch part {
    case "type": column.columnType = text
    case "default": column.defaultExpression = text
    case "generated":
      column.extra = "STORED GENERATED"
      column.generated = TableStructure.Generated(expression: text, isStored: true)
    default:
      column.dataType = "timestamp"
      column.columnType = "timestamp"
      column.extra = "on update \(text)"
    }
    var structure = Self.mysql
    structure.columns[4] = column
    #expect {
      try build([.setNotNull(column: "total")], structure, .mysql(Self.mysql80))
    } throws: { error in
      guard case .unsupported(let message) = error as? StructureDDLError else { return false }
      return message.contains("\"total\"")
    }
  }

  @Test(
    "MySQL: common loaded types, defaults and expressions restate unchanged",
    arguments: [
      ("decimal(10,2)", nil, nil, "decimal(10,2) NOT NULL"),
      ("enum('a','b')", "'a'", nil, "enum('a','b') NOT NULL DEFAULT 'a'"),
      ("set('x','y')", nil, nil, "set('x','y') NOT NULL"),
      ("varchar(255)", "(uuid())", "DEFAULT_GENERATED", "varchar(255) NOT NULL DEFAULT (uuid())"),
      (
        "varchar(255)", "concat(a, ' ', b)", "DEFAULT_GENERATED",
        "varchar(255) NOT NULL DEFAULT (concat(a, ' ', b))"
      ),
      (
        "datetime(3)", "CURRENT_TIMESTAMP(3)", "DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)",
        "datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)"
      ),
      (
        "timestamp", "current_timestamp()", "on update current_timestamp()",
        "timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()"
      ),
    ] as [(String, String?, String?, String)])
  func mysqlCatalogTextAccepted(
    columnType: String, defaultExpression: String?, extra: String?, expected: String
  ) throws {
    var column = Self.column(5, "total", columnType, default: defaultExpression)
    column.columnType = columnType
    column.extra = extra
    var structure = Self.mysql
    structure.columns[4] = column
    #expect(
      try build([.setNotNull(column: "total")], structure, .mysql(Self.mysql80)) == [
        "ALTER TABLE `shop`.`orders` MODIFY COLUMN `total` " + expected
      ])
  }

  @Test("MySQL: a new check naming a column renamed in the same batch is refused")
  func mysqlCheckOnRenamedColumn() throws {
    for expression in ["title <> ''", "`TITLE` <> ''", "length(title) > 0"] {
      #expect(throws: StructureDDLError.unsupported("Rename the column first, then add the check."))
      {
        try build(
          [
            .renameColumn(column: "title", newName: "name"),
            .addConstraint(Constraint(name: "c", kind: .check(expression), columns: [])),
          ], Self.mysql, .mysql(Self.mysql80))
      }
    }
    #expect(
      try build(
        [
          .renameColumn(column: "title", newName: "name"),
          .addConstraint(Constraint(name: "c", kind: .check("'title' <> subtitle"), columns: [])),
        ], Self.mysql, .mysql(Self.mysql80)) == [
          "ALTER TABLE `shop`.`orders` RENAME COLUMN `title` TO `name`, "
            + "ADD CONSTRAINT `c` CHECK ('title' <> subtitle)"
        ])
  }

  // MARK: - SQLite

  @Test(
    "SQLite: supported changes, each its own statement",
    arguments: [
      (newColumn("note", "TEXT"), #"ALTER TABLE "main"."notes" ADD COLUMN "note" TEXT"#),
      (
        newColumn("flag", "INTEGER", nullable: false, default: "0"),
        #"ALTER TABLE "main"."notes" ADD COLUMN "flag" INTEGER NOT NULL DEFAULT 0"#
      ),
      (
        .renameColumn(column: "body", newName: "text"),
        #"ALTER TABLE "main"."notes" RENAME COLUMN "body" TO "text""#
      ),
      (.dropColumn(column: "body"), #"ALTER TABLE "main"."notes" DROP COLUMN "body""#),
      (
        index("notes_body", ["body"], unique: true),
        #"CREATE UNIQUE INDEX "main"."notes_body" ON "notes" ("body")"#
      ),
      (.dropIndex(name: "notes_tag"), #"DROP INDEX "main"."notes_tag""#),
    ] as [(StructureChange, String)])
  func sqliteChange(change: StructureChange, expected: String) throws {
    #expect(try build([change], Self.sqlite, .sqlite(libraryVersion: 3_035_000)) == [expected])
  }

  @Test("SQLite: rename needs 3.25.0 and drop needs 3.35.0")
  func sqliteVersionGates() throws {
    let rename: [StructureChange] = [.renameColumn(column: "body", newName: "text")]
    let drop: [StructureChange] = [.dropColumn(column: "body")]
    #expect(throws: StructureDDLError.self) {
      try build(rename, Self.sqlite, .sqlite(libraryVersion: 3_024_000))
    }
    #expect(try build(rename, Self.sqlite, .sqlite(libraryVersion: 3_025_000)).count == 1)
    #expect(throws: StructureDDLError.self) {
      try build(drop, Self.sqlite, .sqlite(libraryVersion: 3_034_001))
    }
  }

  @Test(
    "SQLite: DROP COLUMN is refused for key, unique, indexed, foreign key and generated columns",
    arguments: ["id", "u", "tag", "parent_id", "gen"])
  func sqliteDropRefused(name: String) {
    #expect(throws: StructureDDLError.self) {
      try build([.dropColumn(column: name)], Self.sqlite, .sqlite(libraryVersion: 3_045_000))
    }
  }

  @Test(
    "SQLite: ADD COLUMN limits",
    arguments: [
      newColumn("a", "TEXT", nullable: false),
      newColumn("a", "TEXT", nullable: false, default: "NULL"),
      newColumn("a", "TEXT", default: "CURRENT_TIMESTAMP"),
      newColumn("a", "INTEGER", default: "(1 + 1)"),
      newColumn("a", "INTEGER PRIMARY KEY"),
      newColumn("a", "TEXT UNIQUE"),
      newColumn("a", "INTEGER GENERATED ALWAYS AS (1) STORED"),
    ])
  func sqliteAddColumnLimits(change: StructureChange) {
    #expect(throws: StructureDDLError.self) {
      try build([change], Self.sqlite, .sqlite(libraryVersion: 3_045_000))
    }
  }

  @Test(
    "SQLite: changes that need a table rebuild are not supported",
    arguments: [
      .alterColumnType(column: "body", type: "BLOB"),
      .setDefault(column: "body", expression: "'x'"),
      .dropDefault(column: "body"),
      .setNotNull(column: "body"),
      .dropNotNull(column: "id"),
      .addConstraint(Constraint(name: nil, kind: .unique, columns: ["body"])),
      .dropConstraint(name: "u_unique", kind: .unique),
    ] as [StructureChange])
  func sqliteUnsupported(change: StructureChange) {
    #expect(throws: StructureDDLError.self) {
      try build([change], Self.sqlite, .sqlite(libraryVersion: 3_045_000))
    }
  }

  // MARK: - DuckDB

  @Test("DuckDB: every change throws; no changes build nothing")
  func duckdbViewOnly() throws {
    var structure = Self.postgres
    structure.tableID = .duckdb(schema: "main", table: "items")
    #expect(throws: StructureDDLError.self) {
      try build([Self.newColumn("a", "INTEGER")], structure, .duckdb)
    }
    #expect(try build([], structure, .duckdb) == [])
  }
}
