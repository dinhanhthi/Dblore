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

  /// Full name in the open scope menu.
  var menuTitle: String {
    switch self {
    case .all: "All"
    case .connection: "This Connection"
    case .workspace: "This Workspace"
    }
  }

  /// Closed-menu label. Shorter than `menuTitle` so the filter row keeps its width.
  var selectedTitle: String {
    switch self {
    case .all: "All"
    case .connection: "This Conn"
    case .workspace: "This Wks"
    }
  }

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
  /// Rows shown on one sidebar page. Storage is capped separately by `AppSettings.historyMaxEntries`.
  static let pageSize = 50

  var query: String = "" {
    didSet {
      guard query != oldValue else { return }
      page = 1
      scheduleSearch()
    }
  }

  var scope: HistoryScope = .all {
    didSet {
      guard scope != oldValue else { return }
      page = 1
      scheduleSearch()
    }
  }

  private(set) var results: [QueryHistoryEntry] = []
  private(set) var isLoading = false
  /// 1-based page currently loaded.
  private(set) var page = 1
  /// Rows matching the current query and scope, not only this page.
  private(set) var totalCount = 0

  var pageCount: Int {
    guard totalCount > 0 else { return 1 }
    return (totalCount + Self.pageSize - 1) / Self.pageSize
  }

  var canGoPrevious: Bool { page > 1 }
  var canGoNext: Bool { page < pageCount }

  /// "1–50 of 230". An empty match is "0".
  static func pageLabel(page: Int, pageSize: Int, total: Int) -> String {
    guard total > 0 else { return "0" }
    let start = (page - 1) * pageSize + 1
    let end = min(page * pageSize, total)
    return "\(start.formatted())–\(end.formatted()) of \(total.formatted())"
  }

  var pageLabel: String {
    Self.pageLabel(page: page, pageSize: Self.pageSize, total: totalCount)
  }

  @ObservationIgnored var browser: @MainActor () -> QueryHistoryStore? = { nil }
  @ObservationIgnored var connectionKey: @MainActor () -> String? = { nil }
  @ObservationIgnored var workspaceID: @MainActor () -> UUID? = { nil }

  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var searchEpoch = 0
  /// Epoch whose results are in `results`. A newer reload can start while this one waits on
  /// the store; `searchNow` does not return until this catches up.
  @ObservationIgnored private var appliedEpoch = 0
  @ObservationIgnored private var searchWaiters: [CheckedContinuation<Void, Never>] = []
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
  /// Returns only after the results match this call or a newer one that superseded it.
  func searchNow() async {
    searchTask?.cancel()
    searchTask = nil
    searchEpoch += 1
    let epoch = searchEpoch
    page = 1
    await load(requestedPage: 1, epoch: epoch)
    if appliedEpoch >= epoch { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      if appliedEpoch >= epoch {
        continuation.resume()
      } else {
        searchWaiters.append(continuation)
      }
    }
  }

  /// Loads `newPage`, clamped to the pages that exist after the count returns.
  func goToPage(_ newPage: Int) async {
    searchTask?.cancel()
    searchTask = nil
    searchEpoch += 1
    let epoch = searchEpoch
    await load(requestedPage: max(newPage, 1), epoch: epoch)
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

  private func load(requestedPage: Int, epoch: Int) async {
    isLoading = true
    defer {
      if epoch == searchEpoch { isLoading = false }
    }
    guard let store = browser() else {
      guard epoch == searchEpoch else { return }
      results = []
      totalCount = 0
      page = 1
      publish(epoch)
      return
    }
    do {
      let scope = resolvedScope()
      let total = try await store.count(text: query, scope: scope)
      guard epoch == searchEpoch else { return }
      let pages = total == 0 ? 1 : (total + Self.pageSize - 1) / Self.pageSize
      let resolved = min(max(requestedPage, 1), pages)
      let offset = (resolved - 1) * Self.pageSize
      let rows = try await store.search(
        text: query, scope: scope, limit: Self.pageSize, offset: offset)
      guard epoch == searchEpoch else { return }
      totalCount = total
      page = resolved
      results = rows
      publish(epoch)
    } catch {
      guard epoch == searchEpoch else { return }
      results = []
      totalCount = 0
      page = 1
      publish(epoch)
      await AppLogger.shared.error(
        "Query history search failed: \(error.localizedDescription)", category: "History")
    }
  }

  /// Records that `epoch` is visible and wakes callers waiting on an older reload.
  private func publish(_ epoch: Int) {
    appliedEpoch = epoch
    guard epoch == searchEpoch, !searchWaiters.isEmpty else { return }
    let waiters = searchWaiters
    searchWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
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

  /// Copies `entry.sql` to the pasteboard.
  func copyHistory(_ entry: QueryHistoryEntry) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(Self.historyClipboardText(entry), forType: .string)
  }

  /// Deletes the rows from the store and reloads the page the user is on.
  func deleteHistory(ids: [Int64]) async {
    guard !ids.isEmpty, let store = resolvedHistoryBrowser() else { return }
    let staying = historyList.page
    do {
      try await store.delete(ids: ids)
      await historyList.goToPage(staying)
    } catch {
      await AppLogger.shared.error(
        "Query history delete failed: \(error.localizedDescription)", category: "History")
    }
  }

  /// Reloads the first page. The history sidebar calls this when it opens.
  /// A recorded statement calls it through `NotebookViewModel.onHistoryRecorded`.
  func refreshHistory() async {
    await historyList.searchNow()
  }
}
