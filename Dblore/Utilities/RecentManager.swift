//
//  RecentManager.swift
//  Dblore
//

import AppKit
import Foundation

/// Manages recent workspaces and connections for the welcome screen.
/// Separate from SessionManager which handles connection history for the connection form.
@MainActor
@Observable
class RecentManager {
  // MARK: - Shared Instance

  static let shared = RecentManager(
    defaults: sharedDefaults,
    documentController: SessionManager.isRunningAsTestHost ? nil : .shared)

  /// Store of `shared`: `.standard` in the app; under XCTest an isolated suite, cleared at
  /// creation, so tests never touch the user's real recents
  nonisolated(unsafe) static let sharedDefaults: UserDefaults = {
    guard SessionManager.isRunningAsTestHost else { return .standard }
    let name = "ace.thi.Dblore.tests.recents"
    let suite = UserDefaults(suiteName: name) ?? UserDefaults()
    suite.removePersistentDomain(forName: name)
    return suite
  }()

  // MARK: - Storage Keys

  private nonisolated static let workspacesKey = "ace.thi.dblore.recentWorkspaces"
  private nonisolated static let maxWorkspaces = 6
  private nonisolated static let documentBookmarksKey = "ace.thi.dblore.recentDocumentBookmarks"
  private nonisolated static let maxDocumentBookmarks = 20

  private let defaults: UserDefaults
  /// Source of the recent .dblore/.sql list; nil under XCTest (never the user's real recents)
  private let documentController: NSDocumentController?

  // MARK: - State

  var recentWorkspaces: [WorkspaceHistoryEntry] = []

  /// Recent document files (.dblore, .sql) from NSDocumentController
  /// This is a cached snapshot that needs to be refreshed manually
  var recentDocuments: [URL] = []

  /// Bookmark of a recent .dblore/.sql file, keyed by its standardized path
  private struct DocumentBookmark: Codable {
    let path: String
    let bookmark: Data
  }

  /// Own bookmarks of recent files (most recent first): the URLs of
  /// `NSDocumentController.recentDocumentURLs` are not relied on to carry access
  @ObservationIgnored private var documentBookmarks: [DocumentBookmark] = []

  /// Recent connections (delegated to SessionManager)
  var recentConnections: [ConnectionHistoryEntry] {
    _ = connectionsRevision
    return SessionManager.loadHistory()
  }

  /// Bumped when the connection history changes, so views reading `recentConnections` refresh
  private var connectionsRevision = 0

  @ObservationIgnored private let localDataChanges = LocalDataChangeObserver()

  // MARK: - Initialization

  init(defaults: UserDefaults, documentController: NSDocumentController? = nil) {
    self.defaults = defaults
    self.documentController = documentController
    loadWorkspaces()
    loadDocumentBookmarks()
    refreshRecentDocuments()
    localDataChanges.start { [weak self] note in
      let recents = LocalDataCategory.notification(note, includes: .recentItems)
      let connections = LocalDataCategory.notification(note, includes: .connectionHistory)
      guard recents || connections else { return }
      Task { @MainActor [weak self] in
        self?.reloadAfterLocalDataChange(recents: recents, connections: connections)
      }
    }
  }

  /// Reloads stored recents and connection history. Does not call `clearAll()` (that also
  /// clears Keychain passwords).
  private func reloadAfterLocalDataChange(recents: Bool, connections: Bool) {
    if recents {
      loadWorkspaces()
      loadDocumentBookmarks()
    }
    if connections {
      connectionsRevision += 1
    }
  }

  // MARK: - Workspace Management

