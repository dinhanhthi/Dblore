// WorkspaceFavoritesTests.swift
// Favorites model helpers, workspace JSON persistence and the WorkspaceManager favorites API.

import Foundation
import Testing

@testable import Dblore

@Suite("WorkspaceFavorites model")
@MainActor
struct WorkspaceFavoritesModelTests {
  @Test("addFolder appends and returns the folder")
  func addFolder() {
    var favorites = WorkspaceFavorites.empty
    let folder = favorites.addFolder(name: "Reports")
    #expect(favorites.folders == [folder])
    #expect(folder.name == "Reports")
  }

  @Test("renameFolder changes only the matching folder")
  func renameFolder() {
    var favorites = WorkspaceFavorites.empty
    let a = favorites.addFolder(name: "A")
    let b = favorites.addFolder(name: "B")
    favorites.renameFolder(id: a.id, name: "A2")
    #expect(favorites.folders.map(\.name) == ["A2", "B"])
    favorites.renameFolder(id: UUID(), name: "X")
    #expect(favorites.folders.map(\.id) == [a.id, b.id])
    #expect(favorites.folders.map(\.name) == ["A2", "B"])
  }

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

  @Test("deleteItem removes only the matching item")
  func deleteItem() {
    var favorites = WorkspaceFavorites.empty
    let keep = FavoriteStatement(name: "keep", sql: "SELECT 1")
    let drop = FavoriteStatement(name: "drop", sql: "SELECT 2")
    favorites.upsert(keep)
    favorites.upsert(drop)
    favorites.deleteItem(id: drop.id)
    #expect(favorites.items == [keep])
  }

  @Test("items(in:) returns root items for nil and folder items for a folder id")
  func itemsInFolder() {
    var favorites = WorkspaceFavorites.empty
    let folder = favorites.addFolder(name: "F")
    let root = FavoriteStatement(name: "root", sql: "SELECT 1")
    let nested = FavoriteStatement(name: "nested", sql: "SELECT 2", folderId: folder.id)
    favorites.upsert(root)
    favorites.upsert(nested)
    #expect(favorites.items(in: nil) == [root])
    #expect(favorites.items(in: folder.id) == [nested])
    #expect(favorites.items(in: UUID()).isEmpty)
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

  @Test("resolvedFolderId is nil for nil or unknown ids and the id for a known folder")
  func resolvedFolderId() {
    var favorites = WorkspaceFavorites.empty
    let folder = favorites.addFolder(name: "F")
    #expect(favorites.resolvedFolderId(nil) == nil)
    #expect(favorites.resolvedFolderId(UUID()) == nil)
    #expect(favorites.resolvedFolderId(folder.id) == folder.id)
  }

  @Test("contains(itemId:) tells existing items from new ones")
  func containsItemId() {
    var favorites = WorkspaceFavorites.empty
    let item = FavoriteStatement(name: "q", sql: "SELECT 1")
    favorites.upsert(item)
    #expect(favorites.contains(itemId: item.id))
    #expect(!favorites.contains(itemId: UUID()))
  }

  @Test("nextDefaultName starts at 1 when empty")
  func defaultNameEmpty() {
    #expect(WorkspaceFavorites.empty.nextDefaultName() == "Favorite statement 1")
  }

  @Test("nextDefaultName skips numbers already used")
  func defaultNameSkipsUsed() {
    let favorites = WorkspaceFavorites(
      items: [FavoriteStatement(name: "Favorite statement 2", sql: "SELECT 1")])
    #expect(favorites.nextDefaultName() == "Favorite statement 3")
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

  @Test("saveFavorite gives a blank name a default name")
  func blankNameGetsDefault() {
    let manager = makeManager()
    manager.saveFavorite(FavoriteStatement(name: "   ", sql: "SELECT 1"))
    #expect(manager.workspace.favorites.items.map(\.name) == ["Favorite statement 1"])
  }

  @Test("saveFavorite trims the name and marks the workspace dirty")
  func trimsNameAndMarksDirty() {
    let manager = makeManager()
    #expect(manager.isDirty == false)
    manager.saveFavorite(FavoriteStatement(name: "  My query \n", sql: "SELECT 1"))
    #expect(manager.workspace.favorites.items.map(\.name) == ["My query"])
    #expect(manager.isDirty)
  }

  @Test("deleteFavorite removes the item and marks dirty")
  func deleteFavorite() {
    let manager = makeManager()
    let item = FavoriteStatement(name: "q", sql: "SELECT 1")
    manager.saveFavorite(item)
    manager.isDirty = false
    manager.deleteFavorite(id: item.id)
    #expect(manager.workspace.favorites.items.isEmpty)
    #expect(manager.isDirty)
  }

  @Test("createFolder ignores an empty name")
  func createFolderIgnoresEmpty() {
    let manager = makeManager()
    manager.createFolder(name: "  ")
    #expect(manager.workspace.favorites.folders.isEmpty)
    #expect(manager.isDirty == false)

    manager.createFolder(name: " Reports ")
    #expect(manager.workspace.favorites.folders.map(\.name) == ["Reports"])
    #expect(manager.isDirty)
  }

  @Test("renameFolder trims, ignores a blank name and marks dirty")
  func renameFolderTrimsAndIgnoresBlank() throws {
    let manager = makeManager()
    manager.createFolder(name: "F")
    let folder = try #require(manager.workspace.favorites.folders.first)
    manager.isDirty = false

    manager.renameFolder(id: folder.id, name: "   ")
    #expect(manager.workspace.favorites.folders.map(\.name) == ["F"])
    #expect(manager.isDirty == false)

    manager.renameFolder(id: folder.id, name: "  Reports \n")
    #expect(manager.workspace.favorites.folders.map(\.name) == ["Reports"])
    #expect(manager.isDirty)
  }

  @Test("insertFavorite is a no-op without an active view model")
  func insertFavoriteWithoutViewModel() {
    let manager = makeManager()
    #expect(manager.activeViewModel == nil)
    manager.insertFavorite(FavoriteStatement(name: "q", sql: "SELECT 1"))
    #expect(manager.workspace.favorites.items.isEmpty)
  }

  @Test("deleteFolder moves its favorites to the root")
  func deleteFolderMovesToRoot() throws {
    let manager = makeManager()
    manager.createFolder(name: "F")
    let folder = try #require(manager.workspace.favorites.folders.first)
    let item = FavoriteStatement(name: "q", sql: "SELECT 1", folderId: folder.id)
    manager.saveFavorite(item)

    manager.deleteFolder(id: folder.id)

    #expect(manager.workspace.favorites.folders.isEmpty)
    #expect(manager.workspace.favorites.items(in: nil).map(\.id) == [item.id])
  }
}
