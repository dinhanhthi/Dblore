//
//  MongoCollectionModel.swift
//  Dblore
//
//  One MongoDB collection screen of a data viewer tab: the selected section and the indexes,
//  read on demand. Lives on `NotebookViewModel` (not in `DataViewerState`, which is Equatable
//  and feeds the page load key) and is replaced when the viewer shows another collection.
//

import Foundation
import Observation

@Observable
@MainActor
final class MongoCollectionModel {
  /// Sections of the collection screen, in tab bar order.
  enum Section: String, CaseIterable, Identifiable {
    case documents
    case indexes

    var id: String { rawValue }

    var title: String {
      switch self {
      case .documents: "Documents"
      case .indexes: "Indexes"
      }
    }
  }

  enum IndexState: Equatable {
    case idle
    case loading
    case loaded(MongoIndexesResult)
    /// User-facing error text
    case failed(String)
  }

  /// Database of the collection (the data viewer's schema), nil when the viewer names none.
  let database: String?
  let collection: String
  var section: Section = .documents
  private(set) var indexState: IndexState = .idle

  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private var indexTask: Task<Void, Never>?

  init(database: String?, collection: String, connectionManager: DatabaseConnectionManager) {
    self.database = database
    self.collection = collection
    self.connectionManager = connectionManager
  }

  /// Read the indexes once: only while nothing was loaded or tried yet.
  func loadIndexesIfNeeded() {
    guard case .idle = indexState else { return }
    startIndexLoad()
  }

  /// Read the indexes again, dropping a read in flight.
  func refreshIndexes() {
    startIndexLoad()
  }

  /// Drop a read in flight; its result is ignored. A cancelled read can start again.
  func cancel() {
    indexTask?.cancel()
    indexTask = nil
    if case .loading = indexState { indexState = .idle }
  }

  /// The read runs on the connection manager actor, off the main actor; a cancelled or
  /// superseded read never writes its result.
  private func startIndexLoad() {
    indexTask?.cancel()
    indexState = .loading
    let connectionManager = connectionManager
    let database = database
    let collection = collection
    indexTask = Task { [weak self] in
      let state: IndexState
      do {
        state = .loaded(
          try await connectionManager.fetchMongoIndexes(
            database: database, collection: collection))
      } catch {
        state = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      self.indexState = state
      self.indexTask = nil
    }
  }
}
