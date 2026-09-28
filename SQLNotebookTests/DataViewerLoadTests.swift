// DataViewerLoadTests.swift
// Data viewer paging actions on the tab view model: page/size/refresh update the state and
// reload; without a connection nothing runs (no DB needed).

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
@Suite("Data Viewer Load Tests")
struct DataViewerLoadTests {

  private func makeViewModel(
    page: Int = 1, pageSize: Int = 100, totalRows: Int? = nil
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"], page: page, pageSize: pageSize,
      totalRows: totalRows)
    return viewModel
  }

  @Test("Normal tabs have no data viewer state")
  func nilByDefault() {
    #expect(NotebookViewModel().dataViewer == nil)
  }

  @Test("Loading without a connection manager runs nothing")
  func loadWithoutConnection() async {
    let viewModel = makeViewModel()
    await viewModel.loadDataViewerPage()
    #expect(viewModel.editorResult == nil)
    #expect(viewModel.isEditorQueryRunning == false)
  }

  @Test("Loading while a run is in flight runs nothing")
  func loadWhileRunning() async {
    let viewModel = makeViewModel()
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.isEditorQueryRunning = true
    await viewModel.loadDataViewerPage()
    #expect(viewModel.editorResult == nil)
    #expect(viewModel.dataViewer?.totalRows == nil)
    #expect(viewModel.isEditorQueryRunning == true)
  }

  @Test("Changing the page size goes back to page 1")
  func setPageSizeResetsPage() async {
    let viewModel = makeViewModel(page: 3)
    await viewModel.setPageSize(250)
    #expect(viewModel.dataViewer?.page == 1)
    #expect(viewModel.dataViewer?.pageSize == 250)
  }

  @Test("goToPage clamps below 1")
  func goToPageLowerBound() async {
    let viewModel = makeViewModel(page: 2)
    await viewModel.goToPage(0)
    #expect(viewModel.dataViewer?.page == 1)
  }

  @Test("goToPage clamps to the page count when the total is known")
  func goToPageUpperBound() async {
    let viewModel = makeViewModel(totalRows: 250)
    await viewModel.goToPage(9)
    #expect(viewModel.dataViewer?.page == 3)
  }

  @Test("goToPage is not capped while the total is unknown")
  func goToPageUnknownTotal() async {
    let viewModel = makeViewModel()
    await viewModel.goToPage(9)
    #expect(viewModel.dataViewer?.page == 9)
  }

  @Test("Refresh forgets the row count")
  func refreshResetsTotal() async {
    let viewModel = makeViewModel(totalRows: 250)
    await viewModel.refreshDataViewer()
    #expect(viewModel.dataViewer?.totalRows == nil)
  }

  @Test("Columns can be hidden and all shown again")
  func hideAndShowColumns() {
    let viewModel = makeViewModel()
    viewModel.setColumnHidden("email", true)
    viewModel.setColumnHidden("name", true)
    #expect(viewModel.dataViewer?.hiddenColumns == ["email", "name"])
    viewModel.setColumnHidden("email", false)
    #expect(viewModel.dataViewer?.hiddenColumns == ["name"])
    viewModel.showAllColumns()
    #expect(viewModel.dataViewer?.hiddenColumns.isEmpty == true)
  }
}
