//
//  NotebookViewModel+Highlight.swift
//  Dblore
//
//  Highlight form of the data viewer: same conditions as the filter, but applying only repaints
//  the loaded rows (no page reset, no reload).
//

import Foundation

extension NotebookViewModel {
  /// Prepare the highlight form: the draft restarts from the applied highlight when the viewer
  /// shows another table, keeps at least one row, and the saved highlights are read again
  func prepareHighlightDraft() {
    guard let state = dataViewer else { return }
    let relation = "\(state.schema).\(state.name)"
    if highlightDraftRelation != relation {
      highlightDraftRelation = relation
      highlightDraft = state.highlight
    }
    if highlightDraft.isEmpty {
      highlightDraft.filter = TableFilter(conditions: [FilterCondition()])
    }
    refreshSavedHighlights()
  }

  /// Apply the draft; a blank draft clears the highlight
  func applyHighlight() {
    guard let state = dataViewer else { return }
    var applied = highlightDraft
    if applied.filter.whereClause(dialect: state.databaseType) == nil {
      applied.filter = TableFilter(conditions: [])
    }
    dataViewer?.highlight = applied
  }

  /// Highlight from the grid context menu: rows where `column` equals `value` (is NULL for a NULL
  /// cell), painted per `style` in `color`. Replaces the applied highlight and fills the form
  /// with it, so the sidebar shows the same rule.
  func highlightCell(
    column: String, value: CellValue, style: HighlightStyle, color: HighlightColor
  ) {
    guard let state = dataViewer else { return }
    let condition =
      value.isNull
      ? FilterCondition(column: column, op: .isNull)
      : FilterCondition(column: column, op: .equals, value: value.fullString)
    let highlight = TableHighlight(
      filter: TableFilter(conditions: [condition]), color: color, style: style)
    highlightDraftRelation = "\(state.schema).\(state.name)"
    highlightDraft = highlight
    dataViewer?.highlight = highlight
  }

  /// Remove the applied highlight and reset the form to one empty row
  func clearHighlight() {
    guard dataViewer != nil else { return }
    highlightDraft.filter = TableFilter(conditions: [FilterCondition()])
    dataViewer?.highlight.filter = TableFilter(conditions: [])
  }

  private var savedHighlightKey: String? {
    guard let state = dataViewer, let config = notebook.connectionConfig else { return nil }
    return SavedFilterStore.key(for: config, schema: state.schema, name: state.name)
  }

  func refreshSavedHighlights() {
    savedHighlights = savedHighlightKey.map { savedFilterStore.listHighlights(for: $0) } ?? []
  }

  /// Save the draft under the trimmed `name`, replacing a saved highlight of that name.
  /// Returns false (nothing saved) for a blank name.
  @discardableResult
  func saveCurrentHighlight(named name: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let key = savedHighlightKey else { return false }
    savedFilterStore.saveHighlight(highlightDraft, named: name, for: key)
    refreshSavedHighlights()
    return true
  }

  /// Fill the draft with a saved highlight (not applied until Apply)
  func loadSavedHighlight(_ saved: SavedHighlight) {
    highlightDraft = saved.highlight
    if highlightDraft.isEmpty {
      highlightDraft.filter = TableFilter(conditions: [FilterCondition()])
    }
  }

  func deleteSavedHighlight(_ saved: SavedHighlight) {
    guard let key = savedHighlightKey else { return }
    savedFilterStore.deleteHighlight(id: saved.id, for: key)
    refreshSavedHighlights()
  }
}
