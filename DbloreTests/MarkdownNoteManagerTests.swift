// MarkdownNoteManagerTests.swift
// A .md file opens as a markdown tab whose text is the file's exact bytes, and saving writes
// the editor text back unchanged. Temp files only; recents use an injected suite.

import Foundation
import Testing

@testable import Dblore

@Suite("Markdown note manager")
@MainActor
struct MarkdownNoteManagerTests {
  /// CRLF line endings, trailing spaces (hard break) and no final newline
  private static let source = "# Title\r\n\r\nline one  \r\n* item\r\nlast line"

  private static func makeFile(_ text: String) throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("markdown-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("note.md")
    try Data(text.utf8).write(to: url)
    return (folder, url)
  }

  private static func manager() throws -> (WorkspaceManager, UserDefaults, String) {
    let name = "MarkdownNoteManagerTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.recents = RecentManager(defaults: suite)
    var hooks = SecurityScopedAccessHooks()
    hooks.resolve = { _ in throw CocoaError(.fileNoSuchFile) }
    hooks.makeBookmark = { _ in nil }
    manager.accessHooks = hooks
    return (manager, suite, name)
  }

  @Test("Opening a .md file gives a markdown tab with the file's exact text")
  func opensByteIdentical() async throws {
    let (folder, url) = try Self.makeFile(Self.source)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }

    try await manager.openFile(url: url)

