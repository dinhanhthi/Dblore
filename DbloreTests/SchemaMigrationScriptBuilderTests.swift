// SchemaMigrationScriptBuilderTests.swift
// SchemaMigrationScriptBuilder: statements in dependency order (foreign key and index drops
// before column drops, creates before foreign key adds, table drops last) for the target schema,
// drops only when ticked, changes a builder refuses listed as manual and never scripted (a
// replaced index is not dropped when its new form cannot be created), lossy column changes
// warned per item, the source schema in PostgreSQL types and defaults rewritten to the target,
// a new PostgreSQL serial column's sequence created before and owned by the column after, inside
// its item (a shared or other-named sequence created only if missing, with a warning, and one a
// target column already reads left alone), and new MySQL columns with expression defaults restated with parentheses and
// INVISIBLE kept (manual on a target that has no invisible columns).

import Foundation
import Testing

@testable import Dblore

@Suite("SchemaMigrationScriptBuilderTests")
struct SchemaMigrationScriptBuilderTests {
  private typealias Column = TableStructure.Column
  private typealias Index = TableStructure.Index
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

  private static func index(_ name: String, _ columns: [String], method: String? = nil) -> Index {
    Index(
      name: name, keys: columns.map { .column($0) }, isUnique: false, isPrimary: false,
      method: method, isPartial: false, predicate: nil)
  }

  private static func foreignKey(
    _ name: String?, _ columns: [String], schema: String, table: String
  ) -> Constraint {
    Constraint(
      name: name,
      kind: .foreignKey(
        .init(
          schema: schema, table: table, columns: ["id"], onUpdate: .noAction, onDelete: .cascade)),
      columns: columns)
  }

  private static func table(
    _ schema: String, _ name: String, _ columns: [Column], indexes: [Index] = [],
    constraints: [Constraint] = []
  ) -> TableStructure {
    TableStructure(
      tableID: .postgresql(oid: 1), schema: schema, name: name, columns: columns,
      indexes: indexes, constraints: constraints)
  }

  private static func customers(_ schema: String) -> TableStructure {
    table(
      schema, "customers", [column(1, "id", "integer", nullable: false)],
      constraints: [Constraint(name: "customers_pkey", kind: .primaryKey, columns: ["id"])])
  }

  /// Source `dev`: a new `audit` table (index, FK to orders). Target `prod`: `orders.legacy`
  /// (indexed, FK to customers) and an `old_stuff` table that the source does not have.
  private static func postgresPair() -> (SchemaSnapshot, SchemaSnapshot) {
    let orders = { (schema: String, legacy: Bool) in
      table(
        schema, "orders",
        [column(1, "id", "integer", nullable: false)]
          + (legacy ? [column(2, "legacy", "integer")] : []),
        indexes: legacy ? [index("orders_legacy_idx", ["legacy"], method: "btree")] : [],
        constraints: [Constraint(name: "orders_pkey", kind: .primaryKey, columns: ["id"])]
          + (legacy
            ? [foreignKey("orders_legacy_fk", ["legacy"], schema: schema, table: "customers")]
            : []))
    }
    let audit = table(
      "dev", "audit",
      [column(1, "id", "integer", nullable: false), column(2, "order_id", "integer")],
      indexes: [index("audit_order_idx", ["order_id"], method: "btree")],
      constraints: [
        Constraint(name: "audit_pkey", kind: .primaryKey, columns: ["id"]),
        foreignKey("audit_order_fk", ["order_id"], schema: "dev", table: "orders"),
      ])
    let source = SchemaSnapshot(
      engine: .postgresql, schema: "dev", tables: [audit, customers("dev"), orders("dev", false)])
    let target = SchemaSnapshot(
      engine: .postgresql, schema: "prod",
      tables: [
        customers("prod"), table("prod", "old_stuff", [column(1, "x", "text")]),
        orders("prod", true),
      ])
    return (source, target)
  }

  private static func script(
    _ source: SchemaSnapshot, _ target: SchemaSnapshot,
    select: (inout SchemaDiffItem) -> Void = { _ in }
  ) throws -> (items: [SchemaDiffItem], script: SchemaMigrationScript) {
    var items = try SchemaDiff.diff(source: source, target: target).items
    for index in items.indices { select(&items[index]) }
    return (items, SchemaMigrationScriptBuilder.build(items, source: source, target: target))
  }

  // MARK: - Tests

