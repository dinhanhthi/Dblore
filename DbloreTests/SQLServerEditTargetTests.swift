// SQLServerEditTargetTests.swift
// SQL Server result column origins through a real `EnginePluginSession` on `FakeEnginePlugin`:
// the plugin's describe (`enrichColumnTypes`) names base columns, the app maps them to
// `TableRef.enginePlugin` and the ordinals of the table's `editTable`, so a keyed single-table
// result (editor or data-viewer page) gets an edit target. Aliases keep their base column,
// expressions have none; several statements, a procedure call, an aborted app transaction, a
// describe of other columns or of another table than the query's, and a keyless table give no
// origin or no target. Inside the pending app transaction the describe is still sent, and only
// cached edit tables and schema-qualified names are used; the server is then asked whether the
// transaction is still open (a timeout may have ended it); if not, it is aborted until Rollback.
// `USE` fails closed: it drops the cached edit tables (they name another database's tables after
// it) and is refused there.

import Foundation
import Testing

@testable import Dblore

@Suite(.timeLimit(.minutes(1))) @MainActor
struct SQLServerEditTargetTests {
  private let policy = ProtectionPolicy(protectionLevel: .none)

  private static let config = ConnectionConfig(
    databaseType: .sqlserver, host: "db.example.com", port: 1433, database: "shop",
    username: "sa", password: "pw", sslMode: .disable, timeoutSeconds: 5,
    protectionLevel: .none, safeMode: .silent, protectedMode: false)

  /// Builds a session on the fake's installed plugin
  private struct PluginFactory: DatabaseSessionFactory {
    let pluginID: String

    func makeSession(config: ConnectionConfig) async throws -> any DatabaseSession {
      EnginePluginSession(
        pluginID: pluginID, config: config, hostKeyValidator: RejectUnknownSSHHostKeys())
    }
  }

  /// A base column of `dbo.orders`
  private static func column(
    _ name: String, type: String = "int", base: String? = nil
  ) -> EngineEvent.Column {
    EngineEvent.Column(
      name: name, type: type,
      origin: .init(schema: "dbo", table: "orders", column: base ?? name))
  }

  /// A fake whose query reads `columns` (one row) and whose describe answers `described`;
  /// `dbo.orders (id, note)` keyed by `id` unless `keyed` is false
  private static func fake(
    columns: [EngineEvent.Column], described: [EngineEvent.Column], keyed: Bool = true
  ) -> FakeEnginePlugin {
    let fake = FakeEnginePlugin()
    fake.columns = columns.map { EngineEvent.Column(name: $0.name, type: $0.type) }
    fake.batches = [[columns.indices.map { .int($0) }]]
    fake.catalogAnswers[.enrichColumnTypes] = .catalog(.enrichColumnTypes(described))
    fake.catalogAnswers[.editTable] = .catalog(
      .editTable(
        .init(
          schema: "dbo", name: "orders", columns: ["id", "note"],
          primaryKeyColumns: keyed ? ["id"] : [])))
    return fake
  }

