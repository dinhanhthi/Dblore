// SecurityScopedRestoreTests.swift
// Reads and writes through security-scoped bookmarks: access tokens are held for the lifetime
// of a workspace and its tabs and released once, stale bookmarks are refreshed and saved, the
// launch-time recents filter keeps bookmark-less entries, recent files reopen through their
// stored bookmark, bookmark-less tab files ask once for the workspace folder, and corrupt files
// still throw. Temp files only; recents use an injected suite, never the user's defaults.

import Foundation
import Testing
import os

@testable import Dblore

@Suite("Security-scoped restore")
@MainActor
struct SecurityScopedRestoreTests {
  // MARK: - Fixtures

  /// Temp folder with a .sqlws whose tabs point to sibling .sql files
  @MainActor
  private struct Fixture {
    let folder: URL
    let workspaceURL: URL
    let tabURLs: [URL]
    let tabs: [WorkspaceTabReference]

    init(tabCount: Int, tabBookmarks: [Data?]? = nil) throws {
      folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      workspaceURL = folder.appendingPathComponent("ws.sqlws")
      var urls: [URL] = []
      var refs: [WorkspaceTabReference] = []
      for index in 0..<tabCount {
        let url = folder.appendingPathComponent("tab\(index).sql")
        try Data("select \(index)".utf8).write(to: url)
        urls.append(url)
        refs.append(
          WorkspaceTabReference(
            fileURL: url, documentType: .sqlFile, title: url.lastPathComponent,
            bookmark: tabBookmarks?[index]))
      }
      tabURLs = urls
      tabs = refs
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(Workspace(tabs: refs)).write(to: workspaceURL)
    }

    func setPermissions(_ mode: Int, _ urls: [URL]) {
      for url in urls {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
      }
    }

    func remove() {
      setPermissions(0o755, [folder])
      setPermissions(0o644, tabURLs)
      try? FileManager.default.removeItem(at: folder)
    }
  }

  /// Counts start/stop calls of the tokens it creates
  private final class AccessCounter: Sendable {
    let starts = OSAllocatedUnfairLock<[String]>(initialState: [])
    let stops = OSAllocatedUnfairLock<[String]>(initialState: [])

    func token(_ url: URL) -> SecurityScopedAccessToken {
      SecurityScopedAccessToken(
        url: url,
        start: { [self] in
          let path = $0.path
          starts.withLock { $0.append(path) }
          return true
        },
        stop: { [self] in
          let path = $0.path
          stops.withLock { $0.append(path) }
        })
    }

    var startCount: Int { starts.withLock { $0.count } }
    var stopCount: Int { stops.withLock { $0.count } }
  }

  private static func hooks(
    counter: AccessCounter, resolved: [Data: (URL, Bool)] = [:],
    chooseFolder: @escaping @MainActor (URL) async -> URL? = { _ in nil },
    chooseFile: @escaping @MainActor (URL) async -> URL? = { _ in nil }
  ) -> SecurityScopedAccessHooks {
    var hooks = SecurityScopedAccessHooks()
    hooks.resolve = { data in
      guard let match = resolved[data] else { throw CocoaError(.fileNoSuchFile) }
      return (url: match.0, isStale: match.1)
    }
    hooks.makeBookmark = { _ in Data([42]) }
    hooks.startAccess = { counter.token($0) }
    hooks.chooseFolder = chooseFolder
    hooks.chooseFile = chooseFile
    return hooks
  }

  private static func recents() throws -> (RecentManager, UserDefaults, String) {
    let name = "SecurityScopedRestoreTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    return (RecentManager(defaults: suite), suite, name)
  }

  // MARK: - Token balance

