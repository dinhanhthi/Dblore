// PostgresTypeCatalogTests.swift
// PostgreSQL sequences and user-defined types: catalog rows (one query each, fed by a fake
// session) mapped to `DatabaseSequence` and `DatabaseUserType` (enum, domain, composite), and the
// read-only DDL rendered from them, with odd identifiers quoted and enum labels escaped. Also
// what the sidebar section shows before, during and after its read.

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL type catalog")
struct PostgresTypeCatalogTests {
  private let introspector = PostgresSchemaIntrospector()

  private static func session(_ rows: [[CellValue]]) -> FakeDatabaseSession {
    FakeDatabaseSession(capabilities: .contract(), columns: [], rows: rows, slowQueries: false)
  }

  // MARK: - Catalog rows

  @Test("Sequence rows map their parameters and owning column")
  func sequenceRows() async throws {
    let session = Self.session([
      [
        .string("public"), .string("orders_id_seq"), .string("integer"), .int(1), .int(1),
        .int(1), .int(2_147_483_647), .int(1), .bool(false), .string("public"),
        .string("orders"), .string("id"), .string("a"), .int(16_400),
      ],
      [
        .string("app"), .string("countdown"), .string("bigint"), .int(-1), .int(-2), .int(-100),
        .int(-1), .int(10), .bool(true), .null, .null, .null, .null, .int(16_401),
      ],
    ])
    let sequences = try await introspector.sequences(in: session)
    #expect(
      sequences == [
        DatabaseSequence(
          schema: "public", name: "orders_id_seq", dataType: "integer", start: 1, increment: 1,
          minValue: 1, maxValue: 2_147_483_647, cache: 1, cycle: false,
          ownedBy: .init(schema: "public", table: "orders", column: "id"), oid: 16_400),
        DatabaseSequence(
          schema: "app", name: "countdown", dataType: "bigint", start: -1, increment: -2,
          minValue: -100, maxValue: -1, cache: 10, cycle: true, oid: 16_401),
      ])
    #expect(session.queries.count == 1)
  }

  @Test("Type rows map enums, domains and composite types; other kinds are skipped")
  func userTypeRows() async throws {
    let session = Self.session([
      [
        .string("public"), .string("mood"), .string("e"), .json(#"["sad","it's ok","happy"]"#),
        .null, .null, .bool(false), .json("[]"), .json("[]"), .int(16_500),
      ],
      [
        .string("public"), .string("positive"), .string("d"), .json("[]"), .string("integer"),
        .string("1"), .bool(true), .json(#"[["positive_check","CHECK ((VALUE > 0))"]]"#),
        .json("[]"), .int(16_501),
      ],
      [
        .string("app"), .string("pair"), .string("c"), .json("[]"), .null, .null, .bool(false),
        .json("[]"), .json(#"[["x","integer"],["Y y","character varying(20)"]]"#),
        .int(16_502),
      ],
      [
        .string("app"), .string("r"), .string("r"), .json("[]"), .null, .null, .bool(false),
        .json("[]"), .json("[]"), .int(16_503),
      ],
    ])
    let types = try await introspector.userTypes(in: session)
    #expect(
      types == [
        DatabaseUserType(
          schema: "public", name: "mood", kind: .enum(["sad", "it's ok", "happy"]), oid: 16_500),
        DatabaseUserType(
          schema: "public", name: "positive",
          kind: .domain(
            baseType: "integer", notNull: true, defaultExpression: "1",
            constraints: [.init(name: "positive_check", definition: "CHECK ((VALUE > 0))")]),
          oid: 16_501),
        DatabaseUserType(
          schema: "app", name: "pair",
          kind: .composite([
            .init(name: "x", type: "integer"), .init(name: "Y y", type: "character varying(20)"),
          ]),
          oid: 16_502),
      ])
    #expect(session.queries.count == 1)
  }

  // MARK: - DDL

  @Test("CREATE SEQUENCE with default bounds as NO MINVALUE / NO MAXVALUE and OWNED BY")
  func sequenceDDL() throws {
    let owned = DatabaseSequence(
      schema: #"odd "s""#, name: "my seq", dataType: "integer", start: 10, increment: 5,
      minValue: 1, maxValue: 2_147_483_647, cache: 20, cycle: true,
      ownedBy: .init(schema: "public", table: "orders", column: "Id"))
    #expect(
      try PostgresSchemaIntrospector.ddl(owned) == #"""
        CREATE SEQUENCE "odd ""s"""."my seq"
          AS integer
          INCREMENT BY 5
          NO MINVALUE
          NO MAXVALUE
          START WITH 10
          CACHE 20
          CYCLE
          OWNED BY "public"."orders"."Id";
        """#)

    let descending = DatabaseSequence(
      schema: "app", name: "countdown", dataType: "bigint", start: -1, increment: -2,
      minValue: -100, maxValue: -1, cache: 1, cycle: false)
    #expect(
      try PostgresSchemaIntrospector.ddl(descending) == #"""
        CREATE SEQUENCE "app"."countdown"
          AS bigint
          INCREMENT BY -2
          MINVALUE -100
          NO MAXVALUE
          START WITH -1
          CACHE 1
          NO CYCLE;
        """#)
  }

  @Test("An identity sequence's comment cannot end on a line break inside its column name")
  func identityCommentStaysOneLine() throws {
    let sequence = DatabaseSequence(
      schema: "public", name: "t_x_seq", dataType: "bigint", start: 1, increment: 1,
      minValue: 1, maxValue: Int(Int64.max), cache: 1, cycle: false,
      ownedBy: .init(
        schema: "public", table: "t",
        column: "x\"\nDROP TABLE t; --\r\nDROP TABLE u; --\u{2028}DROP TABLE v"),
      isIdentity: true)
    let lines = try PostgresSchemaIntrospector.ddl(sequence)
      .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    #expect(lines.first?.hasPrefix("-- Identity sequence of") == true)
    #expect(!lines.contains { $0.hasPrefix("DROP") })
    #expect(lines.count == 9)
  }

  @Test("CREATE TYPE AS ENUM escapes a label with a quote")
  func enumDDL() throws {
    let type = DatabaseUserType(
      schema: "public", name: #"Mo"od"#, kind: .enum(["sad", "it's ok"]))
    #expect(
      try PostgresSchemaIntrospector.ddl(type) == #"""
        CREATE TYPE "public"."Mo""od" AS ENUM (
          'sad',
          'it''s ok'
        );
        """#)
  }

  @Test("CREATE TYPE AS (...) quotes attribute names")
  func compositeDDL() throws {
    let type = DatabaseUserType(
      schema: "app", name: "pair",
      kind: .composite([
        .init(name: "x", type: "integer"), .init(name: #"Y "y""#, type: "text[]"),
      ]))
    #expect(
      try PostgresSchemaIntrospector.ddl(type) == #"""
        CREATE TYPE "app"."pair" AS (
          "x" integer,
          "Y ""y""" text[]
        );
        """#)
  }

  @Test("CREATE DOMAIN with default, NOT NULL and named checks; NOT VALID ones are added after")
  func domainDDL() throws {
    let type = DatabaseUserType(
      schema: "public", name: "positive",
      kind: .domain(
        baseType: "integer", notNull: true, defaultExpression: "1",
        constraints: [
          .init(name: "small", definition: "CHECK ((VALUE < 100)) NOT VALID"),
          .init(name: "positive check", definition: "CHECK ((VALUE > 0))"),
        ]))
    #expect(
      try PostgresSchemaIntrospector.ddl(type) == #"""
        CREATE DOMAIN "public"."positive" AS integer
          DEFAULT 1
          NOT NULL
          CONSTRAINT "positive check" CHECK ((VALUE > 0));
        ALTER DOMAIN "public"."positive" ADD CONSTRAINT "small" CHECK ((VALUE < 100)) NOT VALID;
        """#)
  }

  // MARK: - Sidebar section

  @Test("An unread section shows Loading (a visible row starts its read), then its rows or None")
  func sectionStatus() {
    // Regression: an unread section rendered a zero-height row, which a lazy stack never shows,
    // so the read never started and the expanded section stayed blank
    var catalog = LazyCatalog<Int>()
    #expect(catalog.status(isEmpty: nil) == .loading)
    catalog.items = [1]
    #expect(catalog.status(isEmpty: false) == .rows)
    #expect(catalog.status(isEmpty: true) == .empty)
    catalog.reset()
    catalog.error = "Could not load"
    #expect(catalog.status(isEmpty: nil) == .failed("Could not load"))
  }
}
