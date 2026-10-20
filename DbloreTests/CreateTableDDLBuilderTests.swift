// CreateTableDDLBuilderTests.swift
// CreateTableDDLBuilder: exact CREATE TABLE per engine (columns, composite primary key, unique and
// foreign keys, table comment), quoting of odd identifiers, comment literals, the refusals
// (DuckDB, names, columns, injected text, SQLite comments and cross-schema references), and that
// every built statement passes the schema-change gate.

import Foundation
import Testing

@testable import Dblore

@Suite("CreateTableDDLBuilderTests")
struct CreateTableDDLBuilderTests {
  private typealias Column = CreateTableDraft.Column
  private typealias Constraint = TableStructure.Constraint

  private static let mysql80 = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)
  private static let sqlite = StructureDDLBuilder.Engine.sqlite(libraryVersion: 3_045_000)

  private static func foreignKey(
    _ columns: [String], schema: String, table: String, _ referenced: [String],
    onDelete: ForeignKeyAction = .noAction
  ) -> Constraint {
    Constraint(
      name: nil,
      kind: .foreignKey(
        TableStructure.ForeignKeyReference(
          schema: schema, table: table, columns: referenced, onUpdate: .noAction,
          onDelete: onDelete)),
      columns: columns)
  }

  /// Composite key, a default, a unique and a foreign key
  private static func orderLines(schema: String, comment: String? = nil) -> CreateTableDraft {
    CreateTableDraft(
      schema: schema, name: "order_lines",
      columns: [
        Column(name: "order_id", type: "integer", isPrimaryKey: true),
        Column(name: "line", type: "integer", isPrimaryKey: true),
        Column(name: "sku", type: "varchar(20)", isNullable: false),
        Column(name: "qty", type: "integer", isNullable: false, defaultExpression: "1"),
      ],
      constraints: [
        Constraint(name: "uq_sku", kind: .unique, columns: ["order_id", "sku"]),
        foreignKey(["order_id"], schema: schema, table: "orders", ["id"], onDelete: .cascade),
      ],
      comment: comment)
  }

  // MARK: - Engines

  @Test("PostgreSQL: one CREATE TABLE, then COMMENT ON TABLE")
  func postgres() throws {
    #expect(
      try CreateTableDDLBuilder.build(
        Self.orderLines(schema: "public", comment: "it's"), engine: .postgresql) == [
          #"""
          CREATE TABLE "public"."order_lines" (
            "order_id" integer NOT NULL,
            "line" integer NOT NULL,
            "sku" varchar(20) NOT NULL,
            "qty" integer NOT NULL DEFAULT 1,
            PRIMARY KEY ("order_id", "line"),
            CONSTRAINT "uq_sku" UNIQUE ("order_id", "sku"),
            FOREIGN KEY ("order_id") REFERENCES "public"."orders" ("id") ON DELETE CASCADE
          )
          """#,
          #"COMMENT ON TABLE "public"."order_lines" IS 'it''s'"#,
        ])
  }

  @Test("MySQL: the comment is a table option; NULL is explicit")
  func mysql() throws {
    var draft = Self.orderLines(schema: "shop", comment: "it's")
    draft.columns.append(Column(name: "note", type: "text"))
    #expect(
      try CreateTableDDLBuilder.build(draft, engine: .mysql(Self.mysql80)) == [
        """
        CREATE TABLE `shop`.`order_lines` (
          `order_id` integer NOT NULL,
          `line` integer NOT NULL,
          `sku` varchar(20) NOT NULL,
          `qty` integer NOT NULL DEFAULT 1,
          `note` text NULL,
          PRIMARY KEY (`order_id`, `line`),
          CONSTRAINT `uq_sku` UNIQUE (`order_id`, `sku`),
          FOREIGN KEY (`order_id`) REFERENCES `shop`.`orders` (`id`) ON DELETE CASCADE
        ) COMMENT = 'it''s'
        """
      ])
  }

  @Test("SQLite: the foreign key names its table bare (same database)")
  func sqlite() throws {
    #expect(
      try CreateTableDDLBuilder.build(Self.orderLines(schema: "main"), engine: Self.sqlite) == [
        #"""
        CREATE TABLE "main"."order_lines" (
          "order_id" integer NOT NULL,
          "line" integer NOT NULL,
          "sku" varchar(20) NOT NULL,
          "qty" integer NOT NULL DEFAULT 1,
          PRIMARY KEY ("order_id", "line"),
          CONSTRAINT "uq_sku" UNIQUE ("order_id", "sku"),
          FOREIGN KEY ("order_id") REFERENCES "orders" ("id") ON DELETE CASCADE
        )
        """#
      ])
  }

  @Test("Odd names are quoted with the engine's quote doubled")
  func oddIdentifiers() throws {
    let draft = CreateTableDraft(
      schema: "my schema", name: #"we"ird`t"#,
      columns: [Column(name: #"a "b" `c`"#, type: "text", isPrimaryKey: true)])
    #expect(
      try CreateTableDDLBuilder.build(draft, engine: .postgresql) == [
        #"""
        CREATE TABLE "my schema"."we""ird`t" (
          "a ""b"" `c`" text NOT NULL,
          PRIMARY KEY ("a ""b"" `c`")
        )
        """#
      ])
    #expect(
      try CreateTableDDLBuilder.build(draft, engine: .mysql(Self.mysql80)) == [
        """
        CREATE TABLE `my schema`.`we"ird``t` (
          `a "b" ``c``` text NOT NULL,
          PRIMARY KEY (`a "b" ``c```)
        )
        """
      ])
  }

  // MARK: - Comments

  @Test("Comments: quotes doubled, backslashes escaped; blank adds none; SQLite refuses one")
  func comments() throws {
    let text = "a'b\\c\nd"
    let one = CreateTableDraft(
      schema: "public", name: "t", columns: [Column(name: "id", type: "int")], comment: text)
    #expect(
      try CreateTableDDLBuilder.build(one, engine: .postgresql).last
        == "COMMENT ON TABLE \"public\".\"t\" IS E'a''b\\\\c\nd'")
    #expect(
      try CreateTableDDLBuilder.build(one, engine: .mysql(Self.mysql80)).last?
        .hasSuffix(") COMMENT = 'a''b\\\\c\nd'") == true)

    var blank = one
    blank.comment = "  \n"
    #expect(try CreateTableDDLBuilder.build(blank, engine: .postgresql).count == 1)
    #expect(
      try CreateTableDDLBuilder.build(blank, engine: .mysql(Self.mysql80)).last?.hasSuffix(")")
        == true)
    #expect(try CreateTableDDLBuilder.build(blank, engine: Self.sqlite).count == 1)
    #expect(throws: StructureDDLError.self) {
      try CreateTableDDLBuilder.build(one, engine: Self.sqlite)
    }
  }

  // MARK: - Refusals

  @Test(
    "Refused drafts throw before any SQL is built",
    arguments: [
      // No columns
      CreateTableDraft(schema: "public", name: "t", columns: []),
      // Empty or NUL names
      CreateTableDraft(schema: "public", name: "", columns: [Column(name: "id", type: "int")]),
      CreateTableDraft(
        schema: "public", name: "a\u{0}b", columns: [Column(name: "id", type: "int")]),
      CreateTableDraft(schema: "public", name: "t", columns: [Column(name: "", type: "int")]),
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "i\u{0}d", type: "int")]),
      // Duplicate column
      CreateTableDraft(
        schema: "public", name: "t",
        columns: [Column(name: "id", type: "int"), Column(name: "id", type: "text")]),
      // Text that would end or extend the statement
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "id", type: "int); DROP TABLE x; --")]),
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "id", type: "int, evil int")]),
      CreateTableDraft(
        schema: "public", name: "t",
        columns: [Column(name: "id", type: "int", defaultExpression: "1) --")]),
      // Constraints name unknown columns, mismatched references, unsupported kinds
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "id", type: "int")],
        constraints: [Constraint(name: nil, kind: .unique, columns: ["nope"])]),
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "id", type: "int")],
        constraints: [foreignKey(["id"], schema: "public", table: "o", ["a", "b"])]),
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "id", type: "int")],
        constraints: [Constraint(name: nil, kind: .primaryKey, columns: ["id"])]),
      // NUL in the comment
      CreateTableDraft(
        schema: "public", name: "t", columns: [Column(name: "id", type: "int")], comment: "a\u{0}"),
    ])
  func refusals(_ draft: CreateTableDraft) {
    for engine in [StructureDDLBuilder.Engine.postgresql, .mysql(Self.mysql80), Self.sqlite] {
      #expect(throws: StructureDDLError.self, "\(engine)") {
        try CreateTableDDLBuilder.build(draft, engine: engine)
      }
    }
  }

  @Test("DuckDB is refused; SQLite refuses a foreign key into another database")
  func engineRefusals() {
    #expect(throws: StructureDDLError.self) {
      try CreateTableDDLBuilder.build(Self.orderLines(schema: "main"), engine: .duckdb)
    }
    var draft = Self.orderLines(schema: "main")
    draft.constraints = [Self.foreignKey(["order_id"], schema: "other", table: "orders", ["id"])]
    #expect(throws: StructureDDLError.self) {
      try CreateTableDDLBuilder.build(draft, engine: Self.sqlite)
    }
  }

  // MARK: - Gate

  @Test("Every built statement is one schema statement the gate lets through")
  func builtStatementsPassTheGate() throws {
    let built: [(DatabaseType, [String])] = [
      (
        .postgresql,
        try CreateTableDDLBuilder.build(
          Self.orderLines(schema: "public", comment: #"it's a\b"#), engine: .postgresql)
      ),
      (
        .mysql,
        try CreateTableDDLBuilder.build(
          Self.orderLines(schema: "shop", comment: #"it's a\b"#), engine: .mysql(Self.mysql80))
      ),
      (
        .sqlite,
        try CreateTableDDLBuilder.build(Self.orderLines(schema: "main"), engine: Self.sqlite)
      ),
    ]
    for (type, statements) in built {
      #expect(!statements.isEmpty)
      #expect(
        DatabaseConnectionManager.schemaChangeRefusal(
          statements, databaseType: type, transactionOpen: false) == nil,
        "\(type): \(statements)")
    }
    #expect(built[0].1.count == 2)
  }
}
