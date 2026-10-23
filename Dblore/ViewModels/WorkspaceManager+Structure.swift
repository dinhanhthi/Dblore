// WorkspaceManager+Structure.swift
// Opens and closes the structure editor panel for a sidebar table. The editor uses the active
// tab's connection, rules and History (a new SQL tab when none is open), and an Apply reloads
// the sidebar schema the way a statement run from a tab does. A table rename retargets the
// table's data viewer tabs and the editor; a drop closes them. Under Protected mode both wait
// for Commit (after a Rollback the tabs stay as they are). The sidebar's Rename... and Drop
// Table... open the editor on the Name field or on the drop step. New Table... builds a
// `CreateTableModel` on the same tab, connection and reload.

import Foundation

extension WorkspaceManager {
  /// What the editor does once loaded, when opened from a table row's menu
  enum StructureEditorStart {
    /// Focus the table's Name field
    case rename
    /// Show the typed-name step of Drop Table
    case drop
  }

  /// Rename, Drop Table and New Table in the sidebar: connected, a schema read since the last
  /// connect, an engine whose tables change in Dblore, and a connection that allows schema
  /// changes (MySQL under Protected mode is refused in the editor and sheet, with the reason)
  var canChangeTableSchema: Bool {
    guard connectionState.isConnected, schemaConnectionEpoch != nil,
      let config = workspace.connectionConfig
    else { return false }
    return SidebarSectionModel.supportsTableChanges(config.databaseType)
      && !config.protectionLevel.blocksSchemaChanges
  }

  /// Shows the structure editor on `schema.table` and starts loading it, then applies `start`
  func openStructureEditor(schema: String, table: String, start: StructureEditorStart? = nil) {
    let tabID = activeTabId ?? newSQLFile()
    guard let tab = viewModel(for: tabID),
      let model = StructureEditorModel(schema: schema, table: table, tab: tab)
    else { return }
    model.onApplied = { [weak self] in
      await self?.refreshPendingTransaction()
      await self?.refreshSchemaAfterStatements()
    }
    model.onTableChange = { [weak self] change, pending in
      if pending {
        self?.pendingTableChanges.append(change)
      } else {
        self?.applyTableChange(change)
      }
    }
    model.toastPresenter = { [weak tab] in tab?.showToast($0, type: $1) }
    model.focusesTableName = start == .rename
    structureEditor = model
    Task { [weak self] in
      await model.load()
      if start == .drop, self?.structureEditor === model { model.requestDropTable() }
    }
  }

  /// The Create Table sheet for a table in `schema` (`schemas` are the choices), on the active
  /// tab (a new SQL tab when none is open), already reading the connection state. Nil when that
  /// tab is not connected. A created table reloads the sidebar schema (on Commit when pending).
  func makeCreateTableModel(schema: String, schemas: [String]) -> CreateTableModel? {
    let tabID = activeTabId ?? newSQLFile()
    guard let tab = viewModel(for: tabID),
      let model = CreateTableModel(schema: schema, schemas: schemas, tab: tab)
    else { return nil }
    model.onApplied = { [weak self] _ in
      await self?.refreshPendingTransaction()
      await self?.refreshSchemaAfterStatements()
    }
    model.toastPresenter = { [weak tab] in tab?.showToast($0, type: $1) }
    Task { await model.load() }
    return model
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

  /// The app transaction ended: on Commit the pending renames and drops reach the open tabs, on
  /// any other end (Rollback, a failed Commit, a lost or closed connection) they are forgotten
  func resolvePendingTableChanges(committed: Bool) {
    let changes = pendingTableChanges
    pendingTableChanges = []
    guard committed else { return }
    for change in changes { applyTableChange(change) }
  }

  /// A rename retargets the table's data viewer tabs and the editor; a drop closes them
  func applyTableChange(_ change: StructureEditorModel.TableChange) {
    switch change {
    case .renamed(let schema, let name, let newName):
      renameDataViewerTabs(schema: schema, from: name, to: newName)
      if let model = structureEditor, model.schema == schema, model.table == name {
        model.tableRenamed(to: newName)
      }
    case .dropped(let schema, let name):
      closeDataViewerTabs(schema: schema, name: name)
      if let model = structureEditor, model.schema == schema, model.table == name {
        closeStructureEditor()
      }
    }
  }
}
