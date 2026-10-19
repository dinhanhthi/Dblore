//
//  MongoOverviewModel.swift
//  Dblore
//
//  The Databases and Collections screens of a MongoDB workspace. Databases: `listDatabases` (the
//  current database alone, with a note, when the user may not list them), then `dbStats` per row.
//  Collections: the collections and views of the sidebar schema (followed as it reloads), then
//  `$collStats` per collection; views have no storage stats. At most `maxConcurrentStats` stats
//  reads run at once; `cancel()` stops the whole load, and a result lands only while its load is
//  the latest and the connection epoch read before it is still the current one. Create, drop and
//  rename run through `MongoAdminActionModel`, gated on the epoch the list was read with.
//

import Foundation
import Observation

@MainActor
@Observable
final class MongoOverviewModel {
  nonisolated enum Mode: Sendable {
    case databases
    case collections
  }

  enum StatsState: Equatable {
    case loading
    case loaded
    /// The read failed, or the row has none (a view)
    case unknown
  }

  /// A column of either screen
  enum SortKey {
    case name
    case storageSize
    case dataSize
    /// Collections of a database, documents of a collection
    case count
    case avgSize
    case indexes
  }

  /// A row's numbers; nil: unknown
  nonisolated struct Stats: Sendable {
    /// Bytes
    var storageSize: Int64?
    var dataSize: Int64?
    /// Collections of a database, documents of a collection
    var count: Int64?
    var avgSize: Int64?
    var indexes: Int64?

    init() {}

    init(_ stats: MongoDatabaseStats) {
      (storageSize, dataSize, count) = (stats.storageSize, stats.dataSize, stats.collections)
      indexes = stats.indexes
    }

    init(_ stats: MongoCollectionStats) {
      (storageSize, dataSize, count) = (stats.storageSize, stats.size, stats.count)
      (avgSize, indexes) = (stats.avgObjSize, stats.nindexes)
    }
  }

  struct Row: Identifiable {
    var id: String { name }
    let name: String
    /// The database the row lives in (a database row: its own name)
    let database: String
    /// Capped, time series, clustered (collections)
    let flags: DatabaseTable.CollectionFlags
    let isView: Bool
    /// The database the connection reads
    let isCurrent: Bool
    /// admin, local or config: never dropped
    let isSystem: Bool
    var stats = Stats()
    var statsState: StatsState

    /// `key`'s number, nil while unknown (shown as an em dash, sorted last)
    func value(_ key: SortKey) -> Int64? {
      guard statsState == .loaded else { return nil }
      switch key {
      case .name: return nil
      case .storageSize: return stats.storageSize
      case .dataSize: return stats.dataSize
      case .count: return stats.count
      case .avgSize: return stats.avgSize
      case .indexes: return stats.indexes
      }
    }
  }

  /// `badgeCounts`-style limit of stats reads in flight
  static let maxConcurrentStats = 4

  let mode: Mode
  /// In list order; the screens show `sortedRows`
  private(set) var rows: [Row] = []
  private(set) var isLoading = false
  private(set) var loadError: String?
  /// Why the database list is partial, nil when complete
  private(set) var note: String?
  var sortKey = SortKey.name
  var ascending = true
  /// The running or last admin command (the view presents its confirm sheet)
  private(set) var action: MongoAdminActionModel?
  /// The connection epoch the rows were read with; admin commands are gated on it
  private(set) var listEpoch: UInt64?

  @ObservationIgnored private let workspaceManager: WorkspaceManager
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  /// Bumped by every load and cancel: results of an older load are dropped
  @ObservationIgnored private var generation = 0

  init(mode: Mode, workspaceManager: WorkspaceManager) {
    self.mode = mode
    self.workspaceManager = workspaceManager
  }

  // MARK: - Sorting

  /// `rows` by `sortKey`; rows whose value is unknown come last (by name) in both directions
  var sortedRows: [Row] {
    guard sortKey != .name else {
      return rows.sorted { ascending ? Self.nameOrder($0, $1) : Self.nameOrder($1, $0) }
    }
    let key = sortKey
    let known = rows.compactMap { row in row.value(key).map { (row, $0) } }
      .sorted { lhs, rhs in
        guard lhs.1 != rhs.1 else { return Self.nameOrder(lhs.0, rhs.0) }
        return ascending ? lhs.1 < rhs.1 : lhs.1 > rhs.1
      }
      .map(\.0)
    return known + rows.filter { $0.value(key) == nil }.sorted(by: Self.nameOrder)
  }

