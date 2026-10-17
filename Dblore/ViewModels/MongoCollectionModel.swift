//
//  MongoCollectionModel.swift
//  Dblore
//
//  One MongoDB collection screen of a data viewer tab: the selected section, the aggregation
//  builder, the indexes, read on demand, and the schema analysis of a document sample. Lives on
//  `NotebookViewModel` (not in `DataViewerState`, which is Equatable and feeds the page load
//  key) and is replaced when the viewer shows another collection.
//

import Foundation
import Observation

@Observable
@MainActor
final class MongoCollectionModel {
  /// Sections of the collection screen, in tab bar order.
  enum Section: String, CaseIterable, Identifiable {
    case documents
    case aggregations
    case schema
    case indexes

    var id: String { rawValue }

    var title: String {
      switch self {
      case .documents: "Documents"
      case .aggregations: "Aggregations"
      case .schema: "Schema"
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

  enum SchemaState: Equatable {
    case idle
    case analyzing
    case done(MongoSchemaAnalyzer.Report)
    /// User-facing error text
    case failed(String)
  }

  enum ExplainState: Equatable {
    case idle
    case running
    /// The raw explain reply (indented relaxed JSON), its plan tree and its summary; nil when
    /// the reply has no shape the adapter reads
    case done(text: String, plan: ExplainPlan?, summary: MongoExplainAdapter.Summary?)
    /// User-facing error text
    case failed(String)
  }

  /// Database of the collection (the data viewer's schema), nil when the viewer names none.
  let database: String?
  let collection: String
  /// Written by the tab bar and by the assistant's actions, never a view body: the first
  /// switch to Aggregations builds the builder
  var section: Section = .documents {
    didSet {
      if section == .aggregations, aggregationModel == nil { makeAggregationModel() }
    }
  }
  /// Builder of the Aggregations section, nil until it is first shown; kept while the screen
  /// shows the same collection
  private(set) var aggregationModel: AggregationBuilderModel?
  private(set) var indexState: IndexState = .idle
  /// Filter of the schema sample (relaxed JSON document text, blank for a random sample).
  var schemaFilter: String = ""
  private(set) var schemaState: SchemaState = .idle
  private(set) var explainState: ExplainState = .idle
  /// Filter text set by the assistant, consumed (and reset to nil) by `MongoFilterBar`.
  var pendingFilterDraft: String?

  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private var indexTask: Task<Void, Never>?
  @ObservationIgnored private var schemaTask: Task<Void, Never>?
  @ObservationIgnored private var explainTask: Task<Void, Never>?
  /// The report shown before the analysis in flight (`.done` or `.idle`), restored on cancel.
  @ObservationIgnored private var previousSchemaState: SchemaState = .idle

  init(database: String?, collection: String, connectionManager: DatabaseConnectionManager) {
    self.database = database
    self.collection = collection
    self.connectionManager = connectionManager
  }

  /// Show Documents and hand the text to the filter bar's draft (not applied).
  func insertFilterDraft(_ text: String) {
    section = .documents
    pendingFilterDraft = text
  }

  /// Show Aggregations (building the builder on first use) with the given stages in place of
  /// the current ones. Nothing runs.
  func showGeneratedPipeline(_ stages: [AIMongoAssist.GeneratedStage]) {
    section = .aggregations
    aggregationModel?.replaceStages(stages)
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

  /// Drop the reads in flight; their results are ignored. A cancelled read can start again.
  func cancel() {
    indexTask?.cancel()
    indexTask = nil
    if case .loading = indexState { indexState = .idle }
    cancelSchemaAnalysis()
    cancelExplain()
  }

  /// Sample the collection with `schemaFilter` and analyze it, dropping an analysis in flight.
  /// The read runs on the connection manager actor and the analysis in a detached task, both
  /// off the main actor; a cancelled or superseded analysis never writes its result.
  func analyzeSchema() {
    schemaTask?.cancel()
    switch schemaState {
    case .analyzing: break
    case .done: previousSchemaState = schemaState
    case .idle, .failed: previousSchemaState = .idle
    }
    schemaState = .analyzing
    let connectionManager = connectionManager
    let database = database
    let collection = collection
    let filterText = schemaFilter
    schemaTask = Task { [weak self] in
      let state: SchemaState
      do {
        let documents = try await connectionManager.sampleMongoDocuments(
          database: database, collection: collection, filterText: filterText)
        try Task.checkCancellation()
        state = .done(
          await Task.detached(priority: .userInitiated) {
            MongoSchemaAnalyzer.analyze(documents, calendar: .current)
          }.value)
      } catch {
        state = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      self.schemaState = state
      self.schemaTask = nil
    }
  }

  /// Drop the analysis in flight and show the previous result again (`.idle` when none).
  func cancelSchemaAnalysis() {
    schemaTask?.cancel()
    schemaTask = nil
    guard case .analyzing = schemaState else { return }
    schemaState = previousSchemaState
  }

  /// Explain `command` (the Documents find or the pipeline's aggregate) at executionStats,
  /// dropping an explain in flight. It goes through the gate with a read-only policy, as the
  /// aggregation previews do, so a write (`$out`, `$merge`) is refused before anything is
  /// sent. The read runs on the connection manager actor and the parsing in a detached task;
  /// a cancelled or superseded explain never writes its result.
  func explain(_ command: MongoCommand) {
    explainTask?.cancel()
    explainTask = nil
    switch command {
    case .find, .aggregate: break
    default:
      explainState = .failed("Only find and aggregate can be explained")
      return
    }
    explainState = .running
    let text = MongoCommand.explain(command, verbosity: "executionStats").render()
    let connectionManager = connectionManager
    explainTask = Task { [weak self] in
      let state: ExplainState
      do {
        let result = try await connectionManager.execute(
          userSQL: text, policy: ProtectionPolicy(protectionLevel: .readOnly), maxRows: 1)
        try Task.checkCancellation()
        guard let json = Self.explainText(result) else {
          throw ExplainError(message: "The server returned no explain output")
        }
        state = await Task.detached(priority: .userInitiated) {
          ExplainState.done(
            text: json, plan: MongoExplainAdapter.plan(fromJSON: json),
            summary: MongoExplainAdapter.summary(fromJSON: json))
        }.value
      } catch {
        state = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      self.explainState = state
      self.explainTask = nil
    }
  }

  /// Drop the explain in flight; nothing is shown for it.
  func cancelExplain() {
    explainTask?.cancel()
    explainTask = nil
    if case .running = explainState { explainState = .idle }
  }

  /// Close the explain result (or drop the explain in flight).
  func dismissExplain() {
    cancelExplain()
    explainState = .idle
  }

  /// Text of the `EXPLAIN` cell of an explain result, nil when there is none.
  private nonisolated static func explainText(_ result: QueryResult) -> String? {
    guard let index = result.columns.firstIndex(where: { $0.name == "EXPLAIN" }),
      let row = result.rows.first, row.indices.contains(index),
      case .json(let text) = row[index]
    else { return nil }
    return text
  }

  private struct ExplainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// A builder on the collection with one empty stage, as the sidebar's Build Aggregation opens.
  private func makeAggregationModel() {
    let model = AggregationBuilderModel(
      collection: collection, connectionManager: connectionManager)
    model.addStage()
    aggregationModel = model
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
