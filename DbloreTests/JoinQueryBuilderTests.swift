// JoinQueryBuilderTests.swift
// Build Join Query: picked tables join on the fewest foreign-key hops, junctions are added and
// listed, composite keys compare column by column, every table has its own alias, a table no
// path reaches is refused, and every statement passes ReadOnlyQueryGuard.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Join query builder")
struct JoinQueryBuilderTests {
  typealias Builder = JoinQueryBuilder

  private static func key(
    _ name: String, _ source: String, _ sourceColumns: [String], _ target: String,
    _ targetColumns: [String], schema: String = "public"
  ) -> ForeignKey {
    ForeignKey(
      constraintName: name, sourceSchema: schema, sourceTable: source,
      sourceColumns: sourceColumns, targetSchema: schema, targetTable: target,
      targetColumns: targetColumns)
  }

  private static func pick(
    _ table: String, _ kind: Builder.JoinKind = .inner, _ columns: [String] = [],
    filter: TableFilter? = nil, schema: String = "public"
  ) -> Builder.Pick {
    Builder.Pick(
      table: .init(schema: schema, name: table), kind: kind, columns: columns, filter: filter)
  }

  private static func shopKeys(schema: String = "public") -> [ForeignKey] {
    [
      key("fk_items_order", "order_items", ["order_id"], "orders", ["id"], schema: schema),
      key("fk_items_product", "order_items", ["product_id"], "products", ["id"], schema: schema),
    ]
  }

