//
//  WorkspaceManager+CommandPalette.swift
//  Dblore
//
//  Copies palette rows from the live workspace and runs the row the user picks.
//

import Foundation

/// Fixed palette commands. Ids stay stable. Titles are the ones the menus and buttons already use.
private enum CommandPaletteAction: String, CaseIterable {
  case newNotebook = "new-notebook"
  case newSQLFile = "new-sql-file"
  case runCell = "run-cell"
  case runAll = "run-all"
  case toggleLeftSidebar = "toggle-left-sidebar"
  case toggleRightSidebar = "toggle-right-sidebar"
  case toggleAIAssistant = "toggle-ai-assistant"
  case settings = "settings"
  case schemaVisualizer = "schema-visualizer"
  case connect = "connect"
  case disconnect = "disconnect"
  case commit = "commit"
  case rollback = "rollback"

  var title: String {
    switch self {
    case .newNotebook: "New Notebook"
    case .newSQLFile: "New SQL File"
    case .runCell: "Run Cell"
    case .runAll: "Run All Cells"
    case .toggleLeftSidebar: "Toggle Left Sidebar"
    case .toggleRightSidebar: "Toggle Right Sidebar"
    case .toggleAIAssistant: "Toggle AI Assistant"
    case .settings: "Settings"
    case .schemaVisualizer: "Visualize Schema Relationships"
    case .connect: "Connect"
    case .disconnect: "Disconnect"
    case .commit: "Commit"
    case .rollback: "Roll Back"
    }
  }

  var snapshot: CommandPaletteSnapshot.Action {
    .init(id: rawValue, title: title)
  }
}

extension WorkspaceManager {
  /// Tables, views, functions, open tabs, favorites, and the fixed actions.
  /// History is searched separately. `connectionKey` is empty when no database is configured.
  func paletteSources() -> CommandPaletteSnapshot {
    CommandPaletteSnapshot(
      tables: databaseTables.map { .init(schema: $0.schema, name: $0.name) },
      views: databaseViews.map { .init(schema: $0.schema, name: $0.name) },
      functions: databaseFunctions.map {
        .init(schema: $0.schema, name: $0.name, arguments: $0.arguments)
      },
      tabs: tabs.map { .init(id: $0.id, title: $0.title) },
      favorites: workspace.favorites.items.map { .init(id: $0.id, name: $0.name, sql: $0.sql) },
      actions: CommandPaletteAction.allCases.map(\.snapshot),
      connectionKey: activeHistoryConnectionKey ?? ""
    )
  }

  /// Opens the palette on `paletteSources()`, or closes it when the search field is not focused.
  /// Cmd+K while that field is editing does nothing. Escape still dismisses it.
  func openCommandPalette() {
    if commandPalette != nil {
      guard !commandPaletteFieldFocused else { return }
      commandPalette = nil
      commandPaletteFieldFocused = false
      return
    }
    let model = CommandPaletteModel(historyStore: resolvedHistoryBrowser())
    model.open(paletteSources())
    commandPaletteFieldFocused = true
    commandPalette = model
  }

  /// Runs `item` through the sidebar and menu methods. Commit and rollback use the
  /// transaction API, never the words COMMIT or ROLLBACK as user SQL.
  /// False when nothing ran, so the palette stays open.
  @discardableResult
  func perform(_ item: CommandPaletteItem) -> Bool {
    switch item {
    case .table(let schema, let name):
      openDataViewer(
        schema: schema, name: name, orderColumns: palettePrimaryKeyNames(schema: schema, name: name)
      )
    case .view(let schema, let name):
      openDataViewer(schema: schema, name: name, orderColumns: [])
    case .function(_, let name, _):
      guard canInsertPaletteText() else { return false }
      activeViewModel?.insertTextIntoSelectedCell(name)
      return true
    case .tab(let id, _):
      selectTab(id: id)
    case .favorite(let id, let name, let sql):
      guard canInsertPaletteText() else { return false }
      insertFavorite(FavoriteStatement(id: id, name: name, sql: sql))
      return true
    case .history(let id, let sql):
      guard !QueryHistoryEntry.isTransactionSummary(sql), canInsertPaletteText() else {
        return false
      }
      insertHistory(paletteHistoryEntry(id: id, sql: sql))
      return true
    case .action(let id, _):
      return performPaletteAction(id: id)
    }
    return true
  }

