// LineBookmarkPersistenceTests.swift
// The .sqlws contract of SQL editor line bookmarks: a tab saved before them decodes, a saved
// anchor (fixed bytes, as written by an earlier launch) finds its line again, and marks survive
// a save and reopen. Temp files only.

import Foundation
import Testing

@testable import Dblore

@Suite("Line bookmark persistence")
@MainActor
struct LineBookmarkPersistenceTests {
  /// Anchor of "select 2;" written by an earlier launch (SHA-256 hex prefix)
  private static let selectTwoAnchor = "b1bd6d0bfa373a44"

  @Test("A tab saved before bookmarks decodes without them")
  func legacyTabDecodes() throws {
    let json = """
      {"id":"\(UUID().uuidString)","documentType":"sqlFile","title":"q.sql"}
      """
    let ref = try JSONDecoder().decode(WorkspaceTabReference.self, from: Data(json.utf8))
    #expect(ref.lineBookmarks == nil)
  }

  @Test("A saved anchor finds its line after the file changed, and marks survive save and reopen")
  func fixtureAnchorAndRoundTrip() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("line-bookmarks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // Saved on line 1; the file now has two lines above it
    let fileURL = folder.appendingPathComponent("q.sql")
    try Data("-- note\nselect 1;\nselect 2;\n".utf8).write(to: fileURL)
    let tabId = UUID()
    let json = """
      {"id":"\(tabId.uuidString)","documentType":"sqlFile","title":"q.sql",
       "fileURL":"\(fileURL.absoluteString)",
       "lineBookmarks":[{"line":1,"anchor":"\(Self.selectTwoAnchor)"}]}
      """
    let ref = try JSONDecoder().decode(WorkspaceTabReference.self, from: Data(json.utf8))
    let workspaceURL = folder.appendingPathComponent("ws.sqlws")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Workspace(tabs: [ref])).write(to: workspaceURL)

    var hooks = SecurityScopedAccessHooks()
    hooks.makeBookmark = { _ in nil }
    let manager = try await WorkspaceManager.load(from: workspaceURL, hooks: hooks)
    let viewModel = try #require(manager.viewModel(for: tabId))
    #expect(viewModel.lineBookmarks.lines == [3])

    // Mark line 1 too, save, reopen
    viewModel.toggleLineBookmark(line: 1)
    try manager.encodedWorkspaceData().write(to: workspaceURL)
    let reopened = try await WorkspaceManager.load(from: workspaceURL, hooks: hooks)
    #expect(reopened.viewModel(for: tabId)?.lineBookmarks.lines == [1, 3])
  }
}
