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
}
