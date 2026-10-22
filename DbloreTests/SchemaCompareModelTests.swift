// SchemaCompareModelTests.swift
// SchemaCompareModel safety through fake connections: Run sends the script to the target only,
// through `executeGatedSchemaChange` with the epoch captured at compare time, and nothing to the
// source; a changed epoch refuses before anything is sent; the source's private connection is
// closed after a compare, a failed read and a cancel; a MySQL run that stops at a failing
// statement says what ran and what did not (nothing, when it was rolled back); a ticked drop
// asks first, cannot be skipped by the Safe Mode answer, and once sent closes the table's tabs;
// changing a side clears the result; a new selection clears the last run's report; a second
// compare started before the first runs is ignored. On the app's manager (fake sessions) the
// source connection is a separate session that only reads and is closed, and the tab's session
// gets nothing from it; a MySQL source on another database keeps the tab's unremembered
// certificate.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("SchemaCompareModelTests")
struct SchemaCompareModelTests {
  // MARK: - Fakes

  /// The source's private connection: reads only, records each call and its disconnect
  private actor FakeSource: SchemaCompareSourceConnection {
    enum Failure { case none, read, hang }

    let tables: [TableStructure]
    let failure: Failure
    private(set) var calls: [String] = []
    private(set) var disconnected = false
    private(set) var started = false

    init(tables: [TableStructure], failure: Failure = .none) {
      self.tables = tables
      self.failure = failure
    }

    var databaseType: DatabaseType? { .postgresql }

    func structureEditorState() async -> StructureEditorConnectionState {
      calls.append("state")
      return StructureEditorConnectionState()
    }

    func fetchTables() async throws -> [DatabaseTable] {
      calls.append("tables")
      started = true
      switch failure {
      case .none: break
      case .read: throw DatabaseError.queryFailed("read failed", 0)
      case .hang: try await Task.sleep(for: .seconds(30))
      }
      return tables.map { DatabaseTable(schema: $0.schema, name: $0.name) }
    }

    func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
      calls.append("structure")
      return try #require(tables.first { $0.name == table })
    }

    func fetchQualifiedTableStructures(
      schema: String, tables names: [String], progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [TableStructure] {
      calls.append("qualified")
      return names.compactMap { name in tables.first { $0.name == name } }
    }

    func disconnect() async { disconnected = true }
  }

  /// The tab's connection: its own tables, the gate (recorded, optionally failing) and the
  /// source connections it opened
  private actor FakeTarget: SchemaCompareDatabase {
    struct GateCall {
      let statements: [String]
      let epoch: UInt64
      let caller: UUID?
    }

    let tables: [TableStructure]
    let source: FakeSource
    let gateError: (any Error)?
    private(set) var epoch: UInt64 = 7
    private(set) var gateCalls: [GateCall] = []
    private(set) var openedConfigs: [ConnectionConfig?] = []

    init(tables: [TableStructure], source: FakeSource, gateError: (any Error)? = nil) {
      self.tables = tables
      self.source = source
      self.gateError = gateError
    }

    func reconnected() { epoch += 1 }

    var databaseType: DatabaseType? { .postgresql }

    func structureEditorState() async -> StructureEditorConnectionState {
      var state = StructureEditorConnectionState()
      state.connectionEpoch = epoch
      return state
    }

    func fetchTables() async throws -> [DatabaseTable] {
      tables.map { DatabaseTable(schema: $0.schema, name: $0.name) }
    }

    func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
      try #require(tables.first { $0.name == table })
    }

    func fetchQualifiedTableStructures(
      schema: String, tables names: [String], progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [TableStructure] {
      names.compactMap { name in tables.first { $0.name == name } }
    }

    func executeGatedSchemaChange(
      _ statements: [String], policy: ProtectionPolicy, connectionEpoch: UInt64, caller: UUID?
    ) async throws -> SchemaChangeResult {
      gateCalls.append(GateCall(statements: statements, epoch: connectionEpoch, caller: caller))
      if let gateError { throw gateError }
      return SchemaChangeResult(
        statements: statements, pending: false, insideUserTransaction: false, duration: 0)
    }

    func openSchemaCompareSource(
      config: ConnectionConfig?, database: String?
    ) async throws -> any SchemaCompareSourceConnection {
      openedConfigs.append(config)
      return source
    }
  }

  // MARK: - Fixtures

  private static let caller = UUID()

  private static func table(_ name: String) -> TableStructure {
    TableStructure(
      tableID: .postgresql(oid: 1), schema: "public", name: name,
      columns: [
        TableStructure.Column(
          ordinal: 1, name: "id", dataType: "integer", isNullable: false,
          defaultExpression: nil, identity: nil, generated: nil, comment: nil,
          columnType: nil, extra: nil, characterSet: nil, collation: nil)
      ],
      indexes: [], constraints: [])
  }

  private static let savedEntry = ConnectionHistoryEntry(
    config: ConnectionConfig(
      databaseType: .postgresql, host: "staging", port: 5432, database: "app", username: "u",
      sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))

