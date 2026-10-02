// TabPinPersistenceTests.swift
// Pin state of tabs: round-trips through the .sqlws JSON, legacy files decode to unpinned, and
// restored tabs keep pinned ones first even for out-of-order files. Temp files only.

import Foundation
import Testing

@testable import Dblore

@Suite("Tab pin persistence")
@MainActor
struct TabPinPersistenceTests {
  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  @Test("isPinned round-trips through encode and decode")
  func roundTrip() throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    manager.tabs = [
      TabItem(documentType: .sqlFile, title: "a.sql", isPinned: true),
      TabItem(documentType: .sqlFile, title: "b.sql", isPinned: true),
      TabItem(documentType: .sqlFile, title: "c.sql"),
    ]
    let saved = try Self.decoder().decode(
      Workspace.self, from: manager.encodedWorkspaceData())
    #expect(saved.tabs.map(\.title) == ["a.sql", "b.sql", "c.sql"])
    #expect(saved.tabs.map { $0.isPinned ?? false } == [true, true, false])
  }

  @Test("Legacy tab JSON without isPinned decodes to unpinned")
  func legacyDecodes() throws {
    let json = """
      {"id":"\(UUID().uuidString)","documentType":"sqlFile","title":"q.sql"}
      """
    let ref = try JSONDecoder().decode(WorkspaceTabReference.self, from: Data(json.utf8))
    #expect(ref.isPinned == nil)
    #expect(ref.toTabItem().isPinned == false)
  }

  @Test("Restored tabs list pinned ones first, keeping relative order")
  func restoredPinnedFirst() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("pin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var refs: [WorkspaceTabReference] = []
    for (name, pinned) in [("a", false), ("b", true), ("c", false), ("d", true)] {
      let url = folder.appendingPathComponent("\(name).sql")
      try Data("select 1".utf8).write(to: url)
      refs.append(
        WorkspaceTabReference(
          fileURL: url, documentType: .sqlFile, title: url.lastPathComponent,
          isPinned: pinned ? true : nil))
    }
    let workspaceURL = folder.appendingPathComponent("ws.sqlws")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Workspace(tabs: refs)).write(to: workspaceURL)

    var hooks = SecurityScopedAccessHooks()
    hooks.makeBookmark = { _ in nil }
    let manager = try await WorkspaceManager.load(from: workspaceURL, hooks: hooks)
    #expect(manager.tabs.map(\.title) == ["b.sql", "d.sql", "a.sql", "c.sql"])
    #expect(manager.tabs.map(\.isPinned) == [true, true, false, false])
  }
}
