//
//  WorkspaceManager.swift
//  SQLNotebook
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Manages a single workspace with shared database connection.
/// Replaces TabStateManager for workspace-scoped management.
@MainActor
@Observable
class WorkspaceManager: Identifiable {
  // MARK: - Identification

  let id: UUID

  // MARK: - Workspace Data

  var workspace: Workspace
  var isDirty: Bool = false

  // MARK: - Shared Connection

  /// Single database connection for entire workspace
  let connectionManager = DatabaseConnectionManager()
  var connectionState: ConnectionState = .disconnected
  var editingConnectionConfig: ConnectionConfig

  // MARK: - Tabs

  var tabs: [TabItem] = []
  var activeTabId: UUID?

  // MARK: - Tab Storage

  private var viewModels: [UUID: NotebookViewModel] = [:]
  private var notebookDocuments: [UUID: SQLNotebookDocument] = [:]
  private var editorDocuments: [UUID: SQLEditorDocument] = [:]

  // MARK: - UI State

  var showingCloseConfirmation = false
  var tabToClose: UUID?

  // MARK: - Settings

  let settingsResolver: SettingsResolver

  // MARK: - Sidebar State

  var isLeftSidebarVisible: Bool = false
  var isRightSidebarVisible: Bool = false
  var rightSidebarContent: SidebarContent?

  // Schema data (shared across all tabs)
  var databaseTables: [DatabaseTable] = []
  var databaseViews: [DatabaseView] = []
  var databaseFunctions: [DatabaseFunction] = []
  var databaseProcedures: [DatabaseProcedure] = []
  var databaseUsers: [DatabaseUser] = []
  var databaseRoles: [DatabaseRole] = []
  var databaseForeignKeys: [ForeignKey] = []
  var isLoadingSchema: Bool = false
  var areAllEntitiesExpanded: Bool = false

  // MARK: - Autocomplete

  let autocompleteProvider = SQLAutocompleteProvider()

  // MARK: - Initialization

  init(workspace: Workspace) {
    self.id = workspace.id
    self.workspace = workspace
    editingConnectionConfig = workspace.connectionConfig ?? ConnectionConfig()
    settingsResolver = SettingsResolver(workspaceSettings: workspace.settings)
    isLeftSidebarVisible = settingsResolver.isLeftSidebarVisible

    // Set connection manager for autocomplete
    autocompleteProvider.setConnectionManager(connectionManager)

    // Restore tabs from workspace
    for tabRef in workspace.tabs {
      tabs.append(tabRef.toTabItem())
    }
    activeTabId = workspace.activeTabId
  }

  /// Create a new untitled workspace
  static func createNew(connection: ConnectionConfig? = nil) -> WorkspaceManager {
    let workspace = Workspace.newUntitled(connection: connection)
    return WorkspaceManager(workspace: workspace)
  }

  /// Load workspace from URL
  static func load(from url: URL) async throws -> WorkspaceManager {
    let data = try Data(contentsOf: url)
    var workspace = try JSONDecoder().decode(Workspace.self, from: data)
    workspace.fileURL = url
    workspace.lastOpenedAt = Date()

    let manager = WorkspaceManager(workspace: workspace)

    // Restore tabs from saved workspace
    for tabRef in workspace.tabs {
      if let fileURL = tabRef.fileURL,
        FileManager.default.fileExists(atPath: fileURL.path)
      {
        do {
          try await manager.openFile(url: fileURL, selectTab: false)
        } catch {
          // Log error but continue loading other tabs
          await AppLogger.shared.warning(
            "Failed to restore tab: \(fileURL.lastPathComponent)",
            category: "Workspace"
          )
        }
      }
    }

    // Restore active tab
    if let activeId = workspace.activeTabId,
      manager.tabs.contains(where: { $0.id == activeId })
    {
      manager.selectTab(id: activeId)
    } else if let firstTab = manager.tabs.first {
      manager.selectTab(id: firstTab.id)
    }

    // Auto-connect if connection config exists
    if workspace.connectionConfig != nil {
      await manager.autoConnectIfNeeded()
    }

    return manager
  }

  // MARK: - Computed Properties

