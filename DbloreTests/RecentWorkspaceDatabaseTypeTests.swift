// RecentWorkspaceDatabaseTypeTests.swift
// A recent workspace row remembers its connection's database type for the welcome badge.

import Foundation
import Testing

@testable import Dblore

@Suite("Recent workspace database type")
@MainActor
struct RecentWorkspaceDatabaseTypeTests {
  @Test("An entry made from a workspace keeps its connection's database type")
  func fromWorkspaceKeepsType() throws {
    var workspace = Workspace(name: "A")
    workspace.fileURL = URL(fileURLWithPath: "/tmp/a.sqlws")
    workspace.connectionConfig = ConnectionConfig(databaseType: .mysql)
    let entry = try #require(WorkspaceHistoryEntry.from(workspace))
    #expect(entry.databaseType == .mysql)

    workspace.connectionConfig = nil
    #expect(WorkspaceHistoryEntry.from(workspace)?.databaseType == nil)
  }

  @Test("Old JSON without a database type decodes to nil")
  func oldJSONDecodesNil() throws {
    let json = """
      {"id":"\(UUID().uuidString)","fileURL":"file:///tmp/a.sqlws","name":"A",
      "lastOpenedAt":0,"tabCount":0}
      """
    let entry = try JSONDecoder().decode(WorkspaceHistoryEntry.self, from: Data(json.utf8))
    #expect(entry.databaseType == nil)
  }

  @Test("The database type round-trips and survives an edit")
  func typeRoundTripsAndSurvivesEdit() throws {
    let entry = WorkspaceHistoryEntry(
      fileURL: URL(fileURLWithPath: "/tmp/a.sqlws"), name: "A", databaseType: .mongodb)
    let decoded = try JSONDecoder().decode(
      WorkspaceHistoryEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded.databaseType == .mongodb)
    let edited = entry.edited(
      name: "B", fileURL: URL(fileURLWithPath: "/tmp/b.sqlws"), bookmark: nil)
    #expect(edited.databaseType == .mongodb)
  }
}
