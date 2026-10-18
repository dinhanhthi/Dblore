// DataViewerSearchTests.swift
// Cmd+F in a data viewer tab: the search scans the loaded page, and a MongoDB collection offers it
// on the Documents section only.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Data Viewer Search Tests")
struct DataViewerSearchTests {
  private func makeViewModel(databaseType: DatabaseType = .postgresql) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.connectionManager = DatabaseConnectionManager()
    viewModel.dataViewer = DataViewerState(
      schema: "db", name: "users", orderColumns: ["_id"], databaseType: databaseType)
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(name: "_id", type: "objectId"), ColumnInfo(name: "name", type: "string"),
      ],
      rows: [[.string("a1"), .string("Alice")], [.string("b2"), .string("Bob")]],
      executionTime: 0, rowCount: 2, timestamp: Date())
    return viewModel
  }

  @Test("Search finds a value of the loaded page")
  func findsPageValue() async {
    let viewModel = makeViewModel()
    await viewModel.performSearch(query: "bob", caseSensitive: false)
    #expect(
      viewModel.searchState.matches.map(\.matchType) == [
        .tableData(rowIndex: 1, columnName: "name")
      ])
  }

  @Test("Search finds a value of a MongoDB page")
  func findsMongoPageValue() async {
    let viewModel = makeViewModel(databaseType: .mongodb)
    await viewModel.performSearch(query: "alice", caseSensitive: false)
    #expect(
      viewModel.searchState.matches.map(\.matchType) == [
        .tableData(rowIndex: 0, columnName: "name")
      ])
  }

  @Test("A MongoDB collection offers search on Documents only")
  func mongoSearchOnDocumentsOnly() throws {
    let viewModel = makeViewModel(databaseType: .mongodb)
    let model = try #require(viewModel.mongoCollection)
    #expect(viewModel.isSearchAvailable)
    for section in MongoCollectionModel.Section.allCases where section != .documents {
      model.section = section
      #expect(!viewModel.isSearchAvailable)
    }
  }

  @Test("Cmd+F does not open the search panel outside Documents")
  func openSearchIgnoredOutsideDocuments() throws {
    let viewModel = makeViewModel(databaseType: .mongodb)
    try #require(viewModel.mongoCollection).section = .aggregations
    viewModel.openSearch()
    #expect(!viewModel.isSearchPanelVisible)
  }
}