  private func connected(
    _ fake: FakeEnginePlugin
  ) async throws -> (NotebookViewModel, DatabaseConnectionManager, String) {
    let pluginID = fake.install()
    let manager = DatabaseConnectionManager(sessionFactory: PluginFactory(pluginID: pluginID))
    try await manager.connect(config: Self.config)
    let viewModel = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: Self.config))
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    return (viewModel, manager, pluginID)
  }

  private func run(
    _ sql: String, _ viewModel: NotebookViewModel, _ manager: DatabaseConnectionManager,
    caller: UUID? = nil
  ) async throws -> (result: QueryResult, targets: ResultTargets) {
    let epoch = await manager.connectionEpoch
    let result = try await manager.execute(
      userSQL: sql, policy: policy, maxRows: 100, caller: caller)
    let targets = await viewModel.resultTargets(
      for: sql, result: result, connectionManager: manager, epoch: epoch)
    return (result, targets)
  }

  private static func describes(_ fake: FakeEnginePlugin) -> Int {
    fake.count {
      if case .catalog(let catalog) = $0 { catalog.read == .enrichColumnTypes } else { false }
    }
  }

  @Test(
    "A keyed table read in the editor or a data-viewer page has an edit target",
    arguments: [
      Read.editor("SELECT * FROM [dbo].[orders]"),
      .editor("SELECT id, note FROM dbo.orders WHERE id = 1"),
      .editor("SELECT id, note FROM orders"), .page(orderColumns: ["id"]),
      .page(orderColumns: []),
    ])
  func keyedTableIsEditable(read: Read) async throws {
    let sql = read.sql
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note", type: "nvarchar(50)")],
      described: [Self.column("id"), Self.column("note", type: "nvarchar(50)")])
    let (viewModel, manager, pluginID) = try await connected(fake)
    let (result, targets) = try await run(sql, viewModel, manager)
    let tableID = TableRef.enginePlugin(pluginID, schema: "dbo", table: "orders")
    #expect(result.columns.map(\.origin?.columnOrdinal) == [1, 2])
    #expect(result.columns.allSatisfy { $0.origin?.tableID == tableID })
    #expect(
      result.columns.map(\.sourceName)
        == [
          ColumnSourceName(schema: "dbo", table: "orders", column: "id"),
          ColumnSourceName(schema: "dbo", table: "orders", column: "note"),
        ])
    let target = try #require(targets.editTarget)
    #expect(target.tableID == tableID)
    #expect(target.primaryKeyColumns == ["id"])
    #expect(target.qualifiedName == "[dbo].[orders]")
    // The describe got the query as sent and its columns
    let describe = fake.requests.compactMap { request -> EngineRequest.Catalog? in
      if case .catalog(let catalog) = request.kind, catalog.read == .enrichColumnTypes {
        catalog
      } else {
        nil
      }
    }
    #expect(describe.map { $0.args["query"] } == [.string(sql)])
    await manager.disconnect()
  }

  /// A read of `dbo.orders`: editor text, or a data-viewer page as the viewer builds it
  enum Read: Sendable {
    case editor(String)
    case page(orderColumns: [String])

    @MainActor var sql: String {
      switch self {
      case .editor(let sql): return sql
      case .page(let orderColumns):
        var state = DataViewerState(schema: "dbo", name: "orders", orderColumns: orderColumns)
        state.databaseType = .sqlserver
        return state.pageSQL
      }
    }
  }

  @Test("A bound read is described as sent, its binds as @pN")
  func boundReadIsDescribedAsSent() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    let epoch = await manager.connectionEpoch
    let result = try await manager.execute(
      userSQL: "SELECT * FROM [dbo].[orders] WHERE [id] = :id", parameters: ["id": .text("1")],
      policy: policy, maxRows: 100)
    let describe = fake.requests.compactMap { request -> EngineRequest.Catalog? in
      if case .catalog(let catalog) = request.kind, catalog.read == .enrichColumnTypes {
        catalog
      } else {
        nil
      }
    }
    #expect(
      describe.map { $0.args["query"] } == [
        .string("SELECT * FROM [dbo].[orders] WHERE [id] = @p1")
      ])
    #expect(result.columns.map(\.origin?.columnOrdinal) == [1, 2])
    let targets = await viewModel.resultTargets(
      for: "SELECT * FROM [dbo].[orders] WHERE [id] = @p1", result: result,
      connectionManager: manager, epoch: epoch)
    #expect(targets.editTarget?.primaryKeyColumns == ["id"])
    await manager.disconnect()
  }

  @Test("An alias keeps its base column; an expression has no origin")
  func aliasesAndExpressions() async throws {
    let fake = Self.fake(
      columns: [
        Self.column("order_id", base: "id"), Self.column("note"),
        EngineEvent.Column(name: "two", type: "int"),
      ],
      described: [
        Self.column("order_id", base: "id"), Self.column("note"),
        EngineEvent.Column(name: "two", type: "int"),
      ])
    let (viewModel, manager, _) = try await connected(fake)
    let (result, targets) = try await run(
      "SELECT id AS order_id, note, 1 + 1 AS two FROM dbo.orders", viewModel, manager)
    #expect(result.columns.map(\.origin?.columnOrdinal) == [1, 2, nil])
    #expect(result.columns.map(\.sourceName?.column) == ["id", "note", nil])
    // Not every column is a plain column of the table: read-only, the lookup keeps the bases
    #expect(targets.editTarget == nil)
    #expect(targets.lookupRelation?.baseColumns == ["id", "note", nil])
    await manager.disconnect()
  }

  @Test("A describe of other columns gives no origin and no target")
  func mismatchedDescribeFailsClosed() async throws {
    for described in [
      [Self.column("id")], [Self.column("id"), Self.column("Note", base: "note")],
    ] {
      let fake = Self.fake(columns: [Self.column("id"), Self.column("note")], described: described)
      let (viewModel, manager, _) = try await connected(fake)
      let (result, targets) = try await run("SELECT * FROM dbo.orders", viewModel, manager)
      #expect(result.columns.allSatisfy { $0.origin == nil && $0.sourceName == nil })
      #expect(targets.editTarget == nil)
      #expect(Self.describes(fake) == 1)
      await manager.disconnect()
    }
  }

  @Test("A table without a primary key has no origin and no target")
  func keylessTableIsNotEditable() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")], keyed: false)
    let (viewModel, manager, _) = try await connected(fake)
    let (result, targets) = try await run("SELECT * FROM dbo.orders", viewModel, manager)
    #expect(result.columns.allSatisfy { $0.origin == nil })
    #expect(targets.editTarget == nil)
    await manager.disconnect()
  }

  @Test(
    "Several statements, a procedure call or a join are never described",
    arguments: [
      "SELECT * FROM dbo.orders; SELECT * FROM dbo.orders", "EXEC dbo.list_orders",
      // A second statement without `;`: the driver shows its result, not the first
      "SELECT id, note FROM dbo.orders WHERE 1 = 0 EXEC dbo.list_orders",
      "SELECT id, note FROM dbo.orders WHERE 1 = 0 "
        + "UPDATE dbo.archive SET note = note OUTPUT inserted.id, inserted.note",
      "SELECT id, note FROM dbo.orders WHERE 1 = 0 DECLARE @x int",
      "SELECT o.id, o.note FROM dbo.orders o JOIN dbo.lines l ON l.order_id = o.id",
    ])
  func onlyOneSingleRelationReadIsDescribed(sql: String) async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (_, manager, _) = try await connected(fake)
    let columns = [ColumnInfo(name: "id", type: "int"), ColumnInfo(name: "note", type: "int")]
    let enriched = await manager.enrichColumnTypes(columns: columns, query: sql)
    #expect(enriched == columns)
    #expect(Self.describes(fake) == 0)
    await manager.disconnect()
  }

  private static func editTableReads(_ fake: FakeEnginePlugin) -> Int {
    fake.count {
      if case .catalog(let catalog) = $0 { catalog.read == .editTable } else { false }
    }
  }

  @Test("Inside the app transaction a cached table read is described and editable")
  func appTransactionUsesCachedEditTable() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, pluginID) = try await connected(fake)
    // Caches dbo.orders
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    let reads = Self.editTableReads(fake)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    fake.transactionOpen = true
    #expect(await manager.isMetadataPaused)
    let checks = Self.transactionChecks(fake)
    let (result, targets) = try await run(
      "SELECT * FROM [dbo].[orders]", viewModel, manager, caller: caller)
    #expect(Self.describes(fake) == 2)
    // Asked once after the describe; still open, so nothing changed
    #expect(Self.transactionChecks(fake) == checks + 1)
    #expect(await manager.txState == .appTx(pending: []))
    #expect(Self.editTableReads(fake) == reads)
    let tableID = TableRef.enginePlugin(pluginID, schema: "dbo", table: "orders")
    #expect(result.columns.map(\.origin?.columnOrdinal) == [1, 2])
    #expect(result.columns.allSatisfy { $0.origin?.tableID == tableID })
    #expect(targets.editTarget?.tableID == tableID)
    #expect(targets.editTarget?.primaryKeyColumns == ["id"])
    // An unqualified name is not resolved again there: it may name a view of the same name
    let (unqualified, unqualifiedTargets) = try await run(
      "SELECT * FROM orders", viewModel, manager, caller: caller)
    #expect(unqualified.columns.allSatisfy { $0.origin == nil })
    #expect(unqualifiedTargets.editTarget == nil)
    await manager.disconnect()
  }

  @Test("Inside the app transaction a table not cached has no origin and no catalog read")
  func appTransactionWithoutCacheFailsClosed() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    fake.transactionOpen = true
    let (result, targets) = try await run(
      "SELECT * FROM [dbo].[orders]", viewModel, manager, caller: caller)
    #expect(Self.describes(fake) == 1)
    #expect(Self.editTableReads(fake) == 0)
    #expect(result.columns.allSatisfy { $0.origin == nil })
    #expect(targets.editTarget == nil)
    await manager.disconnect()
  }

  private static func transactionChecks(_ fake: FakeEnginePlugin) -> Int {
    fake.count { $0 == .transactionState }
  }

  @Test("A describe outside a transaction sends no transaction check")
  func describeOutsideTransactionSendsNoCheck() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (_, manager, _) = try await connected(fake)
    let checks = Self.transactionChecks(fake)
    let columns = [ColumnInfo(name: "id", type: "int"), ColumnInfo(name: "note", type: "int")]
    let enriched = await manager.enrichColumnTypes(
      columns: columns, query: "SELECT * FROM dbo.orders")
    #expect(Self.describes(fake) == 1)
    #expect(enriched.map(\.origin?.columnOrdinal) == [1, 2])
    #expect(Self.transactionChecks(fake) == checks)
    await manager.disconnect()
  }

  @Test("A describe after which the server reports no transaction aborts it until Rollback")
  func describeThatEndedTheTransactionAbortsIt() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    // Caches dbo.orders
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    // A timeout during the describe rolled it back (XACT_ABORT ON): @@TRANCOUNT is 0
    fake.transactionOpen = false
    let (result, targets) = try await run(
      "SELECT * FROM [dbo].[orders]", viewModel, manager, caller: caller)
    #expect(Self.describes(fake) == 2)
    #expect(result.columns.allSatisfy { $0.origin == nil })
    #expect(targets.editTarget == nil)
    guard case .aborted(let reason, _) = await manager.txState else {
      Issue.record("The app transaction is not aborted")
      return
    }
    #expect(reason.contains("result columns were described"))
    // The DELETE after a read is never sent: the transaction is gone
    await #expect {
      _ = try await run(
        "SELECT * FROM [dbo].[orders]; DELETE FROM dbo.orders WHERE id = 1", viewModel, manager,
        caller: caller)
    } throws: { error in
      guard case DatabaseError.transactionAborted = error else { return false }
      return true
    }
    #expect(Self.deletes(fake) == 0)
    // ROLLBACK finds no transaction; the server reports none, so it ends as rolled back
    fake.commandError = .init(code: .query, message: "no corresponding BEGIN TRANSACTION")
    try await manager.rollbackAppTransaction()
    #expect(await manager.txState == .idle)
    await manager.disconnect()
  }

  private static func deletes(_ fake: FakeEnginePlugin) -> Int {
    fake.count { kind in
      switch kind {
      case .command(let command): command.sql.contains("DELETE")
      case .query(let query): query.sql.contains("DELETE")
      default: false
      }
    }
  }

  @Test("A describe after which the server does not answer aborts the transaction")
  func describeWithoutTransactionAnswerAbortsIt() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    fake.transactionOpen = nil
    // The DELETE after the read is never sent: the transaction may be gone
    await #expect {
      _ = try await run(
        "SELECT * FROM [dbo].[orders]; DELETE FROM dbo.orders WHERE id = 1", viewModel, manager,
        caller: caller)
    } throws: { error in
      guard case DatabaseError.transactionAborted(let message) = error else { return false }
      return message.contains("result columns were described")
    }
    #expect(Self.describes(fake) == 2)
    guard case .aborted(let reason, _) = await manager.txState else {
      Issue.record("The app transaction is not aborted")
      return
    }
    #expect(reason.contains("result columns were described"))
    #expect(Self.deletes(fake) == 0)
    await manager.disconnect()
  }

  @Test("An aborted app transaction sends no describe")
  func abortedTransactionSendsNoDescribe() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (_, manager, _) = try await connected(fake)
    try await manager.beginAppTransaction(caller: UUID())
    await manager.abortAppTransactionForTesting()
    #expect(await manager.isMetadataPaused)
    let columns = [ColumnInfo(name: "id", type: "int"), ColumnInfo(name: "note", type: "int")]
    let enriched = await manager.enrichColumnTypes(
      columns: columns, query: "SELECT * FROM dbo.orders")
    #expect(enriched == columns)
    #expect(Self.describes(fake) == 0)
    await manager.disconnect()
  }

  @Test("USE fails closed: it drops the cached edit tables and is refused in a transaction")
  func useIsUnknownAndInvalidatesEditTables() throws {
    let use = try #require(
      SQLStatementClassifier.classify("USE other_db", dialect: .sqlserver).first)
    #expect(use.kind == .unknown)
    #expect(use.nonTransactional)
    #expect(ProtectedTransactionRules.invalidatesEditTables(use))
  }

  @Test("After USE the cached edit tables are gone: a read in the app transaction has no target")
  func useDropsCachedEditTables() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    // Caches dbo.orders of `shop`
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    #expect(await !manager.editTableCache.isEmpty)
    let reads = Self.editTableReads(fake)
    _ = try await run("USE other_db", viewModel, manager)
    #expect(await manager.editTableCache.isEmpty)
    #expect(await manager.columnTypeCache.isEmpty)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    fake.transactionOpen = true
    #expect(await manager.isMetadataPaused)
    // [dbo].[orders] now names other_db's table: shop's key and columns are not served
    let (result, targets) = try await run(
      "SELECT * FROM [dbo].[orders]", viewModel, manager, caller: caller)
    #expect(Self.editTableReads(fake) == reads)
    #expect(result.columns.allSatisfy { $0.origin == nil })
    #expect(targets.editTarget == nil)
    await manager.disconnect()
  }

  @Test("After USE a fresh read fetches the edit table again")
  func useRefetchesEditTable() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    let firstReads = Self.editTableReads(fake)
    _ = try await run("USE other_db", viewModel, manager)
    #expect(await manager.editTableCache.isEmpty)
    // Read as the first time, with nothing cached
    let (_, targets) = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    #expect(Self.editTableReads(fake) == 2 * firstReads)
    #expect(targets.editTarget?.primaryKeyColumns == ["id"])
    #expect(await !manager.editTableCache.isEmpty)
    await manager.disconnect()
  }

  @Test("USE inside the app transaction is refused and never sent: the database stays")
  func useInsideAppTransactionIsRefused() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    let sent = fake.requests.count
    await #expect {
      _ = try await run("USE other_db", viewModel, manager, caller: caller)
    } throws: { error in
      guard case DatabaseError.blockedByProtection = error else { return false }
      return true
    }
    #expect(fake.requests.count == sent)
    await manager.disconnect()
  }

  @Test("A read of another relation than the described table has no origin and no target")
  func describeOfAnotherTableFailsClosed() async throws {
    let fake = Self.fake(
      columns: [Self.column("id"), Self.column("note")],
      described: [Self.column("id"), Self.column("note")])
    let (viewModel, manager, _) = try await connected(fake)
    let view = "SELECT id, note FROM [dbo].[orders_view]"
    let (result, targets) = try await run(view, viewModel, manager)
    #expect(Self.describes(fake) == 1)
    #expect(result.columns.allSatisfy { $0.origin == nil })
    #expect(result.columns.map(\.sourceName?.table) == ["orders", "orders"])
    #expect(targets.editTarget == nil)
    // Not even with dbo.orders cached, inside the app transaction
    _ = try await run("SELECT * FROM [dbo].[orders]", viewModel, manager)
    let caller = UUID()
    try await manager.beginAppTransaction(caller: caller)
    fake.transactionOpen = true
    let (paused, pausedTargets) = try await run(view, viewModel, manager, caller: caller)
    #expect(paused.columns.allSatisfy { $0.origin == nil })
    #expect(pausedTargets.editTarget == nil)
    await manager.disconnect()
  }
}

extension DatabaseConnectionManager {
  /// Marks the pending app transaction aborted, as a failed statement inside it does
  fileprivate func abortAppTransactionForTesting() {
    txState = .aborted(reason: "failed", pending: txState.pending)
  }
}