  var activeTab: TabItem? {
    guard let id = activeTabId else { return nil }
    return tabs.first { $0.id == id }
  }

  var activeViewModel: NotebookViewModel? {
    guard let id = activeTabId else { return nil }
    return viewModels[id]
  }

  var activeDocumentMode: DocumentMode? {
    guard let tab = activeTab else { return nil }
    return tab.documentType == .notebook ? .notebook : .editor
  }

  // MARK: - Tab Access

  func viewModel(for tabId: UUID) -> NotebookViewModel? {
    viewModels[tabId]
  }

  func notebookDocument(for tabId: UUID) -> SQLNotebookDocument? {
    notebookDocuments[tabId]
  }

  func editorDocument(for tabId: UUID) -> SQLEditorDocument? {
    editorDocuments[tabId]
  }

  // MARK: - Connection Operations

  func connect(config: ConnectionConfig) async throws {
    connectionState = .connecting

    do {
      try await connectionManager.connect(config: config)
      workspace.connectionConfig = config
      workspace.connectionKeychainKey =
        "\(config.host):\(config.port):\(config.database):\(config.username)"
      editingConnectionConfig = config
      connectionState = .connected
      isDirty = true

      // Save to connection history
      SessionManager.saveConnection(config)

      // Load schema
      await loadDatabaseSchema()

      // Refresh autocomplete
      await autocompleteProvider.refreshSchema()

      // Update all tab ViewModels with connection state
      syncConnectionStateToTabs()
    } catch {
      connectionState = .disconnected
      throw error
    }
  }

  func disconnect() async {
    await connectionManager.disconnect()
    connectionState = .disconnected

    // Clear schema
    databaseTables = []
    databaseViews = []
    databaseFunctions = []
    databaseProcedures = []
    databaseUsers = []
    databaseRoles = []
    databaseForeignKeys = []

    // Clear autocomplete cache
    autocompleteProvider.clearCache()

    // Update all tab ViewModels
    syncConnectionStateToTabs()
  }

  func testConnection() async throws -> Bool {
    try await connectionManager.testConnection(config: editingConnectionConfig)
  }

  func autoConnectIfNeeded() async {
    guard let config = workspace.connectionConfig else { return }

    // Try to get password from Keychain
    if let keychainKey = workspace.keychainKey,
      let password = SessionManager.getPasswordFromKeychain(for: keychainKey)
    {
      var configWithPassword = config
      configWithPassword.password = password
      editingConnectionConfig = configWithPassword

      do {
        try await connect(config: configWithPassword)
        await AppLogger.shared.info(
          "Auto-connected to workspace: \(config.safeDisplayString)",
          category: "Workspace"
        )
      } catch {
        await AppLogger.shared.warning(
          "Auto-connect failed: \(error.localizedDescription)",
          category: "Workspace"
        )
        connectionState = .disconnected
      }
    }
  }

  func syncConnectionStateToTabs() {
    for (_, viewModel) in viewModels {
      viewModel.connectionState = connectionState
      viewModel.databaseTables = databaseTables
      viewModel.databaseViews = databaseViews
      viewModel.databaseFunctions = databaseFunctions
      viewModel.databaseProcedures = databaseProcedures
      viewModel.databaseUsers = databaseUsers
      viewModel.databaseRoles = databaseRoles
      viewModel.databaseForeignKeys = databaseForeignKeys
    }
  }

  // MARK: - Tab Operations

  @discardableResult
  func newNotebook() -> UUID {
    let document = SQLNotebookDocument()
    let viewModel = createViewModel(for: document.notebook)
    viewModel.viewMode = .notebook

    let tab = TabItem.newNotebook()
    tabs.append(tab)
    viewModels[tab.id] = viewModel
    notebookDocuments[tab.id] = document
    isDirty = true

    selectTab(id: tab.id)
    return tab.id
  }

  @discardableResult
  func newSQLFile() -> UUID {
    let document = SQLEditorDocument()
    let cell = NotebookCell(cellType: .sql, content: "")
    let notebook = SQLNotebook(cells: [cell], documentType: .script)
    let viewModel = createViewModel(for: notebook)
    viewModel.viewMode = .editor
    viewModel.editorContent = ""

    let tab = TabItem.newSQLFile()
    tabs.append(tab)
    viewModels[tab.id] = viewModel
    editorDocuments[tab.id] = document
    isDirty = true

    selectTab(id: tab.id)
    return tab.id
  }

