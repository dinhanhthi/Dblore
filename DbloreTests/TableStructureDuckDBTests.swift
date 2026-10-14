// TableStructureDuckDBTests.swift
// DuckDBSchemaIntrospector.tableStructure against an in-memory database through the dev plugin
// (`.requiresDuckDBPlugin`): columns with defaults and comments, CREATE INDEX indexes with
// column and expression keys, primary key, unique, foreign key and check constraints, and names
// that need quoting.

import Foundation
import Testing

@testable import Dblore

@Suite("TableStructureDuckDBTests", .requiresDuckDBPlugin, .serialized)
@MainActor
struct TableStructureDuckDBTests {
  private let introspector = DuckDBSchemaIntrospector()
  private typealias Column = TableStructure.Column
  private static let schema = "o s"
  private static let table = "my \"t\""

  private static let fixture = [
    #"CREATE SCHEMA "o s""#,
    #"CREATE SEQUENCE "o s".seq"#,
    #"CREATE TABLE "o s".parent (a INTEGER, b VARCHAR, PRIMARY KEY (b, a))"#,
    #"""
    CREATE TABLE "o s"."my ""t""" (
      id INTEGER PRIMARY KEY, name VARCHAR NOT NULL DEFAULT 'x', n INTEGER DEFAULT 0 CHECK (n >= 0),
      g INTEGER GENERATED ALWAYS AS (n * 2) VIRTUAL, pa INTEGER, pb VARCHAR,
      s BIGINT DEFAULT nextval('"o s".seq'), UNIQUE (name, n),
      FOREIGN KEY (pb, pa) REFERENCES "o s".parent (b, a), CHECK (n < 100))
    """#,
    #"COMMENT ON COLUMN "o s"."my ""t""".name IS 'the name'"#,
    #"CREATE INDEX ix_expr ON "o s"."my ""t""" ((n + 1), name)"#,
    #"CREATE UNIQUE INDEX "ix u" ON "o s"."my ""t""" (pa)"#,
    #"CREATE TABLE main."my ""t""" (other INTEGER)"#,
  ]

  @Test("Columns: types, nullability, raw defaults and comments; generated reads as a default")
  func columns() async throws {
    try await withFixture { session in
      let table = try await introspector.tableStructure(
        schema: Self.schema, table: Self.table, in: session)
      #expect(table.tableID == .duckdb(schema: Self.schema, table: Self.table))
      #expect(table.schema == Self.schema && table.name == Self.table)
      #expect(
        table.columns == [
          Column(ordinal: 1, name: "id", dataType: "INTEGER", isNullable: false),
          Column(
            ordinal: 2, name: "name", dataType: "VARCHAR", isNullable: false,
            defaultExpression: "'x'", comment: "the name"),
          Column(
            ordinal: 3, name: "n", dataType: "INTEGER", isNullable: true, defaultExpression: "0"),
          Column(
            ordinal: 4, name: "g", dataType: "INTEGER", isNullable: true,
            defaultExpression: "CAST((n * 2) AS INTEGER)"),
          Column(ordinal: 5, name: "pa", dataType: "INTEGER", isNullable: true),
          Column(ordinal: 6, name: "pb", dataType: "VARCHAR", isNullable: true),
          Column(
            ordinal: 7, name: "s", dataType: "BIGINT", isNullable: true,
            defaultExpression: #"nextval('"o s".seq')"#),
        ])

      let other = try await introspector.tableStructure(
        schema: "main", table: Self.table, in: session)
      #expect(other.columns.map(\.name) == ["other"])
    }
  }

  @Test("Indexes: CREATE INDEX only, column and expression keys")
  func indexes() async throws {
    try await withFixture { session in
      let table = try await introspector.tableStructure(
        schema: Self.schema, table: Self.table, in: session)
      #expect(
        table.indexes == [
          .init(
            name: "ix u", keys: [.column("pa")], isUnique: true, isPrimary: false, method: nil,
            isPartial: false, predicate: nil),
          .init(
            name: "ix_expr", keys: [.expression("((n + 1))"), .column("name")], isUnique: false,
            isPrimary: false, method: nil, isPartial: false, predicate: nil),
        ])
    }
  }

  @Test("Constraints: primary key, unique, foreign key and checks in catalog order")
  func constraints() async throws {
    try await withFixture { session in
      let table = try await introspector.tableStructure(
        schema: Self.schema, table: Self.table, in: session)
      #expect(
        table.constraints == [
          .init(name: "my \"t\"_id_pkey", kind: .primaryKey, columns: ["id"]),
          .init(name: "my \"t\"_n_check", kind: .check("(n >= 0)"), columns: ["n"]),
          .init(name: "my \"t\"_name_n_key", kind: .unique, columns: ["name", "n"]),
          .init(
            name: "my \"t\"_pb_pa_b_a_fkey",
            kind: .foreignKey(
              .init(
                schema: Self.schema, table: "parent", columns: ["b", "a"], onUpdate: .noAction,
                onDelete: .noAction)),
            columns: ["pb", "pa"]),
          .init(name: "my \"t\"_n_check", kind: .check("(n < 100)"), columns: ["n"]),
        ])
    }
  }

  @Test("A missing table throws")
  func missingTable() async throws {
    try await withFixture { session in
      await #expect(throws: DatabaseError.self) {
        try await introspector.tableStructure(schema: Self.schema, table: "nope", in: session)
      }
    }
  }

  // MARK: - Fixture

  private func withFixture(_ body: (DuckDBSession) async throws -> Void) async throws {
    let config = ConnectionConfig(
      databaseType: .duckdb, database: DuckDBSession.inMemoryPath, sslMode: .disable,
      protectionLevel: .none, statementTimeoutSeconds: 60)
    let session = DuckDBSession(config: config) { try DuckDBTestPlugin.library() }
    try await session.open()
    do {
      for sql in Self.fixture {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }
}