  @Test("Workspace and tab tokens start once and stop once on tab close / workspace close")
  func tokensAreBalanced() async throws {
    let fixture = try Fixture(tabCount: 2, tabBookmarks: [Data([2]), Data([3])])
    defer { fixture.remove() }
    let counter = AccessCounter()
    let hooks = Self.hooks(
      counter: counter,
      resolved: [
        Data([1]): (fixture.workspaceURL, false),
        Data([2]): (fixture.tabURLs[0], false),
        Data([3]): (fixture.tabURLs[1], false),
      ])

    let manager = try await WorkspaceManager.load(
      from: fixture.workspaceURL, bookmark: Data([1]), hooks: hooks)
    #expect(manager.tabs.count == 2)
    #expect(counter.startCount == 3)
    #expect(counter.stopCount == 0)
    // Valid, non-stale bookmarks are kept as they are
    #expect(manager.workspaceBookmark == Data([1]))
    #expect(manager.tabBookmarks[fixture.tabs[0].id] == Data([2]))

    manager.requestCloseTab(id: fixture.tabs[0].id)
    #expect(counter.stops.withLock { $0 } == [fixture.tabURLs[0].path])

    manager.releaseFileAccess()
    manager.releaseFileAccess()
    #expect(counter.stopCount == 3)
  }

  // MARK: - Stale bookmarks

  @Test("Stale workspace and tab bookmarks are refreshed and saved with the workspace")
  func staleBookmarksAreRefreshed() async throws {
    let fixture = try Fixture(tabCount: 1, tabBookmarks: [Data([2])])
    defer { fixture.remove() }
    let counter = AccessCounter()
    let hooks = Self.hooks(
      counter: counter,
      resolved: [
        Data([1]): (fixture.workspaceURL, true),
        Data([2]): (fixture.tabURLs[0], true),
      ])

    let manager = try await WorkspaceManager.load(
      from: fixture.workspaceURL, bookmark: Data([1]), hooks: hooks)
    manager.autoSaveTask?.cancel()
    #expect(manager.workspaceBookmark == Data([42]))
    #expect(manager.recentEntry?.bookmark == Data([42]))
    #expect(manager.tabBookmarks[fixture.tabs[0].id] == Data([42]))
    #expect(manager.isDirty)
    let saved = try JSONDecoder.iso8601Restore.decode(
      Workspace.self, from: manager.encodedWorkspaceData())
    #expect(saved.tabs.first?.bookmark == Data([42]))
  }

  // MARK: - Launch-time recents filter

  @Test("A bookmark-less recent entry is kept at launch even when its file cannot be seen")
  func bookmarkLessEntryIsKept() throws {
    let name = "SecurityScopedRestoreTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let missing = WorkspaceHistoryEntry(
      fileURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a.sqlws"), name: "A")
    suite.set(
      try JSONEncoder().encode([missing]), forKey: "ace.thi.dblore.recentWorkspaces")

    let recents = RecentManager(defaults: suite)
    #expect(recents.recentWorkspaces.map(\.fileURL) == [missing.fileURL])
  }

  @Test("A recent entry is dropped only when its bookmark shows the file is gone")
  func goneBookmarkedEntryIsDropped() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let existing = folder.appendingPathComponent("kept.sqlws")
    try Data("{}".utf8).write(to: existing)
    let missing = folder.appendingPathComponent("gone.sqlws")
    let entry = WorkspaceHistoryEntry(fileURL: missing, name: "A", bookmark: Data([1]))

