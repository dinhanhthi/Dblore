//
//  WorkspaceFavorites.swift
//  SQLNotebook
//

import Foundation

/// A folder grouping favorite statements in the left sidebar.
struct FavoriteFolder: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String

  init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
}

/// A saved SQL statement, optionally inside a folder (nil folderId = root).
struct FavoriteStatement: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var sql: String
  var folderId: UUID?

  init(id: UUID = UUID(), name: String, sql: String, folderId: UUID? = nil) {
    self.id = id
    self.name = name
    self.sql = sql
    self.folderId = folderId
  }
}

/// Favorite folders and statements stored in the workspace .sqlws file.
struct WorkspaceFavorites: Codable, Equatable, Sendable {
  var folders: [FavoriteFolder]
  var items: [FavoriteStatement]

  static let empty = WorkspaceFavorites(folders: [], items: [])

  init(folders: [FavoriteFolder] = [], items: [FavoriteStatement] = []) {
    self.folders = folders
    self.items = items
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    folders = try container.decodeIfPresent([FavoriteFolder].self, forKey: .folders) ?? []
    items = try container.decodeIfPresent([FavoriteStatement].self, forKey: .items) ?? []
  }

  // MARK: - Mutations

  /// Appends a new folder and returns it
  @discardableResult
  mutating func addFolder(name: String) -> FavoriteFolder {
    let folder = FavoriteFolder(name: name)
    folders.append(folder)
    return folder
  }

  mutating func renameFolder(id: UUID, name: String) {
    guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
    folders[index].name = name
  }

  /// Removes the folder; its items move to the root
  mutating func deleteFolder(id: UUID) {
    folders.removeAll { $0.id == id }
    for index in items.indices where items[index].folderId == id {
      items[index].folderId = nil
    }
  }

  /// Replaces the item with the same id, otherwise appends it
  mutating func upsert(_ item: FavoriteStatement) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
    }
  }

  mutating func deleteItem(id: UUID) {
    items.removeAll { $0.id == id }
  }

  // MARK: - Queries

  /// Items in the given folder (nil = root)
  func items(in folderId: UUID?) -> [FavoriteStatement] {
    items.filter { $0.folderId == folderId }
  }

  /// "Favorite statement N" with the smallest N >= items.count + 1 not used by an item
  func nextDefaultName() -> String {
    let used = Set(items.map(\.name))
    var number = items.count + 1
    while used.contains("Favorite statement \(number)") {
      number += 1
    }
    return "Favorite statement \(number)"
  }
}