  private static func model(
    _ database: any SchemaCompareDatabase, targetSchemas: [String] = ["public"]
  ) -> SchemaCompareModel {
    let model = SchemaCompareModel(
      context: SchemaCompareContext(
        database: database, databaseType: .postgresql,
        policy: { ProtectionPolicy(protectionLevel: .none) }, commitStyle: { .immediate },
        caller: caller, recordHistory: { _ in }, password: { _ in nil }),
      targetSchemas: targetSchemas, targetSchema: "public", savedConnections: [savedEntry])
    model.sourceConnection = .saved(savedEntry.id)
    model.sourceSchema = "public"
    return model
  }

  /// Source: `orders` plus `new` tables; target: `orders` plus `targetOnly` tables
  private static func fakes(
    newTables: [String] = ["audit"], targetOnly: [String] = [],
    failure: FakeSource.Failure = .none, gateError: (any Error)? = nil
  ) -> (FakeTarget, FakeSource) {
    let source = FakeSource(
      tables: [table("orders")] + newTables.map(table), failure: failure)
    let target = FakeTarget(
      tables: [table("orders")] + targetOnly.map(table), source: source, gateError: gateError)
    return (target, source)
  }

  // MARK: - Tests

  @Test func runSendsTheScriptToTheTargetOnlyThroughTheGate() async throws {
    let (target, source) = Self.fakes()
    let model = Self.model(target)
    await model.compare()
    #expect(model.compareError == nil)
    #expect(model.items.map(\.id) == ["table.create \"audit\""])
    let statements = model.script.statements.map(\.sql)
    #expect(!statements.isEmpty)
    // The saved connection was opened for the source, not the tab's own
    let opened = await target.openedConfigs
    #expect(opened.count == 1 && opened.first??.host == "staging")
    #expect(await source.disconnected)
    let sourceCalls = await source.calls

    await model.run()

    let calls = await target.gateCalls
    #expect(calls.count == 1)
    #expect(calls.first?.statements == statements)
    #expect(calls.first?.epoch == 7 && calls.first?.caller == Self.caller)
    // Nothing reached the source during the run, and it stays closed
    #expect(await source.calls == sourceCalls)
    #expect(await target.openedConfigs.count == 1)
    #expect(model.runError == nil)
    #expect(!model.canRun)
  }

  @Test func aChangedConnectionRefusesTheRunBeforeSendingAnything() async throws {
    let (target, _) = Self.fakes()
    let model = Self.model(target)
    await model.compare()
    #expect(model.canRun)
    await target.reconnected()

    await model.run()

    #expect(await target.gateCalls.isEmpty)
    #expect(model.runError == "The connection changed since the compare. Compare again.")
  }

  @Test func theSourceConnectionClosesAfterAFailedReadAndACancel() async throws {
    // A failed read: shown as the source's failure, the connection closed
    let (failingTarget, failing) = Self.fakes(failure: .read)
    let failed = Self.model(failingTarget)
    await failed.compare()
    #expect(await failing.disconnected)
    #expect(failed.compareError?.hasPrefix("Source") == true)
    #expect(failed.items.isEmpty && !failed.canRun)

    // Cancel while the source is read: no error, the connection closed
    let (hangingTarget, hanging) = Self.fakes(failure: .hang)
    let cancelled = Self.model(hangingTarget)
    async let done: Void = cancelled.compare()
    for _ in 0..<500 where !(await hanging.started) {
      try await Task.sleep(for: .milliseconds(5))
    }
    cancelled.cancelCompare()
    await done
    #expect(await hanging.disconnected)
    #expect(cancelled.compareError == nil && cancelled.progress == nil)
    #expect(cancelled.items.isEmpty)
  }

