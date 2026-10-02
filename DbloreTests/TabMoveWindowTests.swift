// TabMoveWindowTests.swift
// Moving a file tab to a new window: eligibility rules and the transfer into another manager.
// Temp files only; recents use an injected suite and hooks, never the shared singletons.

import Foundation
import Testing

@testable import Dblore

@Suite("Move tab to new window")
@MainActor
struct TabMoveWindowTests {
  private static func makeFile() throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("tab.sql")
    try Data("select 1".utf8).write(to: url)
    return (folder, url)
  }

  private static func manager() throws -> (WorkspaceManager, UserDefaults, String) {
    let name = "TabMoveWindowTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = RecentManager(defaults: suite)
    var hooks = SecurityScopedAccessHooks()
    hooks.resolve = { _ in throw CocoaError(.fileNoSuchFile) }
    hooks.makeBookmark = { _ in nil }
    manager.accessHooks = hooks
    return (manager, suite, name)
  }

  @Test("A clean saved file tab can move; the tab is identified by id")
  func cleanFileTabCanMove() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    #expect(manager.canMoveToNewWindow(tabId: manager.tabs[0].id))
    #expect(!manager.canMoveToNewWindow(tabId: UUID()))
  }

  @Test("Dirty, untitled, pinned and transaction-origin tabs cannot move")
  func ineligibleTabs() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    let id = manager.tabs[0].id

    manager.tabs[0].isDirty = true
    #expect(!manager.canMoveToNewWindow(tabId: id))
    manager.tabs[0].isDirty = false

    manager.setPinned(true, id: id)
    #expect(!manager.canMoveToNewWindow(tabId: id))
    manager.setPinned(false, id: id)
    #expect(manager.canMoveToNewWindow(tabId: id))

    manager.transactionOriginTabId = id
    #expect(!manager.canMoveToNewWindow(tabId: id))
    manager.transactionOriginTabId = nil

    let untitled = manager.newSQLFile()
    #expect(!manager.canMoveToNewWindow(tabId: untitled))
  }

  @Test("Transfer opens the file in the target through its bookmark and closes the source tab")
  func transferMovesTab() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (source, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    let (target, targetSuite, targetName) = try Self.manager()
    defer { targetSuite.removePersistentDomain(forName: targetName) }
    try await source.openFile(url: url)
    let id = source.tabs[0].id
    source.tabBookmarks[id] = Data([7])

    var resolved: [Data] = []
    target.accessHooks.resolve = { data in
      resolved.append(data)
      return (url: url, isStale: false)
    }
    try await source.transfer(tabId: id, into: target)

    #expect(resolved == [Data([7])])
    #expect(target.tabs.map(\.fileURL) == [url])
    #expect(target.tabBookmarks[target.tabs[0].id] == Data([7]))
    #expect(source.tabs.isEmpty)
  }

  @Test("A failed open in the target leaves the source tab in place")
  func failedTransferKeepsSource() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (source, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    let (target, targetSuite, targetName) = try Self.manager()
    defer { targetSuite.removePersistentDomain(forName: targetName) }
    try await source.openFile(url: url)
    try FileManager.default.removeItem(at: url)

    await #expect(throws: (any Error).self) {
      try await source.transfer(tabId: source.tabs[0].id, into: target)
    }
    #expect(source.tabs.count == 1)
    #expect(target.tabs.isEmpty)
  }

  @Test("A tab that turns dirty while the target opens it stays only in the source")
  func tabChangedDuringOpenStaysInSource() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (source, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    let (target, targetSuite, targetName) = try Self.manager()
    defer { targetSuite.removePersistentDomain(forName: targetName) }
    try await source.openFile(url: url)
    let id = source.tabs[0].id
    source.tabBookmarks[id] = Data([7])
    target.accessHooks.resolve = { _ in
      source.tabs[0].isDirty = true
      return (url: url, isStale: false)
    }

    await #expect(throws: (any Error).self) {
      try await source.transfer(tabId: id, into: target)
    }
    #expect(source.tabs.count == 1)
    #expect(source.tabToClose == nil)
    #expect(target.tabs.isEmpty)
  }

  @Test("A tab cannot move while a transaction resolution is running")
  func resolvingTransactionBlocksMove() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    manager.isResolvingPendingTransaction = true
    #expect(!manager.canMoveToNewWindow(tabId: manager.tabs[0].id))
  }

  @Test("A failed move discards the new window manager and restores the active workspace")
  func failedMoveDiscardsWindowManager() async throws {
    let (folder, url) = try Self.makeFile()
    defer { try? FileManager.default.removeItem(at: folder) }
    let (source, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    let (target, targetSuite, targetName) = try Self.manager()
    defer { targetSuite.removePersistentDomain(forName: targetName) }
    try await source.openFile(url: url)
    try FileManager.default.removeItem(at: url)
    source.makeWindowManager = { _ in target }
    var discarded: [(UUID, UUID?)] = []
    source.discardWindowManager = { manager, previous in discarded.append((manager.id, previous)) }

    await source.moveTabToNewWindow(id: source.tabs[0].id)

    #expect(discarded.count == 1)
    #expect(discarded.first?.0 == target.id)
    #expect(source.tabs.count == 1)
  }

  @Test("A data viewer tab moves with its relation and the source tab closes")
  func transferMovesDataViewer() async throws {
    let (source, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    let (target, targetSuite, targetName) = try Self.manager()
    defer { targetSuite.removePersistentDomain(forName: targetName) }
    source.openDataViewer(schema: "sales", name: "orders", orderColumns: ["id", "day"])
    let id = source.tabs[0].id

    try await source.transfer(tabId: id, into: target)

    let moved = try #require(target.tabs.first)
    #expect(target.tabs.count == 1)
    #expect(moved.documentType == .dataViewer)
    #expect(moved.title == "sales.orders")
    let state = try #require(target.viewModels[moved.id]?.dataViewer)
    #expect(state.schema == "sales")
    #expect(state.name == "orders")
    #expect(state.orderColumns == ["id", "day"])
    #expect(!moved.isPinned)
    #expect(source.tabs.isEmpty)
  }
}
