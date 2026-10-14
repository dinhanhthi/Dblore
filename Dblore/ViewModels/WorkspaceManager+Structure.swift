// WorkspaceManager+Structure.swift
// Opens and closes the structure editor panel for a sidebar table. The editor uses the active
// tab's connection, rules and History (a new SQL tab when none is open), and an Apply reloads
// the sidebar schema the way a statement run from a tab does.

import Foundation

extension WorkspaceManager {
  /// Shows the structure editor on `schema.table` and starts loading it
  func openStructureEditor(schema: String, table: String) {
    let tabID = activeTabId ?? newSQLFile()
    guard let tab = viewModel(for: tabID),
      let model = StructureEditorModel(schema: schema, table: table, tab: tab)
    else { return }
    model.onApplied = { [weak self] in
      await self?.refreshPendingTransaction()
      await self?.refreshSchemaAfterStatements()
    }
    model.toastPresenter = { [weak tab] in tab?.showToast($0, type: $1) }
    structureEditor = model
    Task { await model.load() }
  }

  /// Hides the editor (its staged changes go). Kept open while a change is being sent. A Safe
  /// Mode step still open is cancelled, so a late Touch ID answer sends nothing.
  func closeStructureEditor() {
    guard structureEditor?.isApplying != true else { return }
    structureEditor?.cancelConfirmation()
    structureEditor = nil
  }

  /// The app transaction ended (Commit / Rollback): an editor made view-only by its pending
  /// change, or opened while the catalog was paused, reads the table again
  func structureEditorTransactionEnded() {
    let paused = StructureEditorModel.pausedMessage
    guard let model = structureEditor,
      model.disabledReason == paused || model.loadState == .failed(paused)
    else { return }
    Task { await model.transactionEnded() }
  }
}
