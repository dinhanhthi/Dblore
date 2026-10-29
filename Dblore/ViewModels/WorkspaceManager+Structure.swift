// WorkspaceManager+Structure.swift
// Opens and closes the structure editor panel for a sidebar table. The editor uses the active
// tab's connection, rules and History (a new SQL tab when none is open), and an Apply reloads
// the sidebar schema the way a statement run from a tab does. A table rename retargets the
// table's data viewer tabs and the editor; a drop closes them. Under Protected mode both wait
// for Commit (after a Rollback the tabs stay as they are). The sidebar's Rename... and Drop
// Table... open the editor on the Name field or on the drop step. New Table... builds a
// `CreateTableModel` on the same tab, connection and reload. The PostgreSQL types editor sheet
// (New Type... and Edit Type...) works the same way, one per window; it reads the server version
// and connection epoch when it opens and goes with the connection (disconnect, connection switch)
// and, once its change went pending, with the transaction (Commit or Rollback).

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

  /// New Type... and Edit Type...: a connected PostgreSQL connection that allows schema changes,
  /// a schema read since the last connect, and no pending transaction (the catalog is paused)
  var canChangeUserTypes: Bool {
    guard connectionState.isConnected, schemaConnectionEpoch != nil, !isSchemaPaused,
      let config = workspace.connectionConfig
    else { return false }
    return config.databaseType == .postgresql && !config.protectionLevel.blocksSchemaChanges
  }

  /// The types editor on `type`
  func openUserTypeEditor(type: DatabaseUserType) {
    openUserTypeEditor { context, version, epoch in
      UserTypeEditorModel(
        type: type, context: context, serverVersion: version, connectionEpoch: epoch)
    }
  }

  /// The types editor on a new type in `schema` (`schemas` are the picker's choices)
  func openNewUserType(schema: String, schemas: [String]) {
    openUserTypeEditor { context, version, epoch in
      let model = UserTypeEditorModel(
        newIn: schema, context: context, serverVersion: version, connectionEpoch: epoch)
      model.schemaChoices = schemas.contains(schema) ? schemas : [schema] + schemas
      return model
    }
  }

  /// Builds the model on the active tab (a new SQL tab when none is open) once the server
  /// version and connection epoch are read (actor reads, no query), unless the connection
  /// changed or another editor opened meanwhile. The tab is picked (or made) only then, so a
  /// bail leaves no empty tab behind.
  private func openUserTypeEditor(
    _ make: @escaping (SchemaChangeContext, Int?, UInt64) -> UserTypeEditorModel
  ) {
    guard userTypeEditor == nil, canChangeUserTypes, let epoch = schemaConnectionEpoch else {
      return
    }
    let manager = connectionManager
    Task { [weak self] in
      let version = await manager.serverVersionNum()
      let connectionEpoch = await manager.connectionEpoch
      guard let self, self.userTypeEditor == nil, connectionEpoch == epoch,
        self.schemaConnectionEpoch == epoch, self.canChangeUserTypes
      else { return }
      let tabID = self.activeTabId ?? self.newSQLFile()
      guard let tab = self.viewModel(for: tabID), let context = SchemaChangeContext(tab: tab)
      else { return }
      let model = make(context, version, connectionEpoch)
      model.onApplied = { [weak self, weak model] pending in
        guard let self, let model, self.userTypeEditor === model else { return }
        await self.refreshPendingTransaction()
        if !pending, self.connectionState == .connected, !self.isSchemaPaused {
          self.startSchemaLoad()
        }
      }
      model.toastPresenter = { [weak tab] in tab?.showToast($0, type: $1) }
      self.userTypeEditor = model
    }
  }

  /// Hides the types editor (its staged changes go). Kept open while a change is being sent; a
  /// Safe Mode step still open is cancelled, so a late Touch ID answer sends nothing.
  func closeUserTypeEditor() {
    guard userTypeEditor?.isApplying != true else { return }
    dropUserTypeEditor()
  }

  /// Closes the types editor even mid-apply: its connection is going
  func dropUserTypeEditor() {
    userTypeEditor?.cancelConfirmation()
    userTypeEditor = nil
  }

  /// The app transaction ended (Commit / Rollback): an editor whose change went pending shows
  /// the type as it was before, so it closes (the sidebar reloads the types)
  func userTypeEditorTransactionEnded() {
    guard userTypeEditor?.disabledReason == UserTypeEditorModel.pausedMessage else { return }
    closeUserTypeEditor()
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