    #expect(RecentManager.isGone(entry, resolve: { _ in (url: missing, isStale: false) }))
    #expect(RecentManager.isGone(entry, resolve: { _ in throw CocoaError(.fileNoSuchFile) }))
    #expect(!RecentManager.isGone(entry, resolve: { _ in (url: existing, isStale: false) }))
    #expect(!RecentManager.isGone(entry, resolve: { _ in throw CocoaError(.fileReadCorruptFile) }))
    #expect(!RecentManager.isGone(WorkspaceHistoryEntry(fileURL: missing, name: "B")))
  }

  @Test("A recent entry with a working bookmark is kept at launch")
  func bookmarkedEntryIsKept() throws {
    let name = "SecurityScopedRestoreTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("recents-\(UUID().uuidString).sqlws")
    try Data("{}".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let entry = WorkspaceHistoryEntry(
      fileURL: url, name: "kept", bookmark: try SecurityScopedAccess.makeBookmark(for: url))
    suite.set(try JSONEncoder().encode([entry]), forKey: "ace.thi.dblore.recentWorkspaces")

    #expect(RecentManager(defaults: suite).recentWorkspaces.map(\.name) == ["kept"])
  }

  // MARK: - Recent file reopen

  @Test("Reopening a recent file uses its stored bookmark and holds access for the tab")
  func recentFileUsesStoredBookmark() async throws {
    let fixture = try Fixture(tabCount: 1)
    defer { fixture.remove() }
    let (recents, suite, name) = try Self.recents()
    defer { suite.removePersistentDomain(forName: name) }
    recents.rememberDocumentBookmark(Data([7]), for: fixture.tabURLs[0])
    let counter = AccessCounter()
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = recents
    manager.accessHooks = Self.hooks(
      counter: counter, resolved: [Data([7]): (fixture.tabURLs[0], false)])

    try await manager.openFile(url: fixture.tabURLs[0])
    #expect(counter.starts.withLock { $0 } == [fixture.tabURLs[0].path])
    #expect(manager.tabs.count == 1)
    #expect(manager.tabBookmarks[manager.tabs[0].id] == Data([7]))
    // A second store is independent: the bookmark survives a reload of the same suite
    #expect(RecentManager(defaults: suite).documentBookmark(for: fixture.tabURLs[0]) == Data([7]))

    manager.releaseFileAccess()
    #expect(counter.stopCount == 1)
  }

  // MARK: - Permission failures

  @Test("Bookmark-less unreadable tabs ask once for the folder, then all tabs restore")
  func folderChooserIsAskedOnce() async throws {
    let fixture = try Fixture(tabCount: 3)
    defer { fixture.remove() }
    fixture.setPermissions(0o000, fixture.tabURLs)
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let counter = AccessCounter()
    let hooks = Self.hooks(
      counter: counter,
      chooseFolder: { workspaceURL in
        asked.withLock { $0 += 1 }
        fixture.setPermissions(0o644, fixture.tabURLs)
        return workspaceURL.deletingLastPathComponent()
      },
      chooseFile: { _ in
        Issue.record("no file chooser expected")
        return nil
      })

    let manager = try await WorkspaceManager.load(from: fixture.workspaceURL, hooks: hooks)
    manager.autoSaveTask?.cancel()
    #expect(asked.withLock { $0 } == 1)
    #expect(manager.tabs.map(\.id) == fixture.tabs.map(\.id))
    #expect(manager.folderBookmark == Data([42]))
    #expect(manager.recentEntry?.folderBookmark == Data([42]))
    #expect(counter.starts.withLock { $0 } == [fixture.folder.path])

    manager.releaseFileAccess()
    #expect(counter.stopCount == 1)
  }

  @Test("Unreadable tabs whose bookmark no longer resolves also ask once for the folder")
  func unresolvableTabBookmarksAskFolderOnce() async throws {
    let fixture = try Fixture(tabCount: 2, tabBookmarks: [Data([99]), Data([98])])
    defer { fixture.remove() }
    fixture.setPermissions(0o000, fixture.tabURLs)
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let hooks = Self.hooks(
      counter: AccessCounter(),
      chooseFolder: { workspaceURL in
        asked.withLock { $0 += 1 }
        fixture.setPermissions(0o644, fixture.tabURLs)
        return workspaceURL.deletingLastPathComponent()
      })

    let manager = try await WorkspaceManager.load(from: fixture.workspaceURL, hooks: hooks)
    manager.autoSaveTask?.cancel()
    #expect(asked.withLock { $0 } == 1)
    #expect(manager.tabs.map(\.id) == fixture.tabs.map(\.id))
    #expect(manager.tabBookmarks[fixture.tabs[0].id] == Data([42]))
  }

  @Test("A declined folder chooser skips the unreadable tabs without throwing")
  func declinedFolderSkipsTabs() async throws {
    let fixture = try Fixture(tabCount: 2)
    defer { fixture.remove() }
    fixture.setPermissions(0o000, fixture.tabURLs)
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let hooks = Self.hooks(
      counter: AccessCounter(),
      chooseFolder: { _ in
        asked.withLock { $0 += 1 }
        return nil
      })

    let manager = try await WorkspaceManager.load(from: fixture.workspaceURL, hooks: hooks)
    #expect(asked.withLock { $0 } == 1)
    #expect(manager.tabs.isEmpty)
  }

  @Test("An unreadable recent file asks the file chooser once and opens the chosen file")
  func unreadableFileAsksFileChooser() async throws {
    let fixture = try Fixture(tabCount: 1)
    defer { fixture.remove() }
    fixture.setPermissions(0o000, fixture.tabURLs)
    let (recents, suite, name) = try Self.recents()
    defer { suite.removePersistentDomain(forName: name) }
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = recents
    manager.accessHooks = Self.hooks(
      counter: AccessCounter(),
      chooseFile: { file in
        asked.withLock { $0 += 1 }
        fixture.setPermissions(0o644, fixture.tabURLs)
        return file
      })

    try await manager.openFile(url: fixture.tabURLs[0])
    #expect(asked.withLock { $0 } == 1)
    #expect(manager.tabs.count == 1)
    #expect(recents.documentBookmark(for: fixture.tabURLs[0]) == Data([42]))
  }

  @Test("A corrupt notebook still throws when opened")
  func corruptFileThrows() async throws {
    let fixture = try Fixture(tabCount: 0)
    defer { fixture.remove() }
    let corrupt = fixture.folder.appendingPathComponent("broken.dblore")
    try Data("not a notebook".utf8).write(to: corrupt)
    let (recents, suite, name) = try Self.recents()
    defer { suite.removePersistentDomain(forName: name) }
    let asked = OSAllocatedUnfairLock(initialState: 0)
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = recents
    manager.accessHooks = Self.hooks(
      counter: AccessCounter(),
      chooseFile: { _ in
        asked.withLock { $0 += 1 }
        return nil
      })

    await #expect(throws: (any Error).self) {
      try await manager.openFile(url: corrupt)
    }
    #expect(asked.withLock { $0 } == 0)
    #expect(manager.tabs.isEmpty)
  }

  // MARK: - Writes

  @Test("A write falls back to non-atomic when the folder is not writable")
  func writeFallsBackToNonAtomic() throws {
    let fixture = try Fixture(tabCount: 1)
    defer { fixture.remove() }
    fixture.setPermissions(0o555, [fixture.folder])

    try SecurityScopedAccess.write(Data("select 2".utf8), to: fixture.tabURLs[0])
    #expect(try String(contentsOf: fixture.tabURLs[0], encoding: .utf8) == "select 2")
  }

  @Test("Permission errors are recognized, missing files are not")
  func permissionErrorClassification() {
    #expect(SecurityScopedAccess.isPermissionError(CocoaError(.fileReadNoPermission)))
    #expect(SecurityScopedAccess.isPermissionError(CocoaError(.fileWriteNoPermission)))
    #expect(!SecurityScopedAccess.isPermissionError(CocoaError(.fileReadNoSuchFile)))
    #expect(!SecurityScopedAccess.isPermissionError(CocoaError(.fileReadCorruptFile)))
  }

  @Test("RecentManager.shared under XCTest is not backed by UserDefaults.standard")
  func sharedRecentsAreIsolated() {
    #expect(RecentManager.sharedDefaults !== UserDefaults.standard)
  }
}

extension JSONDecoder {
  fileprivate static var iso8601Restore: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
