//
//  SidebarFolderLayout.swift
//  Dblore
//
//  Splits the Public tab's tables and views into their folders (`SidebarFolderStore`) and the
//  ungrouped rest, in one pass over the rows and the folders' members.
//

import Foundation

/// A table or view row the sidebar can list in a folder
protocol SidebarFolderItem {
  /// The schema the row belongs to
  var folderSchema: String { get }
  /// `SidebarFolder.member(schema:name:)` of the row
  var folderMember: String { get }
}

/// Folders with their rows, and the rows no folder lists
struct SidebarFolderLayout<Table: SidebarFolderItem, View: SidebarFolderItem> {
  /// A folder and its listed rows (members no row has are left out)
  struct Group: Identifiable {
    let folder: SidebarFolder
    let tables: [Table]
    let views: [View]
    var id: UUID { folder.id }
    var count: Int { tables.count + views.count }
  }

  /// A row's schema and member
  private struct Key: Hashable {
    let schema: String
    let member: String
  }

  let groups: [Group]
  /// Rows no folder lists
  let tables: [Table]
  let views: [View]

  /// `folders` in display order. A row sits in the first folder of its schema listing it; rows
  /// keep their order. While `isFiltering`, a folder without a row is left out.
  static func build(
    folders: [SidebarFolder], tables: [Table], views: [View], isFiltering: Bool
  ) -> Self {
    // Row indices by schema and member: tables first, then views
    var rowsByKey: [Key: [Int]] = [:]
    for (index, table) in tables.enumerated() {
      rowsByKey[Key(schema: table.folderSchema, member: table.folderMember), default: []]
        .append(index)
    }
    for (index, view) in views.enumerated() {
      rowsByKey[Key(schema: view.folderSchema, member: view.folderMember), default: []]
        .append(tables.count + index)
    }

    // A member taken by a folder is not taken again by a later one
    var owner = [Int?](repeating: nil, count: tables.count + views.count)
    var claimed: Set<Key> = []
    for (folderIndex, folder) in folders.enumerated() {
      var taken: [Key] = []
      for member in folder.members {
        let key = Key(schema: folder.schema, member: member)
        guard !claimed.contains(key), let rows = rowsByKey[key] else { continue }
        for row in rows { owner[row] = folderIndex }
        taken.append(key)
      }
      claimed.formUnion(taken)
    }

    var folderTables = [[Table]](repeating: [], count: folders.count)
    var folderViews = [[View]](repeating: [], count: folders.count)
    var restTables: [Table] = []
    var restViews: [View] = []
    for (index, table) in tables.enumerated() {
      if let folderIndex = owner[index] {
        folderTables[folderIndex].append(table)
      } else {
        restTables.append(table)
      }
    }
    for (index, view) in views.enumerated() {
      if let folderIndex = owner[tables.count + index] {
        folderViews[folderIndex].append(view)
      } else {
        restViews.append(view)
      }
    }

    let groups = folders.indices.map {
      Group(folder: folders[$0], tables: folderTables[$0], views: folderViews[$0])
    }
    return Self(
      groups: isFiltering ? groups.filter { $0.count > 0 } : groups, tables: restTables,
      views: restViews)
  }
}
