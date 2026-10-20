//
//  NotebookViewModel+Highlight.swift
//  Dblore
//
//  Highlight rules of the data viewer: same conditions as the filter, but applying only repaints
//  the loaded rows (no page reset, no reload). Several rules apply at once, first match wins.
//

import Foundation

extension NotebookViewModel {
  /// Prepare the highlight form: the draft restarts as one empty row when the viewer shows
  /// another table, keeps at least one row, and the saved highlights are read again
  func prepareHighlightDraft() {
    guard let state = dataViewer else { return }
    let relation = "\(state.schema).\(state.name)"
    if highlightDraftRelation != relation {
      highlightDraftRelation = relation
      highlightDraft = TableHighlight(filter: TableFilter(conditions: []))
    }
    if highlightDraft.isEmpty {
      highlightDraft.filter = TableFilter(conditions: [FilterCondition()])
    }
    refreshSavedHighlights()
  }

  /// Add the draft as a rule; a draft without a complete condition adds nothing
  func applyHighlight() {
    addHighlight(highlightDraft)
  }

  /// Highlight from the grid context menu: rows where `column` equals `value` (is NULL for a NULL
  /// cell), painted per `style` in `color`, added as a rule
  func highlightCell(
    column: String, value: CellValue, style: HighlightStyle, color: HighlightColor
  ) {
    guard dataViewer != nil else { return }
    let condition =
      value.isNull
      ? FilterCondition(column: column, op: .isNull)
      : FilterCondition(column: column, op: .equals, value: value.fullString)
    addHighlight(
      TableHighlight(filter: TableFilter(conditions: [condition]), color: color, style: style))
  }

  /// New rules go first, so they win where they overlap older ones. The same rule applied
  /// again moves to the top instead of repeating.
  private func addHighlight(_ highlight: TableHighlight) {
    guard dataViewer != nil, highlight.hasCompleteCondition else { return }
    var rule = highlight
    rule.id = UUID()
    rule.isEnabled = true
    dataViewer?.highlights.removeAll { $0.isSameRule(as: rule) }
    dataViewer?.highlights.insert(rule, at: 0)
  }

  func removeHighlight(id: UUID) {
    dataViewer?.highlights.removeAll { $0.id == id }
  }

  func setHighlightEnabled(id: UUID, _ isEnabled: Bool) {
    guard let index = dataViewer?.highlights.firstIndex(where: { $0.id == id }) else { return }
    dataViewer?.highlights[index].isEnabled = isEnabled
  }

  /// Remove every rule and reset the form to one empty row
  func clearHighlight() {
    guard dataViewer != nil else { return }
    highlightDraft.filter = TableFilter(conditions: [FilterCondition()])
    dataViewer?.highlights = []
  }

  /// Apply the saved highlights marked active, in saved order; call it when an SQL table opens.
  /// MongoDB viewers are left alone.
  func applySavedHighlights() {
    guard !isMongoDataViewer, let key = savedHighlightKey else { return }
    dataViewer?.highlights = savedFilterStore.listHighlights(for: key)
      .filter { $0.isActive && $0.highlight.hasCompleteCondition }
      .map { saved in
        var rule = saved.highlight
        rule.id = UUID()
        return rule
      }
  }

  /// Mark a saved highlight to come back when the table opens; marking it also applies it now
  func setSavedHighlightActive(_ saved: SavedHighlight, _ isActive: Bool) {
    guard let key = savedHighlightKey else { return }
    savedFilterStore.setHighlightActive(id: saved.id, isActive, for: key)
    refreshSavedHighlights()
    if isActive { addHighlight(saved.highlight) }
  }

  private var savedHighlightKey: String? {
    guard let state = dataViewer, let config = notebook.connectionConfig else { return nil }
    return SavedFilterStore.key(for: config, schema: state.schema, name: state.name)
  }

  func refreshSavedHighlights() {
    savedHighlights = savedHighlightKey.map { savedFilterStore.listHighlights(for: $0) } ?? []
  }

  /// Save the draft under the trimmed `name`, replacing a saved highlight of that name.
  /// Returns false (nothing saved) for a blank name or a draft without a complete condition.
  @discardableResult
  func saveCurrentHighlight(named name: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, highlightDraft.hasCompleteCondition, let key = savedHighlightKey
    else { return false }
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
