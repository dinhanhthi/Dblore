// PostgresViewEditIntegrationTests.swift
// Cell edits through an updatable PostgreSQL view against the docker test database (CI only):
// the view body's probe reads base-table origins, a simple keyed view is editable and one edit
// changes exactly one base row, a CHECK OPTION violation changes nothing, and trigger, join,
// keyless, key-less and nested views stay read-only.

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL view edits - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct PostgresViewEditIntegrationTests {
  static let testConfig = ConnectionConfig(
    host: TestDatabase.host,
    port: TestDatabase.port,
    database: TestDatabase.database,
    username: TestDatabase.username,
    password: TestDatabase.password,
    sslMode: .disable,
    timeoutSeconds: 30
  )

  private let open = ProtectionPolicy(protectionLevel: .none)

  private static let drop = """
    DROP VIEW IF EXISTS b11v_v5, b11v_v1, b11v_v2, b11v_v3, b11v_v4, b11v_v6 CASCADE;
    DROP TABLE IF EXISTS b11v_t, b11v_u, b11v_k CASCADE;
    DROP FUNCTION IF EXISTS b11v_keep() CASCADE
    """

  /// t(id pk, a, b), u(id pk, t_id), k(a, b) with no key, and the views of the phase 13 gate
  private static let fixtures = [
    "CREATE TABLE b11v_t (id int PRIMARY KEY, a int, b text)",
    "INSERT INTO b11v_t VALUES (1, 10, 'x'), (2, 20, 'y')",
    "CREATE TABLE b11v_u (id int PRIMARY KEY, t_id int)",
    "CREATE TABLE b11v_k (a int, b text)",
    "CREATE VIEW b11v_v1 AS SELECT id, a, b FROM b11v_t WHERE a > 0 WITH CHECK OPTION",
    "CREATE VIEW b11v_v2 AS SELECT id, a, b FROM b11v_t",
    "CREATE FUNCTION b11v_keep() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'",
    """
    CREATE TRIGGER b11v_v2_instead INSTEAD OF UPDATE ON b11v_v2
      FOR EACH ROW EXECUTE FUNCTION b11v_keep()
    """,
    """
    CREATE VIEW b11v_v3 AS
      SELECT t.id, t.a, u.id AS u_id FROM b11v_t t JOIN b11v_u u ON u.t_id = t.id
    """,
    "CREATE VIEW b11v_v4 AS SELECT a, b FROM b11v_t",
    "CREATE VIEW b11v_v6 AS SELECT a, b FROM b11v_k",
    "CREATE VIEW b11v_v5 AS SELECT id, a FROM b11v_v1",
  ]

  private func connect() async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.testConfig)
    _ = try await manager.executeInternal(Self.drop)
    for sql in Self.fixtures { _ = try await manager.executeInternal(sql) }
    return manager
  }

  private func cleanUp(_ manager: DatabaseConnectionManager) async {
    _ = try? await manager.executeInternal(Self.drop)
    await manager.disconnect()
  }

  private func oid(_ manager: DatabaseConnectionManager, _ name: String) async throws -> UInt32 {
    let value = try await manager.executeInternal("SELECT '\(name)'::regclass::oid::int8")
      .rows.first?.first
    guard case .int(let number) = value, let oid = UInt32(exactly: number) else {
      throw DatabaseError.notEditable("no oid for \(name)")
    }
    return oid
  }

  private func editTable(
    _ manager: DatabaseConnectionManager, _ view: String
  ) async throws -> EditTable? {
    let viewOID = try await oid(manager, view)
    return try await manager.fetchEditTable(tableName: view, tableID: .postgresql(oid: viewOID))
  }

  @Test("The view body probe reports the base table's OID and attribute numbers")
  func probeReadsBaseOrigins() async throws {
    let manager = try await connect()
    let base = try await oid(manager, "b11v_t")
    let viewOID = try await oid(manager, "b11v_v1")
    let body = try await manager.executeInternal("SELECT pg_get_viewdef(\(viewOID)::oid)")
      .rows.first?.first
    guard case .string(let text) = body else {
      Issue.record("no view definition")
      await cleanUp(manager)
      return
    }
    let origins = try await manager.probeViewBody(text)
    #expect(
      origins == (1...3).map { ColumnOrigin(tableID: .postgresql(oid: base), columnOrdinal: $0) })
    await cleanUp(manager)
  }

  @Test("A simple keyed view is editable, and one edit changes exactly one base row")
  func simpleViewEditsOneBaseRow() async throws {
    let manager = try await connect()
    let table = try #require(try await editTable(manager, "b11v_v1"))
    #expect(table.primaryKeyColumns == ["id"])
    #expect(!table.updateOnly)
    #expect(table.rowLocator == nil)
    let base = try await oid(manager, "b11v_t")
    #expect(table.viewBase?.baseOID == base)
    let statement = try CellUpdateStatement.make(
      qualifiedName: table.qualifiedName, columnName: "b", newValue: "z",
      primaryKeyColumns: table.primaryKeyColumns, rowData: ["id": .int(1)],
      updateOnly: table.updateOnly)
    #expect(!statement.sql.contains("ONLY"))
    #expect(
      try await manager.executeGatedUpdate(
        statement, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)
    let rows = try await manager.executeInternal("SELECT b FROM b11v_t ORDER BY id").rows
    #expect(rows.map(\.first) == [.string("z"), .string("y")])
    await cleanUp(manager)
  }

  @Test("An edit that breaks the CHECK OPTION fails and changes nothing")
  func checkOptionViolationChangesNothing() async throws {
    let manager = try await connect()
    let table = try #require(try await editTable(manager, "b11v_v1"))
    let statement = try CellUpdateStatement.make(
      qualifiedName: table.qualifiedName, columnName: "a", newValue: "-1",
      primaryKeyColumns: table.primaryKeyColumns, rowData: ["id": .int(1)])
    await #expect(throws: (any Error).self) {
      try await manager.executeGatedUpdate(
        statement, policy: open, connectionEpoch: await manager.connectionEpoch)
    }
    let value = try await manager.executeInternal("SELECT a FROM b11v_t WHERE id = 1")
      .rows.first?.first
    #expect(value == .int(10))
    await cleanUp(manager)
  }

  @Test("Trigger, join, key-less, keyless-base and nested views stay read-only")
  func refusedViewsStayReadOnly() async throws {
    let manager = try await connect()
    for view in ["b11v_v2", "b11v_v3", "b11v_v4", "b11v_v6", "b11v_v5"] {
      #expect(try await editTable(manager, view) == nil, "\(view) is editable")
    }
    await cleanUp(manager)
  }
}

extension DatabaseConnectionManager {
  /// `columnOrigins(ofViewBody:)` on this manager's session
  fileprivate func probeViewBody(_ body: String) async throws -> [ColumnOrigin?] {
    try await withSession { try await $0.columnOrigins(ofViewBody: body) }
  }
}
