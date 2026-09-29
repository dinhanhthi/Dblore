//
//  SavedFilterStore.swift
//  SQLNotebook
//

import Foundation

/// A named filter saved for one table
struct SavedFilter: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var filter: TableFilter
}

/// A named highlight saved for one table
struct SavedHighlight: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var highlight: TableHighlight
}

/// Saved table filters and highlights per connection and table, stored as JSON in UserDefaults
final class SavedFilterStore {
  private static let storageKey = "com.sqlnotebook.savedFilters"
  private static let highlightStorageKey = "com.sqlnotebook.savedHighlights"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = RecentManager.sharedDefaults) {
    self.defaults = defaults
  }

  /// `databaseType|host|port|database|schema.name`
  static func key(for config: ConnectionConfig, schema: String, name: String) -> String {
    [config.databaseType.rawValue, config.host, String(config.port), config.database]
      .joined(separator: "|") + "|\(schema).\(name)"
  }

  func list(for key: String) -> [SavedFilter] {
    let all: [String: [SavedFilter]] = load()
    return all[key] ?? []
  }

  /// Saves `filter` under `name`; a filter with the same name is replaced
  func save(_ filter: TableFilter, named name: String, for key: String) {
    var all: [String: [SavedFilter]] = load()
    var filters = all[key] ?? []
    if let index = filters.firstIndex(where: { $0.name == name }) {
      filters[index].filter = filter
    } else {
      filters.append(SavedFilter(name: name, filter: filter))
    }
    all[key] = filters
    store(all)
  }

  func delete(id: UUID, for key: String) {
    var all: [String: [SavedFilter]] = load()
    all[key]?.removeAll { $0.id == id }
    store(all)
  }

  func listHighlights(for key: String) -> [SavedHighlight] {
    load(Self.highlightStorageKey)[key] ?? []
  }

  /// Saves `highlight` under `name`; a highlight with the same name is replaced
  func saveHighlight(_ highlight: TableHighlight, named name: String, for key: String) {
    var all: [String: [SavedHighlight]] = load(Self.highlightStorageKey)
    var highlights = all[key] ?? []
    if let index = highlights.firstIndex(where: { $0.name == name }) {
      highlights[index].highlight = highlight
    } else {
      highlights.append(SavedHighlight(name: name, highlight: highlight))
    }
    all[key] = highlights
    store(all, Self.highlightStorageKey)
  }

  func deleteHighlight(id: UUID, for key: String) {
    var all: [String: [SavedHighlight]] = load(Self.highlightStorageKey)
    all[key]?.removeAll { $0.id == id }
    store(all, Self.highlightStorageKey)
  }

  private func load<T: Decodable>(
    _ storageKey: String = SavedFilterStore.storageKey
  ) -> [String: [T]] {
    guard let data = defaults.data(forKey: storageKey),
      let all = try? JSONDecoder().decode([String: [T]].self, from: data)
    else { return [:] }
    return all
  }

  private func store<T: Encodable>(
    _ all: [String: [T]], _ storageKey: String = SavedFilterStore.storageKey
  ) {
    guard let data = try? JSONEncoder().encode(all) else { return }
    defaults.set(data, forKey: storageKey)
  }
}
