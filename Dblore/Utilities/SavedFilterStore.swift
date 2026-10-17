//
//  SavedFilterStore.swift
//  Dblore
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

/// A named MongoDB Documents query (filter text and options) saved for one collection
struct SavedMongoQuery: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var filter: String
  var options: MongoQueryOptions
}

extension SavedMongoQuery {
  /// Options are optional, so an entry saved before they existed still loads
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    filter = try container.decode(String.self, forKey: .filter)
    options = try container.decodeIfPresent(MongoQueryOptions.self, forKey: .options) ?? .init()
  }
}

/// A named MongoDB aggregation pipeline (stages and options) saved for one collection
struct SavedMongoPipeline: Codable, Identifiable, Equatable {
  struct Stage: Codable, Equatable {
    var `operator`: String
    var body: String
    var isEnabled: Bool
  }

  var id = UUID()
  var name: String
  var stages: [Stage]
  var options: MongoQueryOptions
}

extension SavedMongoPipeline {
  /// Options are optional, so an entry saved without them still loads
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    stages = try container.decode([Stage].self, forKey: .stages)
    options = try container.decodeIfPresent(MongoQueryOptions.self, forKey: .options) ?? .init()
  }
}

extension SavedMongoPipeline.Stage {
  /// The enabled flag is optional, so a stage saved without it loads enabled
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    `operator` = try container.decode(String.self, forKey: .operator)
    body = try container.decode(String.self, forKey: .body)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
  }
}

/// Saved table filters, highlights, MongoDB queries and pipelines per connection and table, stored
/// as JSON in UserDefaults
final class SavedFilterStore {
  private nonisolated static let storageKey = "ace.thi.dblore.savedFilters"
  private nonisolated static let highlightStorageKey = "ace.thi.dblore.savedHighlights"
  private nonisolated static let mongoQueryStorageKey = "ace.thi.dblore.savedMongoQueries"
  private nonisolated static let mongoPipelineStorageKey = "ace.thi.dblore.savedMongoPipelines"

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

  func listMongoQueries(for key: String) -> [SavedMongoQuery] {
    load(Self.mongoQueryStorageKey)[key] ?? []
  }

  /// Saves `filter` and `options` under `name`; a query with the same name is replaced
  func saveMongoQuery(
    filter: String, options: MongoQueryOptions, named name: String, for key: String
  ) {
    var all: [String: [SavedMongoQuery]] = load(Self.mongoQueryStorageKey)
    var queries = all[key] ?? []
    if let index = queries.firstIndex(where: { $0.name == name }) {
      queries[index].filter = filter
      queries[index].options = options
    } else {
      queries.append(SavedMongoQuery(name: name, filter: filter, options: options))
    }
    all[key] = queries
    store(all, Self.mongoQueryStorageKey)
  }

  func deleteMongoQuery(id: UUID, for key: String) {
    var all: [String: [SavedMongoQuery]] = load(Self.mongoQueryStorageKey)
    all[key]?.removeAll { $0.id == id }
    store(all, Self.mongoQueryStorageKey)
  }

  func listMongoPipelines(for key: String) -> [SavedMongoPipeline] {
    load(Self.mongoPipelineStorageKey)[key] ?? []
  }

  /// Saves `stages` and `options` under `name`; a pipeline with the same name is replaced
  func saveMongoPipeline(
    stages: [SavedMongoPipeline.Stage], options: MongoQueryOptions, named name: String,
    for key: String
  ) {
    var all: [String: [SavedMongoPipeline]] = load(Self.mongoPipelineStorageKey)
    var pipelines = all[key] ?? []
    if let index = pipelines.firstIndex(where: { $0.name == name }) {
      pipelines[index].stages = stages
      pipelines[index].options = options
    } else {
      pipelines.append(SavedMongoPipeline(name: name, stages: stages, options: options))
    }
    all[key] = pipelines
    store(all, Self.mongoPipelineStorageKey)
  }

  func deleteMongoPipeline(id: UUID, for key: String) {
    var all: [String: [SavedMongoPipeline]] = load(Self.mongoPipelineStorageKey)
    all[key]?.removeAll { $0.id == id }
    store(all, Self.mongoPipelineStorageKey)
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

  nonisolated static func storedData(
    defaults: UserDefaults, domainName: String
  ) -> (
    filters: Data?, highlights: Data?
  ) {
    let domain = defaults.persistentDomain(forName: domainName) ?? [:]
    return (domain[storageKey] as? Data, domain[highlightStorageKey] as? Data)
  }

  nonisolated static func exportSnapshot(
    defaults: UserDefaults, domainName: String
  ) -> (
    filters: Data?, highlights: Data?
  ) {
    storedData(defaults: defaults, domainName: domainName)
  }

  nonisolated static func replace(
    filters: Data?, highlights: Data?, defaults: UserDefaults, domainName: String
  ) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    if let filters {
      domain[storageKey] = filters
    } else {
      domain.removeValue(forKey: storageKey)
    }
    if let highlights {
      domain[highlightStorageKey] = highlights
    } else {
      domain.removeValue(forKey: highlightStorageKey)
    }
    defaults.setPersistentDomain(domain, forName: domainName)
  }

  nonisolated static func clearAll(defaults: UserDefaults, domainName: String) {
    replace(filters: nil, highlights: nil, defaults: defaults, domainName: domainName)
  }
}
