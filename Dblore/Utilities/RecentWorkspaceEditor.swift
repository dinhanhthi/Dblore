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
  /// Apply `name`, `destination` and the welcome row's `iconColor` to `entry`.
  /// An open workspace is written from memory so unsaved tabs are kept; an open one that was
  /// relocked asks `unlock` first, as its window's cover does.
  /// A closed workspace is read from disk and only its name changes; a locked one asks
  /// `unlock` first.
  static func apply(
    entry: WorkspaceHistoryEntry,
    name: String,
    destination: URL,
    iconColor: AccentColor?,
    recents: RecentManager,
    openWorkspaces: [WorkspaceManager],
    io: LockedFileIO = .shared,
    unlock: LockedFileIO.Unlock = LockedFileIO.keychainUnlock(reason: "rename a locked workspace")
  ) async throws {
    var entry = entry
    entry.iconColor = iconColor
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RecentWorkspaceEditError.emptyName }

    if let manager = openWorkspace(matching: entry, in: openWorkspaces) {
      try await unlockIfRelocked(manager, unlock: unlock)
      try await applyOpen(
        manager, entry: entry, name: trimmed, destination: destination, recents: recents)
      return
    }
    try await applyClosed(
      entry: entry, name: trimmed, destination: destination, recents: recents, io: io,
      unlock: unlock)
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

  /// `renamedData` of a .sqlws file's bytes that may be sealed: an envelope is opened through
  /// `io` off the main actor (asking `unlock` when its workspace is not open). Returns plaintext
  /// JSON and the session that opened it; it never seals (only `commitFile` writes).
  static func renamedData(
    _ data: Data, name: String, io: LockedFileIO, unlock: LockedFileIO.Unlock
  ) async throws -> LockedFileIO.Read {
    let opened = try await io.open(data, unlock: unlock)
    return LockedFileIO.Read(
      plaintext: try renamedData(opened.plaintext, name: name), session: opened.session)
  }

  /// Write the plaintext .sqlws `data` to `destination` through `io`, sealed when `lockKeyId` is
  /// set (its session must be open). The same file is rewritten in place.
  /// A different existing file is left untouched.
  static func commitFile(
    data: Data, from source: URL, to destination: URL, lockKeyId: UUID? = nil,
    io: LockedFileIO = .shared
  ) async throws {
    if sameFile(source, destination) {
      try await io.write(data, kind: .workspace, lockKeyId: lockKeyId, to: destination)
      return
    }
    if FileManager.default.fileExists(atPath: destination.standardizedFileURL.path) {
      throw RecentWorkspaceEditError.destinationExists
    }
    try await io.write(data, kind: .workspace, lockKeyId: lockKeyId, to: destination)
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

  /// An open locked workspace that was relocked is unlocked through `unlock` (against its own
  /// open session) before anything changes; cancel throws `unlockRefused` with nothing written
  private static func unlockIfRelocked(
    _ manager: WorkspaceManager, unlock: LockedFileIO.Unlock
  ) async throws {
    let registry = manager.lockedIO.registry
    guard let id = manager.lockKeyId, registry.isBlocked(.workspace(id)) else { return }
    guard let session = manager.lockedIO.sessions.session(for: id),
      let unlocked = await unlock(session.header), unlocked.workspaceId == id,
      !registry.isBlocked(.workspace(id))
    else { throw LockedFileIOError.unlockRefused(id) }
  }

  private static func applyOpen(
    _ manager: WorkspaceManager,
    entry: WorkspaceHistoryEntry,
    name: String,
    destination: URL,
    recents: RecentManager
  ) async throws {
    manager.autoSaveTask?.cancel()
    manager.workspace.name = name
    let data = try manager.encodedWorkspaceData()
    let source = manager.workspace.fileURL ?? entry.fileURL
    // The open workspace holds its session: sealed with its key when it is locked
    try await commitFile(
      data: data, from: source, to: destination, lockKeyId: manager.lockKeyId,
      io: manager.lockedIO)
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
    recents: RecentManager,
    io: LockedFileIO,
    unlock: LockedFileIO.Unlock
  ) async throws {
    let loaded = try await loadFile(entry)
    defer { loaded.token?.release() }
    let renamed: LockedFileIO.Read
    do {
      renamed = try await renamedData(loaded.data, name: name, io: io, unlock: unlock)
    } catch let error as LockedFileIOError {
      throw error
    } catch {
      throw RecentWorkspaceEditError.unreadable
    }
    // The session that opened a locked file is held only while it is sealed again (one layer)
    let holder = UUID()
    if let session = renamed.session { io.sessions.hold(session, by: holder) }
    defer { io.sessions.release(holder: holder) }
    try await commitFile(
      data: renamed.plaintext, from: loaded.url, to: destination,
      lockKeyId: renamed.session?.workspaceId, io: io)
    let bookmark =
      SecurityScopedAccess.bookmarkIfPossible(for: destination)
      ?? (sameFile(loaded.url, destination) ? entry.bookmark : nil)
    recents.replaceWorkspace(
      id: entry.id, with: entry.edited(name: name, fileURL: destination, bookmark: bookmark))
  }

  private static func loadFile(
    _ entry: WorkspaceHistoryEntry
  ) async throws -> (
    url: URL, data: Data, token: SecurityScopedAccessToken?
  ) {
    if let bookmark = entry.bookmark {
      if let resolved = try? SecurityScopedAccess.resolve(bookmark) {
        let token = SecurityScopedAccessToken(url: resolved.url)
        if let data = try? await contents(of: resolved.url) {
          return (resolved.url, data, token)
        }
        token.release()
      }
    }
    do {
      let data = try await contents(of: entry.fileURL)
      return (entry.fileURL, data, nil)
    } catch {
      throw RecentWorkspaceEditError.unreadable
    }
  }

  /// The file's bytes, read off the main actor
  @concurrent nonisolated private static func contents(of url: URL) async throws -> Data {
    try Data(contentsOf: url)
  }
}
