// WorkspaceFavoritesTests.swift
// Favorites model helpers, workspace JSON persistence and the WorkspaceManager favorites API.

import Foundation
import Testing

@testable import Dblore

@Suite("WorkspaceFavorites model")
@MainActor
struct WorkspaceFavoritesModelTests {
  @Test("deleteFolder moves its items to root and leaves other folders untouched")
  func deleteFolderMovesItemsToRoot() {
    var favorites = WorkspaceFavorites.empty
    let a = favorites.addFolder(name: "A")
    let b = favorites.addFolder(name: "B")
    let inA = FavoriteStatement(name: "one", sql: "SELECT 1", folderId: a.id)
    let inB = FavoriteStatement(name: "two", sql: "SELECT 2", folderId: b.id)
    favorites.upsert(inA)
    favorites.upsert(inB)

    favorites.deleteFolder(id: a.id)

    #expect(favorites.folders == [b])
    #expect(favorites.items.count == 2)
    #expect(favorites.items.first { $0.id == inA.id }?.folderId == nil)
    #expect(favorites.items.first { $0.id == inB.id }?.folderId == b.id)
  }

  @Test("upsert inserts a new item and replaces an existing one")
  func upsertInsertVsUpdate() {
    var favorites = WorkspaceFavorites.empty
    var item = FavoriteStatement(name: "q", sql: "SELECT 1")
    favorites.upsert(item)
    #expect(favorites.items == [item])

    item.name = "renamed"
    item.sql = "SELECT 2"
    favorites.upsert(item)
    #expect(favorites.items.count == 1)
    #expect(favorites.items[0] == item)
  }

  @Test("rootItems keeps items with no folder or an unknown folder, in order")
  func rootItems() {
    var favorites = WorkspaceFavorites.empty
    let folder = favorites.addFolder(name: "F")
    let noFolder = FavoriteStatement(name: "a", sql: "SELECT 1")
    let unknown = FavoriteStatement(name: "b", sql: "SELECT 2", folderId: UUID())
    let nested = FavoriteStatement(name: "c", sql: "SELECT 3", folderId: folder.id)
    favorites.upsert(noFolder)
    favorites.upsert(nested)
    favorites.upsert(unknown)
    #expect(favorites.rootItems == [noFolder, unknown])
  }

}

@Suite("Workspace favorites persistence")
@MainActor
struct WorkspaceFavoritesPersistenceTests {
  private func encode(_ workspace: Workspace) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(workspace)
  }

  private func decode(_ data: Data) throws -> Workspace {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Workspace.self, from: data)
  }

  @Test("favorites survive a JSON round trip")
  func roundTrip() throws {
    var favorites = WorkspaceFavorites.empty
    let folder = favorites.addFolder(name: "F")
    favorites.upsert(FavoriteStatement(name: "a", sql: "SELECT 1", folderId: folder.id))
    favorites.upsert(FavoriteStatement(name: "b", sql: "SELECT 2"))
    let workspace = Workspace(favorites: favorites)

    let decoded = try decode(try encode(workspace))

    #expect(decoded.favorites == favorites)
  }

  @Test("a workspace JSON without a favorites key decodes to empty favorites")
  func missingFavoritesKey() throws {
    var favorites = WorkspaceFavorites.empty
    favorites.upsert(FavoriteStatement(name: "a", sql: "SELECT 1"))
    let data = try encode(Workspace(favorites: favorites))
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["favorites"] != nil)
    json.removeValue(forKey: "favorites")
    let stripped = try JSONSerialization.data(withJSONObject: json)

    let decoded = try decode(stripped)

    #expect(decoded.favorites == .empty)
  }
}

@Suite("WorkspaceManager favorites")
@MainActor
struct WorkspaceManagerFavoritesTests {
  private func makeManager() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(), restoreTabs: false)
  }

  @Test("saveFavorite trims the name and marks the workspace dirty")
  func trimsNameAndMarksDirty() {
    let manager = makeManager()
    #expect(manager.isDirty == false)
    manager.saveFavorite(FavoriteStatement(name: "  My query \n", sql: "SELECT 1"))
    #expect(manager.workspace.favorites.items.map(\.name) == ["My query"])
    #expect(manager.isDirty)
  }

}
