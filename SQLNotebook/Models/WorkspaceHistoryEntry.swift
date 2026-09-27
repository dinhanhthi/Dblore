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
  /// App-scope security-scoped bookmark of the .sqlws file (nil in entries saved before bookmarks)
  var bookmark: Data?
  /// Bookmark of the folder containing the .sqlws, re-granting its bookmark-less tab files
  var folderBookmark: Data?

  init(
    id: UUID = UUID(),
    fileURL: URL,
    name: String,
    connectionDisplayString: String? = nil,
    lastOpenedAt: Date = Date(),
    tabCount: Int = 0,
    bookmark: Data? = nil
  ) {
    self.id = id
    self.fileURL = fileURL
    self.name = name
    self.connectionDisplayString = connectionDisplayString
    self.lastOpenedAt = lastOpenedAt
    self.tabCount = tabCount
    self.bookmark = bookmark
  }

  /// Bookmark bytes differ between creations of the same file, so equality ignores them
  static func == (lhs: WorkspaceHistoryEntry, rhs: WorkspaceHistoryEntry) -> Bool {
    lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.name == rhs.name
      && lhs.connectionDisplayString == rhs.connectionDisplayString
      && lhs.lastOpenedAt == rhs.lastOpenedAt && lhs.tabCount == rhs.tabCount
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
  static func from(_ workspace: Workspace, bookmark: Data? = nil) -> WorkspaceHistoryEntry? {
    guard let fileURL = workspace.fileURL else { return nil }
    return WorkspaceHistoryEntry(
      id: workspace.id,
      fileURL: fileURL,
      name: workspace.name,
      connectionDisplayString: workspace.connectionConfig?.displayString,
      lastOpenedAt: workspace.lastOpenedAt,
      tabCount: workspace.tabs.count,
      bookmark: bookmark
    )
  }
}
