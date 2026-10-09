// PostgresRoutineSourceIntegrationTests.swift
// Trigger listing and routine/trigger source through PostgresSchemaIntrospector against the
// docker test database (TEST_DB_* env, port 5435). Each test uses its own schema, dropped on
// every path, and only asserts on that schema because other suites share the database.

import Foundation
import Testing

@testable import Dblore

@Suite(
  "Postgres routine source - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct PostgresRoutineSourceIntegrationTests {
  private let introspector = PostgresSchemaIntrospector()

  @Test("Triggers are listed with timing, events, enabled flag, and oid", .timeLimit(.minutes(2)))
  func triggersAreListed() async throws {
    try await withFixture { session, schema in
      let triggers = try await introspector.triggers(in: session).filter { $0.schema == schema }
      #expect(triggers.map(\.name) == ["items_ad", "items_biu", "items_bt", "items_view_ii"])

      let biu = try #require(triggers.first { $0.name == "items_biu" })
      #expect(biu.table == "items")
      #expect(biu.timing == .before)
      #expect(biu.events == [.insert, .update])
      #expect(biu.enabled)
      #expect(biu.oid != nil)

      let ad = try #require(triggers.first { $0.name == "items_ad" })
      #expect(ad.timing == .after)
      #expect(ad.events == [.delete])
      #expect(!ad.enabled)
      #expect(ad.oid != nil)
      #expect(ad.oid != biu.oid)

      let bt = try #require(triggers.first { $0.name == "items_bt" })
      #expect(bt.timing == .before)
      #expect(bt.events == [.truncate])

      let viewInsert = try #require(triggers.first { $0.name == "items_view_ii" })
      #expect(viewInsert.table == "items_view")
      #expect(viewInsert.timing == .insteadOf)
      #expect(viewInsert.events == [.insert])

      let source = try #require(try await introspector.definition(of: .trigger(biu), in: session))
      #expect(source.hasPrefix("CREATE TRIGGER items_biu BEFORE INSERT OR UPDATE ON"))
    }
  }

  @Test("Function and procedure source, one per overload; aggregates get a stub")
  func routineSources() async throws {
    try await withFixture { session, schema in
      let functions = try await introspector.functions(in: session).filter { $0.schema == schema }
      let picks = functions.filter { $0.name == "pick" }
      #expect(picks.count == 2)
      #expect(picks.allSatisfy { $0.oid != nil })
      var pickSources: [String] = []
      for pick in picks {
        let source = try #require(
          try await introspector.definition(of: .function(pick), in: session))
        #expect(source.hasPrefix("CREATE OR REPLACE FUNCTION \(schema).pick("))
        pickSources.append(source)
      }
      #expect(Set(pickSources).count == 2)

      let addOne = try #require(functions.first { $0.name == "add_one" })
      let addOneSource = try #require(
        try await introspector.definition(of: .function(addOne), in: session))
      #expect(addOneSource.contains("plpgsql"))
      #expect(addOneSource.contains("RETURN x + 1"))

      let procedures = try await introspector.procedures(in: session).filter { $0.schema == schema }
      let procedure = try #require(procedures.first { $0.name == "do_nothing" })
      #expect(procedure.oid != nil)
      let procedureSource = try #require(
        try await introspector.definition(of: .procedure(procedure), in: session))
      #expect(procedureSource.hasPrefix("CREATE OR REPLACE PROCEDURE \(schema).do_nothing("))

      let aggregateOID = try await oid(of: "my_sum", schema: schema, in: session)
      let aggregate = DatabaseFunction(
        schema: schema, name: "my_sum", returnType: "integer", arguments: "integer",
        oid: aggregateOID)
      let stub = try #require(
        try await introspector.definition(of: .function(aggregate), in: session))
      #expect(stub == "-- Source not available for aggregate my_sum(integer)")

      let unknown = DatabaseFunction(schema: schema, name: "x", returnType: "int")
      #expect(try await introspector.definition(of: .function(unknown), in: session) == nil)
    }
  }

  // MARK: - Fixture

  private func oid(
    of name: String, schema: String, in session: any DatabaseSession
  ) async throws -> UInt32 {
    let source = try await session.query(
      "SELECT p.oid::int8 FROM pg_proc p WHERE p.proname = $1 AND p.pronamespace = $2::regnamespace",
      binds: [.text(name), .text(schema)])
    var found: UInt32?
    for try await row in source.rows {
      if case .int(let value) = row.first { found = UInt32(exactly: value) }
    }
    return try #require(found)
  }

  private func withFixture(
    _ body: @MainActor (any DatabaseSession, String) async throws -> Void
  ) async throws {
    let schema = "routine_src_\(UUID().uuidString.prefix(8).lowercased())"
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config())
    let session = try #require(await manager.session)
    let statements = [
      "CREATE SCHEMA \(schema)",
      """
      CREATE FUNCTION \(schema).add_one(x integer) RETURNS integer LANGUAGE plpgsql
      AS $$ BEGIN RETURN x + 1; END $$
      """,
      "CREATE FUNCTION \(schema).pick(a integer) RETURNS integer LANGUAGE sql AS $$ SELECT a $$",
      "CREATE FUNCTION \(schema).pick(a text) RETURNS text LANGUAGE sql AS $$ SELECT a $$",
      """
      CREATE PROCEDURE \(schema).do_nothing(n integer) LANGUAGE plpgsql
      AS $$ BEGIN NULL; END $$
      """,
      """
      CREATE FUNCTION \(schema).step(integer, integer) RETURNS integer LANGUAGE sql
      AS $$ SELECT $1 + $2 $$
      """,
      "CREATE AGGREGATE \(schema).my_sum(integer) (SFUNC = \(schema).step, STYPE = integer)",
      "CREATE TABLE \(schema).items (id integer)",
      """
      CREATE FUNCTION \(schema).touch() RETURNS trigger LANGUAGE plpgsql
      AS $$ BEGIN RETURN NEW; END $$
      """,
      """
      CREATE TRIGGER items_biu BEFORE INSERT OR UPDATE ON \(schema).items
      FOR EACH ROW EXECUTE FUNCTION \(schema).touch()
      """,
      """
      CREATE TRIGGER items_ad AFTER DELETE ON \(schema).items
      FOR EACH ROW EXECUTE FUNCTION \(schema).touch()
      """,
      "ALTER TABLE \(schema).items DISABLE TRIGGER items_ad",
      """
      CREATE TRIGGER items_bt BEFORE TRUNCATE ON \(schema).items
      FOR EACH STATEMENT EXECUTE FUNCTION \(schema).touch()
      """,
      "CREATE VIEW \(schema).items_view AS SELECT id FROM \(schema).items",
      """
      CREATE TRIGGER items_view_ii INSTEAD OF INSERT ON \(schema).items_view
      FOR EACH ROW EXECUTE FUNCTION \(schema).touch()
      """,
    ]
    do {
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session, schema)
    } catch {
      _ = try? await session.command("DROP SCHEMA IF EXISTS \(schema) CASCADE", binds: [])
      await manager.disconnect()
      throw error
    }
    _ = try? await session.command("DROP SCHEMA IF EXISTS \(schema) CASCADE", binds: [])
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
