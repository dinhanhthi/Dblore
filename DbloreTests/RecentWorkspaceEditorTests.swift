// Recent workspace edits from the welcome screen: name rewrite, file move, and an open manager.

import Foundation
import Testing

@testable import Dblore

@Suite("Recent workspace editor")
@MainActor
struct RecentWorkspaceEditorTests {
  @Test("Renaming JSON keeps the workspace id and tabs")
  func renamedDataKeepsIdentity() throws {
    let id = UUID()
    let tabID = UUID()
    let workspace = Workspace(
      id: id,
      name: "Old",
      tabs: [WorkspaceTabReference(id: tabID, documentType: .sqlFile, title: "q.sql")]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let renamed = try RecentWorkspaceEditor.renamedData(encoder.encode(workspace), name: "New")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Workspace.self, from: renamed)
    #expect(decoded.id == id)
    #expect(decoded.name == "New")
    #expect(decoded.tabs.map(\.id) == [tabID])
    #expect(decoded.tabs.map(\.title) == ["q.sql"])
  }

  @Test("A new path moves the file and leaves the source gone")
  func commitMovesFile() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("old.sqlws")
    let destination = folder.appendingPathComponent("moved.sqlws")
    try Data("before".utf8).write(to: source)

    try RecentWorkspaceEditor.commitFile(
      data: Data("after".utf8), from: source, to: destination)

    #expect(try String(contentsOf: destination, encoding: .utf8) == "after")
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  @Test("The same path is rewritten in place")
  func commitRewritesSameFile() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("same.sqlws")
    try Data("before".utf8).write(to: source)

    try RecentWorkspaceEditor.commitFile(data: Data("after".utf8), from: source, to: source)

    #expect(try String(contentsOf: source, encoding: .utf8) == "after")
  }

  @Test("An existing different file is not overwritten")
  func commitRefusesExistingDestination() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("old.sqlws")
    let destination = folder.appendingPathComponent("taken.sqlws")
    try Data("source".utf8).write(to: source)
    try Data("kept".utf8).write(to: destination)

    #expect(throws: RecentWorkspaceEditError.destinationExists) {
      try RecentWorkspaceEditor.commitFile(
        data: Data("after".utf8), from: source, to: destination)
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "source")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "kept")
  }

  @Test("A closed workspace keeps its recent place after a name and path change")
  func closedEditUpdatesRecentInPlace() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("old.sqlws")
    let destination = folder.appendingPathComponent("renamed.sqlws")
    let workspace = Workspace(name: "Old")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(workspace).write(to: source)

    let recents = try makeRecents()
    let other = WorkspaceHistoryEntry(
      fileURL: folder.appendingPathComponent("other.sqlws"), name: "Other")
    let entry = WorkspaceHistoryEntry(fileURL: source, name: "Old", tabCount: 2)
    recents.addWorkspace(other)
    recents.addWorkspace(entry)

    try RecentWorkspaceEditor.apply(
      entry: entry,
      name: "  Renamed  ",
      destination: destination,
      recents: recents,
      openWorkspaces: []
    )

    #expect(recents.recentWorkspaces.map(\.id) == [entry.id, other.id])
    #expect(recents.recentWorkspaces[0].name == "Renamed")
    #expect(recents.recentWorkspaces[0].fileURL == destination)
    #expect(recents.recentWorkspaces[0].tabCount == 2)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(Workspace.self, from: Data(contentsOf: destination))
    #expect(saved.name == "Renamed")
    #expect(saved.id == workspace.id)
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  @Test("An open workspace is saved from memory and keeps the typed name")
  func openEditUsesManager() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("open.sqlws")
    let destination = folder.appendingPathComponent("open-moved.sqlws")
    try Data("{}".utf8).write(to: source)

    var workspace = Workspace(name: "Old")
    workspace.fileURL = source
    let manager = WorkspaceManager(workspace: workspace, restoreTabs: false)
    let recents = try makeRecents()
    let entry = WorkspaceHistoryEntry(
      id: workspace.id, fileURL: source, name: "Old")
    recents.addWorkspace(entry)

    try RecentWorkspaceEditor.apply(
      entry: entry,
      name: "Kept",
      destination: destination,
      recents: recents,
      openWorkspaces: [manager]
    )

    #expect(manager.workspace.name == "Kept")
    #expect(manager.workspace.fileURL == destination)
    #expect(manager.isDirty == false)
    #expect(recents.recentWorkspaces.first?.name == "Kept")
    #expect(recents.recentWorkspaces.first?.fileURL == destination)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(Workspace.self, from: Data(contentsOf: destination))
    #expect(saved.name == "Kept")
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("recent-workspace-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func makeRecents() throws -> RecentManager {
    let name = "ace.thi.Dblore.tests.recent-workspace-edit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return RecentManager(defaults: defaults)
  }
}
