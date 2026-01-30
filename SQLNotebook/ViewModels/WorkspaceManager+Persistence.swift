//
//  WorkspaceManager+Persistence.swift
//  SQLNotebook
//

import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Workspace Persistence

extension WorkspaceManager {
  /// Save workspace to its file URL
  func saveWorkspace() async throws {
    if let url = workspace.fileURL {
      try await saveWorkspaceToURL(url)
    } else {
      try await saveWorkspaceWithPanel()
    }
  }

  /// Save workspace to a specific URL
  func saveWorkspaceAs(url: URL) async throws {
    try await saveWorkspaceToURL(url)
  }

  /// Save workspace with file panel
  func saveWorkspaceWithPanel() async throws {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.sqlWorkspace]
    panel.nameFieldStringValue = workspace.name
    if !workspace.name.hasSuffix(".sqlws") {
      panel.nameFieldStringValue += ".sqlws"
    }

    guard let window = NSApp.keyWindow else {
      throw CocoaError(.fileNoSuchFile)
    }

    let response = await panel.beginSheetModal(for: window)

    guard response == .OK, let url = panel.url else {
      throw CocoaError(.userCancelled)
    }

    try await saveWorkspaceToURL(url)
  }

  private func saveWorkspaceToURL(_ url: URL) async throws {
    // Update workspace with current state
    workspace.fileURL = url
    workspace.name = url.deletingPathExtension().lastPathComponent
    workspace.tabs = tabs.map { WorkspaceTabReference.from($0) }
    workspace.activeTabId = activeTabId
    workspace.lastOpenedAt = Date()

    // Encode and save
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(workspace)
    try data.write(to: url, options: .atomic)

    isDirty = false

    // Add to recent workspaces
    if let entry = WorkspaceHistoryEntry.from(workspace) {
      RecentManager.shared.addWorkspace(entry)
    }
  }

  /// Check if workspace has unsaved changes
  var hasUnsavedChanges: Bool {
    if isDirty { return true }
    return tabs.contains { $0.isDirty }
  }

  /// Check if workspace can be closed (prompt for unsaved changes)
  func canClose() async -> Bool {
    guard hasUnsavedChanges else { return true }

    // Show alert for unsaved changes
    guard let window = NSApp.keyWindow else { return true }

    let alert = NSAlert()
    alert.messageText = "Do you want to save changes to workspace \"\(workspace.name)\"?"
    alert.informativeText = "Your changes will be lost if you don't save them."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don't Save")
    alert.addButton(withTitle: "Cancel")

    let response = await alert.beginSheetModal(for: window)

    switch response {
    case .alertFirstButtonReturn:
      // Save
      do {
        try await saveWorkspace()
        return true
      } catch {
        if (error as? CocoaError)?.code == .userCancelled {
          return false
        }
        await AppLogger.shared.error("Failed to save workspace: \(error)", category: "Workspace")
        return false
      }
    case .alertSecondButtonReturn:
      // Don't save
      return true
    default:
      // Cancel
      return false
    }
  }
}

// MARK: - Schema Loading

extension WorkspaceManager {
  /// Load database schema
  func loadDatabaseSchema() async {
    guard connectionState == .connected else { return }
    isLoadingSchema = true

    do {
      async let tablesTask = connectionManager.fetchTables()
      async let viewsTask = connectionManager.fetchViews()
      async let functionsTask = connectionManager.fetchFunctions()
      async let proceduresTask = connectionManager.fetchProcedures()
      async let usersTask = connectionManager.fetchUsers()
      async let rolesTask = connectionManager.fetchRoles()
      async let foreignKeysTask = connectionManager.fetchForeignKeys()

      let (tables, views, functions, procedures, users, roles, foreignKeys) = try await (
        tablesTask, viewsTask, functionsTask, proceduresTask, usersTask, rolesTask, foreignKeysTask
      )

      databaseTables = tables
      databaseViews = views
      databaseFunctions = functions
      databaseProcedures = procedures
      databaseUsers = users
      databaseRoles = roles
      databaseForeignKeys = foreignKeys

      // Sync to tab ViewModels
      syncConnectionStateToTabs()
    } catch {
      await AppLogger.shared.error("Failed to load schema: \(error)", category: "Schema")
    }

    isLoadingSchema = false
  }

  /// Refresh database schema
  func refreshDatabaseSchema() async {
    await loadDatabaseSchema()
    await autocompleteProvider.refreshSchema()
  }

  /// Toggle left sidebar visibility
  func toggleLeftSidebar() {
    isLeftSidebarVisible.toggle()
    workspace.settings.isLeftSidebarVisible = isLeftSidebarVisible
    isDirty = true
  }

  /// Toggle expand/collapse all entities
  func toggleExpandCollapseAll() {
    areAllEntitiesExpanded.toggle()
  }

  /// Show right sidebar with content
  func showRightSidebar(content: SidebarContent) {
    rightSidebarContent = content
    isRightSidebarVisible = true
  }

  /// Hide right sidebar
  func hideRightSidebar() {
    isRightSidebarVisible = false
    rightSidebarContent = nil
  }

  /// Toggle right sidebar
  func toggleRightSidebar() {
    isRightSidebarVisible.toggle()
  }

  /// Show connection form in right sidebar
  func showConnectionForm() {
    showRightSidebar(content: .connectionForm)
  }

  /// Show settings in right sidebar
  func showSettings() {
    showRightSidebar(content: .settings)
  }
}

// MARK: - UTType Extension

extension UTType {
  static let sqlWorkspace = UTType(exportedAs: "com.sqlnotebook.workspace", conformingTo: .json)
}
