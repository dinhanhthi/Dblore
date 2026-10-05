// ForeignKeyNavigationTests.swift
// A foreign-key lookup goes through the gate and is not recorded.
// A jump opens the data viewer on the target, and an existing tab honors staged leave.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Foreign key navigation")
struct ForeignKeyNavigationTests {
  private static let secret = "fk-secret"

  @Test("Lookup sends the bound SELECT through the gate and does not record it")
  func lookupSendsBoundSelect() async throws {
    let (viewModel, session, recorder) = try await connectedViewModel(protection: .readOnly)
    viewModel.databaseForeignKeys = [compositeKey]

    let result = try await viewModel.lookupReferencedRow(
      column: "parent_b", schema: "main", table: "link", rowColumns: ["parent_a", "parent_b"],
      values: ["parent_b": .int(1), "parent_a": .string(Self.secret)])

    let sql = try #require(session.statements.first)
    #expect(session.statements.count == 1)
    #expect(
      sql == #"SELECT * FROM "main"."parent" WHERE "b" = $1 AND "a" = $2 LIMIT 2"#)
    #expect(session.statementBinds == [[.text("1"), .text(Self.secret)]])
    #expect(!sql.contains(Self.secret))
    #expect(!sql.contains("= NULL"))
    #expect(!sql.contains(":fk"))
    #expect(result?.rows == [[.int(9)]])
    #expect(await settledSQL(recorder).isEmpty)
  }

