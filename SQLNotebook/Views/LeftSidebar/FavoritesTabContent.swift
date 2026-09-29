//
//  FavoritesTabContent.swift
//  SQLNotebook
//
//  Favorite tab of the left sidebar: saved SQL statements grouped in folders
//

import SwiftUI

struct FavoritesTabContent: View {
  @Bindable var workspaceManager: WorkspaceManager

  @State private var expandedFolders: Set<UUID> = []
  @State private var selectedItemId: UUID?

  private var favorites: WorkspaceFavorites { workspaceManager.workspace.favorites }

  /// Items with no folder, or pointing at a folder that no longer exists
  private var rootItems: [FavoriteStatement] {
    let folderIds = Set(favorites.folders.map(\.id))
    return favorites.items.filter { $0.folderId.map { !folderIds.contains($0) } ?? true }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      if favorites.folders.isEmpty && favorites.items.isEmpty {
        emptyState
      } else {
        list
      }
    }
    .confirmationDialog(
      "Delete favorite?",
      isPresented: Binding(
        get: { workspaceManager.favoriteToDelete != nil },
        set: { if !$0 { workspaceManager.favoriteToDelete = nil } }
      ),
      presenting: workspaceManager.favoriteToDelete
    ) { item in
      Button("Delete", role: .destructive) { workspaceManager.deleteFavorite(id: item.id) }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text("\"\(item.name)\" will be removed from your favorites.")
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Spacer()

      Button {
        workspaceManager.favoriteModal = .folder(nil)
      } label: {
        Image(systemName: "folder.badge.plus")
      }
      .help("New Folder")

      Button {
        workspaceManager.favoriteModal = .favorite(nil)
      } label: {
        Image(systemName: "plus")
      }
      .help("New Favorite")
    }
    .buttonStyle(.plain)
    .foregroundColor(.foregroundMuted)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "star")
        .font(.system(size: 24))
        .foregroundColor(.foregroundSubtle)

      Text("No favorites yet")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(favorites.folders) { folder in
          let isExpanded = expandedFolders.contains(folder.id)
          FolderRowView(
            folder: folder,
            isExpanded: isExpanded,
            onToggle: { toggle(folder.id) },
            onRename: { workspaceManager.favoriteModal = .folder(folder) },
            onNewFavorite: {
              workspaceManager.favoriteModal = .favorite(
                FavoriteStatement(name: "", sql: "", folderId: folder.id))
            },
            onDelete: { workspaceManager.deleteFolder(id: folder.id) }
          )

          if isExpanded {
            ForEach(favorites.items(in: folder.id)) { item in
              row(for: item, indented: true)
            }
          }
        }

        ForEach(rootItems) { item in
          row(for: item, indented: false)
        }
      }
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func row(for item: FavoriteStatement, indented: Bool) -> some View {
    FavoriteRowView(
      item: item,
      isSelected: selectedItemId == item.id,
      indented: indented,
      onSelect: { selectedItemId = item.id },
      onInsert: { workspaceManager.insertFavorite(item) },
      onEdit: { workspaceManager.favoriteModal = .favorite(item) },
      onDelete: { workspaceManager.favoriteToDelete = item }
    )
  }

  private func toggle(_ id: UUID) {
    if expandedFolders.contains(id) {
      expandedFolders.remove(id)
    } else {
      expandedFolders.insert(id)
    }
  }
}