  /// Add a workspace to recent list
  func addWorkspace(_ entry: WorkspaceHistoryEntry) {
    // Keep the bookmarks already stored for this file when the new entry has none
    var entry = entry
    if let existing = recentWorkspaces.first(where: { $0.fileURL == entry.fileURL }) {
      entry.bookmark = entry.bookmark ?? existing.bookmark
      entry.folderBookmark = entry.folderBookmark ?? existing.folderBookmark
    }

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

  /// Replace one recent workspace in place. A different row that already uses the new path is dropped.
  func replaceWorkspace(id: UUID, with entry: WorkspaceHistoryEntry) {
    guard recentWorkspaces.contains(where: { $0.id == id }) else {
      addWorkspace(entry)
      return
    }

    var entry = entry
    if let existing = recentWorkspaces.first(where: { $0.id == id }),
      existing.fileURL.standardizedFileURL == entry.fileURL.standardizedFileURL
    {
      entry.bookmark = entry.bookmark ?? existing.bookmark
      entry.folderBookmark = entry.folderBookmark ?? existing.folderBookmark
    } else if entry.folderBookmark == nil {
      entry.folderBookmark = recentWorkspaces.first { $0.id == id }?.folderBookmark
    }

    let destination = entry.fileURL.standardizedFileURL
    recentWorkspaces.removeAll {
      $0.id != id && $0.fileURL.standardizedFileURL == destination
    }
    guard let index = recentWorkspaces.firstIndex(where: { $0.id == id }) else {
      addWorkspace(entry)
      return
    }
    recentWorkspaces[index] = entry
    saveWorkspaces()
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
    defaults.removeObject(forKey: Self.workspacesKey)
  }

  /// Clear all (workspaces + connections)
  func clearAll() {
    clearWorkspaces()
    SessionManager.clearAllHistory()
  }

  // MARK: - Recent Documents Management

  /// Refresh recent documents from NSDocumentController
  /// Call this after opening/saving a document to update the list
  func refreshRecentDocuments() {
    recentDocuments = (documentController?.recentDocumentURLs ?? []).filter { url in
      let ext = url.pathExtension.lowercased()
      return ext == "dblore" || ext == "sql"
    }
  }

  /// Add a file to the recent documents and remember its bookmark for the next reopen
  func noteRecentDocument(_ url: URL, bookmark: Data?) {
    if let bookmark {
      rememberDocumentBookmark(bookmark, for: url)
    }
    documentController?.noteNewRecentDocumentURL(url)
    refreshRecentDocuments()
  }

  /// Stored bookmark of a recent file
  func documentBookmark(for url: URL) -> Data? {
    let path = url.standardizedFileURL.path
    return documentBookmarks.first { $0.path == path }?.bookmark
  }

  /// Store (or replace) the bookmark of a file opened or saved by the user
  func rememberDocumentBookmark(_ bookmark: Data, for url: URL) {
    let path = url.standardizedFileURL.path
    documentBookmarks.removeAll { $0.path == path }
    documentBookmarks.insert(DocumentBookmark(path: path, bookmark: bookmark), at: 0)
    documentBookmarks = Array(documentBookmarks.prefix(Self.maxDocumentBookmarks))
    guard let data = try? JSONEncoder().encode(documentBookmarks) else { return }
    defaults.set(data, forKey: Self.documentBookmarksKey)
  }

  // MARK: - Connection Management (Delegated to SessionManager)

  /// Add a connection to recent list
  func addConnection(_ config: ConnectionConfig) {
    SessionManager.saveConnection(config)
  }

  /// Replace one recent connection in place.
  @discardableResult
  func replaceConnection(id: UUID, with config: ConnectionConfig) -> Bool {
    guard SessionManager.replaceConnection(id: id, with: config) else { return false }
    connectionsRevision += 1
    return true
  }

  /// Remove a connection from recent list
  func removeConnection(id: UUID) {
    SessionManager.removeConnection(id: id)
    connectionsRevision += 1
  }

  /// Clear all recent connections
  func clearConnections() {
    SessionManager.clearAllHistory()
    connectionsRevision += 1
  }

  // MARK: - Persistence

  private func loadWorkspaces() {
    guard let data = defaults.data(forKey: Self.workspacesKey),
      let entries = try? JSONDecoder().decode([WorkspaceHistoryEntry].self, from: data)
    else {
      recentWorkspaces = []
      return
    }

    // Runs at launch: never prompts. Without access a file looks missing, so only entries
    // whose bookmark shows the file is really gone are dropped.
    recentWorkspaces = entries.filter { !Self.isGone($0) }

    // If we filtered any out, save the cleaned list
    if recentWorkspaces.count != entries.count {
      saveWorkspaces()
    }
  }

  /// `NSCocoaErrorDomain` 4 or 260: the file is not there. Bookmark resolution throws 4;
  /// `Data(contentsOf:)` throws 260 for a missing workspace.
  nonisolated static func isFileNotFound(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain
      && (nsError.code == CocoaError.fileNoSuchFile.rawValue
        || nsError.code == CocoaError.fileReadNoSuchFile.rawValue)
  }

  /// The entry's bookmark resolves to a file that no longer exists, or reports that it does
  /// not exist. Entries without a bookmark, or whose bookmark fails for another reason (for
  /// example Cocoa 259, seen for a deleted file but also possible for an unusable bookmark),
  /// are kept.
  static func isGone(
    _ entry: WorkspaceHistoryEntry,
    resolve: (Data) throws -> (url: URL, isStale: Bool) = { try SecurityScopedAccess.resolve($0) }
  ) -> Bool {
    guard let bookmark = entry.bookmark else { return false }
    do {
      let resolved = try resolve(bookmark)
      let token = SecurityScopedAccessToken(url: resolved.url)
      defer { token.release() }
      return !FileManager.default.fileExists(atPath: resolved.url.path)
    } catch {
      return Self.isFileNotFound(error)
    }
  }

  private func saveWorkspaces() {
    guard let data = try? JSONEncoder().encode(recentWorkspaces) else { return }
    defaults.set(data, forKey: Self.workspacesKey)
  }

  private func loadDocumentBookmarks() {
    guard let data = defaults.data(forKey: Self.documentBookmarksKey),
      let stored = try? JSONDecoder().decode([DocumentBookmark].self, from: data)
    else {
      documentBookmarks = []
      return
    }
    documentBookmarks = stored
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

extension RecentManager {
  nonisolated static func storedRecents(
    defaults: UserDefaults, domainName: String
  ) -> (
    workspaces: Data?, bookmarks: Data?
  ) {
    let domain = defaults.persistentDomain(forName: domainName) ?? [:]
    return (domain[workspacesKey] as? Data, domain[documentBookmarksKey] as? Data)
  }

  nonisolated static func exportSnapshot(
    defaults: UserDefaults, domainName: String
  ) -> (
    workspaces: Data?, bookmarks: Data?
  ) {
    storedRecents(defaults: defaults, domainName: domainName)
  }

  /// Replaces workspace and file-bookmark entries. Does not touch connection history.
  nonisolated static func replace(
    workspaces: Data?, bookmarks: Data?, defaults: UserDefaults, domainName: String
  ) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    set(&domain, workspacesKey, workspaces)
    set(&domain, documentBookmarksKey, bookmarks)
    defaults.setPersistentDomain(domain, forName: domainName)
  }

  /// Clears recent workspaces and file bookmarks in `domainName` only.
  nonisolated static func clearStoredData(defaults: UserDefaults, domainName: String) {
    replace(workspaces: nil, bookmarks: nil, defaults: defaults, domainName: domainName)
  }

  private nonisolated static func set(_ domain: inout [String: Any], _ key: String, _ data: Data?) {
    if let data {
      domain[key] = data
    } else {
      domain.removeValue(forKey: key)
    }
  }
}
