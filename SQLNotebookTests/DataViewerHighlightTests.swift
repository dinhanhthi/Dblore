// DataViewerHighlightTests.swift
// Highlight apply/clear only repaint: page, count, load key and SQL stay untouched.
// Saved highlights round-trip through an isolated store.

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
@Suite("Data Viewer Highlight Tests")
struct DataViewerHighlightTests {
  private func makeViewModel() -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"], page: 3, totalRows: 250)
    viewModel.notebook.connectionConfig = ConnectionConfig()
    let suite = "DataViewerHighlightTests-\(UUID().uuidString)"
    viewModel.savedFilterStore = SavedFilterStore(defaults: UserDefaults(suiteName: suite)!)
    return viewModel
  }

  /// Fixed condition id, so equal drafts compare equal
  private func draft() -> TableHighlight {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    return TableHighlight(
      filter: TableFilter(conditions: [FilterCondition(id: id, column: "name", value: "bob")]),
      color: .green, style: .row)
  }

  @Test("Apply and clear keep page, total, load key and SQL")
  func applyClearDoNotReload() {
    let viewModel = makeViewModel()
    let before = viewModel.dataViewer!
    viewModel.highlightDraft = draft()
    viewModel.applyHighlight()
    #expect(viewModel.dataViewer?.highlight == draft())
    #expect(viewModel.dataViewer?.page == 3)
    #expect(viewModel.dataViewer?.totalRows == 250)
    #expect(viewModel.dataViewer?.loadKey == before.loadKey)
    #expect(viewModel.dataViewer?.pageSQL == before.pageSQL)
    viewModel.clearHighlight()
    #expect(viewModel.dataViewer?.highlight.isEmpty == true)
    #expect(viewModel.dataViewer?.page == 3)
    #expect(viewModel.dataViewer?.totalRows == 250)
    #expect(viewModel.dataViewer?.loadKey == before.loadKey)
    #expect(viewModel.dataViewer?.pageSQL == before.pageSQL)
  }

  @Test("A blank draft applies as an empty highlight")
  func blankDraft() {
    let viewModel = makeViewModel()
    viewModel.prepareHighlightDraft()
    #expect(viewModel.highlightDraft.filter.conditions.count == 1)
    viewModel.applyHighlight()
    #expect(viewModel.dataViewer?.highlight.isEmpty == true)
  }

  @Test("Saved highlights round-trip, replace by name and delete")
  func savedRoundTrip() {
    let viewModel = makeViewModel()
    viewModel.highlightDraft = draft()
    #expect(viewModel.saveCurrentHighlight(named: "  ") == false)
    #expect(viewModel.saveCurrentHighlight(named: "bobs"))
    #expect(viewModel.savedHighlights.count == 1)
    #expect(viewModel.savedHighlights[0].highlight == draft())
    viewModel.highlightDraft.color = .red
    viewModel.saveCurrentHighlight(named: "bobs")
    #expect(viewModel.savedHighlights.count == 1)
    #expect(viewModel.savedHighlights[0].highlight.color == .red)
    viewModel.highlightDraft = TableHighlight(filter: TableFilter(conditions: []))
    viewModel.loadSavedHighlight(viewModel.savedHighlights[0])
    #expect(viewModel.highlightDraft.color == .red)
    viewModel.deleteSavedHighlight(viewModel.savedHighlights[0])
    #expect(viewModel.savedHighlights.isEmpty)
  }

  @Test("Saved highlights do not mix with saved filters")
  func separateFromFilters() {
    let viewModel = makeViewModel()
    viewModel.highlightDraft = draft()
    viewModel.saveCurrentHighlight(named: "h")
    viewModel.refreshSavedFilters()
    #expect(viewModel.savedFilters.isEmpty)
  }
}
