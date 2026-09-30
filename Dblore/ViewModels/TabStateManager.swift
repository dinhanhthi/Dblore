//
//  TabStateManager.swift
//  Dblore
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Legacy tab manager - now superseded by WorkspaceManager
/// Each workspace has its own tab management via WorkspaceManager
/// This class is kept for backward compatibility with some legacy views
/// but the singleton pattern has been removed
@MainActor
@Observable
class TabStateManager {
  // MARK: - Public State

  /// All open tabs
  var tabs: [TabItem] = []

  /// Currently active tab ID
  var activeTabId: UUID?

  /// Whether close confirmation dialog is showing
  var showingCloseConfirmation = false

  /// Tab being closed (for confirmation dialog)
  var tabToClose: UUID?

  // MARK: - Internal Storage

  /// ViewModels for each tab (kept alive while tab exists)
  private var viewModels: [UUID: NotebookViewModel] = [:]

  /// Documents for each tab
  private var notebookDocuments: [UUID: DbloreDocument] = [:]
  private var editorDocuments: [UUID: SQLEditorDocument] = [:]

  // MARK: - Persistence Keys

  private nonisolated static let sessionKey = "Dblore.TabSession"

  // MARK: - Computed Properties

  /// Currently active tab
  var activeTab: TabItem? {
    guard let id = activeTabId else { return nil }
    return tabs.first { $0.id == id }
  }

  /// ViewModel for the active tab
  var activeViewModel: NotebookViewModel? {
    guard let id = activeTabId else { return nil }
    return viewModels[id]
  }

  /// Document mode for the active tab
  var activeDocumentMode: DocumentMode? {
    guard let tab = activeTab else { return nil }
    return tab.documentType == .notebook ? .notebook : .editor
  }

  // MARK: - Tab Access

  /// Get ViewModel for a specific tab
  func viewModel(for tabId: UUID) -> NotebookViewModel? {
    viewModels[tabId]
  }

  /// Get notebook document for a specific tab
  func notebookDocument(for tabId: UUID) -> DbloreDocument? {
    notebookDocuments[tabId]
  }

  /// Get editor document for a specific tab
  func editorDocument(for tabId: UUID) -> SQLEditorDocument? {
    editorDocuments[tabId]
  }

  // MARK: - Tab Operations

  /// Create a new notebook tab
  @discardableResult
  func newNotebook() -> UUID {
    let document = DbloreDocument()
    let viewModel = NotebookViewModel(notebook: document.notebook)
    viewModel.viewMode = .notebook

    let tab = TabItem.newNotebook()

    tabs.append(tab)
    viewModels[tab.id] = viewModel
    notebookDocuments[tab.id] = document

    selectTab(id: tab.id)
    return tab.id
  }

  /// Create a new SQL file tab
  @discardableResult
  func newSQLFile() -> UUID {
    let document = SQLEditorDocument()
    let cell = NotebookCell(cellType: .sql, content: "")
    let notebook = DbloreNotebook(cells: [cell], documentType: .script)
    let viewModel = NotebookViewModel(notebook: notebook)
    viewModel.viewMode = .editor
    viewModel.editorContent = ""

    let tab = TabItem.newSQLFile()

    tabs.append(tab)
    viewModels[tab.id] = viewModel
    editorDocuments[tab.id] = document

    selectTab(id: tab.id)
    return tab.id
  }