  func openFile(url: URL, selectTab: Bool = true) async throws {
    // Check if already open
    if let existingTab = tabs.first(where: { $0.fileURL == url }) {
      if selectTab {
        self.selectTab(id: existingTab.id)
      }
      return
    }

    guard let docType = TabDocumentType.from(url: url) else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }

    let data = try Data(contentsOf: url)
    let title = url.lastPathComponent

    let tab = TabItem(
      fileURL: url,
      documentType: docType,
      title: title
    )

    switch docType {
    case .notebook:
      var decodedNotebook = try DocumentCoder.decode(from: data)
      decodedNotebook.documentType = .notebook

      let document = SQLNotebookDocument(notebook: decodedNotebook)
      document.setFileURL(url)

      let viewModel = createViewModel(for: document.notebook)
      viewModel.viewMode = .notebook

      tabs.append(tab)
      viewModels[tab.id] = viewModel
      notebookDocuments[tab.id] = document

    case .sqlFile:
      guard let content = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadCorruptFile)
      }

      let document = SQLEditorDocument(content: content)
      document.setFileURL(url)

      let cell = NotebookCell(cellType: .sql, content: content)
      let notebook = SQLNotebook(cells: [cell], documentType: .script)
      let viewModel = createViewModel(for: notebook)
      viewModel.viewMode = .editor
      viewModel.editorContent = content

      tabs.append(tab)
      viewModels[tab.id] = viewModel
      editorDocuments[tab.id] = document
    }

    isDirty = true
    if selectTab {
      self.selectTab(id: tab.id)
    }
  }

  /// Create a ViewModel that uses the workspace's shared connection
  private func createViewModel(for notebook: SQLNotebook) -> NotebookViewModel {
    let viewModel = NotebookViewModel(notebook: notebook)

    // Share workspace connection state
    viewModel.connectionState = connectionState
    viewModel.databaseTables = databaseTables
    viewModel.databaseViews = databaseViews
    viewModel.databaseFunctions = databaseFunctions
    viewModel.databaseProcedures = databaseProcedures
    viewModel.databaseUsers = databaseUsers
    viewModel.databaseRoles = databaseRoles
    viewModel.databaseForeignKeys = databaseForeignKeys

    // Override the connection manager reference
    // Note: NotebookViewModel creates its own connectionManager, but we'll use workspace's
    // This is handled in query execution by passing the workspace's connectionManager

    return viewModel
  }

  func selectTab(id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    activeTabId = id
    workspace.activeTabId = id
    isDirty = true

    if let index = tabs.firstIndex(where: { $0.id == id }) {
      tabs[index].lastAccessed = Date()
    }
  }

  func moveTab(from: Int, to: Int) {
    guard from != to,
      from >= 0, from < tabs.count,
      to >= 0, to < tabs.count
    else { return }

    let tab = tabs.remove(at: from)
    tabs.insert(tab, at: to)
    isDirty = true
  }

  func requestCloseTab(id: UUID) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }

    if tab.isDirty {
      tabToClose = id
      showingCloseConfirmation = true
    } else {
      closeTabImmediately(id: id)
    }
  }

  func closeTabWithoutSaving() {
    guard let id = tabToClose else { return }
    closeTabImmediately(id: id)
    tabToClose = nil
    showingCloseConfirmation = false
  }

  func saveAndCloseTab() async {
    guard let id = tabToClose else { return }
    do {
      try await saveTab(id: id)
      closeTabImmediately(id: id)
    } catch {
      await AppLogger.shared.error("Failed to save tab: \(error)", category: "Workspace")
    }
    tabToClose = nil
    showingCloseConfirmation = false
  }

  func cancelClose() {
    tabToClose = nil
    showingCloseConfirmation = false
  }

  private func closeTabImmediately(id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

    if activeTabId == id {
      if tabs.count > 1 {
        let newIndex = index > 0 ? index - 1 : 1
        activeTabId = tabs[newIndex].id
      } else {
        activeTabId = nil
      }
    }

    tabs.remove(at: index)
    viewModels.removeValue(forKey: id)
    notebookDocuments.removeValue(forKey: id)
    editorDocuments.removeValue(forKey: id)
    isDirty = true
  }

  func markDirty(tabId: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    tabs[index].isDirty = true
  }

  func markClean(tabId: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    tabs[index].isDirty = false
  }

  // MARK: - Tab Navigation

  func selectNextTab() {
    guard let currentId = activeTabId,
      let currentIndex = tabs.firstIndex(where: { $0.id == currentId })
    else { return }

    let nextIndex = (currentIndex + 1) % tabs.count
    selectTab(id: tabs[nextIndex].id)
  }

  func selectPreviousTab() {
    guard let currentId = activeTabId,
      let currentIndex = tabs.firstIndex(where: { $0.id == currentId })
    else { return }

    let prevIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
    selectTab(id: tabs[prevIndex].id)
  }

  func selectTab(atIndex index: Int) {
    guard index > 0, index <= tabs.count else { return }
    selectTab(id: tabs[index - 1].id)
  }

  // MARK: - Save Operations

  func saveTab(id: UUID) async throws {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }

    if let url = tab.fileURL {
      try await saveToURL(tabId: id, url: url)
    } else {
      try await saveWithPanel(tabId: id)
    }
  }

  private func saveToURL(tabId: UUID, url: URL) async throws {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

    switch tab.documentType {
    case .notebook:
      guard let document = notebookDocuments[tabId],
        let viewModel = viewModels[tabId]
      else { return }
      document.notebook = viewModel.notebook
      let includeResults = settingsResolver.includeResultsOnSave
      let data = try DocumentCoder.encode(
        document.notebook,
        includeResultsOnSave: includeResults,
        useCompactFormat: false
      )
      try data.write(to: url, options: .atomic)

    case .sqlFile:
      guard let document = editorDocuments[tabId],
        let viewModel = viewModels[tabId]
      else { return }
      document.content = viewModel.editorContent
      guard let data = viewModel.editorContent.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try data.write(to: url, options: .atomic)
    }

    markClean(tabId: tabId)
  }

  private func saveWithPanel(tabId: UUID) async throws {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = tab.title

    switch tab.documentType {
    case .notebook:
      panel.allowedContentTypes = [.sqlNotebook]
      if !tab.title.hasSuffix(".sqlnb") {
        panel.nameFieldStringValue += ".sqlnb"
      }
    case .sqlFile:
      panel.allowedContentTypes = [.sql]
      if !tab.title.hasSuffix(".sql") {
        panel.nameFieldStringValue += ".sql"
      }
    }

    guard let window = NSApp.keyWindow else {
      throw CocoaError(.fileNoSuchFile)
    }

    let response = await panel.beginSheetModal(for: window)

    guard response == .OK, let url = panel.url else {
      throw CocoaError(.userCancelled)
    }

    if let index = tabs.firstIndex(where: { $0.id == tabId }) {
      tabs[index].fileURL = url
      tabs[index].title = url.lastPathComponent
    }

    if tab.documentType == .notebook {
      notebookDocuments[tabId]?.setFileURL(url)
    } else {
      editorDocuments[tabId]?.setFileURL(url)
    }

    try await saveToURL(tabId: tabId, url: url)
  }

  // MARK: - Open Panels

  func openNotebookWithPanel() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.sqlNotebook]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a notebook file to open"

    guard let window = NSApp.keyWindow else { return }
    let response = await panel.beginSheetModal(for: window)

    if response == .OK, let url = panel.url {
      do {
        try await openFile(url: url)
      } catch {
        await AppLogger.shared.error("Failed to open notebook: \(error)", category: "Workspace")
      }
    }
  }

  func openSQLFileWithPanel() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.sql]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a SQL file to open"

    guard let window = NSApp.keyWindow else { return }
    let response = await panel.beginSheetModal(for: window)

    if response == .OK, let url = panel.url {
      do {
        try await openFile(url: url)
      } catch {
        await AppLogger.shared.error("Failed to open SQL file: \(error)", category: "Workspace")
      }
    }
  }
}
