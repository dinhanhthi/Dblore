// GenerateRowsPlannerTests.swift
// Generate Rows plan: identity, generated and server-default columns are never sent, foreign
// keys take only sampled referenced keys (a composite key as a whole tuple), unique keys never
// repeat, and a column that can't be filled refuses the run with its reason.

import Foundation
import Testing

@testable import Dblore

@Suite("Generate rows planner")
struct GenerateRowsPlannerTests {
  private typealias Planner = GenerateRowsPlanner

  private func column(
    _ name: String, _ dataType: String, nullable: Bool = false, defaultExpression: String? = nil,
    identity: TableStructure.Identity? = nil, generated: Bool = false
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: 1, name: name, dataType: dataType, isNullable: nullable,
      defaultExpression: defaultExpression, identity: identity,
      generated: generated ? TableStructure.Generated(expression: "a + b", isStored: true) : nil)
  }

  private func table(
    _ columns: [TableStructure.Column], constraints: [TableStructure.Constraint] = []
  ) -> TableStructure {
    TableStructure(
      tableID: .postgresql(oid: 1), schema: "public", name: "t", columns: columns, indexes: [],
      constraints: constraints)
  }

  private func foreignKey(
    _ columns: [String], _ table: String, _ referenced: [String]
  ) -> TableStructure.Constraint {
    TableStructure.Constraint(
      name: nil,
      kind: .foreignKey(
        TableStructure.ForeignKeyReference(
          schema: "public", table: table, columns: referenced, onUpdate: .noAction,
          onDelete: .noAction)),
      columns: columns)
  }

  /// A reader answering referenced-key reads by table and MAX reads by column; every read must
  /// have passed the read-only guard
  private func reader(
    keys: [String: [[CellValue]]] = [:], max: [String: CellValue] = [:]
  ) -> @Sendable (Planner.Read) async throws -> [[CellValue]] {
    { read in
      #expect(read.statement.classified != nil)
      switch read.purpose {
      case .referencedKeys(let reference): return keys[reference.table] ?? []
      case .currentMax(let column): return [[max[column] ?? .null]]
      }
    }
  }

  private func rows(_ plan: Planner.Plan, count: Int, seed: UInt64) throws -> [[String?]] {
    var plan = plan
    var random = Dblore.SeededGenerator(seed: seed)
    return try (0..<count).map { _ in try plan.nextRow(using: &random) }
  }

  @Test("Identity, generated and server-default columns are never sent")
  func serverFilledColumnsOmitted() async throws {
    let structure = table([
      column("id", "integer", identity: .always),
      column("serial_id", "integer", defaultExpression: "nextval('t_serial_id_seq'::regclass)"),
      column("total", "integer", generated: true),
      column("created_at", "timestamp", defaultExpression: "now()"),
      column("title", "text"),
      column("amount", "integer", nullable: true),
    ])
    let plan = try await Planner.plan(structure: structure, dialect: .postgresql, read: reader())
    #expect(plan.columns == ["title", "amount"])
    for row in try rows(plan, count: 20, seed: 1) { #expect(row.count == 2) }
  }

  @Test("Foreign keys take only sampled keys, a composite key as a whole tuple")
  func foreignKeysFromSampledKeys() async throws {
    let structure = table(
      [
        column("customer_id", "integer"),
        column("country", "text"),
        column("region", "text"),
        column("note", "text", nullable: true),
      ],
      constraints: [
        foreignKey(["customer_id"], "customers", ["id"]),
        foreignKey(["country", "region"], "regions", ["country_code", "code"]),
      ])
    let read = reader(keys: [
      "customers": [[.int(7)], [.int(8)], [.int(9)]],
      "regions": [[.string("fr"), .string("idf")], [.string("us"), .string("ca")]],
    ])
    let plan = try await Planner.plan(structure: structure, dialect: .postgresql, read: read)
    let generated = try rows(plan, count: 300, seed: 42)
    for row in generated {
      #expect(["7", "8", "9"].contains(row[0]))
      #expect(row[1] == "fr" && row[2] == "idf" || row[1] == "us" && row[2] == "ca")
    }
    #expect(Set(generated.map { $0[1] }).count == 2)
    let again = try await Planner.plan(structure: structure, dialect: .postgresql, read: read)
    #expect(try rows(again, count: 300, seed: 42) == generated)
  }

  @Test(
    "A NOT NULL foreign key without parent rows or a NOT NULL column of an unsupported type refuses the run"
  )
  func refusals() async throws {
    let orphan = table(
      [column("customer_id", "integer"), column("title", "text")],
      constraints: [foreignKey(["customer_id"], "customers", ["id"])])
    await #expect(throws: Planner.Error.noParentRows(column: "customer_id", table: "customers")) {
      try await Planner.plan(structure: orphan, dialect: .postgresql, read: reader())
    }
    let binary = table([column("title", "text"), column("photo", "bytea")])
    await #expect(throws: Planner.Error.unsupportedColumn(column: "photo", type: "bytea")) {
      try await Planner.plan(structure: binary, dialect: .postgresql) { _ in
        Issue.record("A refused plan reads nothing")
        return []
      }
    }
  }

  @Test("A nullable foreign key without parent rows and a nullable unsupported column are NULL")
  func nullableFallbacks() async throws {
    let structure = table(
      [
        column("customer_id", "integer", nullable: true),
        column("photo", "bytea", nullable: true),
        column("title", "text"),
      ],
      constraints: [foreignKey(["customer_id"], "customers", ["id"])])
    let plan = try await Planner.plan(structure: structure, dialect: .postgresql, read: reader())
    for row in try rows(plan, count: 20, seed: 3) {
      #expect(row[0] == nil && row[1] == nil && row[2] != nil)
    }
  }

  @Test(
    "Unique keys never repeat: an integer key starts after MAX, a key of foreign keys walks the sample"
  )
  func uniqueKeys() async throws {
    let keyed = table(
      [column("id", "integer"), column("title", "text")],
      constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])])
    let plan = try await Planner.plan(
      structure: keyed, dialect: .postgresql, read: reader(max: ["id": .int(41)]))
    #expect(try rows(plan, count: 3, seed: 5).map { $0[0] } == ["42", "43", "44"])

    let tags = table(
      [column("post_id", "integer"), column("tag_id", "integer")],
      constraints: [
        .init(name: nil, kind: .primaryKey, columns: ["post_id", "tag_id"]),
        foreignKey(["post_id"], "posts", ["id"]),
        foreignKey(["tag_id"], "tags", ["id"]),
      ])
    var tagPlan = try await Planner.plan(
      structure: tags, dialect: .postgresql,
      read: reader(keys: ["posts": [[.int(1)], [.int(2)]], "tags": [[.int(1)], [.int(2)]]]))
    var random = Dblore.SeededGenerator(seed: 9)
    let pairs = try (0..<2).map { _ in try tagPlan.nextRow(using: &random) }
    #expect(Set(pairs).count == 2)
    #expect(throws: ColumnValueGenerator.Error.uniqueValuesExhausted(column: "post_id")) {
      try tagPlan.nextRow(using: &random)
    }
  }

  @Test(
    "A composite key keeps a many-valued column distinct, not a leading boolean, enum or short text"
  )
  func compositeKeyPicksManyValuedColumn() async throws {
    let flagged = table(
      [
        column("is_active", "boolean"), column("status", "enum('draft','live')"),
        column("email", "text"),
      ],
      constraints: [
        .init(name: nil, kind: .unique, columns: ["is_active", "email"]),
        .init(name: nil, kind: .unique, columns: ["status", "email"]),
      ])
    let plan = try await Planner.plan(structure: flagged, dialect: .postgresql, read: reader())
    let emails = try rows(plan, count: 50, seed: 11).map { $0[2] }
    #expect(Set(emails).count == 50)

    // char(2) holds 99 tagged values; the foreign key walk holds all 150 products
    let translations = table(
      [column("locale", "char(2)"), column("product_id", "integer")],
      constraints: [
        .init(name: nil, kind: .primaryKey, columns: ["locale", "product_id"]),
        foreignKey(["product_id"], "products", ["id"]),
      ])
    let products = (1...150).map { [CellValue.int($0)] }
    let translationPlan = try await Planner.plan(
      structure: translations, dialect: .postgresql, read: reader(keys: ["products": products]))
    let ids = try rows(translationPlan, count: 150, seed: 12).map { $0[1] }
    #expect(Set(ids).count == 150)

    // tinyint holds 127 keys from 1; varchar(20) holds all 300 rows
    let levels = table(
      [column("level", "tinyint"), column("code", "varchar(20)")],
      constraints: [.init(name: nil, kind: .unique, columns: ["level", "code"])])
    let levelPlan = try await Planner.plan(structure: levels, dialect: .mysql, read: reader())
    let codes = try rows(levelPlan, count: 300, seed: 13).map { $0[1] }
    #expect(Set(codes).count == 300)

    // A time of day holds 86,400 values, more than the 3 rooms the foreign key walk holds
    let bookings = table(
      [column("room_id", "integer"), column("slot", "time")],
      constraints: [
        .init(name: nil, kind: .unique, columns: ["room_id", "slot"]),
        foreignKey(["room_id"], "rooms", ["id"]),
      ])
    let bookingPlan = try await Planner.plan(
      structure: bookings, dialect: .postgresql,
      read: reader(keys: ["rooms": [[.int(1)], [.int(2)], [.int(3)]]]))
    let slots = try rows(bookingPlan, count: 100, seed: 14).map { $0[1] }
    #expect(Set(slots).count == 100)

    // tinyint holds 127 values, the boolean 2
    let flags = table(
      [column("is_active", "boolean"), column("level", "tinyint")],
      constraints: [.init(name: nil, kind: .unique, columns: ["is_active", "level"])])
    let flagPlan = try await Planner.plan(structure: flags, dialect: .mysql, read: reader())
    let flagLevels = try rows(flagPlan, count: 127, seed: 15).map { $0[1] }
    #expect(Set(flagLevels).count == 127)

    // The sample holds 3 tenants, varchar(4) 9,999 codes
    let tenantCodes = table(
      [column("tenant_id", "integer"), column("code", "varchar(4)")],
      constraints: [
        .init(name: nil, kind: .unique, columns: ["tenant_id", "code"]),
        foreignKey(["tenant_id"], "tenants", ["id"]),
      ])
    let tenantPlan = try await Planner.plan(
      structure: tenantCodes, dialect: .postgresql,
      read: reader(keys: ["tenants": [[.int(1)], [.int(2)], [.int(3)]]]))
    let tenantRows = try rows(tenantPlan, count: 200, seed: 16).map { $0[1] }
    #expect(Set(tenantRows).count == 200)

    // After MAX 32,760 a smallint holds 7 keys, fewer than varchar(4)
    let ranked = table(
      [column("rank", "smallint"), column("label", "varchar(4)")],
      constraints: [.init(name: nil, kind: .unique, columns: ["rank", "label"])])
    let rankPlan = try await Planner.plan(
      structure: ranked, dialect: .postgresql, read: reader(max: ["rank": .int(32_760)]))
    let labels = try rows(rankPlan, count: 50, seed: 17).map { $0[1] }
    #expect(Set(labels).count == 50)

    // A constant default repeats, so the slug keeps the key distinct
    let versioned = table(
      [column("slug", "text"), column("version", "integer", defaultExpression: "1")],
      constraints: [.init(name: nil, kind: .unique, columns: ["slug", "version"])])
    let versionPlan = try await Planner.plan(
      structure: versioned, dialect: .postgresql, read: reader())
    let slugs = try rows(versionPlan, count: 300, seed: 18).map { $0[0] }
    #expect(Set(slugs).count == 300)

    // A constant UUID default doesn't keep a key distinct: the sent column never repeats
    let tagged = table(
      [
        column("realm", "uuid", defaultExpression: "'00000000-0000-0000-0000-000000000000'::uuid"),
        column("slug", "text"),
      ],
      constraints: [.init(name: nil, kind: .unique, columns: ["realm", "slug"])])
    let taggedPlan = try await Planner.plan(
      structure: tagged, dialect: .postgresql, read: reader())
    #expect(Set(try rows(taggedPlan, count: 300, seed: 21).map { $0[0] }).count == 300)

    // Keys the server fills entirely (a default, a computed column) are left to it
    let stamped = table(
      [column("created_at", "timestamp", defaultExpression: "now()"), column("title", "text")],
      constraints: [.init(name: nil, kind: .unique, columns: ["created_at"])])
    let stampedPlan = try await Planner.plan(
      structure: stamped, dialect: .postgresql, read: reader())
    #expect(stampedPlan.columns == ["title"])
    let computed = table(
      [column("email", "text"), column("email_lower", "text", generated: true)],
      constraints: [.init(name: nil, kind: .unique, columns: ["email_lower"])])
    let computedPlan = try await Planner.plan(
      structure: computed, dialect: .postgresql, read: reader())
    #expect(computedPlan.columns == ["email"])
  }

  @Test("A key holding an identity, sequence or random UUID column is left to the server")
  func serverDistinctKeysSkipped() async throws {
    let structure = table(
      [
        column("row_id", "integer", identity: .always),
        column("seq_id", "integer", defaultExpression: "nextval('t_seq_id_seq'::regclass)"),
        column("ref", "uuid", defaultExpression: "GEN_RANDOM_UUID()"),
        column("v7", "uuid", defaultExpression: "uuidv7()"),
        column("flag", "boolean"),
      ],
      constraints: [
        .init(name: nil, kind: .unique, columns: ["row_id", "flag"]),
        .init(name: nil, kind: .unique, columns: ["seq_id", "flag"]),
        .init(name: nil, kind: .unique, columns: ["ref", "flag"]),
        .init(name: nil, kind: .unique, columns: ["v7", "flag"]),
      ])
    let plan = try await Planner.plan(structure: structure, dialect: .postgresql, read: reader())
    #expect(plan.columns == ["flag"])
    #expect(try rows(plan, count: 20, seed: 19).count == 20)
  }
}
