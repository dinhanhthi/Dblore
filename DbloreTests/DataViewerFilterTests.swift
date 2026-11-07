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

  /// A PostgreSQL view model on `public.users` with a `name` column of `nameType` and its
  /// schema read's type data, connected to nothing (each read fails), so the page and count SQL
  /// are built but not run
  private func makeTypedViewModel(
    nameType: String, postgresType: PostgresColumnType?
  ) -> NotebookViewModel {
    let viewModel = makeViewModel()
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.databaseTables = [
      DatabaseTable(
        schema: "public", name: "users",
        columns: [
          DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true),
          DatabaseColumn(name: "name", type: nameType, postgresType: postgresType),
        ])
    ]
    viewModel.filterDraft = TableFilter(conditions: [condition("name", "bob")])
    return viewModel
  }

  private func hasWhere(_ viewModel: NotebookViewModel, _ clause: String) -> Bool {
    viewModel.dataViewer?.pageSQL.contains("WHERE \(clause)") == true
      && viewModel.dataViewer?.countSQL.contains("WHERE \(clause)") == true
  }

  @Test(
    "A citext column of the cached table uses its extension's =; an uncached table qualifies it")
  func citextColumnUsesExtensionOperator() async {
    let citext = PostgresColumnType(
      oid: 16_400, operand: .bare, castName: "public.citext", compareCast: nil,
      operatorSchema: "public")
    let viewModel = makeTypedViewModel(nameType: "citext", postgresType: citext)
    await viewModel.applyFilter()
    #expect(hasWhere(viewModel, "\"name\" OPERATOR(public.=) 'bob'"))

    // Changed column types count the filtered total again (the count read fails here)
    viewModel.dataViewer?.totalRows = 7
    viewModel.databaseTables = []
    await viewModel.loadDataViewerPage()
    #expect(hasWhere(viewModel, "\"name\" OPERATOR(pg_catalog.=) 'bob'"))
    #expect(viewModel.dataViewer?.totalRows == nil)
  }

  @Test("A domain over citext compares cast to citext; a citext no extension owns qualifies")
  func domainOverCitextComparesCast() async {
    let domain = PostgresColumnType(
      oid: 16_401, operand: .bare, castName: "public.email", compareCast: "public.citext",
      operatorSchema: "public")
    let viewModel = makeTypedViewModel(nameType: "email", postgresType: domain)
    await viewModel.applyFilter()
    #expect(
      hasWhere(viewModel, "\"name\"::public.citext OPERATOR(public.=) 'bob'::public.citext"))

    let evil = PostgresColumnType(
      oid: 16_402, operand: .qualified, castName: "evil.citext", compareCast: nil,
      operatorSchema: nil)
    let planted = makeTypedViewModel(nameType: "evil.citext", postgresType: evil)
    await planted.applyFilter()
    #expect(hasWhere(planted, "\"name\" OPERATOR(pg_catalog.=) 'bob'"))
  }

}
