// SchemaSnapshotLoaderTests.swift
// SchemaSnapshotLoader through a fake connection: the schema's tables load sorted with the
// connection epoch (PostgreSQL through the qualified read, other engines table by table); one
// failed read fails the whole load; an open transaction, DuckDB / MongoDB, more than `maxTables`
// tables and a schema with no listed table are refused before any structure is read. The
// manager's qualified read runs on a private connection (never the tab's session), pins an
// empty search_path in a read-only transaction it always rolls back, closes the connection after
// success, failure and cancel, and is refused while a transaction is open.

import Foundation
import Testing

@testable import Dblore

@Suite("SchemaSnapshotLoaderTests")
struct SchemaSnapshotLoaderTests {
  private actor FakeDatabase: SchemaSnapshotDatabase {
    let databaseType: DatabaseType?
    let state: StructureEditorConnectionState
    let tables: [DatabaseTable]
    let failingTable: String?
    /// Structures read, either way
    private(set) var reads = 0
    private(set) var qualifiedReads = 0

    init(
      _ type: DatabaseType? = .postgresql, state: StructureEditorConnectionState = .init(),
      tables: [DatabaseTable], failingTable: String? = nil
    ) {
      self.databaseType = type
      self.state = state
      self.tables = tables
      self.failingTable = failingTable
    }

    func structureEditorState() async -> StructureEditorConnectionState { state }

    func fetchTables() async throws -> [DatabaseTable] { tables }

    func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
      reads += 1
      if table == failingTable { throw DatabaseError.queryFailed("read failed", 0) }
      return TableStructure(
        tableID: .postgresql(oid: 1), schema: schema, name: table, columns: [], indexes: [],
        constraints: [])
    }

    func fetchQualifiedTableStructures(
      schema: String, tables: [String], progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [TableStructure] {
      qualifiedReads += 1
      var structures: [TableStructure] = []
      for table in tables {
        structures.append(try await fetchTableStructure(schema: schema, table: table))
      }
      return structures
    }
  }

  private static func tables(_ schema: String, _ names: [String]) -> [DatabaseTable] {
    names.map { DatabaseTable(schema: schema, name: $0) }
  }

