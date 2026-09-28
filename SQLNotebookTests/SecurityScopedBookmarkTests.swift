// SecurityScopedBookmarkTests.swift
// Security-scoped bookmarks: optional bookmark fields decode from old JSON, round-trip and are
// ignored by equality; bookmarks resolve to the same file; access tokens balance start/stop;
// the saved workspace carries the tab bookmarks.

import Foundation
import Testing
import os

@testable import SQLNotebook

@Suite("Security-scoped bookmarks")
@MainActor
struct SecurityScopedBookmarkTests {
  private static let entryID = UUID()
  private static let tabID = UUID()

  // MARK: - WorkspaceHistoryEntry

  @Test("Old WorkspaceHistoryEntry JSON without bookmark keys decodes to nil bookmarks")
  func entryOldJSONDecodesNil() throws {
    let json = """
      {"id":"\(Self.entryID.uuidString)","fileURL":"file:///tmp/a.sqlws","name":"A",
      "lastOpenedAt":0,"tabCount":2}
      """
    let entry = try JSONDecoder().decode(WorkspaceHistoryEntry.self, from: Data(json.utf8))
    #expect(entry.bookmark == nil)
    #expect(entry.folderBookmark == nil)
    #expect(entry.name == "A")
  }

  @Test("WorkspaceHistoryEntry with bookmarks round-trips through JSON")
  func entryRoundTrips() throws {
    var entry = WorkspaceHistoryEntry(
      fileURL: URL(fileURLWithPath: "/tmp/a.sqlws"), name: "A", bookmark: Data([1, 2, 3]))
    entry.folderBookmark = Data([4, 5])
    let decoded = try JSONDecoder().decode(
      WorkspaceHistoryEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded.bookmark == Data([1, 2, 3]))
    #expect(decoded.folderBookmark == Data([4, 5]))
  }

  @Test("WorkspaceHistoryEntry equality ignores bookmark bytes")
  func entryEqualityIgnoresBookmarks() {
    let date = Date()
    let url = URL(fileURLWithPath: "/tmp/a.sqlws")
    let lhs = WorkspaceHistoryEntry(
      id: Self.entryID, fileURL: url, name: "A", lastOpenedAt: date, bookmark: Data([1]))
    var rhs = WorkspaceHistoryEntry(
      id: Self.entryID, fileURL: url, name: "A", lastOpenedAt: date, bookmark: Data([2]))
    rhs.folderBookmark = Data([3])
    #expect(lhs == rhs)
    let renamed = WorkspaceHistoryEntry(
      id: Self.entryID, fileURL: url, name: "B", lastOpenedAt: date, bookmark: Data([1]))
    #expect(lhs != renamed)
  }

  // MARK: - WorkspaceTabReference

  @Test("Old WorkspaceTabReference JSON without a bookmark key decodes to nil")
  func tabOldJSONDecodesNil() throws {
    let json = """
      {"id":"\(Self.tabID.uuidString)","fileURL":"file:///tmp/a.sql","documentType":"sqlFile",
      "title":"a.sql"}
      """
    let ref = try JSONDecoder().decode(WorkspaceTabReference.self, from: Data(json.utf8))
    #expect(ref.bookmark == nil)
    #expect(ref.title == "a.sql")
  }

  @Test("WorkspaceTabReference with a bookmark round-trips and equality ignores it")
  func tabRoundTripsAndEqualityIgnoresBookmark() throws {
    var ref = WorkspaceTabReference(
      id: Self.tabID, fileURL: URL(fileURLWithPath: "/tmp/a.sql"), documentType: .sqlFile,
      title: "a.sql")
    let plain = ref
    ref.bookmark = Data([9, 8])
    let decoded = try JSONDecoder().decode(
      WorkspaceTabReference.self, from: JSONEncoder().encode(ref))
    #expect(decoded.bookmark == Data([9, 8]))
    #expect(ref == plain)
  }

  // MARK: - SecurityScopedAccess

  @Test("makeBookmark and resolve return the same file, not stale")
  func bookmarkResolvesToSameFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bookmark-\(UUID().uuidString).sql")
    try Data("select 1".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let data = try SecurityScopedAccess.makeBookmark(for: url)
    let resolved = try SecurityScopedAccess.resolve(data)
    #expect(
      resolved.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
    #expect(resolved.isStale == false)
  }

  @Test("A granted access token stops exactly once (release, then deinit)")
  func grantedTokenStopsOnce() {
    let starts = OSAllocatedUnfairLock(initialState: 0)
    let stops = OSAllocatedUnfairLock(initialState: 0)
    var token: SecurityScopedAccessToken? = SecurityScopedAccessToken(
      url: URL(fileURLWithPath: "/tmp/a.sql"),
      start: { _ in
        starts.withLock { $0 += 1 }
        return true
      },
      stop: { _ in stops.withLock { $0 += 1 } })
    #expect(token?.isGranted == true)
    #expect(starts.withLock { $0 } == 1)
    token?.release()
    token?.release()
    token = nil
    #expect(stops.withLock { $0 } == 1)
  }

  @Test("A granted token stops on deinit when never released")
  func grantedTokenStopsOnDeinit() {
    let stops = OSAllocatedUnfairLock(initialState: 0)
    var token: SecurityScopedAccessToken? = SecurityScopedAccessToken(
      url: URL(fileURLWithPath: "/tmp/a.sql"), start: { _ in true },
      stop: { _ in stops.withLock { $0 += 1 } })
    #expect(token != nil)
    token = nil
    #expect(stops.withLock { $0 } == 1)
  }

  @Test("A denied access token never calls stop")
  func deniedTokenNeverStops() {
    let stops = OSAllocatedUnfairLock(initialState: 0)
    var token: SecurityScopedAccessToken? = SecurityScopedAccessToken(
      url: URL(fileURLWithPath: "/tmp/a.sql"), start: { _ in false },
      stop: { _ in stops.withLock { $0 += 1 } })
    #expect(token?.isGranted == false)
    token?.release()
    token = nil
    #expect(stops.withLock { $0 } == 0)
  }

  // MARK: - Saved workspace

  @Test("The saved workspace JSON carries the tab bookmarks when present")
  func savedWorkspaceContainsTabBookmarks() throws {
    let withFile = WorkspaceTabReference(
      id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/a.sql"), documentType: .sqlFile,
      title: "a.sql")
    let withoutBookmark = WorkspaceTabReference(
      id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/b.sql"), documentType: .sqlFile,
      title: "b.sql")
    let manager = WorkspaceManager(
      workspace: Workspace(tabs: [withFile, withoutBookmark]), restoreTabs: true)
    manager.tabBookmarks[withFile.id] = Data([7, 7, 7])

    let data = try manager.encodedWorkspaceData()
    let decoded = try JSONDecoder.iso8601.decode(Workspace.self, from: data)
    #expect(decoded.tabs.map(\.id) == [withFile.id, withoutBookmark.id])
    #expect(decoded.tabs[0].bookmark == Data([7, 7, 7]))
    #expect(decoded.tabs[1].bookmark == nil)
    #expect(String(decoding: data, as: UTF8.self).contains(Data([7, 7, 7]).base64EncodedString()))
  }
}

extension JSONDecoder {
  fileprivate static var iso8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
