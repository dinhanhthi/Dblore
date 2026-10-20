// TableStructurePostgresTests.swift
// PostgresSchemaIntrospector.tableStructure against the docker test database (TEST_DB_*, port
// 5435): identity, serial and generated columns, table and column comments, composite and constraint-backed
// indexes, expression and partial indexes, a cross-schema multi-column foreign key with actions,
// a check, and names that need quoting. Each test creates two schemas of its own, dropped on
// every path.

import Foundation
import Testing

@testable import Dblore

@Suite("TableStructurePostgresTests", .requiresPostgres, .serialized)
@MainActor
struct TableStructurePostgresTests {
  private let introspector = PostgresSchemaIntrospector()
  private typealias Column = TableStructure.Column
  private static let table = "my \"t\""

  @Test("Columns: identity always and by default, serial, generated stored, comments")
  func columns() async throws {
    try await withFixture { session, schema, _ in
      let table = try await introspector.tableStructure(
        schema: schema, table: Self.table, in: session)
      #expect(table.schema == schema && table.name == Self.table)
      #expect(table.comment == "it's the table")
      #expect(table.tableID == .postgresql(oid: try await oid(schema, Self.table, session)))
      #expect(table.columns.map(\.name) == ["id", "bd", "s", "name", "g", "pa", "pb"])
      let byName = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.name, $0) })
      #expect(
        byName["id"]
          == Column(
            ordinal: 1, name: "id", dataType: "integer", isNullable: false, identity: .always))
      #expect(
        byName["bd"]
          == Column(
            ordinal: 2, name: "bd", dataType: "bigint", isNullable: false, identity: .byDefault))
      let serial = try #require(byName["s"])
      #expect(serial.identity == nil && !serial.isNullable)
      #expect(serial.defaultExpression?.hasPrefix("nextval(") == true)
      #expect(serial.defaultExpression?.contains("_s_seq") == true)
      #expect(
        byName["name"]
          == Column(
            ordinal: 4, name: "name", dataType: "character varying(20)", isNullable: false,
            defaultExpression: "'x'::character varying", comment: "the name"))
      #expect(
        byName["g"]
          == Column(
            ordinal: 5, name: "g", dataType: "integer", isNullable: true,
            generated: .init(expression: "(s * 2)", isStored: true)))
    }
  }

  @Test("Constraints: primary key, unique, cross-schema foreign key with actions, check")
  func constraints() async throws {
    try await withFixture { session, schema, other in
      let table = try await introspector.tableStructure(
        schema: schema, table: Self.table, in: session)
      #expect(
        table.constraints == [
          .init(name: "ck", kind: .check("(s > 0)"), columns: ["s"]),
          .init(
            name: "fk",
            kind: .foreignKey(
              .init(
                schema: other, table: "Parent", columns: ["b B", "a"], onUpdate: .setNull,
                onDelete: .cascade)),
            columns: ["pb", "pa"]),
          .init(name: "my \"t\"_pkey", kind: .primaryKey, columns: ["id"]),
          .init(name: "u q", kind: .unique, columns: ["name", "s"]),
        ])

      // A composite primary key in key order, not table order
      let parent = try await introspector.tableStructure(
        schema: other, table: "Parent", in: session)
      #expect(
        parent.constraints == [
          .init(name: "Parent_pkey", kind: .primaryKey, columns: ["b B", "a"])
        ])
      #expect(parent.indexes.map(\.keys) == [[.column("b B"), .column("a")]])
    }
  }

  @Test("Indexes: constraint-backed, expression, partial with method, INCLUDE columns left out")
  func indexes() async throws {
    try await withFixture { session, schema, _ in
      let table = try await introspector.tableStructure(
        schema: schema, table: Self.table, in: session)
      #expect(
        table.indexes == [
          .init(
            name: "ix_expr", keys: [.expression("lower(name::text)"), .column("pa")],
            isUnique: false, isPrimary: false, method: "btree", isPartial: false,
            predicate: nil),
          .init(
            name: "ix_incl", keys: [.column("pa")], isUnique: false, isPrimary: false,
            method: "btree", isPartial: false, predicate: nil),
          .init(
            name: "ix_part", keys: [.column("pa")], isUnique: false, isPrimary: false,
            method: "hash", isPartial: true, predicate: "(pa > 10)"),
          .init(
            name: "my \"t\"_pkey", keys: [.column("id")], isUnique: true, isPrimary: true,
            method: "btree", isPartial: false, predicate: nil),
          .init(
            name: "u q", keys: [.column("name"), .column("s")], isUnique: true,
            isPrimary: false, method: "btree", isPartial: false, predicate: nil),
        ])
    }
  }

  @Test("A missing table, or a view, throws")
  func missingTable() async throws {
    try await withFixture { session, schema, _ in
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: schema, table: "nope", in: session)
      }
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: schema, table: "v", in: session)
      }
    }
  }

  // MARK: - Fixture

  private func oid(
    _ schema: String, _ table: String, _ session: any DatabaseSession
  ) async throws -> UInt32 {
    let source = try await session.query(
      """
      SELECT c.oid::int8 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2
      """,
      binds: [.text(schema), .text(table)])
    var found: UInt32?
    for try await row in source.rows {
      if case .int(let value) = row.first { found = UInt32(exactly: value) }
    }
    return try #require(found)
  }

  /// `body` gets the session, the table schema and a second schema whose name needs quoting.
  private func withFixture(
    _ body: @MainActor (any DatabaseSession, String, String) async throws -> Void
  ) async throws {
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let schema = "ts_pg_\(suffix)"
    let other = "ts Other \(suffix)"
    let a = try SQLDialect.postgresql.quoteIdentifier(schema)
    let b = try SQLDialect.postgresql.quoteIdentifier(other)
    let t = "\(a).\(try SQLDialect.postgresql.quoteIdentifier(Self.table))"
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config())
    let session = try #require(await manager.session)
    let statements = [
      "CREATE SCHEMA \(a)",
      "CREATE SCHEMA \(b)",
      "CREATE TABLE \(b).\"Parent\" (a int, \"b B\" text, PRIMARY KEY (\"b B\", a))",
      """
      CREATE TABLE \(t) (
        id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        bd bigint GENERATED BY DEFAULT AS IDENTITY,
        s serial,
        name varchar(20) NOT NULL DEFAULT 'x',
        g int GENERATED ALWAYS AS (s * 2) STORED,
        pa int,
        pb text,
        CONSTRAINT "u q" UNIQUE (name, s),
        CONSTRAINT fk FOREIGN KEY (pb, pa) REFERENCES \(b)."Parent" ("b B", a)
          ON UPDATE SET NULL ON DELETE CASCADE,
        CONSTRAINT ck CHECK (s > 0)
      )
      """,
      "COMMENT ON COLUMN \(t).name IS 'the name'",
      "COMMENT ON TABLE \(t) IS 'it''s the table'",
      "CREATE INDEX ix_expr ON \(t) (lower(name), pa)",
      "CREATE INDEX ix_part ON \(t) USING hash (pa) WHERE pa > 10",
      "CREATE INDEX ix_incl ON \(t) (pa) INCLUDE (pb)",
      "CREATE VIEW \(a).v AS SELECT 1 AS x",
    ]
    let cleanup = ["DROP SCHEMA IF EXISTS \(a) CASCADE", "DROP SCHEMA IF EXISTS \(b) CASCADE"]
    do {
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session, schema, other)
    } catch {
      for sql in cleanup { _ = try? await session.command(sql, binds: []) }
      await manager.disconnect()
      throw error
    }
    for sql in cleanup { _ = try? await session.command(sql, binds: []) }
    await manager.disconnect()
  }

  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: false,
      statementTimeoutSeconds: 45
    )
  }
}
