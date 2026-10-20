// DataViewerHighlightTests.swift
// Highlight rules only repaint: page, count, load key and SQL stay untouched.
// Saved highlights round-trip through an isolated store; saved active rules come back on open.

import Foundation
import Testing

@testable import Dblore

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

  /// Fixed condition id, so equal filters compare equal
  private func draft(_ value: String, color: HighlightColor = .green) -> TableHighlight {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    return TableHighlight(
      filter: TableFilter(conditions: [FilterCondition(id: id, column: "name", value: value)]),
      color: color, style: .row)
  }

  @Test("Apply and the menu add rules, newest first; clear removes all; nothing reloads")
  func applyClearDoNotReload() {
    let viewModel = makeViewModel()
    let before = viewModel.dataViewer!
    viewModel.highlightDraft = draft("bob")
    viewModel.applyHighlight()
    viewModel.highlightDraft = draft("eve", color: .orange)
    viewModel.applyHighlight()
    viewModel.highlightCell(column: "age", value: .null, style: .cell, color: .blue)
    let rules = viewModel.dataViewer?.highlights ?? []
    #expect(rules.map(\.color) == [.blue, .orange, .green])
    #expect(rules.last?.filter == draft("bob").filter)
    #expect(rules.first?.filter.conditions.first?.op == .isNull)
    #expect(viewModel.dataViewer?.page == 3)
    #expect(viewModel.dataViewer?.totalRows == 250)
    #expect(viewModel.dataViewer?.loadKey == before.loadKey)
    #expect(viewModel.dataViewer?.pageSQL == before.pageSQL)
    viewModel.clearHighlight()
    #expect(viewModel.dataViewer?.highlights.isEmpty == true)
    #expect(viewModel.dataViewer?.page == 3)
    #expect(viewModel.dataViewer?.totalRows == 250)
    #expect(viewModel.dataViewer?.loadKey == before.loadKey)
    #expect(viewModel.dataViewer?.pageSQL == before.pageSQL)
  }

  @Test("Highlighting the same cell again moves the rule to the top instead of repeating it")
  func sameCellHighlightDoesNotRepeat() {
    let viewModel = makeViewModel()
    viewModel.highlightCell(column: "name", value: .string("bob"), style: .cell, color: .blue)
    viewModel.highlightCell(column: "age", value: .null, style: .row, color: .red)
    viewModel.highlightCell(column: "name", value: .string("bob"), style: .cell, color: .blue)
    let rules = viewModel.dataViewer?.highlights ?? []
    #expect(rules.count == 2)
    #expect(rules.first?.filter.conditions.first?.value == "bob")
    // Another color is another rule
    viewModel.highlightCell(column: "name", value: .string("bob"), style: .cell, color: .green)
    #expect(viewModel.dataViewer?.highlights.count == 3)
  }

  @Test("Saved highlights in the stored JSON shape decode through a backup restore")
  func oldJSONDecodes() throws {
    let suite = "DataViewerHighlightTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let key = SavedFilterStore.key(for: ConnectionConfig(), schema: "public", name: "users")
    // Saved before rules could be active; one entry carries a color this build does not know
    let json = """
      {"\(key)": [
        {"id": "00000000-0000-0000-0000-00000000000A", "name": "old",
         "highlight": {"filter": {"conditions": [
           {"id": "00000000-0000-0000-0000-00000000000B", "column": "name", "op": "equals",
            "value": "bob", "connector": "and"}]},
           "color": "red", "style": "row"}},
        {"id": "00000000-0000-0000-0000-00000000000C", "name": "odd",
         "highlight": {"filter": {"conditions": []}, "color": "magenta", "style": "cell"}}
      ]}
      """
    let snapshot = SavedFilterStore.Snapshot(highlights: Data(json.utf8))
    SavedFilterStore.replace(with: snapshot, defaults: defaults, domainName: suite)
    #expect(
      SavedFilterStore.exportSnapshot(defaults: defaults, domainName: suite).highlights
        == Data(json.utf8))
    let saved = SavedFilterStore(defaults: defaults).listHighlights(for: key)
    #expect(saved.map(\.name) == ["old", "odd"])
    #expect(saved.map(\.highlight.color) == [.red, .yellow])
    #expect(saved.map(\.highlight.style) == [.row, .cell])
    #expect(saved.first?.highlight.filter.conditions.first?.value == "bob")
    #expect(saved.allSatisfy { !$0.isActive })
    defaults.removePersistentDomain(forName: suite)
  }

  @Test("Saved rules marked active come back when an SQL table opens, not on MongoDB")
  func activeSavedRulesReapply() throws {
    let viewModel = makeViewModel()
    viewModel.highlightDraft = draft("bob")
    viewModel.saveCurrentHighlight(named: "bob")
    viewModel.highlightDraft = draft("eve", color: .orange)
    viewModel.saveCurrentHighlight(named: "eve")
    let bob = try #require(viewModel.savedHighlights.first { $0.name == "bob" })
    viewModel.setSavedHighlightActive(bob, true)
    #expect(viewModel.dataViewer?.highlights.map(\.filter) == [draft("bob").filter])
    #expect(viewModel.savedHighlights.first { $0.name == "bob" }?.isActive == true)

    // Rules without a complete condition (saved before saves required one) never apply
    let key = SavedFilterStore.key(for: ConnectionConfig(), schema: "public", name: "users")
    let blankRule = TableHighlight(filter: TableFilter(conditions: [FilterCondition()]))
    let emptyInRule = TableHighlight(
      filter: TableFilter(conditions: [FilterCondition(column: "name", op: .in, value: " , ")]))
    viewModel.savedFilterStore.saveHighlight(blankRule, named: "blank", for: key)
    viewModel.savedFilterStore.saveHighlight(emptyInRule, named: "empty in", for: key)
    viewModel.refreshSavedHighlights()
    for name in ["blank", "empty in"] {
      let saved = try #require(viewModel.savedHighlights.first { $0.name == name })
      viewModel.setSavedHighlightActive(saved, true)
    }
    #expect(viewModel.dataViewer?.highlights.map(\.filter) == [draft("bob").filter])

    // Nor does a draft without one save
    viewModel.highlightDraft = blankRule
    #expect(viewModel.saveCurrentHighlight(named: "nothing") == false)
    #expect(!viewModel.savedHighlights.contains { $0.name == "nothing" })

    // Reopen: a fresh state of the same table
    viewModel.dataViewer = DataViewerState(schema: "public", name: "users", orderColumns: ["id"])
    viewModel.applySavedHighlights()
    #expect(viewModel.dataViewer?.highlights.map(\.filter) == [draft("bob").filter])
    #expect(viewModel.dataViewer?.highlights.map(\.color) == [.green])

    // A blank rule in the applied list neither paints nor lights the header dot
    viewModel.dataViewer?.highlights.append(blankRule)
    #expect(viewModel.dataViewer?.activeHighlights.map(\.filter) == [draft("bob").filter])

    var mongo = DataViewerState(schema: "public", name: "users", orderColumns: [])
    mongo.databaseType = .mongodb
    viewModel.dataViewer = mongo
    viewModel.applySavedHighlights()
    #expect(viewModel.dataViewer?.highlights.isEmpty == true)
  }
}
