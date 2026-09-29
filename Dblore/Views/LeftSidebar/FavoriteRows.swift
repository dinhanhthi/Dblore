//
//  FavoriteRows.swift
//  Dblore
//
//  Row views for the Favorite sidebar tab: folders and saved statements
//

import SwiftUI

// MARK: - Folder Row View

struct FolderRowView: View {
  let folder: FavoriteFolder
  let isExpanded: Bool
  let onToggle: () -> Void
  var onRename: () -> Void = {}
  var onNewFavorite: () -> Void = {}
  var onDelete: () -> Void = {}

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))

      Image(systemName: "folder")
        .font(.system(size: 12))
        .foregroundColor(.accent)

      Text(folder.name)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)

      Spacer()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture { onToggle() }
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
    )
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("Rename") { onRename() }
      Button("New Favorite in Folder") { onNewFavorite() }
      Divider()
      Button("Delete Folder", role: .destructive) { onDelete() }
    }
  }
}

// MARK: - Favorite Row View

struct FavoriteRowView: View {
  let item: FavoriteStatement
  let isSelected: Bool
  var indented: Bool = false
  let onSelect: () -> Void
  var onInsert: () -> Void = {}
  var onEdit: () -> Void = {}
  var onDelete: () -> Void = {}

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "star")
        .font(.system(size: 12))
        .foregroundColor(.accent)

      Text(item.name)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)

      Spacer()
    }
    .padding(.leading, Spacing.md + (indented ? Spacing.lg : 0) + 12 + Spacing.xs)
    .padding(.trailing, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { onInsert() }
    .onTapGesture { onSelect() }
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(
          isSelected
            ? Color.accent.opacity(0.15)
            : (isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear))
    )
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("Insert") { onInsert() }
      Button("Edit") { onEdit() }
      Divider()
      Button("Delete", role: .destructive) { onDelete() }
    }
  }
}