  @Test("A junction table is joined, listed and quoted on PostgreSQL")
  func junctionPostgres() throws {
    let query = try Builder.query(
      picks: [Self.pick("orders", .inner, ["id"]), Self.pick("products", .left, ["name"])],
      foreignKeys: Self.shopKeys(), dialect: .postgresql)

    #expect(
      query.sql == """
        SELECT "orders"."id", "products"."name"
        FROM "orders" AS "orders"
        LEFT JOIN "order_items" AS "order_items" ON "order_items"."order_id" = "orders"."id"
        LEFT JOIN "products" AS "products" ON "products"."id" = "order_items"."product_id"
        """)
    #expect(
      query.tables == [
        .init(
          alias: "orders", table: .init(schema: "public", name: "orders"), isPicked: true,
          foreignKeyName: nil),
        .init(
          alias: "order_items", table: .init(schema: "public", name: "order_items"),
          isPicked: false, foreignKeyName: "fk_items_order"),
        .init(
          alias: "products", table: .init(schema: "public", name: "products"), isPicked: true,
          foreignKeyName: "fk_items_product"),
      ])
  }

  @Test("A junction table on MySQL keeps the database and uses backticks")
  func junctionMySQL() throws {
    let query = try Builder.query(
      picks: [
        Self.pick("orders", .inner, ["id"], schema: "shop"),
        Self.pick("products", .inner, ["name"], schema: "shop"),
      ],
      foreignKeys: Self.shopKeys(schema: "shop"), dialect: .mysql)

    #expect(
      query.sql == """
        SELECT `orders`.`id`, `products`.`name`
        FROM `shop`.`orders` AS `orders`
        INNER JOIN `shop`.`order_items` AS `order_items` ON `order_items`.`order_id` = `orders`.`id`
        INNER JOIN `shop`.`products` AS `products` ON `products`.`id` = `order_items`.`product_id`
        """)
  }

  @Test("Picking a table already joined as a junction reuses that join and its kind")
  func pickedJunctionIsReused() throws {
    let quantity = TableFilter(conditions: [
      FilterCondition(column: "quantity", op: .greaterThan, value: "1")
    ])
    let query = try Builder.query(
      picks: [
        Self.pick("orders", .inner, ["id"]), Self.pick("products", .left, ["name"]),
        Self.pick("order_items", .inner, ["quantity"], filter: quantity),
      ],
      foreignKeys: Self.shopKeys(), dialect: .postgresql)

    #expect(
      query.sql == """
        SELECT "orders"."id", "products"."name", "order_items"."quantity"
        FROM "orders" AS "orders"
        LEFT JOIN "order_items" AS "order_items" ON "order_items"."order_id" = "orders"."id"
        LEFT JOIN "products" AS "products" ON "products"."id" = "order_items"."product_id"
        WHERE "order_items"."quantity" > '1'
        """)
    #expect(query.tables.map(\.alias) == ["orders", "order_items", "products"])
    #expect(query.tables.allSatisfy { $0.isPicked })
    #expect(query.pickAliases == ["orders", "products", "order_items"])
  }

  @Test("A chain joins each pick to the closest table before it")
  func chain() throws {
    let keys = [
      Self.key("fk_orders_customer", "orders", ["customer_id"], "customers", ["id"]),
      Self.key("fk_customers_country", "customers", ["country_code"], "countries", ["code"]),
    ]
    let query = try Builder.query(
      picks: [
        Self.pick("orders", .inner, ["id"]), Self.pick("customers"),
        Self.pick("countries", .left, ["name"]),
      ],
      foreignKeys: keys, dialect: .postgresql)

    #expect(
      query.sql == """
        SELECT "orders"."id", "countries"."name"
        FROM "orders" AS "orders"
        INNER JOIN "customers" AS "customers" ON "customers"."id" = "orders"."customer_id"
        LEFT JOIN "countries" AS "countries" ON "countries"."code" = "customers"."country_code"
        """)
    #expect(query.tables.allSatisfy { $0.isPicked })
  }

  @Test("A self-reference joins a second alias and duplicate column names are aliased")
  func selfReference() throws {
    let keys = [Self.key("fk_manager", "employees", ["manager_id"], "employees", ["id"])]
    let picks = [
      Self.pick("employees", .inner, ["name"]), Self.pick("employees", .left, ["name"]),
    ]

    let postgres = try Builder.query(picks: picks, foreignKeys: keys, dialect: .postgresql)
    #expect(
      postgres.sql == """
        SELECT "employees"."name" AS "employees_name", "employees_2"."name" AS "employees_2_name"
        FROM "employees" AS "employees"
        LEFT JOIN "employees" AS "employees_2" ON "employees_2"."id" = "employees"."manager_id"
        """)

    let mysql = try Builder.query(picks: picks, foreignKeys: keys, dialect: .mysql)
    #expect(
      mysql.sql == """
        SELECT `employees`.`name` AS `employees_name`, `employees_2`.`name` AS `employees_2_name`
        FROM `public`.`employees` AS `employees`
        LEFT JOIN `public`.`employees` AS `employees_2` ON `employees_2`.`id` = `employees`.`manager_id`
        """)
  }

  @Test("A composite foreign key compares column by column")
  func composite() throws {
    let keys = [
      Self.key(
        "fk_shipment_line", "shipments", ["order_id", "line_no"], "order_lines",
        ["order_id", "line_no"])
    ]
    let query = try Builder.query(
      picks: [Self.pick("shipments", .inner, ["shipped_at"]), Self.pick("order_lines")],
      foreignKeys: keys, dialect: .postgresql)

    #expect(
      query.sql == """
        SELECT "shipments"."shipped_at"
        FROM "shipments" AS "shipments"
        INNER JOIN "order_lines" AS "order_lines" ON "order_lines"."order_id" = "shipments"."order_id" AND "order_lines"."line_no" = "shipments"."line_no"
        """)
  }

  @Test("Parallel foreign keys to one table join distinct aliases on distinct keys")
  func parallelForeignKeys() throws {
    let keys = [
      Self.key("fk_origin", "flights", ["origin_id"], "airports", ["id"]),
      Self.key("fk_destination", "flights", ["destination_id"], "airports", ["id"]),
    ]
    let query = try Builder.query(
      picks: [
        Self.pick("flights", .inner, ["id"]), Self.pick("airports", .inner, ["code"]),
        Self.pick("airports", .inner, ["code"]),
      ],
      foreignKeys: keys, dialect: .postgresql)

    #expect(
      query.sql == """
        SELECT "flights"."id", "airports"."code" AS "airports_code", "airports_2"."code" AS "airports_2_code"
        FROM "flights" AS "flights"
        INNER JOIN "airports" AS "airports" ON "airports"."id" = "flights"."origin_id"
        INNER JOIN "airports" AS "airports_2" ON "airports_2"."id" = "flights"."destination_id"
        """)
    #expect(query.tables.map(\.foreignKeyName) == [nil, "fk_origin", "fk_destination"])
  }

  @Test("Filters are qualified by alias and parenthesized when several tables have one")
  func filters() throws {
    let open = TableFilter(conditions: [
      FilterCondition(column: "status", op: .equals, value: "open"),
      FilterCondition(column: "status", op: .equals, value: "new", connector: .or),
    ])
    let named = TableFilter(conditions: [
      FilterCondition(column: "name", op: .equals, value: "Pen")
    ])
    let query = try Builder.query(
      picks: [
        Self.pick("orders", .inner, ["id"], filter: open),
        Self.pick("products", .inner, ["name"], filter: named),
      ],
      foreignKeys: Self.shopKeys(), dialect: .postgresql)

    #expect(
      query.sql.hasSuffix(
        """
        WHERE ("orders"."status" = 'open' OR "orders"."status" = 'new') AND ("products"."name" = 'Pen')
        """))

    let single = try Builder.query(
      picks: [Self.pick("orders", .inner, ["id"], filter: open)], foreignKeys: [],
      dialect: .postgresql)
    #expect(
      single.sql == """
        SELECT "orders"."id"
        FROM "orders" AS "orders"
        WHERE "orders"."status" = 'open' OR "orders"."status" = 'new'
        """)
  }

  @Test("No selected column selects every column")
  func noColumns() throws {
    let query = try Builder.query(
      picks: [Self.pick("orders")], foreignKeys: [], dialect: .postgresql)
    #expect(query.sql == "SELECT *\nFROM \"orders\" AS \"orders\"")
  }

  @Test("A table no foreign key reaches is refused, never cross joined")
  func noPathRefused() {
    #expect(throws: Builder.Refusal.noPath(.init(schema: "public", name: "audit_log"))) {
      try Builder.query(
        picks: [Self.pick("orders"), Self.pick("audit_log")], foreignKeys: Self.shopKeys(),
        dialect: .postgresql)
    }
    // The only key from orders to customers is used once
    let keys = [Self.key("fk_orders_customer", "orders", ["customer_id"], "customers", ["id"])]
    #expect(throws: Builder.Refusal.noPath(.init(schema: "public", name: "customers"))) {
      try Builder.query(
        picks: [Self.pick("orders"), Self.pick("customers"), Self.pick("customers")],
        foreignKeys: keys, dialect: .postgresql)
    }
    #expect(throws: Builder.Refusal.noTables) {
      try Builder.query(picks: [], foreignKeys: [], dialect: .postgresql)
    }
  }

  @Test(
    "Every statement passes the read-only guard",
    arguments: [SQLDialect.postgresql, .mysql, .sqlite, .duckdb])
  func guardPasses(dialect: SQLDialect) throws {
    let filter = TableFilter(conditions: [
      FilterCondition(column: "name", op: .ilike, value: "%pen%")
    ])
    let query = try Builder.query(
      picks: [
        Self.pick("orders", .inner, ["id"]),
        Self.pick("products", .left, ["id", "name"], filter: filter),
      ],
      foreignKeys: Self.shopKeys(), dialect: dialect)
    #expect(try ReadOnlyQueryGuard.check(query.sql, dialect: dialect).count == 1)
  }
}
