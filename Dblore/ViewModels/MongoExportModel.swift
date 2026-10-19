// MongoExportModel.swift
// Export of a MongoDB collection, the applied query or an aggregation as Extended JSON or CSV.
// Asks where to save first, then streams every document (`streamMongoDocuments`, no document
// cap, read-only policy: an export is a read) into `MongoExportWriter`, page by page, off the
// main actor. Cancel stops the task and this export's server read only (killOp of its comment
// token); the temporary file is deleted on Cancel and on every failure. A pipeline that writes
// ($out / $merge) is refused before the save panel, and again by the gate. The CSV field picker
// lists the dot paths of a 100-document sample of the source, all checked.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MongoExportModel {
  /// What is exported
  enum Source: Hashable {
    /// `find({})` of the whole collection
    case collection
    /// The applied filter and find options
    case query
    /// The aggregation builder's pipeline
    case aggregation

    var title: String {
      switch self {
      case .collection: "Whole collection"
      case .query: "Current query"
      case .aggregation: "Aggregation pipeline"
      }
    }
  }

  enum Format: Hashable {
    case extendedJSON
    case csv
  }

  enum State: Equatable {
    case idle
    /// Reading the sample of the CSV field picker
    case sampling
    case running(written: Int)
    case done(count: Int, url: URL)
    case failed(String)
    case cancelled
  }

  /// Documents per getMore
  static let pageSize = 1000
  /// Documents read for the CSV field picker
  static let sampleSize = 100

  let collection: String
  /// The sources offered, in picker order
  let sources: [Source]
  var source: Source {
    didSet { if source != oldValue { resetFields() } }
  }
  /// Picking CSV reads the sample of the field picker; leaving CSV stops it quietly (switching
  /// back reads it again)
  var format = Format.extendedJSON {
    didSet {
      if format != .csv { stopSample() }
      loadFieldsIfNeeded()
    }
  }
  var jsonMode = MongoExportWriter.JSONMode.relaxed
  var jsonLayout = MongoExportWriter.JSONLayout.ndjson
  /// Dot paths of the sample, nil until read
  private(set) var fieldCandidates: [String]?
  var checkedFields: Set<String> = []
  /// Why the sample failed or was cancelled (Retry reads it again; JSON export still works)
  private(set) var fieldsError: String?
  private(set) var state = State.idle

  @ObservationIgnored private let database: String?
  @ObservationIgnored private let commands: [Source: MongoCommand]
  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  /// The tab's caller token (another tab's pending transaction refuses the read)
  @ObservationIgnored private let caller: UUID?
  /// The epoch the source was read under; a reconnect since then refuses the export
  @ObservationIgnored private var connectionEpoch: UInt64?
  @ObservationIgnored private var sampleTask: Task<Void, Never>?
  @ObservationIgnored private var runTask: Task<Void, Never>?
  /// The save panel is open: a second Export click opens no other one, and the form's options
  /// stay as they were when Export was clicked
  private(set) var choosingFile = false
  /// The comment token of the server read while it runs: Cancel kills that operation only
  @ObservationIgnored private var streamToken: String?
  /// The form closed: an export whose save panel was still open does not start
  @ObservationIgnored private var dismissed = false
  /// Bumped by every sample, export and cancel: results of an older one are dropped
  @ObservationIgnored private var generation = 0

  /// `query`: the applied filter and options, offered after the whole collection (and picked).
  /// `pipeline`: the aggregation to export, then the only source. `connectionEpoch`: the epoch
  /// the collection was listed under; nil reads the current one on `prepare()`.
  init(
    collection: String, database: String?, query: MongoCommand? = nil,
    pipeline: MongoCommand? = nil, connectionManager: DatabaseConnectionManager,
    caller: UUID? = nil, connectionEpoch: UInt64? = nil
  ) {
    var commands: [Source: MongoCommand] = [
      .collection: .find(
        collection: collection, filter: nil, projection: nil, sort: nil, skip: nil, limit: nil)
    ]
    if let query { commands[.query] = query }
    if let pipeline { commands = [.aggregation: pipeline] }
    let sources = [Source.collection, .query, .aggregation].filter { commands[$0] != nil }
    self.collection = collection
    self.database = database
    self.commands = commands
    self.sources = sources
    self.source = sources.last ?? .collection
    self.connectionManager = connectionManager
    self.caller = caller
    self.connectionEpoch = connectionEpoch
  }

  // MARK: - Derived

  var isRunning: Bool {
    if case .running = state { true } else { false }
  }

  /// The save panel is open or an export runs: the form's options are locked
  var isBusy: Bool { choosingFile || isRunning }

  /// The picked fields in sample order
  var pickedFields: [String] {
    (fieldCandidates ?? []).filter { checkedFields.contains($0) }
  }

  /// Why the selected source cannot be exported, nil when it can
  var refusal: String? {
    guard let command = commands[source] else { return "Nothing to export" }
    guard MongoCommandClassifier.classify(command, summary: command.render()).kind == .read
    else { return "A stage writes data ($out or $merge): such a pipeline is not exported" }
    return nil
  }

  var canExport: Bool {
    switch state {
    case .sampling, .running: return false
    case .idle, .done, .failed, .cancelled: break
    }
    return refusal == nil && (format == .extendedJSON || !pickedFields.isEmpty)
  }

  private var writerFormat: MongoExportWriter.Format {
    switch format {
    case .extendedJSON: .extendedJSON(mode: jsonMode, layout: jsonLayout)
    case .csv: .csv(fields: pickedFields)
    }
  }

  // MARK: - Field picker

  /// Reads the connection epoch when none was given, then the CSV sample when CSV is picked
  func prepare() async {
    if connectionEpoch == nil { connectionEpoch = await connectionManager.connectionEpoch }
    loadFieldsIfNeeded()
  }

  /// Reads the sample of the source once CSV is picked and no sample was read for it
  func loadFieldsIfNeeded() {
    guard format == .csv, fieldCandidates == nil, sampleTask == nil, !isRunning,
      let command = commands[source]
    else { return }
    generation += 1
    let current = generation
    state = .sampling
    fieldsError = nil
    let manager = connectionManager
    let (source, database, collection) = (self.source, self.database, self.collection)
    let epoch = connectionEpoch
    sampleTask = Task { [weak self] in
      let outcome: Result<[String], any Error>
      do {
        let documents: [MongoValue]
        if source == .collection {
          documents = try await manager.sampleMongoDocuments(
            database: database, collection: collection, filterText: "", size: Self.sampleSize)
        } else {
          documents = try await manager.executeMongoDocuments(
            userSQL: command.render(), policy: ProtectionPolicy(protectionLevel: .readOnly),
            maxRows: Self.sampleSize, expectedEpoch: epoch
          ).documents
        }
        try Task.checkCancellation()
        outcome = .success(
          await Task.detached(priority: .userInitiated) { Self.fieldPaths(documents) }.value)
      } catch {
        outcome = .failure(error)
      }
      guard let self, self.generation == current, !Task.isCancelled else { return }
      self.sampleTask = nil
      self.state = .idle
      switch outcome {
      case .success(let paths):
        self.fieldCandidates = paths
        self.checkedFields = Set(paths)
      case .failure(let error):
        self.fieldsError = "The sample could not be read: \(error.localizedDescription)"
      }
    }
  }

  private func resetFields() {
    if sampleTask != nil {
      sampleTask?.cancel()
      sampleTask = nil
      if state == .sampling { state = .idle }
    }
    fieldCandidates = nil
    checkedFields = []
    fieldsError = nil
    loadFieldsIfNeeded()
  }

  /// The dot paths of `documents` in order of first appearance, `_id` first: nested documents
  /// are walked (an empty one is a leaf), arrays are leaves. Keys holding "." or starting with
  /// "$" are skipped: a dot path cannot address them.
  nonisolated static func fieldPaths(_ documents: [MongoValue]) -> [String] {
    var paths: [String] = []
    var seen: Set<String> = []
    func walk(_ fields: [MongoValue.Field], prefix: String) {
      for field in fields where !field.key.contains(".") && !field.key.hasPrefix("$") {
        let path = prefix + field.key
        if case .document(let nested) = field.value, !nested.isEmpty {
          walk(nested, prefix: path + ".")
        } else if seen.insert(path).inserted {
          paths.append(path)
        }
      }
    }
    for case .document(let fields) in documents { walk(fields, prefix: "") }
    let id = paths.filter { $0 == "_id" || $0.hasPrefix("_id.") }
    return id + paths.filter { $0 != "_id" && !$0.hasPrefix("_id.") }
  }

  // MARK: - Export

  /// Asks where to save, then streams the source into the file. Nothing is read when the save
  /// panel is cancelled.
  func export() async {
    guard canExport, !choosingFile, let command = commands[source] else { return }
    let format = writerFormat
    let fileExtension = self.format == .csv ? "csv" : "json"
    // Cleared once the export runs (or on an early exit): a second click opens no other panel
    choosingFile = true
    defer { choosingFile = false }
    let chosen = await Self.chooseSaveURL(
      name: "\(collection).\(fileExtension)", fileExtension: fileExtension)
    if connectionEpoch == nil { connectionEpoch = await connectionManager.connectionEpoch }
    guard !dismissed, let url = chosen, canExport else { return }
    let writer: MongoExportWriter
    do {
      writer = try MongoExportWriter(destination: url, format: format)
    } catch {
      state = .failed(error.localizedDescription)
      return
    }
    generation += 1
    let current = generation
    state = .running(written: 0)
    let token = "dblore:export:\(UUID().uuidString)"
    let manager = connectionManager
    let (caller, epoch) = (self.caller, connectionEpoch)
    let progress: @Sendable (Int) async -> Void = { [weak self] written in
      await self?.report(written: written, generation: current)
    }
    runTask = Task { [weak self] in
      let outcome: State
      do {
        let count = try await PerfSignpost.interval("mongo.export") {
          try Task.checkCancellation()
          self?.streamToken = token
          do {
            _ = try await manager.streamMongoDocuments(
              command, policy: ProtectionPolicy(protectionLevel: .readOnly),
              pageSize: Self.pageSize, caller: caller, expectedEpoch: epoch,
              statementToken: token
            ) { page in
              try Task.checkCancellation()
              try await writer.write(page)
              await progress(await writer.documentsWritten)
            }
          } catch {
            self?.streamToken = nil
            throw error
          }
          self?.streamToken = nil
          try Task.checkCancellation()
          try await writer.finish()
          return await writer.documentsWritten
        }
        outcome = .done(count: count, url: url)
      } catch {
        await writer.cancel()
        let cancelled = Self.isCancellation(error) || Task.isCancelled
        outcome = cancelled ? .cancelled : .failed(error.localizedDescription)
      }
      guard let self, self.generation == current else { return }
      self.runTask = nil
      self.state = outcome
    }
  }

  private func report(written: Int, generation current: Int) {
    guard generation == current, isRunning else { return }
    state = .running(written: written)
  }

  /// Stops a sample (back to idle, Retry reads it again) or an export: the task, and this
  /// export's server read (killOp) while it runs. The export ends as `.cancelled` with no file
  /// left.
  func cancel() {
    if stopSample() {
      fieldsError = "Reading the sample was cancelled."
      return
    }
    guard isRunning, let runTask else { return }
    runTask.cancel()
    guard let streamToken else { return }
    let manager = connectionManager
    Task { await manager.interruptMongoStatement(token: streamToken) }
  }

  /// Stops a running sample, back to idle with no field list; false when none runs
  @discardableResult
  private func stopSample() -> Bool {
    guard let sampleTask else { return false }
    sampleTask.cancel()
    self.sampleTask = nil
    generation += 1
    if state == .sampling { state = .idle }
    return true
  }

  /// The form closed (refused by the presenters while an export runs): stops a sample, and an
  /// export whose save panel is still open does not start
  func dismiss() {
    dismissed = true
    cancel()
  }

  /// Opens the exported file's folder with the file selected
  func showInFinder() {
    guard case .done(_, let url) = state else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  nonisolated private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case DatabaseError.queryCancelled = error { return true }
    return false
  }

  private static func chooseSaveURL(name: String, fileExtension: String) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = UTType(filenameExtension: fileExtension).map { [$0] } ?? []
    panel.canCreateDirectories = true
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}
