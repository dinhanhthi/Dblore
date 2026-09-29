// DataViewerFilterTests.swift
// Filter form actions on the data viewer view model: apply/clear update the state and SQL,
// saved filters round-trip through an isolated store (no DB needed).

import Foundation
import Testing

@testable import SQLNotebook

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
    #expect(viewModel.dataViewer?.pageSQL.contains("WHERE \"name\" = 'bob'") == true)
    #expect(viewModel.dataViewer?.countSQL.contains("WHERE \"name\" = 'bob'") == true)
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

  @Test("A blank saved filter name is rejected")
  func blankNameRejected() {
    let viewModel = makeViewModel()
    #expect(viewModel.saveCurrentFilter(named: " \n ") == false)
    #expect(viewModel.savedFilters.isEmpty)
  }

  @Test("Filter columns come from the schema table, else the loaded result")
  func filterColumns() {
    let viewModel = makeViewModel()
    #expect(viewModel.filterColumns.isEmpty)
    viewModel.databaseTables = [
      DatabaseTable(
        schema: "public", name: "users",
        columns: [
          DatabaseColumn(name: "id", type: "int"), DatabaseColumn(name: "name", type: "text"),
        ])
    ]
    #expect(viewModel.filterColumns == ["id", "name"])
  }

  @Test("The draft restarts from the applied filter when the viewer shows another table")
  func draftResetsPerRelation() {
    let viewModel = makeViewModel()
    viewModel.prepareFilterDraft()
    #expect(viewModel.filterDraft.conditions.count == 1)
    viewModel.filterDraft.conditions[0].column = "id"
    viewModel.dataViewer?.name = "orders"
    viewModel.prepareFilterDraft()
    #expect(viewModel.filterDraft.conditions.map(\.column) == [""])
  }
}
