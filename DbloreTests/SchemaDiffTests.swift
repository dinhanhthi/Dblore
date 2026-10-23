// SchemaDiffTests.swift
// SchemaDiff: identical schemas give no item, also when PostgreSQL prints each side's own schema
// in types, defaults, index keys and predicates; tables only on one side (drops unticked), column
// add / drop / type, nullability and default changes, index renames and changes (constraint
// indexes left out, index drops unticked), foreign key changes (drops unticked, unnamed keys with
// distinct ids), per-engine name matching, same-engine refusal with the MySQL / MariaDB warning,
// and where a schema prefix is rewritten, left alone or refused (`schemaPrefixReplaced`).

import Foundation
import Testing

@testable import Dblore

@Suite("SchemaDiffTests")
struct SchemaDiffTests {
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

  private static func index(
    _ name: String, _ columns: [String], unique: Bool = false, primary: Bool = false
  ) -> Index {
    Index(
      name: name, keys: columns.map { .column($0) }, isUnique: unique || primary,
      isPrimary: primary, method: "btree", isPartial: false, predicate: nil)
  }

  private static func foreignKey(
    _ name: String?, _ columns: [String], schema: String, table: String, _ refColumns: [String],
    onDelete: ForeignKeyAction = .noAction
  ) -> Constraint {
    Constraint(
      name: name,
      kind: .foreignKey(
        .init(
          schema: schema, table: table, columns: refColumns, onUpdate: .noAction,
          onDelete: onDelete)),
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

  /// `customers` and `orders` (FK to customers) in `schema`
  private static func shop(_ schema: String) -> [TableStructure] {
    [
      table(
        schema, "customers",
        [column(1, "id", "integer", nullable: false), column(2, "email", "text")],
        indexes: [index("customers_pkey", ["id"], primary: true)],
        constraints: [Constraint(name: "customers_pkey", kind: .primaryKey, columns: ["id"])]),
      table(
        schema, "orders",
        [
          column(1, "id", "integer", nullable: false),
          column(2, "customer_id", "integer"),
          column(3, "total", "numeric(10,2)", default: "0"),
        ],
        indexes: [
          index("orders_pkey", ["id"], primary: true),
          index("orders_customer_idx", ["customer_id"]),
        ],
        constraints: [
          Constraint(name: "orders_pkey", kind: .primaryKey, columns: ["id"]),
          foreignKey(
            "orders_customer_fk", ["customer_id"], schema: schema, table: "customers", ["id"]),
        ]),
    ]
  }

  private static func snapshot(
    _ schema: String, _ tables: [TableStructure],
    engine: StructureDDLBuilder.Engine = .postgresql
  ) -> SchemaSnapshot {
    var snapshot = SchemaSnapshot(engine: engine, schema: schema, tables: tables)
    if case .sqlite = engine { snapshot.tableNamesIgnoreCase = true }
    return snapshot
  }

  private static func diff(
    _ source: [TableStructure], _ target: [TableStructure]
  ) throws -> [SchemaDiffItem] {
    try SchemaDiff.diff(source: snapshot("dev", source), target: snapshot("prod", target)).items
  }

  // MARK: - Tests

  @Test func identicalSchemasInOtherSchemasHaveNoItems() throws {
    // The foreign key names its own schema on each side: still the same reference
    #expect(try Self.diff(Self.shop("dev"), Self.shop("prod")).isEmpty)
  }

  @Test func tablesOnOneSideAreCreatedOrDroppedAndDropsAreUnticked() throws {
    let source = Self.shop("dev") + [Self.table("dev", "audit", [Self.column(1, "id", "bigint")])]
    let target =
      [Self.shop("prod")[0]] + [Self.table("prod", "legacy", [Self.column(1, "x", "text")])]
    let items = try Self.diff(source, target)
    #expect(items.map(\.table) == ["audit", "legacy", "orders"])
    guard items.count == 3 else { return }
    #expect(items[0].kind == .createTable(source[2]) && items[0].isSelected)
    #expect(items[1].kind == .dropTable(target[1]) && !items[1].isSelected)
    #expect(items[2].kind == .createTable(source[1]) && items[2].isSelected)
    #expect(Set(items.map(\.id)).count == 3)
  }

  @Test func columnsAddedDroppedAndChanged() throws {
    var source = Self.shop("dev")
    var target = Self.shop("prod")
    source[1].columns[2] = Self.column(3, "total", "numeric(12,2)", nullable: false)
    source[1].columns.append(Self.column(4, "note", "text"))
    target[1].columns.append(Self.column(4, "legacy", "text"))
    let items = try Self.diff(source, target)
    #expect(
      items.map(\.kind) == [
        .addColumn(source[1].columns[3]),
        .alterColumn(source: source[1].columns[2], target: target[1].columns[2]),
        .dropColumn(target[1].columns[3]),
      ])
    #expect(items.map(\.isSelected) == [true, true, false])
    #expect(items.allSatisfy { $0.table == "orders" })
    #expect(items[1].description.contains("numeric(12,2)"))
  }

  @Test func renamedIndexIsDropAndAddAndConstraintIndexesAreIgnored() throws {
    var source = Self.shop("dev")
    var target = Self.shop("prod")
    // Renamed; changed keys; a primary key index named differently is not an index change
    source[1].indexes = [
      Self.index("orders_pk", ["id"], primary: true),
      Self.index("orders_by_customer", ["customer_id"]),
      Self.index("orders_total_idx", ["total", "id"]),
    ]
    target[1].indexes.append(Self.index("orders_total_idx", ["total"]))
    // A unique constraint's backing index is the constraint's, not an index item
    target[0].indexes.append(Self.index("customers_email_key", ["email"], unique: true))
    target[0].constraints.append(
      Constraint(name: "customers_email_key", kind: .unique, columns: ["email"]))
    let items = try Self.diff(source, target)
    #expect(
      items.map(\.kind) == [
        .addIndex(source[1].indexes[1]),
        .changeIndex(source: source[1].indexes[2], target: target[1].indexes[2]),
        .dropIndex(target[1].indexes[1]),
      ])
    #expect(items.map(\.isSelected) == [true, true, false])
  }