  @Test("A null component, a missing schema, or a missing reference sends nothing")
  func noLookupSendsNothing() async throws {
    let (viewModel, session, _) = try await connectedViewModel(protection: .none)
    viewModel.databaseForeignKeys = [compositeKey]
    let row = ["parent_a", "parent_b"]
    let present: [String: CellValue] = ["parent_b": .int(1), "parent_a": .string("x")]

    #expect(
      try await viewModel.lookupReferencedRow(
        column: "parent_b", schema: "main", table: "link", rowColumns: row,
        values: ["parent_b": .null, "parent_a": .string("x")]) == nil)
    #expect(
      try await viewModel.lookupReferencedRow(
        column: "parent_b", schema: nil, table: "link", rowColumns: row, values: present) == nil)
    #expect(
      try await viewModel.lookupReferencedRow(
        column: "parent_b", schema: "main", table: nil, rowColumns: row, values: present) == nil)
    #expect(
      try await viewModel.lookupReferencedRow(
        column: "other", schema: "main", table: "link", rowColumns: row, values: present) == nil)

    #expect(session.statements.isEmpty)
    #expect(session.statements.allSatisfy { !$0.contains("= NULL") })
  }

  @Test("A lookup with no connection throws before a query")
  func lookupWithoutConnectionThrows() async {
    let viewModel = NotebookViewModel()
    viewModel.databaseForeignKeys = [userKey]
    do {
      _ = try await viewModel.lookupReferencedRow(
        column: "user_id", schema: "public", table: "orders", rowColumns: ["user_id"],
        values: ["user_id": .int(7)])
      Issue.record("Expected notConnected")
    } catch let error as DatabaseError {
      guard case .notConnected = error else {
        Issue.record("Expected notConnected, got \(error)")
        return
      }
    } catch {
      Issue.record("Expected notConnected, got \(error)")
    }
  }

  @Test("Jump opens the referenced table with the filter and its primary key order")
  func jumpOpensFilteredViewer() throws {
    let manager = Self.manager()
    let source = manager.newSQLFile()
    let viewModel = try #require(manager.viewModel(for: source))
    viewModel.databaseForeignKeys = [userKey]
    viewModel.databaseTables = [
      DatabaseTable(
        schema: "public", name: "users",
        columns: [DatabaseColumn(name: "id", type: "int", isPrimaryKey: true)])
    ]

    #expect(
      viewModel.jumpToReferencedRow(
        column: "user_id", schema: "public", table: "orders", rowColumns: ["id", "user_id"],
        values: ["user_id": .int(7)]))

    #expect(manager.tabs.count == 2)
    let viewerId = try #require(manager.tabs.last?.id)
    let viewer = try #require(manager.viewModel(for: viewerId))
    #expect(viewer.dataViewer?.schema == "public")
    #expect(viewer.dataViewer?.name == "users")
    #expect(viewer.dataViewer?.orderColumns == ["id"])
    #expect(viewer.dataViewer?.filter.conditions.map(\.column) == ["id"])
    #expect(viewer.dataViewer?.filter.conditions.map(\.op) == [.equals])
    #expect(viewer.dataViewer?.filter.conditions.map(\.value) == ["7"])
    #expect(viewer.filterDraft.conditions.map(\.value) == ["7"])
    #expect(viewer.dataViewer?.pageSQL.contains(#"WHERE "id" = '7'"#) == true)
  }

  @Test("A jump with an empty string filters on quoted empty, and a composite keeps both")
  func jumpKeepsEmptyString() throws {
    let manager = Self.manager()
    let source = manager.newSQLFile()
    let viewModel = try #require(manager.viewModel(for: source))
    let composite = ForeignKey(
      constraintName: "orders_tenant", sourceSchema: "public", sourceTable: "orders",
      sourceColumns: ["tenant", "code"], targetSchema: "public", targetTable: "accounts",
      targetColumns: ["tenant", "code"])
    viewModel.databaseForeignKeys = [userKey, composite]

    #expect(
      viewModel.jumpToReferencedRow(
        column: "user_id", schema: "public", table: "orders", rowColumns: ["user_id"],
        values: ["user_id": .string("")]))
    let usersId = try #require(manager.tabs.last?.id)
    let users = try #require(manager.viewModel(for: usersId))
    #expect(users.dataViewer?.pageSQL.contains(#"= ''"#) == true)
    #expect(users.dataViewer?.filter.conditions.map(\.emptyStringIsValue) == [true])

    #expect(
      viewModel.jumpToReferencedRow(
        column: "code", schema: "public", table: "orders", rowColumns: ["tenant", "code"],
        values: ["tenant": .string("acme"), "code": .string("")]))
    let accountsId = try #require(manager.tabs.last?.id)
    let accounts = try #require(manager.viewModel(for: accountsId))
    let page = try #require(accounts.dataViewer?.pageSQL)
    #expect(page.contains(#""tenant" = 'acme'"#))
    #expect(page.contains(#""code" = ''"#))
    #expect(accounts.dataViewer?.filter.conditions.map(\.emptyStringIsValue) == [false, true])
  }

  @Test("A staged preview is pinned when another table opens")
  func stagedPreviewIsPinned() throws {
    let (manager, viewModel) = try stagedViewer()
    let usersId = try #require(manager.tabs.first?.id)
    viewModel.dataViewer?.page = 3
    let filter = Self.equals("id", "7")

    manager.openDataViewer(
      schema: "public", name: "orders", orderColumns: ["id"], filter: filter)

    #expect(manager.tabs.count == 2)
    #expect(manager.tabs[0].id == usersId)
    #expect(manager.tabs[0].isPreview == false)
    #expect(viewModel.dataViewer?.name == "users")
    #expect(viewModel.dataViewer?.page == 3)
    #expect(viewModel.hasPendingStagedChanges)
    let ordersId = manager.tabs[1].id
    let orders = try #require(manager.viewModel(for: ordersId))
    #expect(manager.tabs[1].isPreview)
    #expect(manager.activeTabId == ordersId)
    #expect(orders.dataViewer?.name == "orders")
    #expect(orders.dataViewer?.filter == filter)
    #expect(orders.dataViewer?.pageSQL.contains(#"WHERE "id" = '7'"#) == true)
    #expect(orders.hasPendingStagedChanges == false)
  }

  @Test("Jump does nothing for a null component, a missing schema, or a missing reference")
  func jumpDoesNothingWithoutAFilter() {
    let viewModel = NotebookViewModel()
    viewModel.databaseForeignKeys = [userKey]
    var opened = 0
    viewModel.onOpenDataViewer = { _, _, _, _ in opened += 1 }
    let row = ["user_id"]

    #expect(
      viewModel.jumpToReferencedRow(
        column: "user_id", schema: "public", table: "orders", rowColumns: row,
        values: ["user_id": .null]) == false)
    #expect(
      viewModel.jumpToReferencedRow(
        column: "user_id", schema: nil, table: "orders", rowColumns: row,
        values: ["user_id": .int(7)]) == false)
    #expect(
      viewModel.jumpToReferencedRow(
        column: "user_id", schema: "public", table: nil, rowColumns: row,
        values: ["user_id": .int(7)]) == false)
    #expect(
      viewModel.jumpToReferencedRow(
        column: "other", schema: "public", table: "orders", rowColumns: row,
        values: ["user_id": .int(7)]) == false)
    #expect(opened == 0)
  }

  @Test("A new data viewer opens filtered, and the next preview replaces that filter")
  func newViewerOpensFiltered() throws {
    let manager = Self.manager()
    let users = Self.equals("id", "7")
    manager.openDataViewer(
      schema: "public", name: "users", orderColumns: ["id"], filter: users)
    let id = try #require(manager.tabs.first?.id)
    let viewModel = try #require(manager.viewModel(for: id))
    #expect(viewModel.dataViewer?.filter == users)
    #expect(viewModel.filterDraft == users)
    #expect(viewModel.dataViewer?.pageSQL.contains(#"WHERE "id" = '7'"#) == true)

    let orders = Self.equals("code", "ab")
    manager.openDataViewer(schema: "public", name: "orders", orderColumns: [], filter: orders)
    #expect(manager.tabs.count == 1)
    #expect(manager.tabs.first?.id == id)
    #expect(viewModel.dataViewer?.name == "orders")
    #expect(viewModel.dataViewer?.filter == orders)
    #expect(viewModel.filterDraft == orders)
    #expect(viewModel.dataViewer?.pageSQL.contains(#"WHERE "code" = 'ab'"#) == true)
  }

  @Test("An existing data viewer applies the filter; a nil filter leaves it")
  func existingViewerAppliesFilter() async throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: ["id"])
    let tabId = try #require(manager.tabs.first?.id)
    let viewModel = try #require(manager.viewModel(for: tabId))
    viewModel.connectionManager = nil
    viewModel.dataViewer?.page = 4
    viewModel.dataViewer?.totalRows = 40
    let filter = Self.equals("id", "7")

    manager.openDataViewer(
      schema: "public", name: "users", orderColumns: ["day"], filter: filter)
    await Self.waitUntil { viewModel.dataViewer?.filter == filter }

    #expect(viewModel.dataViewer?.page == 1)
    #expect(viewModel.dataViewer?.totalRows == nil)
    #expect(viewModel.dataViewer?.orderColumns == ["id"])
    #expect(viewModel.dataViewer?.pageSQL.contains(#"WHERE "id" = '7'"#) == true)
    #expect(viewModel.filterDraft == filter)

    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    for _ in 0..<10 { await Task.yield() }
    #expect(viewModel.dataViewer?.filter == filter)
    #expect(viewModel.dataViewer?.orderColumns == ["id"])
  }

  @Test("Discard on the staged-leave prompt applies the filter")
  func discardAppliesTheFilter() async throws {
    let (manager, viewModel) = try stagedViewer()
    viewModel.dataViewer?.page = 3
    let filter = Self.equals("id", "7")

    manager.openDataViewer(
      schema: "public", name: "users", orderColumns: ["id"], filter: filter)
    await Self.waitUntil { viewModel.stagedLeavePromptVisible }
    #expect(viewModel.dataViewer?.filter.isEmpty == true)

    viewModel.resolveStagedLeavePrompt(.discard)
    await Self.waitUntil { viewModel.dataViewer?.filter == filter }

    #expect(viewModel.filterDraft == filter)
    #expect(viewModel.hasPendingStagedChanges == false)
    #expect(viewModel.dataViewer?.page == 1)
    #expect(viewModel.stagedLeavePromptVisible == false)
  }

  @Test("Cancel leaves the applied filter and the staged rows")
  func cancelLeavesTheFilter() async throws {
    let (manager, viewModel) = try stagedViewer()
    viewModel.dataViewer?.page = 3
    let draft = Self.equals("nickname", "neo")
    viewModel.filterDraft = draft
    let filter = Self.equals("id", "7")

    manager.openDataViewer(
      schema: "public", name: "users", orderColumns: ["id"], filter: filter)
    await Self.waitUntil { viewModel.stagedLeavePromptVisible }
    viewModel.resolveStagedLeavePrompt(.cancel)
    for _ in 0..<15 { await Task.yield() }

    #expect(viewModel.stagedLeavePromptVisible == false)
    #expect(viewModel.dataViewer?.filter.isEmpty == true)
    #expect(viewModel.dataViewer?.page == 3)
    #expect(viewModel.hasPendingStagedChanges)
    #expect(viewModel.filterDraft == draft)
  }

  @Test("A jump while the staged-leave prompt is open keeps the draft")
  func jumpDuringPromptKeepsTheDraft() async throws {
    let (manager, viewModel) = try stagedViewer()
    let draft = Self.equals("nickname", "neo")
    viewModel.filterDraft = draft
    let first = Self.equals("id", "7")
    let second = Self.equals("id", "8")

    manager.openDataViewer(
      schema: "public", name: "users", orderColumns: ["id"], filter: first)
    await Self.waitUntil { viewModel.stagedLeavePromptVisible }
    manager.openDataViewer(
      schema: "public", name: "users", orderColumns: ["id"], filter: second)
    for _ in 0..<15 { await Task.yield() }
    #expect(viewModel.filterDraft == draft)

    viewModel.resolveStagedLeavePrompt(.discard)
    await Self.waitUntil { viewModel.dataViewer?.filter == first }
    #expect(viewModel.dataViewer?.filter == first)
    #expect(viewModel.filterDraft == first)
  }

  @Test("A lookup pinned to another connection epoch fails before any SQL")
  func staleEpochLookupFails() async throws {
    let (viewModel, session, _) = try await connectedViewModel(protection: .none)
    viewModel.databaseForeignKeys = [userKey]
    let manager = try #require(viewModel.connectionManager)
    let epoch = await manager.connectionEpoch

    _ = try await viewModel.lookupReferencedRow(
      column: "user_id", schema: "public", table: "orders", rowColumns: ["user_id"],
      values: ["user_id": .int(7)], expectedEpoch: epoch)
    #expect(session.statements.count == 1)

    do {
      _ = try await viewModel.lookupReferencedRow(
        column: "user_id", schema: "public", table: "orders", rowColumns: ["user_id"],
        values: ["user_id": .int(7)], expectedEpoch: epoch &+ 1)
      Issue.record("Expected sessionChanged")
    } catch let error as DatabaseError {
      guard case .sessionChanged = error else {
        Issue.record("Expected sessionChanged, got \(error)")
        return
      }
    }
    #expect(session.statements.count == 1)
  }

  private var compositeKey: ForeignKey {
    ForeignKey(
      constraintName: "link_parent", sourceSchema: "main", sourceTable: "link",
      sourceColumns: ["parent_b", "parent_a"], targetSchema: "main", targetTable: "parent",
      targetColumns: ["b", "a"])
  }

  private var userKey: ForeignKey {
    ForeignKey(
      constraintName: "orders_user", sourceSchema: "public", sourceTable: "orders",
      sourceColumns: ["user_id"], targetSchema: "public", targetTable: "users",
      targetColumns: ["id"])
  }

  private static func manager() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(), restoreTabs: false)
  }

  private static func equals(_ column: String, _ value: String) -> TableFilter {
    TableFilter(conditions: [FilterCondition(column: column, op: .equals, value: value)])
  }

  private func connectedViewModel(
    protection: ConnectionProtectionLevel
  ) async throws -> (NotebookViewModel, FakeDatabaseSession, NavigationHistoryRecorder) {
    let columns = [ColumnInfo(name: "id", type: "int4")]
    let factory = FakeDatabaseSessionFactory(
      capabilities: .contract(), columns: columns, rows: [[.int(9)]])
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    let config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      password: "p", sslMode: .disable, protectionLevel: protection, safeMode: .silent,
      protectedMode: false)
    try await manager.connect(config: config)
    let viewModel = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config))
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    let recorder = NavigationHistoryRecorder()
    viewModel.historyRecorder = recorder
    let suiteName = "ForeignKeyNavigationTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    suite.removePersistentDomain(forName: suiteName)
    let settings = AppSettings(defaults: suite)
    settings.historyEnabled = true
    viewModel.historySettings = settings
    let session = try #require(factory.sessions.first)
    return (viewModel, session, recorder)
  }

  private func stagedViewer() throws -> (WorkspaceManager, NotebookViewModel) {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: ["id"])
    let tabId = try #require(manager.tabs.first?.id)
    let viewModel = try #require(manager.viewModel(for: tabId))
    viewModel.connectionManager = nil
    let tableID = TableRef.postgresql(oid: 1)
    viewModel.notebook.connectionConfig = ConnectionConfig(
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4", origin: ColumnOrigin(tableID: tableID, columnOrdinal: 1)),
        ColumnInfo(
          name: "nickname", type: "text",
          origin: ColumnOrigin(tableID: tableID, columnOrdinal: 2)),
      ],
      rows: [[.int(1), .string("old")]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: tableID, primaryKeyColumns: ["id"],
        updateOnly: true))
    #expect(viewModel.stageEdit(row: 0, column: "nickname", value: .string("neo")) == nil)
    #expect(viewModel.hasPendingStagedChanges)
    return (manager, viewModel)
  }

  private func settledSQL(_ recorder: NavigationHistoryRecorder) async -> [String] {
    for _ in 0..<50 {
      await Task.yield()
    }
    return await recorder.sql
  }

  private static func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<50 {
      if condition() { return }
      await Task.yield()
    }
  }
}

private actor NavigationHistoryRecorder: QueryHistoryRecording {
  private(set) var sql: [String] = []

  func record(_ entry: QueryHistoryEntry) async {
    sql.append(entry.sql)
  }
}
