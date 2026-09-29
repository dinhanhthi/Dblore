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

/// Saved table filters per connection and table, stored as JSON in UserDefaults
final class SavedFilterStore {
  private static let storageKey = "com.sqlnotebook.savedFilters"

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
    load()[key] ?? []
  }

  /// Saves `filter` under `name`; a filter with the same name is replaced
  func save(_ filter: TableFilter, named name: String, for key: String) {
    var all = load()
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
    var all = load()
    all[key]?.removeAll { $0.id == id }
    store(all)
  }

  private func load() -> [String: [SavedFilter]] {
    guard let data = defaults.data(forKey: Self.storageKey),
      let all = try? JSONDecoder().decode([String: [SavedFilter]].self, from: data)
    else { return [:] }
    return all
  }

  private func store(_ all: [String: [SavedFilter]]) {
    guard let data = try? JSONEncoder().encode(all) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}
