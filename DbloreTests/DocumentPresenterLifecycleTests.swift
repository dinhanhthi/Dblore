// DocumentPresenterLifecycleTests.swift
// Closed tabs and closed workspaces unregister their documents as file presenters, so the file
// coordinator no longer keeps them alive. Temp files only; presenters are matched by the test's
// own URLs (other suites register presenters in parallel).

import Foundation
import Testing

@testable import Dblore

@Suite("Document presenter lifecycle")
@MainActor
struct DocumentPresenterLifecycleTests {
  /// A temp folder with a notebook and a script
  private static func makeFiles() throws -> (folder: URL, notebook: URL, script: URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("presenters-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let notebook = folder.appendingPathComponent("notes.dblore")
    let cells = [NotebookCell(cellType: .sql, content: "select 1")]
    try DocumentCoder.encode(
      DbloreNotebook(cells: cells, documentType: .notebook), includeResultsOnSave: false
    ).write(to: notebook)
    let script = folder.appendingPathComponent("query.sql")
    try Data("select 2".utf8).write(to: script)
    return (folder, notebook, script)
  }

  private static func manager() throws -> (WorkspaceManager, UserDefaults, String) {
    let name = "DocumentPresenterLifecycleTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = RecentManager(defaults: suite)
    var hooks = SecurityScopedAccessHooks()
    hooks.resolve = { _ in throw CocoaError(.fileNoSuchFile) }
    hooks.makeBookmark = { _ in nil }
    manager.accessHooks = hooks
    return (manager, suite, name)
  }

  /// Whether a presenter of `url` is registered, once the queued adds and removals ran. The
  /// pool drains the autoreleased presenter list, which would keep the documents alive.
  private static func isPresented(_ url: URL) -> Bool {
    #expect(SQLiteFileAccess.onPresenterQueue {})
    let path = url.standardizedFileURL.path
    return autoreleasepool {
      NSFileCoordinator.filePresenters.contains {
        $0.presentedItemURL?.standardizedFileURL.path == path
      }
    }
  }

  @Test("Closing a notebook tab and a script tab unregisters and frees their documents")
  func closingTabsUnregisters() async throws {
    let files = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: files.folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: files.notebook)
    try await manager.openFile(url: files.script)
    let notebookTab = try #require(manager.tabs.first { $0.fileURL == files.notebook }).id
    let scriptTab = try #require(manager.tabs.first { $0.fileURL == files.script }).id
    weak let notebook = manager.notebookDocument(for: notebookTab)
    weak let script = manager.editorDocument(for: scriptTab)
    #expect(notebook != nil && script != nil)
    #expect(Self.isPresented(files.notebook) && Self.isPresented(files.script))

    manager.closeTabImmediately(id: notebookTab)
    manager.closeTabImmediately(id: scriptTab)

    #expect(!Self.isPresented(files.notebook))
    #expect(!Self.isPresented(files.script))
    #expect(notebook == nil)
    #expect(script == nil)
  }

  @Test("Closing a legacy tab manager's tabs unregisters and frees their documents")
  func closingLegacyTabsUnregisters() async throws {
    let files = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: files.folder) }
    let manager = TabStateManager()
    try await manager.openFile(url: files.notebook)
    try await manager.openFile(url: files.script)
    let notebookTab = try #require(manager.tabs.first { $0.fileURL == files.notebook }).id
    let scriptTab = try #require(manager.tabs.first { $0.fileURL == files.script }).id
    weak let notebook = manager.notebookDocument(for: notebookTab)
    weak let script = manager.editorDocument(for: scriptTab)
    #expect(notebook != nil && script != nil)
    #expect(Self.isPresented(files.notebook) && Self.isPresented(files.script))

    manager.requestCloseTab(id: notebookTab)
    manager.requestCloseTab(id: scriptTab)

    #expect(manager.tabs.isEmpty)
    #expect(!Self.isPresented(files.notebook))
    #expect(!Self.isPresented(files.script))
    #expect(notebook == nil)
    #expect(script == nil)
  }

  @Test("Closing a workspace unregisters and frees every document")
  func closingWorkspaceUnregisters() async throws {
    let files = try Self.makeFiles()
    defer { try? FileManager.default.removeItem(at: files.folder) }
    let name = "DocumentPresenterLifecycleTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }
    let windows = WorkspaceWindowManager(recents: RecentManager(defaults: suite))
    weak var notebook: DbloreDocument?
    weak var script: SQLEditorDocument?
    // Only weak references outlive this scope: the window manager holds the workspace
    func openWorkspace() async throws -> UUID {
      let (manager, managerSuite, managerName) = try Self.manager()
      defer { managerSuite.removePersistentDomain(forName: managerName) }
      windows.workspaces[manager.id] = manager
      try await manager.openFile(url: files.notebook)
      try await manager.openFile(url: files.script)
      let notebookTab = try #require(manager.tabs.first { $0.fileURL == files.notebook }).id
      let scriptTab = try #require(manager.tabs.first { $0.fileURL == files.script }).id
      notebook = manager.notebookDocument(for: notebookTab)
      script = manager.editorDocument(for: scriptTab)
      return manager.id
    }
    let id = try await openWorkspace()
    #expect(notebook != nil && script != nil)
    #expect(Self.isPresented(files.notebook) && Self.isPresented(files.script))

    #expect(await windows.closeWorkspace(id: id, force: true))

    #expect(windows.workspaces.isEmpty)
    #expect(!Self.isPresented(files.notebook))
    #expect(!Self.isPresented(files.script))
    #expect(notebook == nil)
    #expect(script == nil)
  }
}