  /// A header click: the same column flips the direction, another one sorts ascending
  func sort(by key: SortKey) {
    if sortKey == key {
      ascending.toggle()
    } else {
      (sortKey, ascending) = (key, true)
    }
  }

  /// Finder-like name order, ties broken by the exact text so the order is total
  private static func nameOrder(_ lhs: Row, _ rhs: Row) -> Bool {
    switch lhs.name.localizedStandardCompare(rhs.name) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: lhs.name < rhs.name
    }
  }

  // MARK: - Loading

  /// Reads the list, then the stats of every row. Collections wait for a sidebar schema read
  /// since the last connect and load again whenever it reloads.
  func load() {
    cancel()
    let generation = generation
    isLoading = true
    loadError = nil
    loadTask = Task { [weak self] in
      await PerfSignpost.interval("mongo.overview.load") {
        guard let self else { return }
        switch self.mode {
        case .databases: await self.loadDatabases(generation)
        case .collections: await self.loadCollections(generation)
        }
      }
    }
  }

  /// Stops the list and stats reads (disappear, switch, reconnect); nothing of them lands
  func cancel() {
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
  }

  private func loadDatabases(_ generation: Int) async {
    let manager = workspaceManager.connectionManager
    // Read before the fetch: a reconnect meanwhile leaves an older epoch, which only refuses
    let epoch = await manager.connectionEpoch
    let list: MongoDatabaseList
    do {
      list = try await manager.mongoDatabases()
    } catch {
      guard await isCurrent(generation, epoch) else { return endLoading(generation) }
      loadError = error.localizedDescription
      isLoading = false
      return
    }
    guard await isCurrent(generation, epoch) else { return endLoading(generation) }
    let current = workspaceManager.workspace.connectionConfig.map(
      WorkspaceManager.mongoDatabaseName(of:))
    note = list.note
    listEpoch = epoch
    rows = list.databases.map {
      Row(
        name: $0.name, database: $0.name, flags: [], isView: false, isCurrent: $0.name == current,
        isSystem: MongoDatabaseName.reserved.contains($0.name.lowercased()), statsState: .loading)
    }
    isLoading = false
    await loadStats(generation, epoch)
  }

  private func loadCollections(_ generation: Int) async {
    followSchema(generation)
    // Loading or not read since the last connect: the load landing calls `load()` again
    guard !workspaceManager.isLoadingSchema else { return }
    guard let epoch = workspaceManager.schemaConnectionEpoch else {
      isLoading = false
      return
    }
    listEpoch = epoch
    rows =
      workspaceManager.databaseTables.map {
        Row(
          name: $0.name, database: $0.schema, flags: $0.collectionFlags, isView: false,
          isCurrent: false, isSystem: false, statsState: .loading)
      }
      + workspaceManager.databaseViews.map {
        Row(
          name: $0.name, database: $0.schema, flags: [], isView: true, isCurrent: false,
          isSystem: false, statsState: .unknown)
      }
    isLoading = false
    // A reconnect since the schema read: its reload comes next
    guard await isCurrent(generation, epoch) else { return }
    await loadStats(generation, epoch)
  }

  /// Calls `load()` once the sidebar schema starts or finishes a load, or a connect resets it
  private func followSchema(_ generation: Int) {
    withObservationTracking {
      _ = workspaceManager.isLoadingSchema
      _ = workspaceManager.schemaConnectionEpoch
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.load()
      }
    }
  }

  /// Stats of the rows still loading, at most `maxConcurrentStats` in flight
  private func loadStats(_ generation: Int, _ epoch: UInt64) async {
    let manager = workspaceManager.connectionManager
    let mode = mode
    let names = rows.filter { $0.statsState == .loading }.map(\.name)
    _ = try? await withThrowingTaskGroup(of: (String, Stats?).self) { group in
      for (index, name) in names.enumerated() {
        if index >= Self.maxConcurrentStats, let (done, stats) = try await group.next() {
          await land(done, stats, generation, epoch)
        }
        try Task.checkCancellation()
        group.addTask { (name, try await Self.stats(of: name, mode: mode, manager: manager)) }
      }
      for try await (name, stats) in group { await land(name, stats, generation, epoch) }
    }
  }

  /// `name`'s stats, or nil when the read failed (a view, a missing privilege). Cancel is
  /// rethrown.
  private nonisolated static func stats(
    of name: String, mode: Mode, manager: DatabaseConnectionManager
  ) async throws -> Stats? {
    do {
      switch mode {
      case .databases: return Stats(try await manager.mongoDatabaseStats(name))
      case .collections: return Stats(try await manager.mongoCollectionStats(name))
      }
    } catch {
      if Task.isCancelled || error is CancellationError { throw error }
      return nil
    }
  }

  private func land(_ name: String, _ stats: Stats?, _ generation: Int, _ epoch: UInt64) async {
    guard await isCurrent(generation, epoch),
      let index = rows.firstIndex(where: { $0.name == name })
    else { return }
    rows[index].stats = stats ?? Stats()
    rows[index].statsState = stats == nil ? .unknown : .loaded
  }

  /// The latest load read under an older connection: it lands nothing but stops loading, so the
  /// screen can read again
  private func endLoading(_ generation: Int) {
    if generation == self.generation { isLoading = false }
  }

  /// The load is still the latest and the connection the one it read
  private func isCurrent(_ generation: Int, _ epoch: UInt64) async -> Bool {
    guard generation == self.generation else { return false }
    let current = await workspaceManager.connectionManager.connectionEpoch
    return generation == self.generation && current == epoch
  }

  // MARK: - Actions

  /// The active tab is a connected MongoDB tab whose protection allows schema changes, and a list
  /// was read: Create, Drop and Rename are offered
  var canChangeSchema: Bool { adminTab != nil && listEpoch != nil }

  private var adminTab: NotebookViewModel? {
    guard let tab = workspaceManager.activeViewModel, tab.connectionManager != nil,
      tab.connectionState == .connected, tab.notebook.connectionConfig?.databaseType == .mongodb,
      !tab.protectionPolicy.protectionLevel.blocksSchemaChanges
    else { return nil }
    return tab
  }

  /// Creates database `name` with its first collection (a database exists once it holds one)
  func createDatabase(_ name: String, collection: String) async {
    await run(.createDatabase(database: name, collection: collection, options: nil), database: name)
  }

  /// Drops `row`'s database, named explicitly so the typed name and the dropped database are the
  /// same; data viewer tabs reading it close once it is gone
  func dropDatabase(_ row: Row) async {
    guard mode == .databases, !row.isSystem else { return }
    await run(.dropDatabase(database: row.name), database: row.name) { [weak self] in
      self?.closeDataViewerTabs(database: row.name)
    }
  }

  func dropCollection(_ row: Row) async {
    guard mode == .collections else { return }
    await run(.drop(collection: row.name), isView: row.isView, database: row.database) {
      [weak self] in
      self?.workspaceManager.closeDataViewerTabs(schema: row.database, name: row.name)
    }
  }

  func renameCollection(_ row: Row, to newName: String) async {
    guard mode == .collections else { return }
    await run(.renameCollection(collection: row.name, to: newName), database: row.database) {
      [weak self] in
      self?.workspaceManager.renameDataViewerTabs(
        schema: row.database, from: row.name, to: newName)
    }
  }

  /// Reconnects to database `name`; returns why it was refused or failed, nil once connected
  func switchTo(_ name: String) async -> String? {
    cancel()
    let refusal = await workspaceManager.switchMongoDatabase(to: name)
    load()
    return refusal
  }

  /// Starts `command` on the active tab's connection, gated on `listEpoch`. Once it is done,
  /// `onDone` runs and the database list is read again (collections follow the schema reload).
  private func run(
    _ command: MongoAdminCommand, isView: Bool = false, database: String,
    onDone: (@MainActor () -> Void)? = nil
  ) async {
    guard action?.state != .running, let tab = adminTab, let epoch = listEpoch else { return }
    // `onExecuted` also runs after a failure; the model sets its state first
    weak var started: MongoAdminActionModel?
    guard
      let model = MongoAdminActionModel(
        tab: tab, connectionEpoch: epoch,
        onExecuted: { [weak self] in
          guard started?.state == .done else { return }
          onDone?()
          if self?.mode == .databases { self?.load() }
        })
    else { return }
    started = model
    action = model
    await model.request(command, isView: isView, database: database)
  }

  /// Pinned tabs too (nothing is left to read). Staged edits are discarded first: a committed
  /// insert would create the database again
  private func closeDataViewerTabs(database: String) {
    for id in workspaceManager.tabs.map(\.id)
    where workspaceManager.viewModels[id]?.dataViewer?.schema == database {
      workspaceManager.viewModels[id]?.discardStaged()
      workspaceManager.closeTabImmediately(id: id)
    }
  }
}
