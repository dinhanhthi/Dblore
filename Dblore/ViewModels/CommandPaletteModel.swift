//
//  CommandPaletteModel.swift
//  Dblore
//
//  Ranks a palette snapshot off the main actor and searches this connection's history.
//

import Foundation
import Observation

/// Sources copied when the palette opens. A later query does not read them again.
nonisolated struct CommandPaletteSnapshot: Equatable, Sendable {
  var tables: [Relation] = []
  var views: [Relation] = []
  var functions: [Function] = []
  var tabs: [Tab] = []
  var favorites: [Favorite] = []
  var actions: [Action] = []
  /// `QueryHistoryStore.Scope.connection` key. Empty still searches only that key.
  var connectionKey: String = ""

  nonisolated struct Relation: Equatable, Sendable {
    var schema: String
    var name: String
  }

  nonisolated struct Function: Equatable, Sendable {
    var schema: String
    var name: String
    var arguments: String = ""
  }

  nonisolated struct Tab: Equatable, Sendable {
    var id: UUID
    var title: String
  }

  nonisolated struct Favorite: Equatable, Sendable {
    var id: UUID
    var name: String
    var sql: String
  }

  nonisolated struct Action: Equatable, Sendable {
    var id: String
    var title: String
  }

  /// Tables, views, functions, tabs, favorites, then actions. History is not included.
  var items: [CommandPaletteItem] {
    var items: [CommandPaletteItem] = []
    items.reserveCapacity(
      tables.count + views.count + functions.count + tabs.count + favorites.count + actions.count)
    for table in tables {
      items.append(.table(schema: table.schema, name: table.name))
    }
    for view in views {
      items.append(.view(schema: view.schema, name: view.name))
    }
    for function in functions {
      items.append(
        .function(schema: function.schema, name: function.name, arguments: function.arguments))
    }
    for tab in tabs {
      items.append(.tab(id: tab.id, title: tab.title))
    }
    for favorite in favorites {
      items.append(.favorite(id: favorite.id, name: favorite.name, sql: favorite.sql))
    }
    for action in actions {
      items.append(.action(id: action.id, title: action.title))
    }
    return items
  }
}

/// Score order for snapshot rows. Higher wins. Equal scores keep the earlier snapshot index.
/// Each keyword must score against some search text, or the row is out. An empty query scores 0.
nonisolated enum CommandPaletteRanking: Sendable {
  static let limit = 50

  static func rank(_ items: [CommandPaletteItem], _ query: String) async -> [CommandPaletteItem] {
    assert(!Thread.isMainThread)
    let keywords = SidebarEntityFilter.keywords(in: query)
    var scored: [(index: Int, score: Int, item: CommandPaletteItem)] = []
    scored.reserveCapacity(items.count)
    for (index, item) in items.enumerated() {
      if index.isMultiple(of: 32), Task.isCancelled { return [] }
      guard let score = score(item, keywords: keywords) else { continue }
      scored.append((index, score, item))
    }
    if Task.isCancelled { return [] }
    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.index < rhs.index
    }
    return scored.prefix(limit).map(\.item)
  }

  private static func score(_ item: CommandPaletteItem, keywords: [String]) -> Int? {
    if keywords.isEmpty { return 0 }
    var total = 0
    for keyword in keywords {
      var best: Int?
      for text in item.searchTexts where !text.isEmpty {
        guard let value = SidebarEntityFilter.score(keyword, in: text) else { continue }
        best = max(best ?? value, value)
      }
      guard let best else { return nil }
      total += best
    }
    return total
  }
}

/// Snapshot rank plus this connection's history. The store is injected; `.shared` is never opened.
@MainActor
@Observable
final class CommandPaletteModel {
  static let rankedLimit = CommandPaletteRanking.limit
  static let historyLimit = 50

  var query = "" {
    didSet {
      guard query != oldValue else { return }
      schedule()
    }
  }

  /// Snapshot rows that matched, best score first, at most 50.
  private(set) var ranked: [CommandPaletteItem] = []
  /// History for `connectionKey`, newest first when the query is blank. At most 50.
  private(set) var history: [CommandPaletteItem] = []

  @ObservationIgnored private var snapshotItems: [CommandPaletteItem] = []
  @ObservationIgnored private var connectionKey = ""
  @ObservationIgnored private var didOpen = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var rankTask: Task<Void, Never>?
  @ObservationIgnored private var historyTask: Task<Void, Never>?
  @ObservationIgnored private let historyStore: QueryHistoryStore?
  @ObservationIgnored private let rank:
    @Sendable ([CommandPaletteItem], String) async -> [CommandPaletteItem]

  init(
    historyStore: QueryHistoryStore? = nil,
    rank: (@Sendable ([CommandPaletteItem], String) async -> [CommandPaletteItem])? = nil
  ) {
    self.historyStore = historyStore
    self.rank = rank ?? CommandPaletteRanking.rank
  }

  /// Replaces the copied snapshot and connection key, then ranks and searches again.
  func open(_ snapshot: CommandPaletteSnapshot) {
    snapshotItems = snapshot.items
    connectionKey = snapshot.connectionKey
    didOpen = true
    schedule()
  }

  private func schedule() {
    guard didOpen else { return }
    // Drop the previous page before the new rank. Return must not run it.
    history = []
    ranked = []
    generation += 1
    let generation = generation
    let items = snapshotItems
    let query = query
    let connectionKey = connectionKey
    let rank = rank

    rankTask?.cancel()
    rankTask = Task.detached {
      let ranked = await rank(items, query)
      guard !Task.isCancelled else { return }
      await self.adoptRank(ranked, generation: generation)
    }

    historyTask?.cancel()
    guard let historyStore else { return }
    historyTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, generation == self.generation else { return }
      await self.loadHistory(
        store: historyStore, text: query, connectionKey: connectionKey, generation: generation)
    }
  }

  private func adoptRank(_ items: [CommandPaletteItem], generation: Int) {
    guard generation == self.generation else { return }
    ranked = items
  }

  private func loadHistory(
    store: QueryHistoryStore, text: String, connectionKey: String, generation: Int
  ) async {
    let rows: [QueryHistoryEntry]
    do {
      rows = try await store.search(
        text: text, scope: .connection(connectionKey), limit: Self.historyLimit, offset: 0,
        writesOnly: false)
    } catch {
      guard generation == self.generation else { return }
      history = []
      return
    }
    guard generation == self.generation, !Task.isCancelled else { return }
    history = rows.prefix(Self.historyLimit).compactMap { row in
      guard !QueryHistoryEntry.isTransactionSummary(row.sql) else { return nil }
      return .history(id: row.id, sql: row.sql)
    }
  }
}
