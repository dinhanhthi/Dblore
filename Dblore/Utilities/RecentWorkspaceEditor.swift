//
//  RecentWorkspaceEditor.swift
//  Dblore
//

import Foundation

/// Failure while editing a recent workspace from the welcome screen.
enum RecentWorkspaceEditError: LocalizedError, Equatable {
  case emptyName
  case destinationExists
  case unreadable

  var errorDescription: String? {
    switch self {
    case .emptyName:
      "Workspace name is required"
    case .destinationExists:
      "A file already exists at that location"
    case .unreadable:
      "Could not read the workspace file"
    }
  }
}

/// Rewrites a recent workspace's display name and, when asked, moves its .sqlws file.
@MainActor
enum RecentWorkspaceEditor {
  /// Apply `name` and `destination` to `entry`.
  /// An open workspace is written from memory so unsaved tabs are kept.
  /// A closed workspace is read from disk and only its name changes.
  static func apply(
    entry: WorkspaceHistoryEntry,
    name: String,
    destination: URL,
    recents: RecentManager,
    openWorkspaces: [WorkspaceManager]
  ) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RecentWorkspaceEditError.emptyName }

    if let manager = openWorkspace(matching: entry, in: openWorkspaces) {
      try applyOpen(
        manager, entry: entry, name: trimmed, destination: destination, recents: recents)
      return
    }
    try applyClosed(entry: entry, name: trimmed, destination: destination, recents: recents)
  }

  /// Replace the workspace name inside encoded .sqlws JSON.
  static func renamedData(_ data: Data, name: String) throws -> Data {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var workspace = try decoder.decode(Workspace.self, from: data)
    workspace.name = name
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(workspace)
  }

  /// Write `data` to `destination`. The same file is rewritten in place.
  /// A different existing file is left untouched.
  static func commitFile(data: Data, from source: URL, to destination: URL) throws {
    if sameFile(source, destination) {
      try SecurityScopedAccess.write(data, to: destination)
      return
    }
    if FileManager.default.fileExists(atPath: destination.standardizedFileURL.path) {
      throw RecentWorkspaceEditError.destinationExists
    }
    try SecurityScopedAccess.write(data, to: destination)
    do {
      try FileManager.default.removeItem(at: source)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  /// True when both URLs name the same file, including a case-insensitive path.
  static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    let left = lhs.standardizedFileURL
    let right = rhs.standardizedFileURL
    if left == right { return true }
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    guard
      let leftID = try? left.resourceValues(forKeys: keys).fileResourceIdentifier,
      let rightID = try? right.resourceValues(forKeys: keys).fileResourceIdentifier
    else { return false }
    return (leftID as AnyObject).isEqual(rightID)
  }

  private static func openWorkspace(
    matching entry: WorkspaceHistoryEntry, in managers: [WorkspaceManager]
  ) -> WorkspaceManager? {
    let entryURL = entry.fileURL.standardizedFileURL
    return managers.first { manager in
      if let url = manager.workspace.fileURL {
        return url.standardizedFileURL == entryURL
      }
      return manager.workspace.id == entry.id
    }
  }

  private static func applyOpen(
    _ manager: WorkspaceManager,
    entry: WorkspaceHistoryEntry,
    name: String,
    destination: URL,
    recents: RecentManager
  ) throws {
    manager.autoSaveTask?.cancel()
    manager.workspace.name = name
    let data = try manager.encodedWorkspaceData()
    let source = manager.workspace.fileURL ?? entry.fileURL
    try commitFile(data: data, from: source, to: destination)
    manager.workspace.fileURL = destination
    manager.isDirty = false
    manager.workspaceBookmarkURL = destination
    manager.workspaceBookmark = manager.accessHooks.makeBookmark(destination)
    let bookmark =
      manager.workspaceBookmark ?? (sameFile(source, destination) ? entry.bookmark : nil)
    recents.replaceWorkspace(
      id: entry.id, with: entry.edited(name: name, fileURL: destination, bookmark: bookmark))
  }

  private static func applyClosed(
    entry: WorkspaceHistoryEntry,
    name: String,
    destination: URL,
    recents: RecentManager
  ) throws {
    let loaded = try loadFile(entry)
    defer { loaded.token?.release() }
    let renamed: Data
    do {
      renamed = try renamedData(loaded.data, name: name)
    } catch {
      throw RecentWorkspaceEditError.unreadable
    }
    try commitFile(data: renamed, from: loaded.url, to: destination)
    let bookmark =
      SecurityScopedAccess.bookmarkIfPossible(for: destination)
      ?? (sameFile(loaded.url, destination) ? entry.bookmark : nil)
    recents.replaceWorkspace(
      id: entry.id, with: entry.edited(name: name, fileURL: destination, bookmark: bookmark))
  }

  private static func loadFile(
    _ entry: WorkspaceHistoryEntry
  ) throws -> (
    url: URL, data: Data, token: SecurityScopedAccessToken?
  ) {
    if let bookmark = entry.bookmark {
      if let resolved = try? SecurityScopedAccess.resolve(bookmark) {
        let token = SecurityScopedAccessToken(url: resolved.url)
        if let data = try? Data(contentsOf: resolved.url) {
          return (resolved.url, data, token)
        }
        token.release()
      }
    }
    do {
      let data = try Data(contentsOf: entry.fileURL)
      return (entry.fileURL, data, nil)
    } catch {
      throw RecentWorkspaceEditError.unreadable
    }
  }
}