  @Test func loadsTheSchemasTablesSortedWithTheEpoch() async throws {
    var state = StructureEditorConnectionState()
    state.connectionEpoch = 7
    let server = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)
    state.mysqlServerInfo = server
    let listed = Self.tables("dev", ["orders", "audit"]) + Self.tables("prod", ["x"])
    // PostgreSQL reads every structure with qualified names: each side prints its own schema
    let cases: [(DatabaseType, StructureDDLBuilder.Engine, qualifiedReads: Int)] = [
      (.postgresql, .postgresql, 1), (.mysql, .mysql(server), 0),
    ]
    for (type, engine, qualifiedReads) in cases {
      let database = FakeDatabase(type, state: state, tables: listed)
      let snapshot = try await SchemaSnapshotLoader.load(schema: "dev", from: database)
      #expect(snapshot.tables.map(\.name) == ["audit", "orders"])
      #expect(snapshot.schema == "dev" && snapshot.engine == engine)
      #expect(snapshot.connectionEpoch == 7)
      #expect(await database.qualifiedReads == qualifiedReads, "\(type)")
    }
  }

  @Test func temporaryTablesAreLeftOut() async throws {
    var state = StructureEditorConnectionState()
    state.mysqlServerInfo = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)
    let listed =
      Self.tables("dev", ["orders"]) + [
        DatabaseTable(schema: "dev", name: "tmp", isTemporary: true)
      ]
    let database = FakeDatabase(.mysql, state: state, tables: listed)
    let snapshot = try await SchemaSnapshotLoader.load(schema: "dev", from: database)
    #expect(snapshot.tables.map(\.name) == ["orders"])
  }

  /// Once armed, cancels the task that sends the next matching statement
  private final class CancelSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func fire() {
      guard
        lock.withLock({
          defer { armed = false }
          return armed
        })
      else { return }
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }

  @Test func qualifiedReadRunsOnAPrivateConnectionThatAlwaysRollsBackAndCloses() async throws {
    let cancel = CancelSwitch()
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities,
      commandRows: { sql in
        // Armed: the read is cancelled inside its transaction, before any table is read
        if sql.hasPrefix("SET LOCAL") { cancel.fire() }
        return nil
      })
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    let tab = try #require(factory.sessions.first)
    let tabSent = tab.statements.count
    let begin = "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"
    let pin = "SET LOCAL search_path = ''"
    /// The private session of the read just made: closed, with its statements
    func side(_ number: Int) throws -> [String] {
      #expect(factory.sessions.count == number + 1)
      let session = try #require(factory.sessions.last)
      #expect(session.didClose)
      return session.statements
    }
    // Success (no table to read)
    let none = try await manager.fetchQualifiedTableStructures(
      schema: "dev", tables: [], progress: nil)
    #expect(none.isEmpty)
    #expect(try side(1) == [begin, pin, "ROLLBACK"])
    // Failure: the fake lists no table, the first read fails inside the transaction
    await #expect(throws: DatabaseError.self) {
      _ = try await manager.fetchQualifiedTableStructures(
        schema: "dev", tables: ["orders"], progress: nil)
    }
    let failed = try side(2)
    #expect(Array(failed.prefix(2)) == [begin, pin])
    #expect(failed.count == 4 && failed.last == "ROLLBACK")
    // Cancel
    cancel.arm()
    let task = Task {
      try await manager.fetchQualifiedTableStructures(
        schema: "dev", tables: ["orders"], progress: nil)
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try side(3) == [begin, pin, "ROLLBACK"])
    // Nothing went to the tab's session
    #expect(tab.statements.count == tabSent)
    // Never inside a transaction the user opened: no connection is opened, nothing is sent
    _ = try await manager.execute(
      userSQL: "BEGIN", policy: ProtectionPolicy(protectionLevel: .none))
    let sent = tab.statements.count
    await #expect(throws: SchemaCompareError.transactionOpen) {
      _ = try await manager.fetchQualifiedTableStructures(
        schema: "dev", tables: ["orders"], progress: nil)
    }
    #expect(tab.statements.count == sent && factory.sessions.count == 4)
  }

  @Test func oneFailedReadFailsTheWholeLoad() async throws {
    let database = FakeDatabase(
      tables: Self.tables("dev", ["a", "b", "c", "d", "e", "f"]), failingTable: "c")
    await #expect(throws: DatabaseError.self) {
      _ = try await SchemaSnapshotLoader.load(schema: "dev", from: database)
    }
  }

  @Test func refusalsComeBeforeAnyStructureRead() async throws {
    var open = StructureEditorConnectionState()
    open.transactionOpen = true
    let many = Self.tables("dev", (0...SchemaSnapshotLoader.maxTables).map { "t\($0)" })
    let cases: [(FakeDatabase, SchemaCompareError)] = [
      (FakeDatabase(state: open, tables: Self.tables("dev", ["a"])), .transactionOpen),
      (FakeDatabase(.duckdb, tables: Self.tables("dev", ["a"])), .unsupportedEngine("DuckDB")),
      (FakeDatabase(.mongodb, tables: Self.tables("dev", ["a"])), .unsupportedEngine("MongoDB")),
      (FakeDatabase(tables: many), .tooManyTables(SchemaSnapshotLoader.maxTables + 1)),
      // MySQL lists only the connected database: another schema is not an empty one
      (FakeDatabase(tables: Self.tables("prod", ["a"])), .schemaNotFound("dev")),
    ]
    for (database, expected) in cases {
      await #expect(throws: expected) {
        _ = try await SchemaSnapshotLoader.load(schema: "dev", from: database)
      }
      #expect(await database.reads == 0)
    }
  }
}