  /// A selected notebook cell, or an editor text view. A data viewer has neither.
  private func canInsertPaletteText() -> Bool {
    guard let viewModel = activeViewModel else { return false }
    if viewModel.viewMode == .editor {
      return viewModel.editorTextView != nil
    }
    return viewModel.selectedCellId != nil
  }

  private func performPaletteAction(id: String) -> Bool {
    guard let action = CommandPaletteAction(rawValue: id) else { return false }
    switch action {
    case .newNotebook:
      newNotebook()
    case .newSQLFile:
      newSQLFile()
    case .runCell:
      return runPaletteCell()
    case .runAll:
      return runPaletteAll()
    case .toggleLeftSidebar:
      toggleLeftSidebar()
    case .toggleRightSidebar:
      guard let viewModel = activeViewModel else { return false }
      viewModel.toggleSidebar()
    case .toggleAIAssistant:
      withSidebarAnimation { aiAssistant.isVisible.toggle() }
    case .settings:
      showSettings()
    case .schemaVisualizer:
      showSchemaVisualizer()
    case .connect:
      // The Connect button opens the form. It does not connect by itself.
      showConnectionForm()
    case .disconnect:
      Task { await disconnect() }
    case .commit:
      guard case .appTx = pendingTransaction else { return false }
      requestCommit()
    case .rollback:
      guard !pendingTransaction.isIdle else { return false }
      Task { await rollback() }
    }
    return true
  }

  /// Primary key names in column order. The schema sidebar passes the same list.
  private func palettePrimaryKeyNames(schema: String, name: String) -> [String] {
    databaseTables.first { $0.schema == schema && $0.name == name }?
      .columns.filter(\.isPrimaryKey).map(\.name) ?? []
  }

  /// Enough of a row for `insertHistory` to accept or refuse the SQL.
  private func paletteHistoryEntry(id: Int64, sql: String) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: id, sql: sql, executedAt: .distantPast, durationMs: 0, rowCount: nil, status: .success,
      errorMessage: nil, connectionKey: activeHistoryConnectionKey ?? "", connectionLabel: "",
      workspaceID: workspace.id, workspaceName: workspace.name, source: .cell)
  }

  /// Notebook: the selected cell, with its confirm dialog. Editor: the Query menu's Run.
  private func runPaletteCell() -> Bool {
    guard let viewModel = activeViewModel else { return false }
    if viewModel.viewMode == .notebook {
      guard let cellId = viewModel.selectedCellId else { return false }
      viewModel.confirmAndRunCell(id: cellId)
      return true
    }
    return runPaletteEditor()
  }

  /// Notebook: the Cell menu posts `.runAllCells`, and that handler shows "Run all cells?"
  /// before `runAllCells()`. Editor: the same Run as the Query menu.
  private func runPaletteAll() -> Bool {
    guard let viewModel = activeViewModel, !isSchemaVisualizerActive else { return false }
    if viewModel.viewMode == .notebook {
      NotificationCenter.default.post(name: .runAllCells, object: nil)
      return true
    }
    return runPaletteEditor()
  }

  /// Query menu Run. `runEditorQuery` reloads a data viewer and runs a SQL file.
  private func runPaletteEditor() -> Bool {
    guard !isSchemaVisualizerActive, activeViewModel?.viewMode == .editor else { return false }
    NotificationCenter.default.post(name: .runEditorQuery, object: nil)
    return true
  }
}
