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
}

// MARK: - Favorites

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

  /// Inserts the favorite SQL into the selected cell of the active view model
  func insertFavorite(_ favorite: FavoriteStatement) {
    activeViewModel?.insertTextIntoSelectedCell(favorite.sql)
  }
}
