//
//  WorkspaceManager+History.swift
//  Dblore
//
//  Query history list and the actions that insert, copy, or delete a row.
//

import AppKit
import Foundation
import Observation

/// `databaseType|host|port|database|username`, the key stored on a history row. Never the password.
nonisolated enum QueryHistoryIdentity {
  static func connectionKey(for config: ConnectionConfig) -> String {
    [
      config.databaseType.rawValue, config.host, String(config.port), config.database,
      config.username,
    ].joined(separator: "|")
  }
}

/// Which history rows the sidebar is showing. A missing connection or workspace searches everything.
nonisolated enum HistoryScope: Equatable, Sendable {
  case all
  case connection
  case workspace

  func storeScope(connectionKey: String?, workspaceID: UUID?) -> QueryHistoryStore.Scope {
    switch self {
    case .all:
      return .all
    case .connection:
      guard let connectionKey, !connectionKey.isEmpty else { return .all }
      return .connection(connectionKey)
    case .workspace:
      guard let workspaceID else { return .all }
      return .workspace(workspaceID)
    }
  }
}

/// One page of query history for the sidebar. `query` changes wait 250 ms, then call `searchNow()`.
@MainActor
@Observable
final class HistoryListModel {
  static let pageSize = 100

  var query: String = "" {
    didSet {
      guard query != oldValue else { return }
      scheduleSearch()
    }
  }

  var scope: HistoryScope = .all {
    didSet {
      guard scope != oldValue else { return }
      scheduleSearch()
    }
  }

  private(set) var results: [QueryHistoryEntry] = []
  private(set) var isLoading = false

  @ObservationIgnored var browser: @MainActor () -> QueryHistoryStore? = { nil }
  @ObservationIgnored var connectionKey: @MainActor () -> String? = { nil }
  @ObservationIgnored var workspaceID: @MainActor () -> UUID? = { nil }

  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var searchEpoch = 0
  @ObservationIgnored private var nextOffset = 0
  @ObservationIgnored private var hasMore = false
  @ObservationIgnored private let localDataChanges = LocalDataChangeObserver()

  init() {
    localDataChanges.start { [weak self] note in
      guard LocalDataCategory.notification(note, includes: .queryHistory) else { return }
      Task { @MainActor [weak self] in
        await self?.searchNow()
      }
    }
  }

  /// Reloads the first page. The debounced query change calls this.
  func searchNow() async {
    searchTask?.cancel()
    searchTask = nil
    searchEpoch += 1
    await reloadFirstPage(epoch: searchEpoch)
  }

  /// Appends the next page. A short page ends the list.
  func loadMore() async {
    guard hasMore, !isLoading, let store = browser() else { return }
    let epoch = searchEpoch
    let offset = nextOffset
    isLoading = true
    defer {
      if epoch == searchEpoch { isLoading = false }
    }
    do {
      let page = try await store.search(
        text: query, scope: resolvedScope(), limit: Self.pageSize, offset: offset)
      guard epoch == searchEpoch else { return }
      results.append(contentsOf: page)
      nextOffset += page.count
      hasMore = page.count == Self.pageSize
    } catch {
      await AppLogger.shared.error(
        "Query history search failed: \(error.localizedDescription)", category: "History")
    }
  }

  func remove(ids: [Int64]) {
    let dropping = Set(ids)
    guard !dropping.isEmpty else { return }
    results.removeAll { dropping.contains($0.id) }
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    searchEpoch += 1
    let epoch = searchEpoch
    searchTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let self, !Task.isCancelled, epoch == self.searchEpoch else { return }
      self.searchTask = nil
      await self.searchNow()
    }
  }

  private func reloadFirstPage(epoch: Int) async {
    isLoading = true
    defer {
      if epoch == searchEpoch { isLoading = false }
    }
    guard let store = browser() else {
      results = []
      nextOffset = 0
      hasMore = false
      return
    }
    do {
      let page = try await store.search(
        text: query, scope: resolvedScope(), limit: Self.pageSize, offset: 0)
      guard epoch == searchEpoch else { return }
      results = page
      nextOffset = page.count
      hasMore = page.count == Self.pageSize
    } catch {
      guard epoch == searchEpoch else { return }
      results = []
      nextOffset = 0
      hasMore = false
      await AppLogger.shared.error(
        "Query history search failed: \(error.localizedDescription)", category: "History")
    }
  }

  private func resolvedScope() -> QueryHistoryStore.Scope {
    scope.storeScope(connectionKey: connectionKey(), workspaceID: workspaceID())
  }
}

extension WorkspaceManager {
  /// SQL text placed on the pasteboard. The action is what talks to `NSPasteboard`.
  static func historyClipboardText(_ entry: QueryHistoryEntry) -> String {
    entry.sql
  }

  /// Store for the history list. The test host never opens `QueryHistoryStore.shared`.
  func resolvedHistoryBrowser() -> QueryHistoryStore? {
    if let historyBrowser { return historyBrowser }
    if SessionManager.isRunningAsTestHost { return nil }
    return QueryHistoryStore.shared
  }

  /// Connection key of the workspace, or nil when no database is configured.
  var activeHistoryConnectionKey: String? {
    guard let config = workspace.connectionConfig else { return nil }
    let key = QueryHistoryIdentity.connectionKey(for: config)
    return key.isEmpty ? nil : key
  }

  /// Inserts the statement at the cursor, the same way a favorite does.
  func insertHistory(_ entry: QueryHistoryEntry) {
    activeViewModel?.insertTextIntoSelectedCell(entry.sql)
  }

  /// Adds a SQL cell after the selection (or at the end) and fills it. Does not run it.
  func runHistoryInNewCell(_ entry: QueryHistoryEntry) {
    guard let viewModel = activeViewModel, viewModel.viewMode == .notebook else { return }
    viewModel.addCell(type: .sql, after: viewModel.selectedCellId)
    guard let id = viewModel.selectedCellId,
      let index = viewModel.notebook.cells.firstIndex(where: { $0.id == id })
    else { return }
    viewModel.notebook.cells[index].content = entry.sql
    viewModel.onDocumentChanged?()
  }

  /// Copies `entry.sql` to the pasteboard.
  func copyHistory(_ entry: QueryHistoryEntry) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(Self.historyClipboardText(entry), forType: .string)
  }

  /// Deletes the rows from the store and drops them from the loaded page.
  func deleteHistory(ids: [Int64]) async {
    guard !ids.isEmpty, let store = resolvedHistoryBrowser() else { return }
    do {
      try await store.delete(ids: ids)
      historyList.remove(ids: ids)
    } catch {
      await AppLogger.shared.error(
        "Query history delete failed: \(error.localizedDescription)", category: "History")
    }
  }

  /// Reloads the first page. The history sidebar calls this when it opens and after a
  /// statement is recorded.
  func refreshHistory() async {
    await historyList.searchNow()
  }
}
