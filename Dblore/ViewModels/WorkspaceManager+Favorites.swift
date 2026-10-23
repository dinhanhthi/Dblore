//
//  WorkspaceManager+Favorites.swift
//  Dblore
//
//  Favorite statements and folders API for the left sidebar Favorite tab
//

import Foundation

// MARK: - Modal Route

/// Favorite modal to present (nil payload = create)
enum FavoriteModalRoute: Identifiable {
  case favorite(FavoriteStatement?)
  case folder(FavoriteFolder?)

  var id: String {
    switch self {
    case .favorite(let favorite): return "favorite-\(favorite?.id.uuidString ?? "new")"
    case .folder(let folder): return "folder-\(folder?.id.uuidString ?? "new")"
    }
  }

  var isFolder: Bool {
    if case .folder = self { return true }
    return false
  }
}

// MARK: - Favorites

/// Favorites an import added, and those already in the folder.
struct FavoritesImportResult: Equatable, Sendable {
  var added: Int
  var skipped: Int
}

extension WorkspaceManager {
  /// Saves a favorite (create or update); an empty name gets a default one
  func saveFavorite(_ favorite: FavoriteStatement) {
    var favorite = favorite
    favorite.name = favorite.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if favorite.name.isEmpty {
      favorite.name = workspace.favorites.nextDefaultName()
    }
    workspace.favorites.upsert(favorite)
    markDirtyAndScheduleAutoSave()
  }

  func deleteFavorite(id: UUID) {
    workspace.favorites.deleteItem(id: id)
    markDirtyAndScheduleAutoSave()
  }

  func createFolder(name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    workspace.favorites.addFolder(name: name)
    markDirtyAndScheduleAutoSave()
  }

  func renameFolder(id: UUID, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    workspace.favorites.renameFolder(id: id, name: name)
    markDirtyAndScheduleAutoSave()
  }

  /// Deletes the folder; its favorites move to the root
  func deleteFolder(id: UUID) {
    workspace.favorites.deleteFolder(id: id)
    markDirtyAndScheduleAutoSave()
  }

  /// Adds favorites read from a Dblore export file to the folder `folderName`, reusing a folder
  /// of that name. A favorite whose name and SQL are already in the folder is skipped (a blank
  /// name, which gets a default one, matches on its SQL). Nothing from the file is kept but each
  /// name, SQL text and the folder name.
  @discardableResult
  func importFavorites(
    _ favorites: [DbloreConnectionFile.Favorite], folderName: String
  )
    -> FavoritesImportResult
  {
    guard !favorites.isEmpty else { return FavoritesImportResult(added: 0, skipped: 0) }
    let reused = workspace.favorites.folders.first { $0.name == folderName }
    let folder = reused ?? workspace.favorites.addFolder(name: folderName)
    let existing = workspace.favorites.items.filter { $0.folderId == folder.id }
    var names = Set(existing.map { [$0.name, $0.sql] })
    var sqls = Set(existing.map(\.sql))
    var result = FavoritesImportResult(added: 0, skipped: 0)
    // File names stay on one line: no control, format or line separator characters.
    let removed = CharacterSet.controlCharacters.union(.newlines)
    for favorite in favorites {
      let line = String(favorite.name.unicodeScalars.filter { !removed.contains($0) })
      let name = String(line.trimmingCharacters(in: .whitespaces).prefix(200))
      let isNew =
        name.isEmpty ? !sqls.contains(favorite.sql) : !names.contains([name, favorite.sql])
      guard isNew else {
        result.skipped += 1
        continue
      }
      let statement = FavoriteStatement(
        name: name.isEmpty ? workspace.favorites.nextDefaultName() : name, sql: favorite.sql,
        folderId: folder.id)
      workspace.favorites.upsert(statement)
      names.insert([statement.name, statement.sql])
      sqls.insert(statement.sql)
      result.added += 1
    }
    if reused == nil || result.added > 0 { markDirtyAndScheduleAutoSave() }
    return result
  }

  /// Inserts the favorite SQL into the selected cell of the active view model
  func insertFavorite(_ favorite: FavoriteStatement) {
    activeViewModel?.insertTextIntoSelectedCell(favorite.sql)
  }
}
