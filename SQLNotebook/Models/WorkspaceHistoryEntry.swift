//
//  WorkspaceHistoryEntry.swift
//  SQLNotebook
//

import Foundation

/// Entry for recent workspaces list
struct WorkspaceHistoryEntry: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let fileURL: URL
  let name: String
  let connectionDisplayString: String?
  let lastOpenedAt: Date
  let tabCount: Int

  init(
    id: UUID = UUID(),
    fileURL: URL,
    name: String,
    connectionDisplayString: String? = nil,
    lastOpenedAt: Date = Date(),
    tabCount: Int = 0
  ) {
    self.id = id
    self.fileURL = fileURL
    self.name = name
    self.connectionDisplayString = connectionDisplayString
    self.lastOpenedAt = lastOpenedAt
    self.tabCount = tabCount
  }

  /// Display string for the welcome screen
  /// Format: "My Project (mydb@localhost:5432)" or just "My Project" if no connection
  var displayString: String {
    if let conn = connectionDisplayString {
      return "\(name) (\(conn))"
    }
    return name
  }

  /// Short display name (just the workspace name)
  var shortDisplayName: String {
    name
  }

  /// Formatted last opened date
  var formattedLastOpened: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: lastOpenedAt, relativeTo: Date())
  }

  /// Create from a Workspace
  static func from(_ workspace: Workspace) -> WorkspaceHistoryEntry? {
    guard let fileURL = workspace.fileURL else { return nil }
    return WorkspaceHistoryEntry(
      id: workspace.id,
      fileURL: fileURL,
      name: workspace.name,
      connectionDisplayString: workspace.connectionConfig?.displayString,
      lastOpenedAt: workspace.lastOpenedAt,
      tabCount: workspace.tabs.count
    )
  }
}