    let tab = try #require(manager.tabs.first)
    #expect(tab.documentType == .markdown)
    let viewModel = try #require(manager.viewModel(for: tab.id))
    #expect(viewModel.viewMode == .markdown)
    #expect(Data(viewModel.editorContent.utf8) == Data(Self.source.utf8))
  }

  @Test("Saving a markdown tab writes the editor text unchanged")
  func savesByteIdentical() async throws {
    let (folder, url) = try Self.makeFile(Self.source)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    let tab = try #require(manager.tabs.first)
    let viewModel = try #require(manager.viewModel(for: tab.id))

    let edited = Self.source + "\r\nadded  "
    viewModel.editorContent = edited
    try await manager.saveTab(id: tab.id)

    #expect(try Data(contentsOf: url) == Data(edited.utf8))
  }

  @Test("Saving a markdown tab first flushes the preview text")
  func saveFlushesPreview() async throws {
    let (folder, url) = try Self.makeFile(Self.source)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    let tab = try #require(manager.tabs.first)
    let viewModel = try #require(manager.viewModel(for: tab.id))
    viewModel.flushMarkdownPreview = { viewModel.editorContent = "flushed" }

    try await manager.saveTab(id: tab.id)

    #expect(try Data(contentsOf: url) == Data("flushed".utf8))
  }

  @Test("Saving a SQL file tab without a flush hook writes its text unchanged")
  func saveWithoutFlushHook() async throws {
    let (folder, mdURL) = try Self.makeFile("")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = mdURL.deletingPathExtension().appendingPathExtension("sql")
    try Data("select 1".utf8).write(to: url)
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    let tab = try #require(manager.tabs.first)
    #expect(tab.documentType == .sqlFile)
    let viewModel = try #require(manager.viewModel(for: tab.id))
    #expect(viewModel.flushMarkdownPreview == nil)

    viewModel.editorContent = "select 2"
    try await manager.saveTab(id: tab.id)

    #expect(try Data(contentsOf: url) == Data("select 2".utf8))
  }

  @Test("newMarkdownFile appends a dirty untitled markdown note")
  func newMarkdownFile() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)

    let id = manager.newMarkdownFile()

    let tab = try #require(manager.tabs.last)
    #expect(tab.id == id)
    #expect(tab.documentType == .markdown)
    #expect(tab.title == "Untitled.md")
    #expect(tab.isDirty == true)
    #expect(tab.fileURL == nil)
    let viewModel = try #require(manager.viewModel(for: id))
    #expect(viewModel.viewMode == .markdown)
    #expect(viewModel.editorContent == "")
    #expect(manager.editorDocument(for: id)?.content == "")
    #expect(manager.activeTabId == id)
  }

  @Test("A saved, clean markdown tab can be revealed and moved to a new window")
  func savedTabActions() async throws {
    let (folder, url) = try Self.makeFile(Self.source)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)
    let id = try #require(manager.tabs.first?.id)

    #expect(manager.canRevealFile(tabId: id))
    #expect(manager.canMoveToNewWindow(tabId: id))

    manager.tabs[0].isDirty = true
    #expect(!manager.canMoveToNewWindow(tabId: id))
  }

  @Test("An untitled markdown note cannot move to a new window")
  func untitledCannotMove() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)

    let id = manager.newMarkdownFile()

    #expect(!manager.canRevealFile(tabId: id))
    #expect(!manager.canMoveToNewWindow(tabId: id))
  }

  @Test("Reopening a closed markdown tab restores it as markdown")
  func reopensAsMarkdown() async throws {
    let (folder, url) = try Self.makeFile(Self.source)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (manager, suite, name) = try Self.manager()
    defer { suite.removePersistentDomain(forName: name) }
    try await manager.openFile(url: url)

    manager.requestCloseTab(id: manager.tabs[0].id)
    #expect(manager.tabs.isEmpty)
    try await manager.reopenClosedTab()

    let tab = try #require(manager.tabs.first)
    #expect(tab.documentType == .markdown)
    #expect(tab.fileURL == url)
    let viewModel = try #require(manager.viewModel(for: tab.id))
    #expect(viewModel.viewMode == .markdown)
  }

  @Test("activeDocumentMode maps markdown, SQL file and notebook tabs")
  func activeDocumentMode() {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)

    manager.newMarkdownFile()
    #expect(manager.activeDocumentMode == .markdown)
    manager.newSQLFile()
    #expect(manager.activeDocumentMode == .editor)
    manager.newNotebook()
    #expect(manager.activeDocumentMode == .notebook)
  }

  @Test("Sidebar text insertion on a markdown note posts no cell insert")
  func insertTextIsNoOp() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let viewModel = try #require(manager.viewModel(for: manager.newMarkdownFile()))
    var posted = false
    let observer = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { _ in posted = true }
    defer { NotificationCenter.default.removeObserver(observer) }

    viewModel.insertTextIntoSelectedCell("users")

    #expect(!posted)
    #expect(viewModel.editorContent == "")
  }

  @Test("AI SQL insertion on a markdown note adds no cell and leaves the text")
  func insertAISQLIsNoOp() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let viewModel = try #require(manager.viewModel(for: manager.newMarkdownFile()))
    viewModel.notebook.cells[0].content = "select 1"
    viewModel.selectedCellId = viewModel.notebook.cells[0].id

    viewModel.insertAISQL("select 2")

    #expect(viewModel.notebook.cells.count == 1)
    #expect(viewModel.editorContent == "")
    #expect(viewModel.aiCurrentSQL == nil)
  }

  @Test("The New Markdown Note palette action appends a markdown tab")
  func paletteNewMarkdownNote() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)

    #expect(manager.paletteSources().actions.contains { $0.id == "new-markdown-file" })
    #expect(manager.perform(.action(id: "new-markdown-file", title: "New Markdown Note")))

    let tab = try #require(manager.tabs.last)
    #expect(tab.documentType == .markdown)
    #expect(manager.activeTabId == tab.id)
  }

  @Test("The Toggle Right Sidebar palette action does nothing on a markdown tab")
  func paletteRightSidebarIsNoOp() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.newMarkdownFile()
    let viewModel = try #require(manager.activeViewModel)

    #expect(!manager.perform(.action(id: "toggle-right-sidebar", title: "Toggle Right Sidebar")))
    #expect(!viewModel.isRightSidebarVisible)
  }

  @Test("Recent documents keep .md files and drop .txt files")
  func recentsKeepMarkdown() {
    let names = ["a.dblore", "b.sql", "c.md", "d.MD", "e.txt"]

    let kept = names.filter { RecentManager.isRecentDocument(URL(fileURLWithPath: "/tmp/\($0)")) }

    #expect(kept == ["a.dblore", "b.sql", "c.md", "d.MD"])
  }
}
