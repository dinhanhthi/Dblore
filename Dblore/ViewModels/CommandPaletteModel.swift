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
  /// Functions, procedures and triggers whose source View Source opens
  var sources: [ObjectSourceRef] = []
  var tabs: [Tab] = []
  var favorites: [Favorite] = []
  var actions: [Action] = []
  /// `QueryHistoryStore.Scope.connection` key. Empty still searches only that key.
  var connectionKey: String = ""
  /// Cached table, view and function rows; when set, `tables`, `views` and `functions` are
  /// left empty and these rows come first
  var catalog: CommandPaletteCatalog?

  nonisolated struct Relation: Hashable, Sendable {
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

  /// Tables, views, functions, sources, tabs, favorites, then actions. History is not included.
  var items: [CommandPaletteItem] {
    var items: [CommandPaletteItem] = catalog?.items ?? []
    items.reserveCapacity(
      items.count + tables.count + views.count + functions.count + sources.count + tabs.count
        + favorites.count + actions.count)
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
    for source in sources {
      items.append(.source(source))
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
    await rank(catalog: nil, items, query)
  }

  /// Ranks the `catalog` rows, then `items`, as one list. The catalog's stored keys spare
  /// lowercasing every name on each keystroke.
  static func rank(
    catalog: CommandPaletteCatalog?, _ items: [CommandPaletteItem], _ query: String
  ) async -> [CommandPaletteItem] {
    assert(!Thread.isMainThread)
    let keywords = SidebarEntityFilter.keywords(in: query)
    let cached = catalog?.items ?? []
    let keys = catalog?.searchKeys ?? []
    var scored: [(index: Int, score: Int, item: CommandPaletteItem)] = []
    scored.reserveCapacity(cached.count + items.count)
    for index in 0..<(cached.count + items.count) {
      if index.isMultiple(of: 32), Task.isCancelled { return [] }
      let isCached = index < cached.count
      let item = isCached ? cached[index] : items[index - cached.count]
      // An empty query scores 0 without reading the texts
      let texts: [String] =
        keywords.isEmpty
        ? [] : isCached ? keys[index] : item.searchTexts.map { $0.lowercased() }
      guard let score = score(texts, keywords: keywords) else { continue }
      scored.append((index, score, item))
    }
    if Task.isCancelled { return [] }
    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.index < rhs.index
    }
    return scored.prefix(limit).map(\.item)
  }

  /// `keywords` and `texts` are lowercased (`SidebarEntityFilter.keywords(in:)`)
  private static func score(_ texts: [String], keywords: [String]) -> Int? {
    var total = 0
    for keyword in keywords {
      var best: Int?
      for text in texts where !text.isEmpty {
        guard let value = SidebarEntityFilter.score(lowercased: keyword, in: text) else {
          continue
        }
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

  /// Bumped on each query. `ranked` and `history` stay on screen until their own generation
  /// catches up. Observed so the view redraws when a keystroke makes them stale.
  private var generation = 0
  private var rankedGeneration = 0
  private var historyGeneration = 0

  /// `ranked` belongs to the current query.
  var isRankFresh: Bool { rankedGeneration == generation }
  /// `history` belongs to the current query. Always true without a store.
  var isHistoryFresh: Bool { historyStore == nil || historyGeneration == generation }
  /// The current query's results are in, and they are empty.
  var showsNoMatches: Bool {
    isRankFresh && isHistoryFresh && ranked.isEmpty && history.isEmpty
  }

  /// Return must not run a row left over from an older query.
  func canPerform(_ item: CommandPaletteItem) -> Bool {
    (isRankFresh && ranked.contains(item)) || (isHistoryFresh && history.contains(item))
  }

  /// Rows after `snapshotCatalog`'s (all of them when it is nil)
  @ObservationIgnored private var snapshotItems: [CommandPaletteItem] = []
  @ObservationIgnored private var snapshotCatalog: CommandPaletteCatalog?
  @ObservationIgnored private var connectionKey = ""
  @ObservationIgnored private var didOpen = false
  @ObservationIgnored private var rankTask: Task<Void, Never>?
  @ObservationIgnored private var historyTask: Task<Void, Never>?
  @ObservationIgnored private let historyStore: QueryHistoryStore?
  @ObservationIgnored private let rank:
    @Sendable (CommandPaletteCatalog?, [CommandPaletteItem], String) async -> [CommandPaletteItem]

  init(
    historyStore: QueryHistoryStore? = nil,
    rank: (@Sendable ([CommandPaletteItem], String) async -> [CommandPaletteItem])? = nil
  ) {
    self.historyStore = historyStore
    if let rank {
      // An injected rank sees one list, the catalog's rows first
      self.rank = { catalog, items, query in await rank((catalog?.items ?? []) + items, query) }
    } else {
      self.rank = CommandPaletteRanking.rank(catalog:_:_:)
    }
  }

  /// Replaces the copied snapshot and connection key, then ranks and searches again.
  /// The catalog's rows are kept as they are (no copy on the main actor).
  func open(_ snapshot: CommandPaletteSnapshot) {
    var rest = snapshot
    rest.catalog = nil
    snapshotItems = rest.items
    snapshotCatalog = snapshot.catalog
    connectionKey = snapshot.connectionKey
    didOpen = true
    schedule()
  }

  private func schedule() {
    guard didOpen else { return }
    // Keep the previous rows on screen. The new generation marks them stale for Return.
    generation += 1
    let generation = generation
    let items = snapshotItems
    let catalog = snapshotCatalog
    let query = query
    let connectionKey = connectionKey
    let rank = rank

    rankTask?.cancel()
    rankTask = Task.detached {
      let ranked = await rank(catalog, items, query)
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
    rankedGeneration = generation
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
      historyGeneration = generation
      return
    }
    guard generation == self.generation, !Task.isCancelled else { return }
    history = rows.prefix(Self.historyLimit).compactMap { row in
      guard !row.isLabel else { return nil }
      return .history(id: row.id, sql: row.sql)
    }
    historyGeneration = generation
  }
}