  @Test func aRunThatStopsAtAFailingStatementSaysWhatRanAndWhatDidNot() async throws {
    let (target, _) = Self.fakes(
      newTables: ["a1", "a2", "a3"],
      gateError: DatabaseError.schemaChangePartiallyApplied(
        applied: 1, total: 3, reason: "table exists"))
    let model = Self.model(target)
    await model.compare()
    let statements = model.script.statements.map(\.sql)
    #expect(statements.count == 3)

    await model.run()

    let report = try #require(model.runReport)
    #expect(report.applied == [statements[0]])
    #expect(report.failed == statements[1])
    #expect(report.notRun == [statements[2]])
    #expect(model.runError?.contains("Compare again") == true)
    // Part of it is applied: the diff is stale until the next compare
    #expect(!model.canRun)

    // An atomic run rolled back: nothing ran, every other statement did not run, the diff
    // still holds
    let (atomic, _) = Self.fakes(
      newTables: ["a1", "a2", "a3"],
      gateError: DatabaseError.batchStatementFailed(
        index: 1, sqlPrefix: "", reason: "table exists", rolledBack: true))
    let rolledBack = Self.model(atomic)
    var applied = 0
    rolledBack.onApplied = { applied += 1 }
    await rolledBack.compare()
    await rolledBack.run()
    let atomicReport = try #require(rolledBack.runReport)
    #expect(atomicReport.applied.isEmpty)
    #expect(atomicReport.failed == statements[1])
    #expect(atomicReport.notRun == [statements[0], statements[2]])
    #expect(applied == 0)
    #expect(rolledBack.canRun)
    // A new selection builds another script: the old run's report goes with it
    rolledBack.setSelected(try #require(rolledBack.items.first).id, false)
    #expect(rolledBack.runReport == nil && rolledBack.runError == nil)
  }

  @Test func aSecondCompareStartedBeforeTheFirstRunsIsIgnored() async throws {
    let (target, _) = Self.fakes()
    let model = Self.model(target)
    let first = Task { await model.compare() }
    let second = Task { await model.compare() }
    await first.value
    await second.value
    #expect(await target.openedConfigs.count == 1)
    #expect(model.items.map(\.id) == ["table.create \"audit\""])
    #expect(!model.isComparing)
  }

  @Test func aTickedDropAsksFirstAndClosesTheTablesTabsOnceSent() async throws {
    let (target, _) = Self.fakes(newTables: [], targetOnly: ["legacy"])
    let model = Self.model(target)
    var changes: [(StructureEditorModel.TableChange, Bool)] = []
    model.onTableChange = { changes.append(($0, $1)) }
    await model.compare()
    let drop = try #require(model.items.first { model.isDestructive($0) })
    model.setSelected(drop.id, true)
    for _ in 0..<500 where model.isBuildingScript {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.script.statements.isEmpty)

    await model.run()
    #expect(await target.gateCalls.isEmpty)
    #expect(model.pendingDestructive != nil)
    // The Safe Mode answer cannot skip the drop confirmation
    await model.confirmRun()
    #expect(await target.gateCalls.isEmpty)
    #expect(changes.isEmpty)

    await model.confirmDestructive()
    #expect(await target.gateCalls.count == 1)
    #expect(changes.count == 1)
    #expect(changes.first?.0 == .dropped(schema: "public", table: "legacy"))
    #expect(changes.first?.1 == false)
  }

  @Test func changingASideClearsTheResult() async throws {
    let (target, _) = Self.fakes()
    let model = Self.model(target, targetSchemas: ["public", "other"])
    await model.compare()
    #expect(model.canRun && model.comparedTargetSchema == "public")

    model.targetSchema = "other"
    #expect(!model.hasResult && !model.canRun)
    #expect(model.items.isEmpty && model.script.statements.isEmpty)
    #expect(model.comparedTargetSchema == nil)

    model.targetSchema = "public"
    await model.compare()
    #expect(model.canRun)
    model.sourceSchema = "staging"
    #expect(!model.hasResult && !model.canRun)
  }

  /// Records the client certificate each new session would load for its own config
  nonisolated private final class CertificateRecordingFactory: DatabaseSessionFactory,
    @unchecked Sendable
  {
    let inner = FakeDatabaseSessionFactory(capabilities: DatabaseType.mysql.capabilities)
    private let lock = NSLock()
    private var recorded: [(account: String, material: ClientCertificateMaterial?)] = []

    var loads: [(account: String, material: ClientCertificateMaterial?)] {
      lock.withLock { recorded }
    }

    func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
      let material = ClientCertificateStoreFactory.load(for: config)
      let account = ClientCertificateStoreFactory.account(for: config)
      lock.withLock { recorded.append((account, material)) }
      return inner.makeSession(config: config)
    }
  }

  @Test func aMySQLSourceInAnotherDatabaseKeepsTheTabsUnrememberedCertificate() async throws {
    let factory = CertificateRecordingFactory()
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .mysql, host: "compare-cert", port: 3306, database: "app", username: "u",
      sslMode: .disable, rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    let material = ClientCertificateMaterial(certificatePEM: "cert", privateKeyPEM: "key")
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: config), material: material)
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await manager.connect(config: config)
    }
    scoped.clear()

    let side = try await manager.openSchemaCompareSource(config: nil, database: "staging")
    await side.disconnect()

    var staging = config
    staging.database = "staging"
    let loads = factory.loads
    #expect(
      loads.map(\.account) == [config, staging].map(ClientCertificateStoreFactory.account(for:)))
    #expect(loads.last?.material == material)
  }

  @Test func onTheAppManagerTheSourceIsAPrivateSessionThatOnlyReads() async throws {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.postgresql.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    let tab = try #require(factory.sessions.first)
    let tabSent = tab.statements.count
    let model = Self.model(manager)

    // The fake lists no table: the source read stops at its table list
    await model.compare()

    #expect(model.compareError?.hasPrefix("Source") == true)
    let sides = Array(factory.sessions.dropFirst())
    #expect(!sides.isEmpty)
    let transaction: Set<String> = [
      "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
      "SET LOCAL search_path = ''", "ROLLBACK",
    ]
    for side in sides {
      #expect(side.didClose)
      let reads = side.queries
      for sql in side.statements {
        #expect(reads.contains(sql) || transaction.contains(sql), "\(sql)")
      }
    }
    #expect(tab.statements.count == tabSent)
    #expect(await manager.isConnected)
  }
}
