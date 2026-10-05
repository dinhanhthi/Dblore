// InlineEditIntegrationTests.swift
// Inline grid edit (S6) against the docker test database (TEST_DB_* env, port 5435 in CI/autopilot)

import Foundation
import Testing

@testable import Dblore

@Suite("Inline Edit - Integration (Requires PostgreSQL)", .requiresPostgres)
@MainActor
struct InlineEditIntegrationTests {
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

  private func connect() async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.testConfig)
    return manager
  }

  private func scalar(
    _ manager: DatabaseConnectionManager, _ sql: String
  ) async throws
    -> CellValue?
  {
    try await manager.executeInternal(sql).rows.first?.first
  }

  @Test("PK table: edit reports 1 affected row and the value changed (text bind, int column)")
  func editPrimaryKeyTable() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s6_edit_pk")
    _ = try await manager.executeInternal(
      "CREATE TABLE s6_edit_pk (id int PRIMARY KEY, name text, qty int NOT NULL DEFAULT 0)")
    _ = try await manager.executeInternal(
      "INSERT INTO s6_edit_pk VALUES (1, 'a', 1), (2, 'b', 2)")

    #expect(try await manager.fetchPrimaryKeyColumns(tableName: "s6_edit_pk") == ["id"])

    let rename = try CellUpdateStatement.make(
      qualifiedName: "public.s6_edit_pk", columnName: "name", newValue: "it's new",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1), "name": .string("a")])
    #expect(
      try await manager.executeGatedUpdate(
        rename, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)

    let requantify = try CellUpdateStatement.make(
      qualifiedName: "public.s6_edit_pk", columnName: "qty", newValue: "42",
      primaryKeyColumns: ["id"], rowData: ["id": .int(1)])
    #expect(
      try await manager.executeGatedUpdate(
        requantify, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)

    #expect(
      try await scalar(manager, "SELECT name FROM s6_edit_pk WHERE id = 1") == .string("it's new"))
    #expect(try await scalar(manager, "SELECT qty FROM s6_edit_pk WHERE id = 1") == .int(42))
    #expect(try await scalar(manager, "SELECT name FROM s6_edit_pk WHERE id = 2") == .string("b"))
    _ = try await manager.executeInternal("DROP TABLE s6_edit_pk")
  }

  @Test("Setting NULL works")
  func setNull() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s6_edit_null")
    _ = try await manager.executeInternal(
      "CREATE TABLE s6_edit_null (id int PRIMARY KEY, note text, n int)")
    _ = try await manager.executeInternal("INSERT INTO s6_edit_null VALUES (1, 'x', 5)")

    for column in ["note", "n"] {
      let statement = try CellUpdateStatement.make(
        qualifiedName: "public.s6_edit_null", columnName: column, newValue: nil,
        primaryKeyColumns: ["id"], rowData: ["id": .int(1)])
      #expect(
        try await manager.executeGatedUpdate(
          statement, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)
    }
    #expect(
      try await scalar(manager, "SELECT (note IS NULL AND n IS NULL)::text FROM s6_edit_null")
        == .string("true"))
    _ = try await manager.executeInternal("DROP TABLE s6_edit_null")
  }

  @Test("Composite uuid/int PK and identifiers with embedded quotes")
  func compositeKeyAndWeirdIdentifiers() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal(#"DROP TABLE IF EXISTS "s6_we""ird""#)
    _ = try await manager.executeInternal(
      #"CREATE TABLE "s6_we""ird" (k uuid, line int, "co""l" numeric, PRIMARY KEY (k, line))"#)
    let key = "0b9f6a52-7c43-4c43-9d1e-2f6f1f0f7a11"
    _ = try await manager.executeInternal(
      #"INSERT INTO "s6_we""ird" VALUES ('\#(key)', 1, 1.5), ('\#(key)', 2, 2.5)"#)

    #expect(
      try await manager.fetchPrimaryKeyColumns(tableName: #""s6_we""ird""#) == ["k", "line"])

    let statement = try CellUpdateStatement.make(
      qualifiedName: #"public."s6_we""ird""#, columnName: #"co"l"#, newValue: "9.75",
      primaryKeyColumns: ["k", "line"], rowData: ["k": .string(key), "line": .int(2)])
    #expect(
      try await manager.executeGatedUpdate(
        statement, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)
    #expect(
      try await scalar(manager, #"SELECT "co""l"::text FROM "s6_we""ird" WHERE line = 2"#)
        == .string("9.75"))
    #expect(
      try await scalar(manager, #"SELECT "co""l"::text FROM "s6_we""ird" WHERE line = 1"#)
        == .string("1.5"))
    _ = try await manager.executeInternal(#"DROP TABLE "s6_we""ird""#)
  }

  @Test("A timestamptz primary key with microseconds matches its decoded row")
  func microsecondTimestampPrimaryKey() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s6_edit_ts")
    _ = try await manager.executeInternal(
      "CREATE TABLE s6_edit_ts (at timestamptz PRIMARY KEY, note text)")
    _ = try await manager.executeInternal(
      "INSERT INTO s6_edit_ts VALUES ('2024-01-02 03:04:05.123456+00', 'x')")

    let decoded = try #require(try await scalar(manager, "SELECT at FROM s6_edit_ts"))
    let statement = try CellUpdateStatement.make(
      qualifiedName: "public.s6_edit_ts", columnName: "note", newValue: "y",
      primaryKeyColumns: ["at"], rowData: ["at": decoded])
    #expect(statement.values.last == "2024-01-02T03:04:05.123456Z")
    #expect(
      try await manager.executeGatedUpdate(
        statement, policy: open, connectionEpoch: await manager.connectionEpoch) == 1)
    #expect(try await scalar(manager, "SELECT note FROM s6_edit_ts") == .string("y"))
    _ = try await manager.executeInternal("DROP TABLE s6_edit_ts")
  }

  @Test("Table without PK: not editable and the edit is refused before sending")
  func noPrimaryKeyRefused() async throws {
    let manager = try await connect()
    defer { Task { await manager.disconnect() } }
    _ = try await manager.executeInternal("DROP TABLE IF EXISTS s6_edit_nopk")
    _ = try await manager.executeInternal("CREATE TABLE s6_edit_nopk (a int, b text)")
    _ = try await manager.executeInternal("INSERT INTO s6_edit_nopk VALUES (1, 'x'), (1, 'x')")

    let pk = try await manager.fetchPrimaryKeyColumns(tableName: "s6_edit_nopk")
    #expect(pk.isEmpty)

    let result = CellResult(
      columns: [ColumnInfo(name: "a", type: "int4"), ColumnInfo(name: "b", type: "text")],
      rows: [[.int(1), .string("x")]], tableName: "s6_edit_nopk", primaryKeyColumns: pk)
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: .none, safeMode: .silent)
    #expect(viewModel.canEdit(result) == false)

    viewModel.handleCellValueEdit(
      columnName: "b", columnType: "text", newValue: "changed", originalValue: .string("x"),
      tableName: "s6_edit_nopk", rowData: ["a": .int(1), "b": .string("x")],
      primaryKeyColumns: pk, cellId: nil, connectionManager: manager)

    #expect(throws: DatabaseError.self) {
      try CellUpdateStatement.make(
        qualifiedName: "public.s6_edit_nopk", columnName: "b", newValue: "changed",
        primaryKeyColumns: pk,
        rowData: ["a": .int(1), "b": .string("x")])
    }
    // Give a (wrongly) spawned send a chance to run, then prove nothing changed
    try await Task.sleep(for: .milliseconds(300))
    #expect(
      try await scalar(manager, "SELECT count(*)::int FROM s6_edit_nopk WHERE b = 'x'")
        == .int(2))
    _ = try await manager.executeInternal("DROP TABLE s6_edit_nopk")
  }
}
