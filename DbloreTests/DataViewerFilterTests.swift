// DataViewerFilterTests.swift
// Filter form actions on the data viewer view model: apply/clear update the state and SQL,
// saved filters round-trip through an isolated store (no DB needed).

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Data Viewer Filter Tests")
struct DataViewerFilterTests {

  private func makeViewModel(page: Int = 1, totalRows: Int? = nil) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"], page: page, totalRows: totalRows)
    viewModel.notebook.connectionConfig = ConnectionConfig()
    let suite = "DataViewerFilterTests-\(UUID().uuidString)"
    viewModel.savedFilterStore = SavedFilterStore(defaults: UserDefaults(suiteName: suite)!)
    return viewModel
  }

  private func condition(_ column: String, _ value: String) -> FilterCondition {
    FilterCondition(column: column, op: .equals, value: value)
  }

  @Test("Apply copies the draft, goes to page 1 and forgets the count")
  func applyFilter() async {
    let viewModel = makeViewModel(page: 3, totalRows: 250)
    viewModel.filterDraft = TableFilter(conditions: [condition("name", "bob")])
    await viewModel.applyFilter()
    #expect(viewModel.dataViewer?.filter == viewModel.filterDraft)
    #expect(viewModel.dataViewer?.page == 1)
    #expect(viewModel.dataViewer?.totalRows == nil)
    #expect(
      viewModel.dataViewer?.pageSQL.contains("WHERE \"name\" OPERATOR(pg_catalog.=) 'bob'") == true)
    #expect(
      viewModel.dataViewer?.countSQL.contains("WHERE \"name\" OPERATOR(pg_catalog.=) 'bob'") == true
    )
  }

  @Test("Apply with a blank draft keeps the filter empty and the SQL unchanged")
  func applyBlankDraft() async {
    let viewModel = makeViewModel()
    let unfiltered = viewModel.dataViewer?.pageSQL
    viewModel.prepareFilterDraft()
    await viewModel.applyFilter()
    #expect(viewModel.dataViewer?.filter.isEmpty == true)
    #expect(viewModel.dataViewer?.pageSQL == unfiltered)
  }

  @Test("A count for an old filter is not written back after the filter changed")
  func staleCountDropped() async {
    let viewModel = makeViewModel()
    let old = viewModel.dataViewer!
    viewModel.filterDraft = TableFilter(conditions: [condition("name", "bob")])
    await viewModel.applyFilter()
    viewModel.storeDataViewerTotal(999, for: old)
    #expect(viewModel.dataViewer?.totalRows == nil)
    viewModel.storeDataViewerTotal(5, for: viewModel.dataViewer!)
    #expect(viewModel.dataViewer?.totalRows == 5)
  }

  @Test("Clear removes the applied filter and restores the unfiltered SQL")
  func clearFilter() async {
    let viewModel = makeViewModel()
    let unfiltered = viewModel.dataViewer?.pageSQL
    viewModel.filterDraft = TableFilter(conditions: [condition("name", "bob")])
    await viewModel.applyFilter()
    await viewModel.clearFilter()
    #expect(viewModel.dataViewer?.filter.isEmpty == true)
    #expect(viewModel.filterDraft.conditions.count == 1)
    #expect(viewModel.dataViewer?.pageSQL == unfiltered)
  }

  @Test("Saved filters round-trip: save, load into the draft only, delete")
  func savedFilterRoundTrip() {
    let viewModel = makeViewModel()
    viewModel.filterDraft = TableFilter(conditions: [condition("name", "bob")])
    #expect(viewModel.saveCurrentFilter(named: "  bobs  "))
    #expect(viewModel.savedFilters.map(\.name) == ["bobs"])

    viewModel.filterDraft = TableFilter(conditions: [FilterCondition()])
    viewModel.loadSavedFilter(viewModel.savedFilters[0])
    #expect(viewModel.filterDraft.conditions.map(\.value) == ["bob"])
    #expect(viewModel.dataViewer?.filter.isEmpty == true)

    viewModel.deleteSavedFilter(viewModel.savedFilters[0])
    #expect(viewModel.savedFilters.isEmpty)
  }

  // MARK: - Operand kind from the schema cache

  /// A PostgreSQL view model on `public.users` with a `name` column of `nameType`, connected
  /// to nothing (each read fails), so the page and count SQL are built but not run
  private func makeTypedViewModel(nameType: String) -> NotebookViewModel {
    let viewModel = makeViewModel()
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.databaseTables = [
      DatabaseTable(
        schema: "public", name: "users",
        columns: [
          DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true),
          DatabaseColumn(name: "name", type: nameType),
        ])
    ]
    viewModel.filterDraft = TableFilter(conditions: [condition("name", "bob")])
    return viewModel
  }

  private func hasWhere(_ viewModel: NotebookViewModel, _ clause: String) -> Bool {
    viewModel.dataViewer?.pageSQL.contains("WHERE \(clause)") == true
      && viewModel.dataViewer?.countSQL.contains("WHERE \(clause)") == true
  }

  @Test("A citext column of the cached table keeps the bare =; an uncached table qualifies it")
  func citextColumnKeepsBareOperator() async {
    let viewModel = makeTypedViewModel(nameType: "citext")
    await viewModel.applyFilter()
    #expect(hasWhere(viewModel, "\"name\" = 'bob'"))

    // Changed column types count the filtered total again (the count read fails here)
    viewModel.dataViewer?.totalRows = 7
    viewModel.databaseTables = []
    await viewModel.loadDataViewerPage()
    #expect(hasWhere(viewModel, "\"name\" OPERATOR(pg_catalog.=) 'bob'"))
    #expect(viewModel.dataViewer?.totalRows == nil)
  }

  @Test("An open transaction does not mark the user types read as failed")
  func pendingTransactionDefersUserTypesRead() async throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: ConnectionConfig()), restoreTabs: false)
    manager.connectionState = .connected
    manager.pendingTransaction = .appTx(pending: [])
    let viewModel = try #require(manager.viewModel(for: manager.newNotebook()))

    viewModel.requestUserTypes()
    for _ in 0..<20 { await Task.yield() }
    #expect(manager.databaseUserTypes.error == nil)

    // After Commit or Rollback the next page asks (the unconnected read fails)
    manager.pendingTransaction = .idle
    viewModel.requestUserTypes()
    for _ in 0..<200 where manager.databaseUserTypes.error == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(manager.databaseUserTypes.error != nil)
  }

  @Test("A domain over citext keeps the bare = once the user types are cached")
  func domainOverCitextKeepsBareOperator() async {
    let viewModel = makeTypedViewModel(nameType: "email")
    var requests = 0
    viewModel.requestUserTypes = { requests += 1 }
    await viewModel.applyFilter()
    #expect(hasWhere(viewModel, "\"name\" OPERATOR(pg_catalog.=) 'bob'"))
    #expect(requests > 0)

    let domain = { (name: String, base: String) in
      DatabaseUserType(
        schema: "public", name: name,
        kind: .domain(baseType: base, notNull: false, defaultExpression: nil, constraints: []))
    }
    // Domain over domain: email -> work_email_base -> public.citext
    viewModel.databaseTables[0].columns[1] = DatabaseColumn(name: "name", type: "public.email")
    viewModel.workspaceUserTypes = {
      [domain("email", "work_email_base"), domain("work_email_base", "public.citext")]
    }
    await viewModel.applyFilter()
    #expect(hasWhere(viewModel, "\"name\" = 'bob'"))
  }

}