  @Test func foreignKeysAddedAndChanged() throws {
    var source = Self.shop("dev")
    var target = Self.shop("prod")
    target[0].constraints.append(
      Self.foreignKey("customers_legacy_fk", ["id"], schema: "prod", table: "orders", ["id"]))
    source[1].constraints[1] = Self.foreignKey(
      "orders_customer_fk", ["customer_id"], schema: "dev", table: "customers", ["id"],
      onDelete: .cascade)
    source[0].constraints.append(
      Self.foreignKey("customers_self_fk", ["id"], schema: "dev", table: "customers", ["id"]))
    let items = try Self.diff(source, target)
    #expect(
      items.map(\.kind) == [
        .addForeignKey(source[0].constraints[1]),
        .dropForeignKey(target[0].constraints[1]),
        .changeForeignKey(source: source[1].constraints[1], target: target[1].constraints[1]),
      ])
    #expect(items.map(\.table) == ["customers", "customers", "orders"])
    #expect(items.map(\.isSelected) == [true, false, true])
  }

  @Test func unnamedForeignKeysToOtherTablesHaveDistinctIDs() throws {
    let sqlite = StructureDDLBuilder.Engine.sqlite(libraryVersion: 3_045_000)
    let notes = { (constraints: [Constraint]) in
      [Self.table("main", "notes", [Self.column(1, "ref", "INTEGER")], constraints: constraints)]
    }
    let items = try SchemaDiff.diff(
      source: Self.snapshot(
        "main",
        notes([
          Self.foreignKey(nil, ["ref"], schema: "main", table: "a", ["id"]),
          Self.foreignKey(nil, ["ref"], schema: "main", table: "b", ["id"]),
        ]), engine: sqlite),
      target: Self.snapshot("main", notes([]), engine: sqlite)
    ).items
    #expect(items.count == 2)
    #expect(Set(items.map(\.id)).count == 2)
  }

  @Test func eachSidesQualifiedSchemaNamesReadAsTheSame() throws {
    // Off the search_path, format_type and pg_get_expr print each side's own schema
    let orders = { (schema: String, printed: String, sequence: String) in
      Self.table(
        schema, "orders",
        [
          Self.column(
            1, "id", "integer", nullable: false,
            default: "nextval('\(printed).\(sequence)'::regclass)"),
          Self.column(2, "mood", "\(printed).mood", default: "'happy'::\(printed).mood"),
        ],
        indexes: [
          Index(
            name: "orders_mood_idx", keys: [.expression("\(printed).rank(mood)")],
            isUnique: false, isPrimary: false, method: "btree", isPartial: true,
            predicate: "(mood <> 'sad'::\(printed).mood)")
        ])
    }
    for (schema, printed) in [("dev", "dev"), ("Dev", "\"Dev\"")] {
      let items = try SchemaDiff.diff(
        source: Self.snapshot(schema, [orders(schema, printed, "orders_id_seq")]),
        target: Self.snapshot("prod", [orders("prod", "prod", "orders_id_seq")])
      ).items
      #expect(items.isEmpty, "\(schema)")
    }
    // Another sequence is still a change
    let items = try SchemaDiff.diff(
      source: Self.snapshot("dev", [orders("dev", "dev", "orders_seq")]),
      target: Self.snapshot("prod", [orders("prod", "prod", "orders_id_seq")])
    ).items
    #expect(items.map(\.id) == [#"column.alter "orders"."id""#])
  }

  @Test func schemaPrefixesAreRewrittenOnlyWhereSafe() {
    let cases: [(text: String, expected: String?)] = [
      ("nextval('dev.seq'::regclass)", "nextval('X.seq'::regclass)"),
      ("'a'::\"dev\".mood", "'a'::X.mood"),
      // Not the schema: left as they are
      ("mydev.mood", "mydev.mood"),
      ("x.dev.mood", "x.dev.mood"),
      ("\"a\"\"dev\".mood", "\"a\"\"dev\".mood"),
      // The schema where it cannot be rewritten safely: refused
      ("'dev.x'::text", nil),
      ("nextval('dev.seq dev.other'::regclass)", nil),
      ("'dev.x", nil),
    ]
    for (text, expected) in cases {
      #expect(
        SchemaDiff.schemaPrefixReplaced(in: text, schema: "dev", with: "X.") == expected, "\(text)")
    }
  }

  @Test func namesMatchPerEngineCaseRules() throws {
    let upper = [Self.table("main", "Users", [Self.column(1, "ID", "INTEGER")])]
    let lower = [Self.table("main", "users", [Self.column(1, "id", "integer")])]
    let sqlite = StructureDDLBuilder.Engine.sqlite(libraryVersion: 3_045_000)
    #expect(
      try SchemaDiff.diff(
        source: Self.snapshot("main", upper, engine: sqlite),
        target: Self.snapshot("main", lower, engine: sqlite)
      ).items.isEmpty)
    // PostgreSQL quoted names are case-sensitive: a different table
    let items = try SchemaDiff.diff(
      source: Self.snapshot("main", upper), target: Self.snapshot("main", lower)
    ).items
    #expect(items.map(\.table) == ["Users", "users"])
  }

  @Test func differentEnginesAreRefusedAndMariaDBIsWarned() throws {
    let sqlite = Self.snapshot("main", [], engine: .sqlite(libraryVersion: 3_045_000))
    #expect(throws: SchemaCompareError.engineMismatch) {
      try SchemaDiff.diff(source: sqlite, target: Self.snapshot("public", []))
    }
    let mysql = Self.snapshot(
      "shop", [], engine: .mysql(MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)))
    let mariadb = Self.snapshot(
      "shop", [],
      engine: .mysql(MySQLServerInfo(flavor: .mariadb, major: 11, minor: 4, patch: 2)))
    let result = try SchemaDiff.diff(source: mysql, target: mariadb)
    #expect(result.items.isEmpty)
    #expect(result.warnings.count == 1)
  }
}