  @Test func statementsRunInDependencyOrder() throws {
    let (source, target) = Self.postgresPair()
    let (items, script) = try Self.script(source, target) { $0.isSelected = true }
    #expect(
      script.statements.map(\.sql) == [
        #"ALTER TABLE "prod"."orders" DROP CONSTRAINT "orders_legacy_fk""#,
        #"DROP INDEX "prod"."orders_legacy_idx""#,
        """
        CREATE TABLE "prod"."audit" (
          "id" integer NOT NULL,
          "order_id" integer,
          PRIMARY KEY ("id")
        )
        """,
        #"ALTER TABLE "prod"."orders" DROP COLUMN "legacy""#,
        #"CREATE INDEX "audit_order_idx" ON "prod"."audit" USING btree ("order_id")"#,
        #"ALTER TABLE "prod"."audit" ADD CONSTRAINT "audit_order_fk" FOREIGN KEY ("order_id") "#
          + #"REFERENCES "prod"."orders" ("id") ON DELETE CASCADE"#,
        #"DROP TABLE "prod"."old_stuff""#,
      ])
    let id = { (kind: String) in items.first { $0.id.hasPrefix(kind) }?.id }
    #expect(
      script.statements.map(\.itemID)
        == [
          id("fk.drop"), id("index.drop"), id("table.create"), id("column.drop"),
          id("table.create"), id("table.create"), id("table.drop"),
        ].compactMap { $0 })
    #expect(script.manualItems.isEmpty)
  }

  @Test func dropsAreScriptedOnlyWhenTicked() throws {
    let (source, target) = Self.postgresPair()
    let sql = try Self.script(source, target).script.statements.map(\.sql)
    #expect(!sql.contains { $0.hasPrefix("DROP") || $0.contains(" DROP ") })
    // CREATE TABLE "audit", its index and its foreign key
    #expect(sql.count == 3)
  }

  @Test func changesTheSQLiteBuilderRefusesAreManual() throws {
    let sqlite = StructureDDLBuilder.Engine.sqlite(libraryVersion: 3_045_000)
    let notes = { (body: String, extra: [Column]) in
      Self.table(
        "main", "notes",
        [Self.column(1, "id", "INTEGER", nullable: false), Self.column(2, "body", body)] + extra,
        constraints: [Constraint(name: nil, kind: .primaryKey, columns: ["id"])])
    }
    var source = notes("TEXT", [Self.column(3, "tag", "TEXT", default: "'none'")])
    source.constraints.append(Self.foreignKey(nil, ["id"], schema: "main", table: "notes"))
    let (items, script) = try Self.script(
      SchemaSnapshot(engine: sqlite, schema: "main", tables: [source]),
      SchemaSnapshot(engine: sqlite, schema: "main", tables: [notes("BLOB", [])]))
    #expect(
      script.statements.map(\.sql) == [
        #"ALTER TABLE "main"."notes" ADD COLUMN "tag" TEXT DEFAULT 'none'"#
      ])
    let manual = Set(script.manualItems.map(\.itemID))
    #expect(
      manual
        == Set(
          items.filter { $0.id.hasPrefix("column.alter") || $0.id.hasPrefix("fk.add") }.map(\.id)))
    #expect(manual.count == 2)
    #expect(script.manualItems.allSatisfy { !$0.reason.isEmpty })
  }

  @Test func aReplacedIndexIsKeptWhenItsNewFormCannotBeCreated() throws {
    var partial = Self.index("orders_legacy_idx", ["legacy"])
    partial.isPartial = true
    partial.predicate = "legacy > 0"
    let (source, target) = Self.postgresPair()
    var changed = source
    changed.tables[2].columns.append(Self.column(2, "legacy", "integer"))
    changed.tables[2].indexes = [partial]
    let (items, script) = try Self.script(changed, target)
    let change = try #require(items.first { $0.id.hasPrefix("index.change") })
    #expect(!script.statements.contains { $0.itemID == change.id })
    #expect(script.manualItems.map(\.itemID).contains(change.id))
  }

  @Test func lossyColumnChangesAreWarnedAndIdentityChangesAreManual() throws {
    let orders = { (schema: String, total: Column, id: Column) in
      Self.table(schema, "orders", [id, total])
    }
    var identity = Self.column(1, "id", "integer", nullable: false)
    identity.identity = .always
    let source = SchemaSnapshot(
      engine: .postgresql, schema: "dev",
      tables: [orders("dev", Self.column(2, "total", "integer", nullable: false), identity)])
    let target = SchemaSnapshot(
      engine: .postgresql, schema: "prod",
      tables: [
        orders(
          "prod", Self.column(2, "total", "numeric(10,2)"),
          Self.column(
            1, "id", "integer", nullable: false,
            default: "nextval('orders_id_seq'::regclass)"))
      ])
    let (items, script) = try Self.script(source, target)
    let total = try #require(items.first { $0.id == #"column.alter "orders"."total""# })
    let id = try #require(items.first { $0.id == #"column.alter "orders"."id""# })
    #expect(total.isSelected && id.isSelected)
    #expect(
      script.statements.map(\.sql) == [
        #"ALTER TABLE "prod"."orders" ALTER COLUMN "total" TYPE integer, "#
          + #"ALTER COLUMN "total" SET NOT NULL"#
      ])
    #expect(script.warnings.map(\.itemID) == [total.id])
    #expect(script.warnings.first?.message.contains("check the data first") == true)
    // Identity on one side: never DROP DEFAULT
    #expect(script.manualItems.map(\.itemID) == [id.id])
  }

  @Test func theSourceSchemaInTypesAndDefaultsBecomesTheTarget() throws {
    let tickets = Self.table(
      "dev", "tickets",
      [
        Self.column(
          1, "id", "integer", nullable: false,
          default: "nextval('dev.tickets_id_seq'::regclass)"),
        Self.column(2, "mood", "dev.mood", default: "'happy'::dev.mood"),
      ])
    let orders = { (schema: String, note: Column) in
      Self.table(schema, "orders", [Self.column(1, "id", "integer", nullable: false), note])
    }
    // Not a name: the text cannot be rewritten safely
    let source = SchemaSnapshot(
      engine: .postgresql, schema: "dev",
      tables: [
        orders("dev", Self.column(2, "note", "text", default: "'see dev.readme'::text")),
        tickets,
      ])
    let target = SchemaSnapshot(
      engine: .postgresql, schema: "prod",
      tables: [orders("prod", Self.column(2, "note", "text"))])
    let (items, script) = try Self.script(source, target)
    let create = try #require(script.statements.first { $0.sql.hasPrefix("CREATE TABLE") })
    #expect(create.sql.contains(#"DEFAULT nextval('"prod".tickets_id_seq'::regclass)"#))
    #expect(create.sql.contains(#""mood" "prod".mood DEFAULT 'happy'::"prod".mood"#))
    #expect(!create.sql.contains("dev."))
    let note = try #require(items.first { $0.id == #"column.alter "orders"."note""# })
    #expect(script.manualItems.map(\.itemID) == [note.id])
    #expect(!script.statements.contains { $0.itemID == note.id })
  }

  @Test func aSerialColumnsSequenceIsCreatedAndOwnedByItsColumn() throws {
    let serial = { (ordinal: Int, name: String, sequence: String) in
      Self.column(
        ordinal, name, "integer", nullable: false,
        default: "nextval('dev.\(sequence)'::regclass)")
    }
    let orders = { (schema: String, columns: [Column]) in
      Self.table(schema, "orders", [Self.column(1, "id", "integer", nullable: false)] + columns)
    }
    let source = SchemaSnapshot(
      engine: .postgresql, schema: "dev",
      tables: [
        Self.table("dev", "customers", [serial(1, "id", "customers_id_seq")]),
        orders("dev", [serial(2, "seq", "orders_seq_seq")]),
      ])
    let target = SchemaSnapshot(
      engine: .postgresql, schema: "prod", tables: [orders("prod", [])])
    let (items, script) = try Self.script(source, target)
    let create = try #require(items.first { $0.id.hasPrefix("table.create") })
    let add = try #require(items.first { $0.id.hasPrefix("column.add") })
    #expect(
      script.statements.map(\.sql) == [
        #"CREATE SEQUENCE "prod"."customers_id_seq" AS integer"#,
        """
        CREATE TABLE "prod"."customers" (
          "id" integer NOT NULL DEFAULT nextval('"prod".customers_id_seq'::regclass)
        )
        """,
        #"ALTER SEQUENCE "prod"."customers_id_seq" OWNED BY "prod"."customers"."id""#,
        #"CREATE SEQUENCE "prod"."orders_seq_seq" AS integer"#,
        #"ALTER TABLE "prod"."orders" ADD COLUMN "seq" integer NOT NULL "#
          + #"DEFAULT nextval('"prod".orders_seq_seq'::regclass)"#,
        #"ALTER SEQUENCE "prod"."orders_seq_seq" OWNED BY "prod"."orders"."seq""#,
      ])
    #expect(
      script.statements.map(\.itemID) == [create.id, create.id, create.id, add.id, add.id, add.id])
    #expect(script.warnings.isEmpty)

    // Unticked: none of its sequence statements
    let unticked = try Self.script(source, target) { $0.isSelected = $0.id == add.id }.script
    #expect(unticked.statements.count == 3)
    #expect(unticked.statements.allSatisfy { $0.itemID == add.id })
    #expect(!unticked.statements.contains { $0.sql.contains("customers_id_seq") })
  }

  @Test func sharedOrOtherNamedSequencesAreCreatedIfMissingAndNeverOwned() throws {
    let reading = { (name: String, type: String, schema: String, sequence: String) in
      Self.column(
        1, name, type, nullable: false,
        default: "nextval('\"\(schema)\".\(sequence)'::regclass)")
    }
    let orders = { (schema: String, columns: [Column]) in
      Self.table(schema, "orders", [Self.column(1, "id", "integer", nullable: false)] + columns)
    }
    // invoices and receipts (a copy with its defaults) share one sequence; notes reads one that
    // is not named as serial names it; tags in the target already reads global_seq
    let source = SchemaSnapshot(
      engine: .postgresql, schema: "Dev",
      tables: [
        Self.table("Dev", "invoices", [reading("id", "integer", "Dev", "invoices_id_seq")]),
        Self.table("Dev", "notes", [reading("id", "bigint", "Dev", "note_ids")]),
        orders("Dev", [reading("ref", "integer", "Dev", "global_seq")]),
        Self.table("Dev", "receipts", [reading("id", "integer", "Dev", "invoices_id_seq")]),
        Self.table("Dev", "tags", [reading("id", "integer", "Dev", "global_seq")]),
      ])
    let target = SchemaSnapshot(
      engine: .postgresql, schema: "Prod",
      tables: [
        orders("Prod", []),
        Self.table("Prod", "tags", [reading("id", "integer", "Prod", "global_seq")]),
      ])
    let (items, script) = try Self.script(source, target)
    let created = { (table: String) in items.first { $0.id == "table.create \"\(table)\"" }?.id }
    let create = { (table: String, type: String, sequence: String) in
      """
      CREATE TABLE "Prod"."\(table)" (
        "id" \(type) NOT NULL DEFAULT nextval('"Prod".\(sequence)'::regclass)
      )
      """
    }
    #expect(
      script.statements.map(\.sql) == [
        #"CREATE SEQUENCE IF NOT EXISTS "Prod"."invoices_id_seq""#,
        create("invoices", "integer", "invoices_id_seq"),
        #"CREATE SEQUENCE IF NOT EXISTS "Prod"."note_ids""#,
        create("notes", "bigint", "note_ids"),
        #"CREATE SEQUENCE IF NOT EXISTS "Prod"."invoices_id_seq""#,
        create("receipts", "integer", "invoices_id_seq"),
        #"ALTER TABLE "Prod"."orders" ADD COLUMN "ref" integer NOT NULL "#
          + #"DEFAULT nextval('"Prod".global_seq'::regclass)"#,
      ])
    #expect(
      script.warnings.map(\.itemID) == ["invoices", "notes", "receipts"].compactMap(created))
    #expect(script.warnings.allSatisfy { $0.message.contains("ownership is left unchanged") })
    #expect(script.manualItems.isEmpty)
  }

  @Test func mysqlNewColumnsKeepExpressionDefaultsAndInvisible() throws {
    let mysql = StructureDDLBuilder.Engine.mysql(
      MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36))
    var token = Self.column(2, "token", "varchar", default: "uuid()")
    token.columnType = "varchar(36)"
    token.extra = "DEFAULT_GENERATED"
    var secret = Self.column(3, "secret", "int")
    secret.extra = "INVISIBLE"
    let orders = { (columns: [Column]) in
      Self.table("shop", "orders", [Self.column(1, "id", "int", nullable: false)] + columns)
    }
    let source = SchemaSnapshot(engine: mysql, schema: "shop", tables: [orders([token, secret])])
    let script = try Self.script(
      source, SchemaSnapshot(engine: mysql, schema: "shop", tables: [orders([])])
    ).script
    #expect(
      script.statements.map(\.sql) == [
        "ALTER TABLE `shop`.`orders` ADD COLUMN `token` varchar(36) NULL DEFAULT (uuid())",
        "ALTER TABLE `shop`.`orders` ADD COLUMN `secret` int INVISIBLE NULL",
      ])
    // MySQL before 8.0.23 has no invisible columns: never created visible
    let old = StructureDDLBuilder.Engine.mysql(
      MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 22))
    let refused = try Self.script(
      source, SchemaSnapshot(engine: old, schema: "shop", tables: [orders([])])
    ).script
    #expect(refused.manualItems.map(\.itemID) == [#"column.add "orders"."secret""#])
    #expect(refused.statements.count == 1)
  }
}
