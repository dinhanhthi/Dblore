//
//  MongoCollectionModel.swift
//  Dblore
//
//  One MongoDB collection screen of a data viewer tab: the selected section, the aggregation
//  builder, the indexes and the validation rules, read on demand, and the schema analysis of a
//  document sample. Lives on
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
    case validation

    var id: String { rawValue }

    var title: String {
      switch self {
      case .documents: "Documents"
      case .aggregations: "Aggregations"
      case .schema: "Schema"
      case .indexes: "Indexes"
      case .validation: "Validation"
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

  enum ValidationState: Equatable {
    case idle
    case loading
    case loaded(MongoCollectionInfo)
    /// User-facing error text
    case failed(String)
  }

  /// Generate from Sample of the Validation section
  enum ValidationSampleState: Equatable {
    case idle
    case sampling
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
  /// Connection epoch the shown indexes were read with: an index change is gated by it, so a
  /// reconnect since the read refuses it. Nil until a read finished.
  private(set) var indexEpoch: UInt64?
  /// Names of the index rows showing their key, kept across section switches
  var expandedIndexes: Set<String> = []
  /// What the server can do (hidden indexes), nil until read
  private(set) var serverFeatures: MongoServerFeatures?
  private(set) var validationState: ValidationState = .idle
  /// Connection epoch the shown rules were read with (see `indexEpoch`). Nil until a read
  /// finished.
  private(set) var validationEpoch: UInt64?
  /// The rules being edited, kept across section switches; reset to the collection's rules on
  /// each read
  var validatorDraft: String = ""
  var validationLevelDraft: MongoValidationRules.Level = .strict
  var validationActionDraft: MongoValidationRules.Action = .error
  private(set) var validationSampleState: ValidationSampleState = .idle
  /// Filter of the schema sample (relaxed JSON document text, blank for a random sample).
  var schemaFilter: String = ""
  private(set) var schemaState: SchemaState = .idle
  private(set) var explainState: ExplainState = .idle
  /// Filter text set by the assistant, consumed (and reset to nil) by `MongoFilterBar`.
  var pendingFilterDraft: String?
  /// The Bulk Update / Delete form of the Documents header, shown by `DataViewerView` while set
  var bulkWrite: MongoBulkWriteModel?
  /// The Export form of the Documents header, shown by `DataViewerView` while set
  var export: MongoExportModel?

  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private var indexTask: Task<Void, Never>?
  @ObservationIgnored private var schemaTask: Task<Void, Never>?
  @ObservationIgnored private var explainTask: Task<Void, Never>?
  @ObservationIgnored private var featuresTask: Task<Void, Never>?
  @ObservationIgnored private var validationTask: Task<Void, Never>?
  @ObservationIgnored private var validationSampleTask: Task<Void, Never>?
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

  /// Read the validation rules once: only while nothing was loaded or tried yet.
  func loadValidationIfNeeded() {
    guard case .idle = validationState else { return }
    startValidationLoad()
  }

  /// Read the validation rules again, dropping a read in flight; the draft is reset to them.
  func refreshValidation() {
    startValidationLoad()
  }

  /// Sample the whole collection (random, no filter), analyze it and put its `$jsonSchema` in
  /// the validator draft, dropping a sample in flight. Runs off the main actor like
  /// `analyzeSchema`; the Schema section's report is left alone. A cancelled or superseded
  /// sample never writes the draft.
  func generateValidatorFromSample() {
    validationSampleTask?.cancel()
    validationSampleState = .sampling
    let connectionManager = connectionManager
    let database = database
    let collection = collection
    validationSampleTask = Task { [weak self] in
      let validator: MongoValue
      do {
        let documents = try await connectionManager.sampleMongoDocuments(
          database: database, collection: collection, filterText: "")
        try Task.checkCancellation()
        let report = await Task.detached(priority: .userInitiated) {
          PerfSignpost.interval("mongo.validation.sample") {
            MongoSchemaAnalyzer.analyze(documents, calendar: .current)
          }
        }.value
        validator = try MongoValidationRules.fromSample(report)
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.validationSampleState = .failed(error.localizedDescription)
        self.validationSampleTask = nil
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.validatorDraft =
        MongoValidationRules(
          validator: validator, level: self.validationLevelDraft,
          action: self.validationActionDraft
        ).validatorText
      self.validationSampleState = .idle
      self.validationSampleTask = nil
    }
  }

  /// Drop the sample in flight; the draft is unchanged.
  func cancelValidationSample() {
    validationSampleTask?.cancel()
    validationSampleTask = nil
    validationSampleState = .idle
  }

  /// Read the server version once (cached by the session; an unknown version shows every
  /// action).
  func loadServerFeaturesIfNeeded() {
    guard serverFeatures == nil, featuresTask == nil else { return }
    let connectionManager = connectionManager
    featuresTask = Task { [weak self] in
      let features = await connectionManager.mongoServerVersion()
      self?.serverFeatures = features
      self?.featuresTask = nil
    }
  }

  /// Drop the reads in flight; their results are ignored. A cancelled read can start again. An
  /// export is stopped too (no file left), and one whose save panel is open does not start.
  func cancel() {
    export?.dismiss()
    indexTask?.cancel()
    indexTask = nil
    if case .loading = indexState { indexState = .idle }
    validationTask?.cancel()
    validationTask = nil
    if case .loading = validationState { validationState = .idle }
    cancelValidationSample()
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
      let epoch = await connectionManager.connectionEpoch
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
      self.indexEpoch = epoch
      self.indexTask = nil
    }
  }

  /// Like `startIndexLoad`; a successful read resets the draft to the collection's rules.
  private func startValidationLoad() {
    validationTask?.cancel()
    validationState = .loading
    let connectionManager = connectionManager
    let database = database
    let collection = collection
    validationTask = Task { [weak self] in
      let epoch = await connectionManager.connectionEpoch
      let state: ValidationState
      do {
        state = .loaded(
          try await connectionManager.fetchMongoCollectionInfo(
            database: database, collection: collection))
      } catch {
        state = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      if case .loaded(let info) = state {
        let rules = MongoValidationRules(options: info.options)
        self.validatorDraft = rules.validatorText
        self.validationLevelDraft = rules.level
        self.validationActionDraft = rules.action
      }
      self.validationState = state
      self.validationEpoch = epoch
      self.validationTask = nil
    }
  }
}