  /// Open a file in a new tab or activate existing tab
  func openFile(url: URL) async throws {
    // Check if already open
    if let existingTab = tabs.first(where: { $0.fileURL == url }) {
      selectTab(id: existingTab.id)
      return
    }

    // Detect file type
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
      // Decode notebook from JSON data
      var decodedNotebook = try DocumentCoder.decode(from: data)
      decodedNotebook.documentType = .notebook

      let document = DbloreDocument(notebook: decodedNotebook)
      document.setFileURL(url)

      let viewModel = NotebookViewModel(notebook: document.notebook)
      viewModel.viewMode = .notebook

      tabs.append(tab)
      viewModels[tab.id] = viewModel
      notebookDocuments[tab.id] = document

    case .sqlFile:
      // Read SQL content as string
      guard let content = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadCorruptFile)
      }

      let document = SQLEditorDocument(content: content)
      document.setFileURL(url)

      let cell = NotebookCell(cellType: .sql, content: content)
      let notebook = DbloreNotebook(cells: [cell], documentType: .script)
      let viewModel = NotebookViewModel(notebook: notebook)
      viewModel.viewMode = .editor
      viewModel.editorContent = content

      tabs.append(tab)
      viewModels[tab.id] = viewModel
      editorDocuments[tab.id] = document

    case .dataViewer:
      return  // Never detected from a file URL
    }

    selectTab(id: tab.id)
  }

  /// Select a tab
  func selectTab(id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    activeTabId = id

    // Update last accessed time
    if let index = tabs.firstIndex(where: { $0.id == id }) {
      tabs[index].lastAccessed = Date()
    }
  }

  /// Move tab from one position to another
  func moveTab(from: Int, to: Int) {
    guard from != to,
      from >= 0, from < tabs.count,
      to >= 0, to < tabs.count
    else { return }

    let tab = tabs.remove(at: from)
    tabs.insert(tab, at: to)
  }

  /// Request to close a tab (may show confirmation if dirty)
  func requestCloseTab(id: UUID) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }

    if tab.isDirty {
      tabToClose = id
      showingCloseConfirmation = true
    } else {
      closeTabImmediately(id: id)
    }
  }

  /// Close tab without saving
  func closeTabWithoutSaving() {
    guard let id = tabToClose else { return }
    closeTabImmediately(id: id)
    tabToClose = nil
    showingCloseConfirmation = false
  }

  /// Save and close tab
  func saveAndCloseTab() async {
    guard let id = tabToClose else { return }
    do {
      try await saveTab(id: id)
      closeTabImmediately(id: id)
    } catch {
      // If save fails, keep tab open
      print("Failed to save tab: \(error)")
    }
    tabToClose = nil
    showingCloseConfirmation = false
  }

  /// Cancel close operation
  func cancelClose() {
    tabToClose = nil
    showingCloseConfirmation = false
  }

  /// Close tab immediately (internal)
  private func closeTabImmediately(id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

    // If closing active tab, select adjacent
    if activeTabId == id {
      if tabs.count > 1 {
        let newIndex = index > 0 ? index - 1 : 1
        activeTabId = tabs[newIndex].id
      } else {
        activeTabId = nil
      }
    }

    // Note: Connection is now managed at workspace level (WorkspaceManager)
    // No need to disconnect per-tab connections

    // Remove tab and clean up
    tabs.remove(at: index)
    viewModels.removeValue(forKey: id)
    notebookDocuments.removeValue(forKey: id)
    editorDocuments.removeValue(forKey: id)
  }

  /// Mark tab as dirty
  func markDirty(tabId: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    tabs[index].isDirty = true
  }

  /// Mark tab as clean
  func markClean(tabId: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    tabs[index].isDirty = false
  }

  // MARK: - Save Operations

  /// Save a tab's document
  func saveTab(id: UUID) async throws {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }

    if let url = tab.fileURL {
      try await saveToURL(tabId: id, url: url)
    } else {
      try await saveWithPanel(tabId: id)
    }
  }

  /// Save to a specific URL
  private func saveToURL(tabId: UUID, url: URL) async throws {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

    switch tab.documentType {
    case .notebook:
      guard let document = notebookDocuments[tabId],
        let viewModel = viewModels[tabId]
      else { return }
      // Sync notebook from viewModel to document
      document.notebook = viewModel.notebook
      // Encode and save directly
      let includeResults = AppSettings.getIncludeResultsOnSave()
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
      // Sync content from viewModel to document
      document.content = viewModel.editorContent
      // Save as UTF-8 text
      guard let data = viewModel.editorContent.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
      }
      try SecurityScopedAccess.write(data, to: url)

    case .dataViewer:
      return  // Data viewer tabs have no file
    }

    markClean(tabId: tabId)
  }

  /// Show save panel and save
  private func saveWithPanel(tabId: UUID) async throws {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = tab.title

    switch tab.documentType {
    case .notebook:
      panel.allowedContentTypes = [.dblore]
      panel.nameFieldStringValue += ".dblore"
    case .sqlFile:
      panel.allowedContentTypes = [.sql]
      panel.nameFieldStringValue += ".sql"
    case .dataViewer:
      return  // Data viewer tabs have no file
    }

    let response = await panel.beginSheetModal(for: NSApp.keyWindow!)

    guard response == .OK, let url = panel.url else {
      throw CocoaError(.userCancelled)
    }

    // Update tab with new URL and title
    if let index = tabs.firstIndex(where: { $0.id == tabId }) {
      tabs[index].fileURL = url
      tabs[index].title = url.lastPathComponent
    }

    // Set file URL on document
    if tab.documentType == .notebook {
      notebookDocuments[tabId]?.setFileURL(url)
    } else {
      editorDocuments[tabId]?.setFileURL(url)
    }

    try await saveToURL(tabId: tabId, url: url)
  }

  // MARK: - Tab Navigation

  /// Select next tab
  func selectNextTab() {
    guard let currentId = activeTabId,
      let currentIndex = tabs.firstIndex(where: { $0.id == currentId })
    else { return }

    let nextIndex = (currentIndex + 1) % tabs.count
    selectTab(id: tabs[nextIndex].id)
  }

  /// Select previous tab
  func selectPreviousTab() {
    guard let currentId = activeTabId,
      let currentIndex = tabs.firstIndex(where: { $0.id == currentId })
    else { return }

    let prevIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
    selectTab(id: tabs[prevIndex].id)
  }

  /// Show open panel for notebook files
  func openNotebookWithPanel() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.dblore]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a notebook file to open"

    let response = await panel.beginSheetModal(for: NSApp.keyWindow!)

    if response == .OK, let url = panel.url {
      do {
        try await openFile(url: url)
      } catch {
        print("Failed to open notebook: \(error)")
      }
    }
  }

  /// Show open panel for SQL files
  func openSQLFileWithPanel() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.sql]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Select a SQL file to open"

    let response = await panel.beginSheetModal(for: NSApp.keyWindow!)

    if response == .OK, let url = panel.url {
      do {
        try await openFile(url: url)
      } catch {
        print("Failed to open SQL file: \(error)")
      }
    }
  }

  /// Select tab by index (1-based for keyboard shortcuts)
  func selectTab(atIndex index: Int) {
    guard index > 0, index <= tabs.count else { return }
    selectTab(id: tabs[index - 1].id)
  }

  // MARK: - State Persistence

  /// Save current tab state to UserDefaults
  func saveState() {
    let state = TabSessionState(
      tabs: tabs,
      activeTabId: activeTabId
    )

    if let data = try? JSONEncoder().encode(state) {
      UserDefaults.standard.set(data, forKey: Self.sessionKey)
    }
  }

  /// Restore tab state from UserDefaults
  func restoreState() async {
    guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
      let state = try? JSONDecoder().decode(TabSessionState.self, from: data)
    else { return }

    // Reopen tabs with valid file URLs
    for tab in state.tabs {
      if let url = tab.fileURL, FileManager.default.fileExists(atPath: url.path) {
        do {
          try await openFile(url: url)
        } catch {
          print("Failed to restore tab for \(url.lastPathComponent): \(error)")
        }
      }
    }

    // Restore active tab
    if let activeId = state.activeTabId,
      tabs.contains(where: { $0.id == activeId })
    {
      selectTab(id: activeId)
    }
  }

  /// Clear saved state
  func clearSavedState() {
    UserDefaults.standard.removeObject(forKey: Self.sessionKey)
  }

  nonisolated static func storedSession(defaults: UserDefaults, domainName: String) -> Data? {
    defaults.persistentDomain(forName: domainName)?[sessionKey] as? Data
  }

  nonisolated static func exportSnapshot(defaults: UserDefaults, domainName: String) -> Data? {
    storedSession(defaults: defaults, domainName: domainName)
  }

  nonisolated static func replace(_ data: Data?, defaults: UserDefaults, domainName: String) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    if let data {
      domain[sessionKey] = data
    } else {
      domain.removeValue(forKey: sessionKey)
    }
    defaults.setPersistentDomain(domain, forName: domainName)
  }

  nonisolated static func clearAll(defaults: UserDefaults, domainName: String) {
    replace(nil, defaults: defaults, domainName: domainName)
  }
}

// MARK: - Session State for Persistence

struct TabSessionState: Codable {
  var tabs: [TabItem]
  var activeTabId: UUID?
}
