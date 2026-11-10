// PostgresFlavorCatalogTests.swift
// Catalog reads on a CockroachDB connection: it has no `pg_stat_get_live_tuples`, and it
// refuses a privilege check on a relation of its `crdb_internal` schema, which it may evaluate
// before the schema filter. So the table listing reads no stats counter, and every privilege
// check runs only once the row's schema is known not to be a system schema. PostgreSQL itself
// gets the same SQL as before. On a server verified as Redshift, procedures and foreign keys
// send nothing (their catalog columns are PG11+).

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL catalog reads on wire-compatible servers")
struct PostgresFlavorCatalogTests {
  private static let privilegeFunctions = [
    "pg_catalog.pg_has_role", "pg_catalog.has_table_privilege",
    "pg_catalog.has_any_column_privilege", "pg_catalog.has_column_privilege",
  ]

  /// The SQL of each listing read, sent through a fake session
  private static func listingSQL(_ flavor: DatabaseFlavor?) async throws -> [String: String] {
    let introspector = PostgresSchemaIntrospector(flavor: flavor)
    let reads: [(String, (any DatabaseSession) async throws -> Void)] = [
      ("tables", { _ = try await introspector.tables(in: $0) }),
      ("views", { _ = try await introspector.views(in: $0) }),
      ("allColumns", { _ = try await introspector.allColumns(in: $0) }),
    ]
    var sql: [String: String] = [:]
    for (name, read) in reads {
      let session = FakeDatabaseSession(
        capabilities: .contract(), columns: [], rows: [], slowQueries: false)
      try await read(session)
      sql[name] = try #require(session.statements.first)
    }
    return sql
  }

  @Test("On CockroachDB the table listing reads no stats counter")
  func cockroachTablesReadNoStatsCounter() async throws {
    let tables = try #require(try await Self.listingSQL(.cockroachdb)["tables"])
    #expect(!tables.contains("pg_stat_get_live_tuples"))
  }

  @Test("On CockroachDB every privilege check is guarded by a system schema check")
  func cockroachPrivilegeChecksAreGuarded() async throws {
    for (name, sql) in try await Self.listingSQL(.cockroachdb) {
      let first = Self.privilegeFunctions.compactMap { sql.range(of: $0)?.lowerBound }.min()
      let privilege = try #require(first, "\(name) has no privilege check")
      let before = sql[..<privilege]
      let guardStart = try #require(
        before.range(of: "CASE WHEN n.nspname", options: .backwards), "\(name) is not guarded")
      let guardText = before[guardStart.lowerBound...]
      #expect(guardText.contains("'crdb_internal'"), "\(name): \(guardText)")
      #expect(guardText.contains("'pg_extension'"), "\(name): \(guardText)")
    }
  }

  @Test("PostgreSQL keeps the stats counter and unguarded privilege checks")
  func postgresSQLIsUnchanged() async throws {
    let sql = try await Self.listingSQL(nil)
    let tables = try #require(sql["tables"])
    #expect(tables.contains("pg_catalog.pg_stat_get_live_tuples(c.oid)"))
    for text in sql.values {
      #expect(!text.contains("crdb_internal"))
      #expect(!text.contains("CASE WHEN n.nspname"))
    }
  }

  /// The SQL that procedures and foreign keys send, with a configured and a verified flavor
  private static func routineAndKeySQL(
    flavor: DatabaseFlavor?, verified: DatabaseFlavor?
  ) async throws -> (procedures: [String], foreignKeys: [String], results: Int) {
    let introspector = PostgresSchemaIntrospector(flavor: flavor)
    let procedureSession = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [], slowQueries: false)
    procedureSession.brakeFlavor = verified
    let procedures = try await introspector.procedures(in: procedureSession)
    let keySession = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [], slowQueries: false)
    keySession.brakeFlavor = verified
    let keys = try await introspector.foreignKeys(in: keySession)
    return (procedureSession.statements, keySession.statements, procedures.count + keys.count)
  }

  @Test("A verified Redshift server gets no procedures or foreign keys read")
  func redshiftSkipsPG11Catalog() async throws {
    let sent = try await Self.routineAndKeySQL(flavor: .redshift, verified: .redshift)
    #expect(sent.results == 0)
    #expect(sent.procedures.isEmpty && sent.foreignKeys.isEmpty)
  }

  @Test(
    "Procedures and foreign keys are read unless the server is verified Redshift",
    arguments: [DatabaseFlavor.redshift, .cockroachdb, nil] as [DatabaseFlavor?])
  func unverifiedServersReadRoutinesAndKeys(_ flavor: DatabaseFlavor?) async throws {
    let sent = try await Self.routineAndKeySQL(flavor: flavor, verified: nil)
    #expect(sent.procedures.contains { $0.contains("p.prokind OPERATOR(pg_catalog.=) 'p'") })
    #expect(sent.foreignKeys.contains { $0.contains("c.conparentid OPERATOR(pg_catalog.=) 0") })
  }
}
