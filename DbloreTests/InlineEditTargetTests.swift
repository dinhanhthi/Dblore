// InlineEditTargetTests.swift
// Inline edit is allowed only when every result column is a plain column of the target table
// (source table OID + attribute number from the RowDescription), so an edit can never be keyed
// by a value that came from another table or an expression.

import Foundation
import Testing

@testable import Dblore

@Suite("Inline Edit Target Tests")
struct InlineEditTargetTests {
  private static let ordersOID: UInt32 = 16_400
  private static let customersOID: UInt32 = 16_500

  /// orders(id PK = attnum 1, customer_id = 2, total = 3)
  private let orders = EditTable(
    oid: ordersOID, attributeNames: [1: "id", 2: "customer_id", 3: "total"],
    primaryKeyColumns: ["id"])

  private func column(_ name: String, _ oid: UInt32 = 0, _ attnum: Int16 = 0) -> ColumnInfo {
    ColumnInfo(name: name, type: "int4", tableOID: oid, attributeNumber: attnum)
  }

  @Test("SELECT * FROM orders is editable")
  func plainTableEditable() {
    let columns = [
      column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 2),
      column("total", Self.ordersOID, 3),
    ]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders) == ["id"])
  }

  @Test("Comma join: customers.id shadows orders.id -> not editable")
  func commaJoinNotEditable() {
    let columns = [
      column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 2),
      column("total", Self.ordersOID, 3), column("id", Self.customersOID, 1),
      column("name", Self.customersOID, 2),
    ]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("SELECT *, 5 AS id FROM orders -> not editable")
  func computedAliasNotEditable() {
    let columns = [
      column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 2),
      column("total", Self.ordersOID, 3), column("id"),
    ]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("A real column aliased as another column's name -> not editable")
  func renamedColumnNotEditable() {
    // SELECT id, total AS customer_id FROM orders
    let columns = [column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 3)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("PK column missing from the result -> not editable")
  func missingPrimaryKeyNotEditable() {
    let columns = [column("total", Self.ordersOID, 3)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("No origin metadata (old result) or no table -> not editable")
  func missingMetadataNotEditable() {
    let columns = [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "total", type: "int4")]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
    let plain = [column("id", Self.ordersOID, 1)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: plain, table: nil).isEmpty)
  }

  @Test("Table without primary key -> not editable")
  func noPrimaryKeyNotEditable() {
    let table = EditTable(oid: Self.ordersOID, attributeNames: [1: "id"], primaryKeyColumns: [])
    let columns = [column("id", Self.ordersOID, 1)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: table).isEmpty)
  }

  /// `orders` with its catalog schema and name, as the server resolves it
  private var namedOrders: EditTable {
    EditTable(
      oid: Self.ordersOID, attributeNames: [1: "id", 2: "customer_id", 3: "total"],
      primaryKeyColumns: ["id"], connectionEpoch: 4, schema: "public", name: "orders")
  }

  @Test("Lookup relation: an alias maps to its base column, an expression maps to nothing")
  func lookupRelationMapsAliases() throws {
    // SELECT id, customer_id AS cid, 1 AS x FROM orders
    let columns = [
      column("id", Self.ordersOID, 1), column("cid", Self.ordersOID, 2), column("x"),
    ]
    let relation = try #require(
      CellUpdateStatement.lookupRelation(columns: columns, table: namedOrders))
    #expect(relation.schema == "public")
    #expect(relation.table == "orders")
    #expect(relation.baseColumns == ["id", "customer_id", nil])
    #expect(relation.connectionEpoch == 4)
    // Editing stays fail-closed for the same columns
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: namedOrders).isEmpty)
  }

  @Test("Lookup relation: columns from two tables, no origin, or no catalog name -> none")
  func lookupRelationFailsClosed() {
    let join = [column("id", Self.ordersOID, 1), column("name", Self.customersOID, 2)]
    #expect(CellUpdateStatement.lookupRelation(columns: join, table: namedOrders) == nil)
    #expect(
      CellUpdateStatement.lookupRelation(columns: [column("x")], table: namedOrders) == nil)
    let plain = [column("cid", Self.ordersOID, 2)]
    #expect(CellUpdateStatement.lookupRelation(columns: plain, table: orders) == nil)
    #expect(CellUpdateStatement.lookupRelation(columns: plain, table: nil) == nil)
  }

  @Test("An aliased result gets a lookup relation and still no edit target")
  @MainActor
  func aliasedResultLooksUpButStaysReadOnly() async {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let manager = DatabaseConnectionManager()
    var table = namedOrders
    table.qualifiedName = "public.orders"
    table.connectionEpoch = 0
    await manager.seedPausedEditTable(table, id: orders)
    let columns = [
      ColumnInfo(
        name: "id", type: "int4", origin: ColumnOrigin(tableID: orders, columnOrdinal: 1)),
      ColumnInfo(
        name: "cid", type: "int4", origin: ColumnOrigin(tableID: orders, columnOrdinal: 2)),
      ColumnInfo(name: "x", type: "int4"),
    ]
    let result = QueryResult(
      columns: columns, rows: [[.int(1), .int(9), .int(1)]], rowCount: 1, executionTime: 0)
    let targets = await NotebookViewModel().resultTargets(
      for: "SELECT id, customer_id AS cid, 1 AS x FROM orders", result: result,
      connectionManager: manager, epoch: 0)
    #expect(targets.editTarget == nil)
    #expect(targets.lookupRelation?.baseColumns == ["id", "customer_id", nil])
  }

  @Test("PostgreSQL keyless plain and partitioned tables get a locator; inheritance parents none")
  func postgresKeylessLocator() async throws {
    // pg_class + pg_attribute rows of `editTable`: oid, attnum, attname, key position,
    // format('%I.%I'), relkind, relhassubclass, nspname, relname, generated
    func table(relkind: String, subclass: Bool, keyPosition: Int = 0) async throws -> EditTable? {
      let session = FakeDatabaseSession(
        capabilities: .contract(), columns: [],
        rows: [
          [
            .int(16_384), .int(1), .string("body"), .int(keyPosition), .string("public.notes"),
            .string(relkind), .bool(subclass), .string("public"), .string("notes"), .bool(false),
          ]
        ],
        slowQueries: false)
      return try await PostgresSchemaIntrospector().editTable(named: "notes", in: session)
    }
    let plain = try #require(try await table(relkind: "r", subclass: false))
    #expect(plain.primaryKeyColumns.isEmpty)
    #expect(plain.rowLocator == .pgLocator)
    #expect(plain.updateOnly)
    let partitioned = try #require(try await table(relkind: "p", subclass: true))
    #expect(partitioned.rowLocator == .pgLocator)
    // Child rows live in the partitions: never UPDATE ONLY
    #expect(!partitioned.updateOnly)
    #expect(try await table(relkind: "r", subclass: true) == nil)
    let keyed = try #require(try await table(relkind: "r", subclass: false, keyPosition: 1))
    #expect(keyed.primaryKeyColumns == ["body"])
    #expect(keyed.rowLocator == nil)
  }

  @Test("A pending transaction resolves the edit target from the column table identity")
  @MainActor
  func pendingTransactionResolvesColumnTableIdentity() async {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let target = await cachedTarget(cachedID: orders, columnID: orders)
    #expect(target?.tableID == orders)
    #expect(target?.primaryKeyColumns == ["id"])
    #expect(target?.qualifiedName == "public.orders")
  }

  @Test("The edit-table cache does not match a different table identity")
  @MainActor
  func cacheDoesNotMatchADifferentTableIdentity() async {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let customers = TableRef.postgresql(oid: Self.customersOID)
    #expect(await cachedTarget(cachedID: customers, columnID: orders) == nil)
  }

  @Test("A masked column is read-only, and a masked primary key leaves no edit target")
  @MainActor
  func maskedColumnsRefuseEdits() async throws {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let target = try #require(
      await cachedTarget(cachedID: orders, columnID: orders, masked: ["total"]))
    #expect(target.primaryKeyColumns == ["id"])
    #expect(target.generatedColumns.contains("total"))
    let columns = [
      ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "total", type: "int4", masked: true),
    ]
    let result = CellResult(
      columns: columns, rows: [[.int(1), .string("****")]], editTarget: target)
    #expect(NotebookViewModel().readOnlyColumnIndexes(result) == [1])
    // Mask text in the WHERE key would name the wrong row, or none
    #expect(await cachedTarget(cachedID: orders, columnID: orders, masked: ["id"]) == nil)
  }

  // MARK: - Updatable PostgreSQL views

  private static let viewOID: UInt32 = 16_600

  @Test("The view body probe is read-only and always rolls back, also when its SELECT fails")
  func viewBodyProbeRollsBack() async throws {
    let session = FakeDatabaseSession(
      capabilities: .contract(),
      columns: [column("id", Self.ordersOID, 1), column("x")], rows: [], slowQueries: false)
    let origins = try await session.columnOrigins(ofViewBody: " SELECT o.id, 1 AS x\n   FROM o;\n")
    #expect(
      origins == [ColumnOrigin(tableID: .postgresql(oid: Self.ordersOID), columnOrdinal: 1), nil])
    #expect(
      session.statements == [
        "BEGIN READ ONLY", "SET LOCAL statement_timeout = '5s'", "SET LOCAL lock_timeout = '5s'",
        "SELECT * FROM (\n SELECT o.id, 1 AS x\n   FROM o\n) AS v LIMIT 0", "ROLLBACK",
      ])
    let failing = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: [], slowQueries: false,
      failingQuery: "LIMIT 0")
    await #expect(throws: FakeQueryError.self) {
      try await failing.columnOrigins(ofViewBody: "SELECT 1;")
    }
    #expect(failing.statements.first == "BEGIN READ ONLY")
    #expect(failing.statements.last == "ROLLBACK")
  }

  @Test("A view's target comes from its catalog candidate and the probe on a side connection")
  @MainActor
  func viewTargetFromCandidateAndProbe() async throws {
    // CREATE VIEW v1(key, total, doubled) AS SELECT id, total, total * 2 FROM orders
    let (manager, factory) = try await viewManager(
      columns: [(1, "key", true), (2, "total", true), (3, "doubled", false)],
      probe: [ordersOrigin(1), ordersOrigin(3), nil])
    let view = TableRef.postgresql(oid: Self.viewOID)
    let table = try #require(try await manager.fetchEditTable(tableName: "v1", tableID: view))
    #expect(table.qualifiedName == "public.v1")
    #expect(table.primaryKeyColumns == ["key"])
    #expect(!table.updateOnly)
    #expect(table.rowLocator == nil)
    #expect(table.generatedColumns == ["doubled"])
    #expect(table.viewBase?.columns == ["key": 1, "total": 3])
    // The body is read and probed on a side connection, closed after; never on the tab's
    let tab = try #require(factory.sessions.first)
    let side = try #require(factory.sessions.dropFirst().first)
    #expect(side.statements.count == 6)
    #expect(side.statements.first?.contains("pg_catalog.pg_get_viewdef(") == true)
    #expect(
      Array(side.statements.dropFirst()).map { $0.prefix(14) } == [
        "BEGIN READ ONL", "SET LOCAL stat", "SET LOCAL lock", "SELECT * FROM ", "ROLLBACK",
      ])
    #expect(side.didClose)
    #expect(!tab.statements.contains { $0.contains("LIMIT 0") || $0.contains("pg_get_viewdef") })

    // A result of the view gets a view target, its masked column read-only; the probe is
    // cached: no second side connection
    let columns = [
      ColumnInfo(name: "key", type: "int4", origin: ColumnOrigin(tableID: view, columnOrdinal: 1)),
      ColumnInfo(
        name: "total", type: "int4", origin: ColumnOrigin(tableID: view, columnOrdinal: 2),
        masked: true),
    ]
    let result = QueryResult(
      columns: columns, rows: [[.int(1), .int(9)]], rowCount: 1, executionTime: 0)
    let target = try #require(
      await NotebookViewModel().editTarget(
        for: "SELECT key, total FROM v1", result: result, connectionManager: manager,
        epoch: await manager.connectionEpoch))
    #expect(target.viewBase == table.viewBase)
    #expect(target.generatedColumns == ["doubled", "total"])
    #expect(target.primaryKeyColumns == ["key"])
    #expect(factory.sessions.count == 2)
    await manager.disconnect()
  }

  @Test("A view missing its key column, or with an origin in another relation, is refused once")
  func viewRefusedAfterProbe() async throws {
    let cases: [(columns: [(Int16, String, Bool)], probe: [ColumnOrigin?])] = [
      // CREATE VIEW v1 AS SELECT total FROM orders
      ([(1, "total", true)], [ordersOrigin(3)]),
      // A view column whose origin is another relation
      (
        [(1, "id", true), (2, "name", true)],
        [
          ordersOrigin(1),
          ColumnOrigin(tableID: .postgresql(oid: Self.customersOID), columnOrdinal: 2),
        ]
      ),
    ]
    for refused in cases {
      let (manager, factory) = try await viewManager(columns: refused.columns, probe: refused.probe)
      let view = TableRef.postgresql(oid: Self.viewOID)
      #expect(try await manager.fetchEditTable(tableName: "v1", tableID: view) == nil)
      #expect(factory.sessions.dropFirst().first?.didClose == true)
      // Cached as not editable: no second probe, and no target while the catalog is paused
      #expect(try await manager.fetchEditTable(tableName: "v1", tableID: view) == nil)
      #expect(factory.sessions.count == 2)
      #expect(await manager.cachedEditTable(id: view) == nil)
      await manager.disconnect()
    }
  }

  @Test("A probe the server refuses is cached as not editable; a Cancel or lost link is not")
  func viewProbeServerErrorIsCached() async throws {
    let view = TableRef.postgresql(oid: Self.viewOID)
    let columns: [(Int16, String, Bool)] = [(1, "id", true)]
    // The base table's SELECT privilege is missing (42501): the next result opens no side link
    let denied = MySQLSessionError(code: 1142, sqlState: "42501", message: "permission denied")
    let (refused, refusedFactory) = try await viewManager(
      columns: columns, probe: [ordersOrigin(1)], probeError: denied)
    #expect(try await refused.fetchEditTable(tableName: "v1", tableID: view) == nil)
    #expect(try await refused.fetchEditTable(tableName: "v1", tableID: view) == nil)
    #expect(refusedFactory.sessions.count == 2)
    #expect(refusedFactory.sessions.dropFirst().first?.didClose == true)
    await refused.disconnect()
    // A cancelled statement (57014) or an error with no server answer is thrown, and not
    // probed again for 30 s: the results meanwhile open no side link
    let cancelled = MySQLSessionError(code: 1317, sqlState: "57014", message: "cancelled")
    for error in [cancelled as any Error, FakeQueryError()] {
      let clock = ProbeClock()
      let (manager, factory) = try await viewManager(
        columns: columns, probe: [ordersOrigin(1)], probeError: error, now: { clock.now })
      for _ in 0..<2 {
        await #expect(throws: (any Error).self) {
          try await manager.fetchEditTable(tableName: "v1", tableID: view)
        }
      }
      #expect(factory.sessions.count == 2)
      clock.advance(by: 31)
      await #expect(throws: (any Error).self) {
        try await manager.fetchEditTable(tableName: "v1", tableID: view)
      }
      #expect(factory.sessions.count == 3)
      await manager.disconnect()
    }
  }

  @Test("A lazy page of an uncached view opens no side link; the background read probes it")
  @MainActor
  func lazyViewPageOpensNoSideConnection() async throws {
    let (manager, factory) = try await viewManager(
      columns: [(1, "key", true), (2, "payload", true)], probe: [ordersOrigin(1), ordersOrigin(3)])
    let view = TableRef.postgresql(oid: Self.viewOID)
    var state = DataViewerState(schema: "public", name: "v1", orderColumns: ["key"])
    state.databaseType = .postgresql
    state.lazyColumns = [
      DataViewerState.LazyColumn(name: "key", type: "int4", isPrimaryKey: false, isPrefixed: false),
      DataViewerState.LazyColumn(
        name: "payload", type: "bytea", isPrimaryKey: false, isPrefixed: true),
    ]
    let read = QueryResult(
      columns: [
        ColumnInfo(
          name: "key", type: "int4", origin: ColumnOrigin(tableID: view, columnOrdinal: 1)),
        ColumnInfo(name: "payload", type: "bytea"),
        ColumnInfo(name: "dblore_byte_length_1", type: "int4"),
      ],
      rows: [[.int(1), .data(Data([1, 2])), .int(2)]], rowCount: 1, executionTime: 0)
    let viewModel = NotebookViewModel()
    let epoch = await manager.connectionEpoch
    let page = try await viewModel.strippedDataViewerPage(
      read, state: state, epoch: epoch, connectionManager: manager)
    #expect(page.result.columns.map(\.name) == ["key", "payload"])
    #expect(page.result.columns[1].origin == nil)
    #expect(factory.sessions.count == 1)
    // The background read probes it; the next page takes the cached map
    #expect(try await manager.fetchEditTable(tableName: #""public"."v1""#, tableID: view) != nil)
    #expect(factory.sessions.count == 2)
    let next = try await viewModel.strippedDataViewerPage(
      read, state: state, epoch: epoch, connectionManager: manager)
    #expect(next.result.columns[1].origin == ColumnOrigin(tableID: view, columnOrdinal: 2))
    #expect(factory.sessions.count == 2)
    await manager.disconnect()
  }

  @Test("Two results of the same uncached view opened together share one probe")
  func concurrentViewProbesShareOneSideConnection() async throws {
    let (manager, factory) = try await viewManager(
      columns: [(1, "key", true)], probe: [ordersOrigin(1)])
    let view = TableRef.postgresql(oid: Self.viewOID)
    // Both lookups pass the catalog read before either probes
    let barrier = ArrivalBarrier(parties: 2)
    await manager.setCatalogReadHook { await barrier.arrive() }
    async let first = manager.fetchEditTable(tableName: "v1", tableID: view)
    async let second = manager.fetchEditTable(tableName: "v1", tableID: view)
    let tables = try await [first, second]
    #expect(tables.allSatisfy { $0?.viewBase != nil })
    #expect(factory.sessions.count == 2)
    await manager.disconnect()
  }

  @Test("A cached view map is probed again after CREATE OR REPLACE VIEW (a new rule xmin)")
  func replacedViewIsProbedAgain() async throws {
    let version = ViewVersion("771")
    let (manager, factory) = try await viewManager(
      columns: [(1, "key", true), (2, "total", true)], probe: [ordersOrigin(1), ordersOrigin(3)],
      version: version)
    let view = TableRef.postgresql(oid: Self.viewOID)
    #expect(try await manager.fetchEditTable(tableName: "v1", tableID: view) != nil)
    #expect(try await manager.fetchEditTable(tableName: "v1", tableID: view) != nil)
    #expect(factory.sessions.count == 2)
    // Same names, base table and key, but the view was replaced: never the stale map
    version.set("905")
    let table = try #require(try await manager.fetchEditTable(tableName: "v1", tableID: view))
    #expect(factory.sessions.count == 3)
    #expect(table.viewBase?.definitionVersion == "905")
    await manager.disconnect()
  }

  private func ordersOrigin(_ attnum: Int) -> ColumnOrigin {
    ColumnOrigin(tableID: .postgresql(oid: Self.ordersOID), columnOrdinal: attnum)
  }

  /// A PostgreSQL manager on fake sessions where `v1` is a view candidate over `orders` (key
  /// attnum 1, no generated column, its `_RETURN` rule at `version`) with `columns` (attnum,
  /// name, updatable), and the body's probe reports `probe`, or throws `probeError`
  private func viewManager(
    columns: [(Int16, String, Bool)], probe: [ColumnOrigin?], probeError: (any Error)? = nil,
    version: ViewVersion = ViewVersion("771"),
    now: @escaping @Sendable () -> Date = { Date() }
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let candidateRows: @Sendable () -> [[CellValue]] = {
      columns.map { column in
        [
          .int(Int(Self.viewOID)), .string("public.v1"), .string("public"), .string("v1"),
          .int(28), .bool(true), .bool(true), .int(1), .int(Int(Self.ordersOID)), .string("r"),
          .bool(false), .string("{1}"), .int(Int(column.0)), .string(column.1), .bool(column.2),
          .string(version.value), .null,
        ]
      }
    }
    let probeColumns = probe.enumerated().map { index, origin in
      ColumnInfo(
        name: "c\(index)", type: "int4",
        origin: origin ?? ColumnOrigin(tableID: .postgresql(oid: 0), columnOrdinal: 0))
    }
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.postgresql.capabilities,
      failingQuery: probeError == nil ? nil : "LIMIT 0",
      queryAnswer: { sql, _ in
        if sql.contains("pg_relation_is_updatable") {
          return FakeQueryAnswer(columns: [], rows: candidateRows())
        }
        if sql.contains("pg_get_viewdef") {
          return FakeQueryAnswer(columns: [], rows: [[.string(" SELECT orders.id FROM orders;")]])
        }
        if sql.contains("LIMIT 0") { return FakeQueryAnswer(columns: probeColumns, rows: []) }
        return nil
      }, failingQueryError: probeError ?? FakeQueryError())
    let manager = DatabaseConnectionManager(sessionFactory: factory, now: now)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    return (manager, factory)
  }

  /// Catalog lookup is paused. The only stored table is `cachedID`; columns name `columnID`;
  /// `masked` columns carry the mask flag a rule sets.
  @MainActor
  private func cachedTarget(
    cachedID: TableRef, columnID: TableRef, masked: Set<String> = []
  ) async -> EditTarget? {
    let manager = DatabaseConnectionManager()
    let table = EditTable(
      oid: Self.ordersOID,
      attributeNames: [1: "id", 2: "customer_id", 3: "total"],
      primaryKeyColumns: ["id"],
      qualifiedName: "public.orders",
      connectionEpoch: 0,
      updateOnly: true)
    await manager.seedPausedEditTable(table, id: cachedID)
    let columns = [
      ColumnInfo(
        name: "id", type: "int4", origin: ColumnOrigin(tableID: columnID, columnOrdinal: 1),
        masked: masked.contains("id")),
      ColumnInfo(
        name: "total", type: "int4", origin: ColumnOrigin(tableID: columnID, columnOrdinal: 3),
        masked: masked.contains("total")),
    ]
    let result = QueryResult(
      columns: columns, rows: [[.int(1), .int(9)]], rowCount: 1, executionTime: 0)
    return await NotebookViewModel().editTarget(
      for: "SELECT id, total FROM orders", result: result, connectionManager: manager, epoch: 0)
  }
}

extension DatabaseConnectionManager {
  /// Pauses catalog lookup and stores one edit table under `id`.
  fileprivate func seedPausedEditTable(_ table: EditTable, id: TableRef) {
    txState = .appTx(pending: [])
    editTableCache = [id: table]
  }
}

/// The `_RETURN` rule `xmin` the fake catalog reports, changed by a test between reads
private final class ViewVersion: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String

  init(_ value: String) { stored = value }

  func set(_ value: String) {
    lock.lock()
    stored = value
    lock.unlock()
  }

  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

/// The clock of a view probe's retry window, moved by a test
private final class ProbeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_000_000)

  var now: Date { lock.withLock { current } }

  func advance(by seconds: TimeInterval) {
    lock.withLock { current = current.addingTimeInterval(seconds) }
  }
}

/// Holds each caller of `arrive` until `parties` callers have arrived
private actor ArrivalBarrier {
  private let parties: Int
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var arrived = 0

  init(parties: Int) { self.parties = parties }

  func arrive() async {
    arrived += 1
    guard arrived < parties else {
      for continuation in waiting { continuation.resume() }
      waiting = []
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }
}
