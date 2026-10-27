//
//  ConnectionExportModel.swift
//  Dblore
//
//  Export of saved connections, and optionally the favorites of one open workspace, to a Dblore
//  connections file. Rows keep only the allow-listed fields of `DbloreConnectionFile.Connection`,
//  so no password or key read with the history ever reaches the model. File databases are left
//  out, and so is a locked connection until it is unlocked (Welcome asks first). The file is
//  encoded and written off the main actor.
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ConnectionExportModel {
  /// One saved connection in the picker. Display fields hold no secrets.
  struct Row: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// "host:port/database"
    let address: String
    let engine: String
    var isSelected = true
    fileprivate let connection: DbloreConnectionFile.Connection
    /// Every lock the row reaches: a relock while the picker is open leaves it out of the file
    fileprivate let lockIdentities: Set<LockIdentity>
  }

  /// An open workspace whose favorites can be exported.
  struct FavoritesSource: Identifiable, Equatable {
    let id: UUID
    let name: String
    fileprivate let favorites: [DbloreConnectionFile.Favorite]

    var count: Int { favorites.count }
  }

  static let defaultFileName = "Dblore Connections.json"

  private(set) var rows: [Row]
  /// File databases, which are not exported.
  let skippedFileDatabases: Int
  let favoritesSources: [FavoritesSource]
  /// Workspace whose favorites are exported; nil exports none.
  var favoritesSourceID: UUID?
  private(set) var isExporting = false
  private(set) var errorMessage: String?
  private let registry: LockRegistry

  /// `workspaces`: open workspaces; those with favorites are offered. A connection whose lock
  /// is not unlocked in this session is left out.
  init(
    connections: [ConnectionHistoryEntry], workspaces: [WorkspaceManager],
    registry: LockRegistry = .shared
  ) {
    self.registry = registry
    var rows: [Row] = []
    var skippedFileDatabases = 0
    for entry in connections {
      guard let connection = DbloreConnectionFile.Connection(config: entry.config) else {
        skippedFileDatabases += 1
        continue
      }
      guard registry.refusal(for: entry.config) == nil else { continue }
      rows.append(
        Row(
          id: entry.id, name: entry.shortDisplayName,
          address: "\(connection.host):\(connection.port)/\(connection.database)",
          engine: entry.config.databaseType.displayName, connection: connection,
          lockIdentities: LockIdentity.all(entry.config)))
    }
    self.rows = rows
    self.skippedFileDatabases = skippedFileDatabases
    favoritesSources =
      workspaces
      .filter { !$0.workspace.favorites.items.isEmpty }
      .map {
        FavoritesSource(
          id: $0.id, name: $0.workspace.name, favorites: Self.favorites($0.workspace.favorites))
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Plain name and SQL text of each favorite.
  private static func favorites(_ favorites: WorkspaceFavorites) -> [DbloreConnectionFile.Favorite]
  {
    favorites.items.map { DbloreConnectionFile.Favorite(name: $0.name, sql: $0.sql) }
  }

  var selectedCount: Int { rows.count { $0.isSelected } }

  /// The selected connections whose locks are still unlocked
  var exportedConnections: [DbloreConnectionFile.Connection] {
    rows.filter { $0.isSelected && !$0.lockIdentities.contains(where: registry.isBlocked) }
      .map(\.connection)
  }

  private var selectedFavorites: [DbloreConnectionFile.Favorite] {
    favoritesSources.first { $0.id == favoritesSourceID }?.favorites ?? []
  }

  var canExport: Bool {
    !isExporting && (selectedCount > 0 || !selectedFavorites.isEmpty)
  }

  // MARK: - Selection

  func toggle(_ id: Row.ID) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    rows[index].isSelected.toggle()
  }

  func selectAll() {
    for index in rows.indices { rows[index].isSelected = true }
  }

  func deselectAll() {
    for index in rows.indices { rows[index].isSelected = false }
  }

  // MARK: - Export

  /// Asks where to save, then writes the file. Returns the toast text once written; nil when
  /// the panel was cancelled or the write failed (`errorMessage` says why).
  func export() async -> String? {
    guard canExport else { return nil }
    isExporting = true
    errorMessage = nil
    defer { isExporting = false }
    guard let url = await Self.showSavePanel() else { return nil }
    let file = DbloreConnectionFile(
      connections: exportedConnections, favorites: selectedFavorites)
    let result = await Task.detached(priority: .userInitiated) {
      Result {
        try file.encoded().write(to: url, options: .atomic)
        // Owner only: the file names hosts, users and SSH tunnels.
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
      }
    }.value
    switch result {
    case .success:
      var message = "Exported \(Self.count(file.connections.count, "connection"))"
      if !file.favorites.isEmpty {
        message += " and \(Self.count(file.favorites.count, "favorite"))"
      }
      return message
    case .failure:
      // A fixed sentence: never the path or the file content.
      errorMessage = "The connections file could not be written."
      return nil
    }
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }

  private static func showSavePanel() async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultFileName
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
