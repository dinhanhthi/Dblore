// SchemaDiagramEditModelTests.swift
// `SchemaDiagramEditModel`: structures read through a fake loader, sends through a
// `FakeDatabaseSession`-backed manager. The build passes order statements across tables (a
// foreign key is dropped before the column it uses, a column is added before the foreign key
// that uses it), SQLite refuses foreign-key changes up front, a MySQL apply that stops part way
// is reported and routes only the table renames that ran, renames reach `onTableChange` as
// pending or not, an added column's rename and drop carry its foreign key, a column staged to be
// dropped refuses a rename with the reason, Apply records History through the context it was
// re-targeted to, and a table rename applied from the diagram moves its saved position.

import CoreGraphics
import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("SchemaDiagramEditModelTests")
struct SchemaDiagramEditModelTests {
  private typealias Key = SchemaDiagramEditModel.TableKey

  private static let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private static let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)
  private static let mysql80 = MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36)

  // MARK: - Fixtures

  private static func column(
    _ ordinal: Int, _ name: String, _ type: String
  )
    -> TableStructure
    .Column
  {
    TableStructure.Column(
      ordinal: ordinal, name: name, dataType: type, isNullable: true, defaultExpression: nil,
      identity: nil, generated: nil, comment: nil, columnType: nil, extra: nil,
      characterSet: nil, collation: nil)
  }

  private static func table(
    _ schema: String, _ name: String, _ columns: [String], type: String = "integer"
  ) -> TableStructure {
    TableStructure(
      tableID: TableRef("test:\(schema).\(name)"), schema: schema, name: name,
      columns: columns.enumerated().map { column($0.offset + 1, $0.element, type) },
      indexes: [], constraints: [])
  }

  private static func tables(_ schema: String) -> [TableStructure] {
    [table(schema, "users", ["id", "name"]), table(schema, "orders", ["id", "user_id"])]
  }

  private static func newColumn(_ name: String) -> StructureChange.NewColumn {
    StructureChange.NewColumn(name: name, type: "text", isNullable: true, defaultExpression: nil)
  }

  private func connect(
    _ type: DatabaseType
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: type, host: "fake", port: 1, database: "db", username: "u",
        password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    return (manager, factory)
  }

  private func model(
    _ manager: DatabaseConnectionManager, _ database: FakeDiagramDatabase, type: DatabaseType,
    policy: ProtectionPolicy = open, commitStyle: CommitStyle = .immediate
  ) async -> SchemaDiagramEditModel {
    let context = SchemaChangeContext(
      manager: manager, databaseType: type, policy: policy, commitStyle: { commitStyle },
      caller: nil, recordHistory: { _ in })
    return SchemaDiagramEditModel(
      context: context, database: database, connectionEpoch: await manager.connectionEpoch)
  }

  // MARK: - Passes

  @Test("A foreign key is dropped before the column it references, whatever the staging order")
  func dropForeignKeyBeforeDropColumn() async throws {
    let (manager, factory) = try await connect(.postgresql)
    let model = await model(manager, FakeDiagramDatabase(Self.tables("public")), type: .postgresql)
    let users = Key(schema: "public", table: "users")

    await model.dropColumn("id", in: users)
    await model.dropForeignKey(
      ForeignKey(
        constraintName: "orders_user_id_fkey", sourceSchema: "public", sourceTable: "orders",
        sourceColumns: ["user_id"], targetSchema: "public", targetTable: "users",
        targetColumns: ["id"]))

    let expected = [
      "ALTER TABLE \"public\".\"orders\" DROP CONSTRAINT \"orders_user_id_fkey\"",
      "ALTER TABLE \"public\".\"users\" DROP COLUMN \"id\"",
    ]
    #expect(model.previewStatements == expected)
    #expect(model.changeCount == 2)
    #expect(model.touchedTables == ["public.users", "public.orders"])

    await model.apply()

    #expect(model.applyError == nil)
    #expect(factory.statements == ["BEGIN"] + expected + ["COMMIT"])
    #expect(model.resultMessage == SchemaDiagramEditModel.appliedMessage)
    #expect(model.changeCount == 0)
  }

  @Test("A column is added before the foreign key that uses it, on either table")
  func addColumnBeforeAddForeignKey() async throws {
    let (manager, _) = try await connect(.postgresql)
    let model = await model(manager, FakeDiagramDatabase(Self.tables("public")), type: .postgresql)
    let users = Key(schema: "public", table: "users")
    let orders = Key(schema: "public", table: "orders")

    await model.addColumn(Self.newColumn("owner_code"), to: orders)
    await model.addForeignKey(from: orders, column: "owner_code", to: users, column: "code")
    await model.addColumn(Self.newColumn("code"), to: users)

    #expect(
      model.previewStatements == [
        "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"owner_code\" text",
        "ALTER TABLE \"public\".\"users\" ADD COLUMN \"code\" text",
        "ALTER TABLE \"public\".\"orders\" ADD FOREIGN KEY (\"owner_code\") "
          + "REFERENCES \"public\".\"users\" (\"code\")",
      ])
  }

  @Test("Two staging calls on one table read it once; the table shows loading meanwhile")
  func concurrentStagingReadsOnce() async throws {
    let (manager, _) = try await connect(.postgresql)
    let database = FakeDiagramDatabase(Self.tables("public"))
    let model = await model(manager, database, type: .postgresql)
    let users = Key(schema: "public", table: "users")

    async let first: Void = model.addColumn(Self.newColumn("a"), to: users)
    async let second: Void = model.addColumn(Self.newColumn("b"), to: users)
    _ = await (first, second)

    #expect(await database.loads == ["public.users"])
    #expect(model.changeCount == 2)
    #expect(model.loadingTables.isEmpty)
  }

  // MARK: - Loaded names

  @Test("An added column's rename edits its ADD COLUMN and foreign key; its drop removes both")
  func addedColumnCarriesForeignKey() async throws {
    let (manager, _) = try await connect(.postgresql)
    let model = await model(manager, FakeDiagramDatabase(Self.tables("public")), type: .postgresql)
    let users = Key(schema: "public", table: "users")
    let orders = Key(schema: "public", table: "orders")

    await model.addColumn(Self.newColumn("owner"), to: orders)
    await model.addForeignKey(from: orders, column: "owner", to: users, column: "id")
    await model.renameColumn("owner", in: orders, to: "owner_id")

    #expect(
      model.previewStatements == [
        "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"owner_id\" text",
        "ALTER TABLE \"public\".\"orders\" ADD FOREIGN KEY (\"owner_id\") "
          + "REFERENCES \"public\".\"users\" (\"id\")",
      ])

    await model.dropColumn("owner_id", in: orders)
    #expect(model.changeCount == 0)
    #expect(model.touchedTables.isEmpty)
    #expect(model.previewStatements.isEmpty)
  }

  @Test("Renaming a loaded column staged to be dropped says why and stages nothing")
  func renameDroppedColumnToasts() async throws {
    let (manager, _) = try await connect(.postgresql)
    let model = await model(manager, FakeDiagramDatabase(Self.tables("public")), type: .postgresql)
    let users = Key(schema: "public", table: "users")
    var toasts: [String] = []
    model.toastPresenter = { message, _ in toasts.append(message) }

    await model.dropColumn("name", in: users)
    let preview = model.previewStatements
    await model.renameColumn("name", in: users, to: "full_name")

    #expect(toasts == [SchemaDiagramEditModel.droppedColumnMessage])
    #expect(model.changes(in: users) == [.dropColumn(column: "name")])
    #expect(model.previewStatements == preview)
  }

  // MARK: - Context

  @Test("Apply after a retarget records History through the new context only")
  func retargetMovesHistory() async throws {
    let (manager, _) = try await connect(.postgresql)
    var first: [QueryHistoryOutcome] = []
    var second: [QueryHistoryOutcome] = []
    let epoch = await manager.connectionEpoch
    func context(
      _ record: @escaping @MainActor ([QueryHistoryOutcome]) async -> Void
    )
      -> SchemaChangeContext
    {
      SchemaChangeContext(
        manager: manager, databaseType: .postgresql, policy: Self.open,
        commitStyle: { .immediate }, caller: nil, recordHistory: record)
    }
    let model = SchemaDiagramEditModel(
      context: context { first += $0 }, database: FakeDiagramDatabase(Self.tables("public")),
      connectionEpoch: epoch)

    await model.renameTable(Key(schema: "public", table: "users"), to: "people")
    model.retarget(context { second += $0 })
    await model.apply()

    #expect(model.applyError == nil)
    #expect(first.isEmpty)
    #expect(second.map(\.sql) == ["ALTER TABLE \"public\".\"users\" RENAME TO \"people\""])
  }

  // MARK: - SQLite

  @Test("SQLite refuses foreign-key changes with the reason and reads nothing")
  func sqliteRefusesForeignKeys() async throws {
    let database = FakeDiagramDatabase(Self.tables("main"))
    let model = await model(
      DatabaseConnectionManager(
        sessionFactory: FakeDatabaseSessionFactory(capabilities: .contract())),
      database,
      type: .sqlite)
    var toasts: [String] = []
    model.toastPresenter = { message, _ in toasts.append(message) }
    let users = Key(schema: "main", table: "users")
    let orders = Key(schema: "main", table: "orders")

    #expect(model.foreignKeyChangeDisabledReason == SchemaDiagramEditModel.sqliteForeignKeyMessage)
    await model.addForeignKey(from: orders, column: "user_id", to: users, column: "id")
    await model.dropForeignKey(
      ForeignKey(
        constraintName: "fk", sourceSchema: "main", sourceTable: "orders",
        sourceColumns: ["user_id"], targetSchema: "main", targetTable: "users",
        targetColumns: ["id"]))

    #expect(toasts == Array(repeating: SchemaDiagramEditModel.sqliteForeignKeyMessage, count: 2))
    #expect(
      SchemaDiagramEditModel.sqliteForeignKeyMessage
        == "SQLite cannot add or drop a foreign key on an existing table.")
    #expect(model.changeCount == 0)
    #expect(await database.loads.isEmpty)
  }

  // MARK: - MySQL

  @Test(
    "MySQL warns before Apply; a partial apply is reported and routes only the renames that ran")
  func mysqlPartialApply() async throws {
    let (manager, factory) = try await connect(.mysql)
    let database = FakeDiagramDatabase(
      Self.tables("app"), state: .init(mysqlServerInfo: Self.mysql80))
    let model = await model(manager, database, type: .mysql)
    var toasts: [ToastMessage.ToastType] = []
    model.toastPresenter = { toasts.append($1) }
    var renames: [StructureEditorModel.TableChange] = []
    model.onTableChange = { change, _ in renames.append(change) }
    var applied: [Bool] = []
    model.onApplied = { applied.append($0) }
    let users = Key(schema: "app", table: "users")
    let orders = Key(schema: "app", table: "orders")

    await model.dropColumn("name", in: users)
    await model.renameTable(users, to: "people")
    await model.renameTable(orders, to: "purchases")
    let expected = [
      "ALTER TABLE `app`.`users` DROP COLUMN `name`",
      "RENAME TABLE `app`.`users` TO `app`.`people`",
      "RENAME TABLE `app`.`orders` TO `app`.`purchases`",
    ]
    #expect(model.previewStatements == expected)
    #expect(
      model.applyWarning
        == "Each statement commits at once; a failure leaves the earlier ones applied")
    try #require(factory.sessions.first).failNextCommand(containing: "`purchases`")

    await model.apply()

    #expect(factory.statements == expected)
    #expect(model.applyPartiallyFailed)
    #expect(model.applyError?.contains("Applied 2 of 3") == true)
    #expect(toasts.last == .warning)
    #expect(renames == [.renamed(schema: "app", from: "users", to: "people")])
    #expect(applied == [false])
    #expect(model.changeCount == 0)
  }

  // MARK: - Rename routing

  @Test(
    "A table rename reaches onTableChange, pending under Review",
    arguments: [false, true])
  func renameRouting(review: Bool) async throws {
    let (manager, _) = try await connect(.postgresql)
    let model = await model(
      manager, FakeDiagramDatabase(Self.tables("public")), type: .postgresql,
      policy: review ? Self.protected : Self.open, commitStyle: review ? .review : .immediate)
    var routed: [(StructureEditorModel.TableChange, Bool)] = []
    model.onTableChange = { routed.append(($0, $1)) }

    await model.renameTable(Key(schema: "public", table: "users"), to: "people")
    await model.apply()

    #expect(model.applyError == nil)
    #expect(routed.map(\.0) == [.renamed(schema: "public", from: "users", to: "people")])
    #expect(routed.map(\.1) == [review])
    #expect(model.disabledReason == (review ? SchemaDiagramEditModel.pausedMessage : nil))
    #expect(
      model.resultMessage
        == (review ? SchemaDiagramEditModel.pendingMessage : SchemaDiagramEditModel.appliedMessage))

    model.transactionEnded()
    #expect(model.disabledReason == nil)
  }

  @Test("A table renamed from the diagram keeps its saved position")
  func workspaceRenameMovesPosition() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-diagram-edit-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try SQLiteHandle(url: url)
    try handle.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
    let config = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      rememberConnection: false, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false)
    try await workspace.connectionManager.connect(config: config)
    defer { Task { await workspace.connectionManager.disconnect() } }
    workspace.connectionState = .connected
    workspace.workspace.connectionConfig = config
    await workspace.loadDatabaseSchema()
    let key = SchemaPositionsStore.connectionKey(from: config)
    defer { SchemaPositionsStore.clearPositions(forConnection: key) }
    SchemaPositionsStore.savePositions(
      [SavedNodePosition(tableQualifiedName: "main.items", position: CGPoint(x: 40, y: 50))],
      forConnection: key)
    workspace.schemaDiagramTables = ["main.items"]

    let model = try #require(workspace.makeSchemaDiagramEditModel())
    await model.renameTable(Key(schema: "main", table: "items"), to: "goods")
    #expect(model.previewStatements == ["ALTER TABLE \"main\".\"items\" RENAME TO \"goods\""])
    await model.apply()

    #expect(model.applyError == nil)
    #expect(
      SchemaPositionsStore.loadPositions(forConnection: key) == [
        SavedNodePosition(tableQualifiedName: "main.goods", position: CGPoint(x: 40, y: 50))
      ])
    #expect(workspace.schemaDiagramTables == ["main.goods"])
  }
}

/// Table structures by `schema.table`; sends never reach it (they go through the manager)
private actor FakeDiagramDatabase: StructureEditorDatabase {
  private let structures: [String: TableStructure]
  private let state: StructureEditorConnectionState
  private(set) var loads: [String] = []

  init(_ structures: [TableStructure], state: StructureEditorConnectionState = .init()) {
    self.structures = Dictionary(
      uniqueKeysWithValues: structures.map { ("\($0.schema).\($0.name)", $0) })
    self.state = state
  }

  func fetchTableStructure(schema: String, table: String) async throws -> TableStructure {
    loads.append("\(schema).\(table)")
    guard let structure = structures["\(schema).\(table)"] else {
      throw DatabaseError.queryFailed("no table \(table)", 0)
    }
    return structure
  }

  func structureEditorState() async -> StructureEditorConnectionState { state }

  func executeGatedSchemaChange(
    _ statements: [String], policy: ProtectionPolicy, connectionEpoch: UInt64, caller: UUID?
  ) async throws -> SchemaChangeResult {
    throw DatabaseError.notConnected
  }
}
