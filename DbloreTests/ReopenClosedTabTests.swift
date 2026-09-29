// ReopenClosedTabTests.swift
// Cmd+Shift+T reopens closed file tabs, most recent first, at their original position and
// through their bookmark. Untitled tabs are not remembered. Temp files only; recents use an
// injected suite, never the user's defaults.

import Foundation
import Testing

@testable import Dblore

@Suite("Reopen closed tab")
@MainActor
struct ReopenClosedTabTests {
  /// Temp folder with `count` .sql files
  private static func makeFiles(_ count: Int) throws -> (URL, [URL]) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("reopen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let urls = try (0..<count).map { index in
      let url = folder.appendingPathComponent("tab\(index).sql")
      try Data("select \(index)".utf8).write(to: url)
      return url
    }
    return (folder, urls)
  }

  private static func manager() throws -> (WorkspaceManager, UserDefaults, String) {
    let name = "ReopenClosedTabTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = RecentManager(defaults: suite)
    var hooks = SecurityScopedAccessHooks()
    hooks.resolve = { _ in throw CocoaError(.fileNoSuchFile) }
    hooks.makeBookmark = { _ in nil }
    manager.accessHooks = hooks
    return (manager, suite, name)
  }

  @Test("Reopens the last closed file tab at its position and selects it")
  func reopensAtOriginalPosition() async throws {
    let (folder, urls) = try Self.makeFiles(3)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    for url in urls { try await manager.openFile(url: url) }

    manager.requestCloseTab(id: manager.tabs[1].id)
    #expect(manager.tabs.map(\.fileURL) == [urls[0], urls[2]])
    #expect(manager.canReopenClosedTab)

    try await manager.reopenClosedTab()
    #expect(manager.tabs.map(\.fileURL) == urls)
    #expect(manager.activeTabId == manager.tabs[1].id)
    #expect(!manager.canReopenClosedTab)
  }

  @Test("Reopens closed tabs most recent first")
  func reopensInReverseOrder() async throws {
    let (folder, urls) = try Self.makeFiles(2)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    for url in urls { try await manager.openFile(url: url) }

    manager.requestCloseTab(id: manager.tabs[0].id)
    manager.requestCloseTab(id: manager.tabs[0].id)
    #expect(manager.tabs.isEmpty)

    try await manager.reopenClosedTab()
    #expect(manager.tabs.map(\.fileURL) == [urls[1]])
    try await manager.reopenClosedTab()
    #expect(manager.tabs.map(\.fileURL) == urls)
  }

  @Test("Untitled tabs are not remembered")
  func untitledTabIsNotRemembered() async throws {
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    _ = manager.newSQLFile()
    manager.requestCloseTab(id: manager.tabs[0].id)
    manager.closeTabWithoutSaving()
    #expect(manager.tabs.isEmpty)
    #expect(!manager.canReopenClosedTab)

    try await manager.reopenClosedTab()
    #expect(manager.tabs.isEmpty)
  }

  @Test("A reopened tab reads through the closed tab's bookmark")
  func reopenUsesClosedTabBookmark() async throws {
    let (folder, urls) = try Self.makeFiles(1)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: urls[0])
    manager.tabBookmarks[manager.tabs[0].id] = Data([9])
    manager.requestCloseTab(id: manager.tabs[0].id)
    // makeBookmark returns nil: the bookmark is only known to the closed tab, not to recents
    #expect(manager.recents.documentBookmark(for: urls[0]) == nil)

    var resolved: [Data] = []
    manager.accessHooks.resolve = { data in
      resolved.append(data)
      return (url: urls[0], isStale: false)
    }
    try await manager.reopenClosedTab()
    #expect(resolved == [Data([9])])
    #expect(manager.tabBookmarks[manager.tabs[0].id] == Data([9]))
  }
}
