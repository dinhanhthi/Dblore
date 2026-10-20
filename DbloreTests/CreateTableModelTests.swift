// CreateTableModelTests.swift
// CreateTableModel: builds the draft from the sheet's fields into an exact DDL preview, refuses up
// front where the structure editor would (DuckDB, protected connections, MySQL under Protected
// mode), asks Safe Mode before sending, sends exactly the preview through the gate and reports
// created / pending outcomes. Also the sidebar entry points: New Table... per engine and the
// Rename / Drop Table row items, only where the connection may change the schema.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("CreateTableModelTests")
struct CreateTableModelTests {
  private static let mysql80 = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)
  private static let open = ProtectionPolicy(protectionLevel: .none)

  private func makeModel(
    _ database: FakeCreateTableDatabase, type: DatabaseType = .postgresql,
    policy: ProtectionPolicy = open, schema: String = "public",
    commitStyle: @escaping @MainActor () -> CommitStyle = { .immediate },
    history: CreateTableHistoryLog = CreateTableHistoryLog()
  ) -> CreateTableModel {
    CreateTableModel(
      schema: schema, schemas: [schema, "sales"],
      context: StructureEditorContext(
        database: database, databaseType: type, policy: policy, commitStyle: commitStyle,
        caller: nil, recordHistory: { history.outcomes += $0 }))
  }

  /// `items (id integer PK, name text DEFAULT 'x')`, names typed with stray spaces
  private func fill(_ model: CreateTableModel, comment: String = "") {
    model.tableName = " items "
    model.columns[0].name = "id "
    model.columns[0].type = "integer"
    model.columns[0].isPrimaryKey = true
    model.addColumn()
    model.columns[1].name = "name"
    model.columns[1].type = "text"
    model.columns[1].defaultExpression = "'x'"
    model.comment = comment
  }

  private static let itemsSQL = #"""
    CREATE TABLE "public"."items" (
      "id" integer NOT NULL,
      "name" text DEFAULT 'x',
      PRIMARY KEY ("id")
    )
    """#

  // MARK: - Draft and preview

  @Test("The fields build an exact preview; an incomplete draft explains and cannot be created")
  func previewFromFields() async throws {
    let model = makeModel(FakeCreateTableDatabase())
    await model.load()
    #expect(model.previewStatements.isEmpty)
    #expect(model.previewError != nil)
    #expect(!model.canCreate)

    fill(model, comment: "Things")
    #expect(model.previewError == nil)
    #expect(
      model.previewStatements == [
        Self.itemsSQL, #"COMMENT ON TABLE "public"."items" IS 'Things'"#,
      ])
    #expect(model.canCreate)

    // A blank comment adds nothing; another schema retargets the table
    model.comment = "  "
    model.schema = "sales"
    #expect(model.previewStatements.count == 1)
    #expect(model.previewStatements[0].hasPrefix(#"CREATE TABLE "sales"."items" ("#))

    // Removing a column drops the constraints that name it
    model.constraints = [TableStructure.Constraint(name: nil, kind: .unique, columns: ["name"])]
    model.removeColumn(model.columns[1].id)
    #expect(model.constraints.isEmpty)
    #expect(model.previewError == nil)
  }

  // MARK: - Refusals

  @Test("DuckDB, protected connections and MySQL under Protected mode are refused up front")
  func refusedUpFront() async throws {
    let cases: [(DatabaseType, ProtectionPolicy, StructureEditorConnectionState, String)] = [
      (.duckdb, Self.open, .init(), StructureEditorModel.duckDBMessage),
      (
        .postgresql, ProtectionPolicy(protectionLevel: .readOnly), .init(),
        StructureEditorModel.readOnlyMessage
      ),
      (
        .sqlite, ProtectionPolicy(protectionLevel: .schemaOnly), .init(),
        StructureEditorModel.schemaOnlyMessage
      ),
      (
        .mysql, ProtectionPolicy(protectionLevel: .none, protectedMode: true),
        .init(mysqlServerInfo: Self.mysql80), StructureEditorModel.mysqlReviewMessage
      ),
    ]
    for (type, policy, state, reason) in cases {
      let database = FakeCreateTableDatabase(state: state)
      let model = makeModel(database, type: type, policy: policy)
      await model.load()
      fill(model)
      #expect(model.disabledReason == reason, "\(type)")
      #expect(!model.canCreate, "\(type)")
      await model.create()
      #expect(await database.sent.isEmpty, "\(type)")
    }

    // MySQL with the server known and no Protected mode builds its own DDL
    let ready = FakeCreateTableDatabase(state: .init(mysqlServerInfo: Self.mysql80))
    let mysql = makeModel(ready, type: .mysql, schema: "shop")
    await mysql.load()
    fill(mysql, comment: "x")
    #expect(mysql.disabledReason == nil)
    #expect(mysql.previewStatements.last?.hasSuffix(") COMMENT = 'x'") == true)
  }

  // MARK: - Gate path

  @Test("Create sends exactly the preview through the gate, records it and finishes")
  func createSendsPreview() async throws {
    let database = FakeCreateTableDatabase(state: .init(connectionEpoch: 7))
    let history = CreateTableHistoryLog()
    let model = makeModel(database, history: history)
    var applied: [Bool] = []
    model.onApplied = { applied.append($0) }
    await model.load()
    fill(model)
    await model.create()
    #expect(await database.sent == [[Self.itemsSQL]])
    #expect(await database.epochs == [7])
    #expect(history.outcomes.map(\.status) == [.success])
    #expect(model.isFinished)
    #expect(model.applyError == nil)
    #expect(applied == [false])
  }

  @Test("Under Protected mode the table is pending until Commit; a failure keeps the sheet open")
  func pendingAndFailure() async throws {
    let pendingDatabase = FakeCreateTableDatabase()
    await pendingDatabase.setOutcome(pending: true)
    let pending = makeModel(pendingDatabase)
    var applied: [Bool] = []
    pending.onApplied = { applied.append($0) }
    await pending.load()
    fill(pending)
    await pending.create()
    #expect(pending.isFinished)
    #expect(pending.resultMessage == StructureEditorModel.pendingMessage)
    #expect(applied == [true])

    let failing = FakeCreateTableDatabase()
    await failing.setApplyError(DatabaseError.queryFailed("relation exists", 0))
    let history = CreateTableHistoryLog()
    let failed = makeModel(failing, history: history)
    await failed.load()
    fill(failed)
    await failed.create()
    #expect(!failed.isFinished)
    #expect(failed.applyError?.contains("relation exists") == true)
    #expect(history.outcomes.map(\.status) == [.error])
  }

  @Test("Safe Mode asks first; Cancel or an edit sends nothing; Confirm sends the preview")
  func safeMode() async throws {
    let database = FakeCreateTableDatabase()
    let model = makeModel(database, commitStyle: { .password })
    await model.load()
    fill(model)
    await model.create()
    #expect(model.pendingConfirmation?.count == 1)
    #expect(model.confirmationRequiresPassword)
    #expect(await database.sent.isEmpty)

    model.cancelConfirmation()
    await model.confirmCreate()
    #expect(await database.sent.isEmpty)

    // An edit after Safe Mode asked: what it showed is no longer what would be sent
    await model.create()
    model.tableName = "goods"
    await model.confirmCreate()
    #expect(await database.sent.isEmpty)

    await model.create()
    await model.confirmCreate()
    #expect(await database.sent.count == 1)
    #expect(await database.sent.first?.first?.contains(#""public"."goods""#) == true)
  }

  // MARK: - Sidebar entry points

  @Test("SQL table rows offer Rename and Drop Table only when the schema may change")
  func sqlRowActions() {
    #expect(
      SidebarSectionModel.rowActions(for: .tables, name: "items", language: .sql).isEmpty)
    let actions = SidebarSectionModel.rowActions(
      for: .tables, name: "items", language: .sql, canChangeSchema: true)
    #expect(actions == [.rename, .drop])
    #expect(actions.map { $0.title(for: .sql) } == ["Rename…", "Drop Table…"])
    // MongoDB keeps its titles
    #expect(SidebarSectionModel.RowAction.drop.title(for: .mongosh) == "Drop…")
    for kind in [SidebarSectionModel.Kind.views, .functions, .procedures, .triggers] {
      #expect(
        SidebarSectionModel.rowActions(
          for: kind, name: "items", language: .sql, canChangeSchema: true
        ).isEmpty)
    }
  }

  @Test("New Table... and table changes per engine: not DuckDB, not MongoDB")
  func perEngine() {
    for type in [DatabaseType.postgresql, .mysql, .sqlite] {
      #expect(SidebarSectionModel.supportsTableChanges(type), "\(type)")
      #expect(
        SidebarSectionModel.createActionTitle(for: .tables, databaseType: type) == "New Table…")
      #expect(SidebarSectionModel.createActionTitle(for: .views, databaseType: type) == nil)
    }
    #expect(!SidebarSectionModel.supportsTableChanges(.duckdb))
    #expect(!SidebarSectionModel.supportsTableChanges(.mongodb))
    #expect(SidebarSectionModel.createActionTitle(for: .tables, databaseType: .duckdb) == nil)
    #expect(
      SidebarSectionModel.createActionTitle(for: .tables, databaseType: .mongodb)
        == "New Collection…")
  }

  @Test("Table changes need a connected SQL workspace with a schema read that may change it")
  func canChangeTableSchema() {
    var config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: "/tmp/x.db", username: "",
      sslMode: .disable)
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    manager.schemaConnectionEpoch = 1
    #expect(!manager.canChangeTableSchema)  // disconnected
    manager.connectionState = .connected
    #expect(manager.canChangeTableSchema)
    manager.schemaConnectionEpoch = nil
    #expect(!manager.canChangeTableSchema)  // no schema read since the connect
    manager.schemaConnectionEpoch = 1
    for level in [ConnectionProtectionLevel.schemaOnly, .readOnly] {
      config.protectionLevel = level
      manager.workspace.connectionConfig = config
      #expect(!manager.canChangeTableSchema, "\(level)")
    }
    config.protectionLevel = .none
    config.databaseType = .duckdb
    manager.workspace.connectionConfig = config
    #expect(!manager.canChangeTableSchema)
  }
}

private final class CreateTableHistoryLog {
  var outcomes: [QueryHistoryOutcome] = []
}

private actor FakeCreateTableDatabase: StructureEditorDatabase {
  private let state: StructureEditorConnectionState
  private var applyError: Error?
  private var pending = false
  private(set) var sent: [[String]] = []
  private(set) var epochs: [UInt64] = []

  init(state: StructureEditorConnectionState = .init()) {
    self.state = state
  }

  func setApplyError(_ error: Error) { applyError = error }
  func setOutcome(pending: Bool) { self.pending = pending }

  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
    throw DatabaseError.queryFailed("not used", 0)
  }

  func structureEditorState() async -> StructureEditorConnectionState { state }

  func executeGatedSchemaChange(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch: UInt64, caller: UUID?
  ) async throws -> SchemaChangeResult {
    if let applyError { throw applyError }
    sent.append(statements)
    epochs.append(connectionEpoch)
    return SchemaChangeResult(
      statements: statements, pending: pending, insideUserTransaction: false, duration: 0.01)
  }
}
