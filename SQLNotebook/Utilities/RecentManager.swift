//
//  RecentManager.swift
//  SQLNotebook
//

import Foundation

/// Manages recent workspaces and connections for the welcome screen.
/// Separate from SessionManager which handles connection history for the connection form.
@MainActor
@Observable
class RecentManager {
  // MARK: - Shared Instance

  static let shared = RecentManager()

  // MARK: - Storage Keys

  private nonisolated static let workspacesKey = "com.sqlnotebook.recentWorkspaces"
  private nonisolated static let maxWorkspaces = 6

  // MARK: - State

  var recentWorkspaces: [WorkspaceHistoryEntry] = []

  /// Recent connections (delegated to SessionManager)
  var recentConnections: [ConnectionHistoryEntry] {
    SessionManager.loadHistory()
  }

  // MARK: - Initialization

  private init() {
    loadWorkspaces()
  }

  // MARK: - Workspace Management

  /// Add a workspace to recent list
  func addWorkspace(_ entry: WorkspaceHistoryEntry) {
    // Remove if already exists (will re-add at top)
    recentWorkspaces.removeAll { $0.fileURL == entry.fileURL }

    // Add at beginning
    recentWorkspaces.insert(entry, at: 0)

    // Trim to max
    if recentWorkspaces.count > Self.maxWorkspaces {
      recentWorkspaces = Array(recentWorkspaces.prefix(Self.maxWorkspaces))
    }

    saveWorkspaces()
  }

  /// Add a workspace from Workspace model
  func addWorkspace(_ workspace: Workspace) {
    guard let entry = WorkspaceHistoryEntry.from(workspace) else { return }
    addWorkspace(entry)
  }

  /// Remove a workspace from recent list
  func removeWorkspace(id: UUID) {
    recentWorkspaces.removeAll { $0.id == id }
    saveWorkspaces()
  }

  /// Remove workspace by file URL
  func removeWorkspace(url: URL) {
    recentWorkspaces.removeAll { $0.fileURL == url }
    saveWorkspaces()
  }

  /// Clear all recent workspaces
  func clearWorkspaces() {
    recentWorkspaces = []
    UserDefaults.standard.removeObject(forKey: Self.workspacesKey)
  }

  /// Clear all (workspaces + connections)
  func clearAll() {
    clearWorkspaces()
    SessionManager.clearAllHistory()
  }

  // MARK: - Connection Management (Delegated to SessionManager)

  /// Add a connection to recent list
  func addConnection(_ config: ConnectionConfig) {
    SessionManager.saveConnection(config)
  }

  /// Remove a connection from recent list
  func removeConnection(id: UUID) {
    SessionManager.removeConnection(id: id)
  }

  /// Clear all recent connections
  func clearConnections() {
    SessionManager.clearAllHistory()
  }

  // MARK: - Persistence

  private func loadWorkspaces() {
    guard let data = UserDefaults.standard.data(forKey: Self.workspacesKey),
      let entries = try? JSONDecoder().decode([WorkspaceHistoryEntry].self, from: data)
    else {
      recentWorkspaces = []
      return
    }

    // Filter out workspaces whose files no longer exist
    recentWorkspaces = entries.filter { entry in
      FileManager.default.fileExists(atPath: entry.fileURL.path)
    }

    // If we filtered any out, save the cleaned list
    if recentWorkspaces.count != entries.count {
      saveWorkspaces()
    }
  }

  private func saveWorkspaces() {
    guard let data = try? JSONEncoder().encode(recentWorkspaces) else { return }
    UserDefaults.standard.set(data, forKey: Self.workspacesKey)
  }

  // MARK: - Computed Properties

  /// Whether there are any recent items (workspaces or connections)
  var hasRecentItems: Bool {
    !recentWorkspaces.isEmpty || !recentConnections.isEmpty
  }

  /// Whether there are only workspaces (no connections)
  var hasOnlyWorkspaces: Bool {
    !recentWorkspaces.isEmpty && recentConnections.isEmpty
  }

  /// Whether there are only connections (no workspaces)
  var hasOnlyConnections: Bool {
    recentWorkspaces.isEmpty && !recentConnections.isEmpty
  }

  /// Whether both lists have items
  var hasBothLists: Bool {
    !recentWorkspaces.isEmpty && !recentConnections.isEmpty
  }
}
