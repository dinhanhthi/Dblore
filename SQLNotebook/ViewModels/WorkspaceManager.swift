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
  var autoSaveTask: Task<Void, Never>?

  // MARK: - Shared Connection

  /// Single database connection for entire workspace
  let connectionManager = DatabaseConnectionManager()
  var connectionState: ConnectionState = .disconnected
  var editingConnectionConfig: ConnectionConfig
  /// Connect to the same database with weaker safety settings, held until the Safe Mode
  /// unlock succeeds (see `WorkspaceManager+ConnectionSync.swift`)
  var pendingWeakeningConnect: ConnectionConfig?
  /// The server closed the session: shown with Reconnect (WorkspaceManager+ConnectionLoss.swift)
  var connectionLostMessage: String?

  // MARK: - Protected Transaction (see WorkspaceManager+Transaction.swift)

  /// Mirror of the actor's transaction state, refreshed after every execution in any tab
  var pendingTransaction: TransactionState = .idle
  var transactionOpenedAt: Date?
  /// The tab whose execution opened the pending transaction
  var transactionOriginTabId: UUID?
  var isCommitConfirmationVisible = false
  var isCommitUnlockVisible = false
  /// Actor generation of `pendingTransaction`, and the one the Commit confirmation showed
  @ObservationIgnored var pendingTransactionGeneration: UInt64 = 0
  @ObservationIgnored var commitReviewedGeneration: UInt64?
  /// A gated statement of the transaction was in flight at the last refresh
  @ObservationIgnored var isStatementInFlight = false
  /// A resolve prompt is open: a second resolve (or tab close) must not stack another one
  @ObservationIgnored var isResolvingPendingTransaction = false
  /// Asks "Commit / Roll back / Cancel"; nil = NSAlert (tests inject an answer)
  @ObservationIgnored var pendingTransactionPrompt: PendingTransactionPrompt?

  // MARK: - Tabs

  var tabs: [TabItem] = []
  var activeTabId: UUID?

  // MARK: - Tab Storage

  private(set) var viewModels: [UUID: NotebookViewModel] = [:]
  private var notebookDocuments: [UUID: SQLNotebookDocument] = [:]
  private var editorDocuments: [UUID: SQLEditorDocument] = [:]

  // MARK: - Security-Scoped Bookmarks

  /// Bookmark of each tab's file, written to the .sqlws on save
  @ObservationIgnored var tabBookmarks: [UUID: Data] = [:]
  /// Bookmark of the .sqlws file itself, stored in the recent workspaces entry
  @ObservationIgnored var workspaceBookmark: Data?
  /// Location `workspaceBookmark` was last created for (a failed attempt is not retried)
  @ObservationIgnored var workspaceBookmarkURL: URL?
  /// Bookmark of the folder containing the .sqlws (granted once for bookmark-less tab files)
  @ObservationIgnored var folderBookmark: Data?
  /// Access held while the workspace is open (released on close)
  @ObservationIgnored var workspaceAccess: SecurityScopedAccessToken?
  @ObservationIgnored var folderAccess: SecurityScopedAccessToken?
  /// Access held while each tab is open (released on tab close)
  @ObservationIgnored var tabAccess: [UUID: SecurityScopedAccessToken] = [:]
  @ObservationIgnored var accessHooks = SecurityScopedAccessHooks.live
  @ObservationIgnored var recents = RecentManager.shared

  // MARK: - UI State

  var showingCloseConfirmation = false
  var tabToClose: UUID?

  // MARK: - Connection Modals

  var isConnectionFormModalVisible: Bool = false
  var isConnectionInfoModalVisible: Bool = false

  // MARK: - Settings Modal

  var isSettingsModalVisible: Bool = false

  // MARK: - Settings

  let settingsResolver: SettingsResolver

  // MARK: - Sidebar State

  var isLeftSidebarVisible: Bool = false

  // Schema Visualizer state (workspace-level)
  var isSchemaVisualizerActive: Bool = false
  var schemaGraph: SchemaGraph?
  var visualizerScale: CGFloat = 1.0
  var visualizerOffset: CGPoint = .zero
  var selectedGraphNodeId: UUID?
  var isLoadingSchemaGraph: Bool = false
  weak var schemaGraphNSView: SchemaGraphNSView?
  var showTableConnections: Bool = true
  var showColumnConnections: Bool = false
  var schemaSearchState: SchemaSearchState = SchemaSearchState()
  var isSchemaSearchPanelVisible: Bool = false
  var schemaSearchFocusTrigger: UUID = UUID()  // Trigger re-focus on Cmd+F

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

  init(workspace: Workspace, restoreTabs: Bool = true) {
    self.id = workspace.id
    self.workspace = workspace
    editingConnectionConfig = workspace.connectionConfig ?? ConnectionConfig()
    settingsResolver = SettingsResolver(workspaceSettings: workspace.settings)
    isLeftSidebarVisible = settingsResolver.isLeftSidebarVisible

    // Set connection manager for autocomplete
    autocompleteProvider.setConnectionManager(connectionManager)
    startSessionLossListener()

    // Only restore tabs for new workspaces (not loading from disk)
    // When loading from disk, load() will handle tab restoration with proper viewModels
    if restoreTabs {
      for tabRef in workspace.tabs {
        tabs.append(tabRef.toTabItem())
        tabBookmarks[tabRef.id] = tabRef.bookmark
      }
      activeTabId = workspace.activeTabId
    }
  }

  /// Create a new untitled workspace
  static func createNew(connection: ConnectionConfig? = nil) -> WorkspaceManager {
    let workspace = Workspace.newUntitled(connection: connection)
    return WorkspaceManager(workspace: workspace)
  }

  /// Load workspace from URL, reading it (and its tab files) through the stored bookmarks of
  /// its recent entry. Called on user action only: a permission failure asks the user to
  /// select the file again, or once for the folder of bookmark-less tab files.
  static func load(
    from url: URL, bookmark: Data? = nil, folderBookmark: Data? = nil,
    hooks: SecurityScopedAccessHooks = .live
  ) async throws -> WorkspaceManager {
    let access = hooks.access(bookmark)
    let folderAccess = hooks.access(folderBookmark)
    var fileURL = access?.isStale == true ? access?.url ?? url : url
    var fileBookmark = access?.bookmark
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error where SecurityScopedAccess.isPermissionError(error) {
      guard let chosen = await hooks.chooseFile(fileURL) else { throw error }
      data = try Data(contentsOf: chosen)
      fileURL = chosen
      fileBookmark = nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var workspace = try decoder.decode(Workspace.self, from: data)
    workspace.fileURL = fileURL
    workspace.lastOpenedAt = Date()

    // Don't restore tabs in init - we'll do it here with proper viewModels
    let manager = WorkspaceManager(workspace: workspace, restoreTabs: false)
    manager.accessHooks = hooks
    manager.workspaceAccess = fileBookmark == nil ? nil : access?.token
    manager.folderAccess = folderAccess?.token
    manager.folderBookmark = folderAccess?.bookmark
    manager.workspaceBookmark = fileBookmark ?? hooks.makeBookmark(fileURL)
    manager.workspaceBookmarkURL = fileURL

    // Restore tabs from saved workspace with their original IDs; save refreshed bookmarks
    if await manager.restoreTabs(workspace.tabs) {
      manager.markDirtyAndScheduleAutoSave()
    }

    // Restore active tab
    if let activeId = workspace.activeTabId,
      manager.tabs.contains(where: { $0.id == activeId })
    {
      manager.activeTabId = activeId
    } else if let firstTab = manager.tabs.first {
      manager.activeTabId = firstTab.id
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

  /// Connect without the weakening check. Only `connect(config:globalSafeMode:)` and
  /// `completePendingWeakeningConnect()` (after the Safe Mode unlock) may call this.
  func connectWithoutUnlockCheck(config: ConnectionConfig) async throws {
    connectionState = .connecting
    // The actor disconnects first, so current edit targets die even if the connect fails
    invalidateEditTargetsInTabs()

    do {
      try await connectionManager.connect(config: config)
      invalidateEditTargetsInTabs()  // targets resolved while the actor was switching
      workspace.connectionConfig = config
      workspace.connectionKeychainKey =
        "\(config.host):\(config.port):\(config.database):\(config.username)"
      editingConnectionConfig = config
      connectionState = .connected
      connectionLostMessage = nil
      await refreshPendingTransaction()
      markDirtyAndScheduleAutoSave()

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
      invalidateEditTargetsInTabs()
      await refreshPendingTransaction()
      throw error
    }
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
      viewModel.connectionManager = connectionManager
      viewModel.applyWorkspaceConnectionConfig(workspace.connectionConfig)
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
    markDirtyAndScheduleAutoSave()

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
    markDirtyAndScheduleAutoSave()

    selectTab(id: tab.id)
    return tab.id
  }

  /// Restore the saved tabs in order. The first tab file the app may not read (no usable
  /// bookmark) asks once for the workspace folder; tabs still unreadable are skipped with a toast.
  /// Returns whether a tab bookmark changed (refreshed or newly created) and needs saving.
  private func restoreTabs(_ tabRefs: [WorkspaceTabReference]) async -> Bool {
    var bookmarksChanged = false
    var askedForFolder = folderAccess != nil
    var deniedFiles: [String] = []
    for tabRef in tabRefs {
      guard let fileURL = tabRef.fileURL else { continue }
      do {
        do {
          bookmarksChanged = try await restoreTab(tabRef: tabRef) || bookmarksChanged
        } catch let error where SecurityScopedAccess.isPermissionError(error) && !askedForFolder {
          askedForFolder = true
          guard await grantWorkspaceFolder() else { throw error }
          bookmarksChanged = try await restoreTab(tabRef: tabRef) || bookmarksChanged
        }
      } catch {
        // Log error but continue loading other tabs
        if SecurityScopedAccess.isPermissionError(error) {
          deniedFiles.append(fileURL.lastPathComponent)
        }
        await AppLogger.shared.warning(
          "Failed to restore tab: \(fileURL.lastPathComponent)",
          category: "Workspace"
        )
      }
    }
    if !deniedFiles.isEmpty {
      WorkspaceWindowManager.shared.showToast(
        "No access to \(deniedFiles.joined(separator: ", ")): tab not restored", type: .warning)
    }
    return bookmarksChanged
  }

  /// Ask once for the folder containing the .sqlws and hold access to it for the workspace
  private func grantWorkspaceFolder() async -> Bool {
    guard let workspaceURL = workspace.fileURL,
      let folder = await accessHooks.chooseFolder(workspaceURL)
    else { return false }
    folderAccess = accessHooks.startAccess(folder)
    folderBookmark = accessHooks.makeBookmark(folder)
    return true
  }

  /// Restore a tab from workspace with its original ID (used when loading from disk), reading
  /// through its bookmark. Returns whether its bookmark changed.
  private func restoreTab(tabRef: WorkspaceTabReference) async throws -> Bool {
    guard let savedURL = tabRef.fileURL else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let access = accessHooks.access(tabRef.bookmark)
    let fileURL = access?.isStale == true ? access?.url ?? savedURL : savedURL

    // Create tab with original ID from workspace
    var tab = tabRef.toTabItem()
    tab.fileURL = fileURL
    let data = try Data(contentsOf: fileURL)

    switch tabRef.documentType {
    case .notebook:
      var decodedNotebook = try DocumentCoder.decode(from: data)
      decodedNotebook.documentType = .notebook

      let document = SQLNotebookDocument(notebook: decodedNotebook)
      document.setFileURL(fileURL)

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
      document.setFileURL(fileURL)

      let cell = NotebookCell(cellType: .sql, content: content)
      let notebook = SQLNotebook(cells: [cell], documentType: .script)
      let viewModel = createViewModel(for: notebook)
      viewModel.viewMode = .editor
      viewModel.editorContent = content

      tabs.append(tab)
      viewModels[tab.id] = viewModel
      editorDocuments[tab.id] = document
    }
    tabAccess[tab.id] = access?.token
    let bookmark = access?.bookmark ?? accessHooks.makeBookmark(fileURL)
    tabBookmarks[tab.id] = bookmark
    return bookmark != tabRef.bookmark
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

    // Read through the file's stored bookmark; on a permission failure ask for the file
    var access = accessHooks.access(recents.documentBookmark(for: url))
    var url = access?.isStale == true ? access?.url ?? url : url
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error where SecurityScopedAccess.isPermissionError(error) {
      guard let chosen = await accessHooks.chooseFile(url) else { throw error }
      data = try Data(contentsOf: chosen)
      url = chosen
      access = nil
    }
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
    tabAccess[tab.id] = access?.token
    let bookmark = access?.bookmark ?? accessHooks.makeBookmark(url)
    tabBookmarks[tab.id] = bookmark

    markDirtyAndScheduleAutoSave()
    if selectTab {
      self.selectTab(id: tab.id)
    }

    // Add to recent documents (with the bookmark for the next reopen) and refresh the list
    recents.noteRecentDocument(url, bookmark: bookmark)
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

    // Share workspace's connection manager so ViewModels can execute queries
    viewModel.connectionManager = connectionManager
    // Protection level / Safe Mode come from the workspace connection config
    shareConnectionConfig(with: viewModel)
    attachTransactionHook(to: viewModel)

    return viewModel
  }

  func selectTab(id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    activeTabId = id
    workspace.activeTabId = id
    markDirtyAndScheduleAutoSave()

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
    markDirtyAndScheduleAutoSave()
  }

  func requestCloseTab(id: UUID) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    // The tab that opened a pending Protected transaction resolves it first
    guard !deferCloseTabForPendingTransaction(id: id) else { return }

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
    tabBookmarks.removeValue(forKey: id)
    tabAccess.removeValue(forKey: id)?.release()
    markDirtyAndScheduleAutoSave()
  }

  /// Stop accessing the workspace, its folder and its tab files (workspace closed)
  func releaseFileAccess() {
    for token in tabAccess.values { token.release() }
    tabAccess = [:]
    workspaceAccess?.release()
    workspaceAccess = nil
    folderAccess?.release()
    folderAccess = nil
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
      try SecurityScopedAccess.write(data, to: url)

    case .sqlFile:
      guard let document = editorDocuments[tabId],
        let viewModel = viewModels[tabId]
      else { return }
      document.content = viewModel.editorContent
      guard let data = viewModel.editorContent.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try SecurityScopedAccess.write(data, to: url)
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
    tabAccess.removeValue(forKey: tabId)?.release()
    tabBookmarks[tabId] = accessHooks.makeBookmark(url)
    if let bookmark = tabBookmarks[tabId] {
      recents.rememberDocumentBookmark(bookmark, for: url)
    }
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

  // MARK: - Schema Visualizer

  /// Toggle the schema visualizer visibility
  func toggleSchemaVisualizer() {
    isSchemaVisualizerActive.toggle()

    if isSchemaVisualizerActive {
      showSchemaVisualizer()
    } else {
      hideSchemaVisualizer()
    }
  }

  /// Show the schema visualizer
  func showSchemaVisualizer() {
    isSchemaVisualizerActive = true

    // Load graph if not already loaded
    if schemaGraph == nil {
      Task {
        await loadSchemaGraph()
      }
    }
  }

  /// Hide the schema visualizer
  func hideSchemaVisualizer() {
    isSchemaVisualizerActive = false
  }

  /// Load and calculate the schema graph layout
  func loadSchemaGraph() async {
    guard connectionState.isConnected else {
      schemaGraph = nil
      return
    }

    isLoadingSchemaGraph = true

    // Build graph from existing data
    let layoutEngine = SchemaLayoutEngine()

    // Calculate canvas size based on number of tables
    let tableCount = databaseTables.count
    let canvasWidth = max(800, CGFloat(tableCount) * 100)
    let canvasHeight = max(600, CGFloat(tableCount) * 80)
    let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

    // Calculate layout
    var graph = layoutEngine.calculateLayout(
      tables: databaseTables,
      foreignKeys: databaseForeignKeys,
      canvasSize: canvasSize
    )

    // Restore saved positions if available from local storage
    if let config = workspace.connectionConfig {
      let key = SchemaPositionsStore.connectionKey(from: config)
      let savedPositions = SchemaPositionsStore.loadPositions(forConnection: key)
      if !savedPositions.isEmpty {
        graph.applyPositions(savedPositions)
      }
    }

    schemaGraph = graph

    // Reset view state
    visualizerScale = 1.0
    visualizerOffset = .zero
    selectedGraphNodeId = nil

    isLoadingSchemaGraph = false
  }

  /// Save current schema node positions to local storage
  func saveSchemaNodePositions() {
    guard let graph = schemaGraph,
      let config = workspace.connectionConfig
    else { return }

    let key = SchemaPositionsStore.connectionKey(from: config)
    let positions = graph.exportPositions()
    SchemaPositionsStore.savePositions(positions, forConnection: key)
  }

  /// Reset schema layout to default (recalculate positions)
  func resetSchemaLayout() async {
    guard connectionState.isConnected else { return }

    isLoadingSchemaGraph = true

    // Clear saved positions from local storage
    if let config = workspace.connectionConfig {
      let key = SchemaPositionsStore.connectionKey(from: config)
      SchemaPositionsStore.clearPositions(forConnection: key)
    }

    // Recalculate layout
    let layoutEngine = SchemaLayoutEngine()
    let tableCount = databaseTables.count
    let canvasWidth = max(800, CGFloat(tableCount) * 100)
    let canvasHeight = max(600, CGFloat(tableCount) * 80)
    let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

    schemaGraph = layoutEngine.calculateLayout(
      tables: databaseTables,
      foreignKeys: databaseForeignKeys,
      canvasSize: canvasSize
    )

    // Reset view state but keep current zoom level
    visualizerOffset = .zero
    selectedGraphNodeId = nil

    isLoadingSchemaGraph = false
  }

  /// Refresh the schema graph
  func refreshSchemaGraph() async {
    // Reload schema data first
    await loadDatabaseSchema()
    // Then rebuild graph
    await loadSchemaGraph()
  }

  // MARK: - Schema Visualizer Controls

  /// Zoom in the visualizer
  func zoomInVisualizer() {
    visualizerScale = min(visualizerScale + 0.1, 3.0)
  }

  /// Zoom out the visualizer
  func zoomOutVisualizer() {
    visualizerScale = max(visualizerScale - 0.1, 0.3)
  }

  /// Reset visualizer view (zoom and offset)
  func resetVisualizerView() {
    visualizerScale = 1.0
    visualizerOffset = .zero
  }

  /// Export schema as PNG image
  func exportSchemaAsImage() {
    guard let nsView = schemaGraphNSView else {
      Task { @MainActor in
        await AppLogger.shared.warning(
          "Cannot export: Schema view not available",
          category: "SchemaVisualizer"
        )
      }
      return
    }

    // Create save panel
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.png]
    savePanel.nameFieldStringValue = "schema_diagram.png"
    savePanel.title = "Export Schema Diagram"
    savePanel.message = "Choose a location to save the schema diagram"

    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }

      // Capture image from NSView using bitmapImageRepForCachingDisplay
      Task { @MainActor in
        let bounds = nsView.bounds
        guard
          let bitmapRep = nsView.bitmapImageRepForCachingDisplay(in: bounds)
        else {
          await AppLogger.shared.error(
            "Failed to create bitmap representation",
            category: "SchemaVisualizer"
          )
          return
        }

        nsView.cacheDisplay(in: bounds, to: bitmapRep)

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
          do {
            try pngData.write(to: url)
            await AppLogger.shared.info(
              "Schema diagram exported to \(url.path)",
              category: "SchemaVisualizer"
            )
          } catch {
            await AppLogger.shared.error(
              "Failed to export schema: \(error)",
              category: "SchemaVisualizer"
            )
          }
        }
      }
    }
  }
}

// MARK: - Preview Support

extension WorkspaceManager {
  /// Create a WorkspaceManager instance for SwiftUI previews
  static func preview(
    isSchemaVisualizerActive: Bool = true,
    isConnected: Bool = true
  ) -> WorkspaceManager {
    let manager = WorkspaceManager(workspace: Workspace())
    manager.isSchemaVisualizerActive = isSchemaVisualizerActive

    if isConnected {
      manager.connectionState = .connected
      // Add sample tables for preview
      manager.databaseTables = [
        DatabaseTable(
          schema: "public", name: "users",
          columns: [
            DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true),
            DatabaseColumn(name: "name", type: "varchar"),
            DatabaseColumn(name: "email", type: "varchar"),
          ]),
        DatabaseTable(
          schema: "public", name: "posts",
          columns: [
            DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true),
            DatabaseColumn(name: "user_id", type: "integer"),
            DatabaseColumn(name: "title", type: "varchar"),
          ]),
      ]
    }

    return manager
  }
}
