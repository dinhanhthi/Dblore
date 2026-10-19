// MongoImportModel.swift
// Import of a JSON array, NDJSON or CSV file into an existing or a new MongoDB collection. The
// file is read and checked off the main actor (`MongoImportReader`), then split into insert
// batches (`MongoInsertBatcher`) before anything is asked or sent, so a bad record or a document
// over the server limit stops the import with nothing sent. Refuses up front on protected
// connections with the gate's text, then shows one confirmation for the whole import (the Safe
// Mode panel per commit style; Review counts as Confirm). A new collection is created first;
// each batch then goes through `executeGatedMongoCommands` with the epoch read at open (which
// re-checks every refusal). Cancel stops between batches: the batch in flight finishes (the
// typed gate has no per-statement token to kill it alone). One History row under `.dataImport`
// holds a mongosh comment, so Insert / Copy from History never run anything.

import Foundation
import Observation

@MainActor
@Observable
final class MongoImportModel {
  /// Where the documents go
  enum Target: Equatable {
    case existing(String)
    /// Created with `createCollection` before the first insert
    case new(String)

    var collection: String {
      switch self {
      case .existing(let name), .new(let name): name
      }
    }
  }

  /// What the confirm sheet shows before anything is sent
  struct Confirmation: Equatable {
    /// One per request: a late answer meant for an earlier confirmation never sends a later one
    let id = UUID()
    let fileName: String
    let target: Target
    let documentCount: Int
    let needsSafeModePanel: Bool
    let requiresPassword: Bool
  }

  enum State: Equatable {
    case idle
    /// Reading and checking the file
    case loading
    /// Splitting the documents into insert batches
    case preparing
    case confirming(Confirmation)
    case running(inserted: Int, total: Int)
    /// The result line
    case done(String)
    case failed(String)
    case cancelled(String)
  }

  /// Documents shown in the preview
  static let previewCount = 5

  private(set) var state = State.idle
  private(set) var fileURL: URL?
  private(set) var format: MongoImportReader.Format?
  /// CSV only: the columns the documents were built with (inferred types, overrides)
  private(set) var columns: [MongoImportReader.Column] = []
  private(set) var documentCount = 0
  /// The first converted documents
  private(set) var preview: [MongoValue] = []
  /// Cancel was asked while the import runs: it stops after the batch in flight
  private(set) var cancelRequested = false
  /// An import of the loaded documents ran (something may have been written): a new Import
  /// waits for the file to be loaded again, so no document is sent twice
  private(set) var importStarted = false

  @ObservationIgnored private let context: MongoAdminContext
  /// The epoch the form was opened under; a reconnect since then refuses every batch
  @ObservationIgnored private let connectionEpoch: UInt64
  /// Called after an import ran (to refresh the sidebar)
  @ObservationIgnored private let onFinished: (@MainActor () async -> Void)?
  @ObservationIgnored private var documents: [MongoValue] = []
  /// The batches of the pending confirmation
  @ObservationIgnored private var pendingBatches: [[MongoValue]] = []
  @ObservationIgnored private var limits: MongoWriteLimits?
  /// Stops the read or split under way
  @ObservationIgnored private var stopWork: (@Sendable () -> Void)?
  /// The form closed: nothing new starts
  @ObservationIgnored private var dismissed = false
  /// Bumped by every load, request and cancel: results of an older one are dropped
  @ObservationIgnored private var generation = 0

  init(
    context: MongoAdminContext, connectionEpoch: UInt64,
    onFinished: (@MainActor () async -> Void)?
  ) {
    self.context = context
    self.connectionEpoch = connectionEpoch
    self.onFinished = onFinished
  }

  /// The model for `tab`'s connection, nil when the tab is not connected. `onFinished` runs
  /// after an import ran, before the sidebar reload.
  convenience init?(
    tab: NotebookViewModel, connectionEpoch: UInt64,
    onFinished: (@MainActor () -> Void)? = nil
  ) {
    guard let manager = tab.connectionManager, let config = tab.notebook.connectionConfig else {
      return nil
    }
    self.init(
      context: MongoAdminContext(
        manager: manager, policy: tab.protectionPolicy,
        commitStyle: { [weak tab] in
          (tab?.notebook.connectionConfig ?? config)
            .resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
        },
        caller: tab.id,
        // Strong: the History row and the sidebar refresh still happen when the tab closed
        // while the import ran (the tab does not hold the model)
        recordHistory: { await tab.recordExecution($0, source: .dataImport) },
        database: config.database.isEmpty ? MongoSession.defaultDatabase : config.database),
      connectionEpoch: connectionEpoch,
      onFinished: {
        onFinished?()
        await tab.onStatementsExecuted?()
      })
  }

  // MARK: - Derived

  var isRunning: Bool {
    if case .running = state { true } else { false }
  }

  /// Reading, preparing or importing: the form's options are locked
  var isBusy: Bool {
    switch state {
    case .loading, .preparing, .running: true
    case .idle, .confirming, .done, .failed, .cancelled: false
    }
  }

  // MARK: - File

  /// Reads `url` off the main actor: `format` nil detects it, `columns` (CSV) are the columns
  /// with the user's overrides (nil infers them). A bad record stops the read with its number.
  func load(
    url: URL, format: MongoImportReader.Format? = nil,
    columns: [MongoImportReader.Column]? = nil
  ) async {
    guard !dismissed, !isRunning else { return }
    stopWork?()
    generation += 1
    let current = generation
    state = .loading
    if url != fileURL {
      self.format = nil
      self.columns = []
    }
    // Kept when the read fails, so a bad override can be changed back
    if let columns { self.columns = columns }
    fileURL = url
    documents = []
    importStarted = false
    pendingBatches = []
    documentCount = 0
    preview = []
    let maxBsonObjectSize = await writeLimits().maxBsonObjectSize
    guard generation == current else { return }
    let reading = Task.detached(priority: .userInitiated) {
      let format = try format ?? MongoImportReader.detect(url: url)
      let output = try MongoImportReader.read(
        url: url, format: format, columns: columns, maxBsonObjectSize: maxBsonObjectSize)
      return (format, output)
    }
    stopWork = { reading.cancel() }
    let result = await withTaskCancellationHandler {
      await reading.result
    } onCancel: {
      reading.cancel()
    }
    guard generation == current else { return }
    stopWork = nil
    switch result {
    case .success(let (format, output)):
      self.format = format
      self.columns = output.columns
      documents = output.documents
      documentCount = output.documents.count
      preview = Array(output.documents.prefix(Self.previewCount))
      state = .idle
    case .failure(let error):
      state = error is CancellationError ? .idle : .failed(error.localizedDescription)
    }
  }

  // MARK: - Import

  /// Does nothing once an import of the loaded documents ran (`importStarted`). Refuses an empty
  /// file, a bad new collection name and, before any prompt, a protected connection (read-only;
  /// schema-only for a new collection; Protected mode) with the gate's text. Then splits
  /// the documents into batches (a document over the server limit stops here) and asks for the
  /// one confirmation, or imports at once when the commit style asks nothing.
  func request(target: Target) async {
    var target = target
    if case .new(let name) = target {
      target = .new(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    switch state {
    case .loading, .preparing, .running: return
    case .idle, .confirming, .done, .failed, .cancelled: break
    }
    guard !dismissed, !importStarted, let fileURL else { return }
    generation += 1
    let current = generation
    cancelRequested = false
    pendingBatches = []
    guard !documents.isEmpty else {
      state = .failed("The file holds no documents; nothing was sent.")
      return
    }
    if case .new(let name) = target, let problem = MongoCollectionDraft.nameProblem(name) {
      state = .failed(problem)
      return
    }
    let reason = await refusal(for: target)
    guard generation == current, !dismissed else { return }
    if let reason {
      state = .failed(reason)
      return
    }
    state = .preparing
    let limits = await writeLimits()
    guard generation == current, !dismissed else { return }
    let documents = self.documents
    let splitting = Task.detached(priority: .userInitiated) {
      try Self.batches(of: documents, limits: limits)
    }
    stopWork = { splitting.cancel() }
    let result = await splitting.result
    guard generation == current, !dismissed else { return }
    stopWork = nil
    let batches: [[MongoValue]]
    switch result {
    case .success(let value): batches = value
    case .failure(let error):
      state = error is CancellationError ? .idle : .failed(error.localizedDescription)
      return
    }
    let commitStyle = context.commitStyle()
    let pending = Confirmation(
      fileName: fileURL.lastPathComponent, target: target, documentCount: documents.count,
      needsSafeModePanel: commitStyle != .immediate,
      requiresPassword: commitStyle.requiresPassword)
    guard pending.needsSafeModePanel else {
      await run(pending, batches: batches)
      return
    }
    pendingBatches = batches
    state = .confirming(pending)
  }

  /// Whether `confirmation` is still the one being asked (not cancelled or replaced since)
  func isPending(_ confirmation: Confirmation) -> Bool {
    if case .confirming(let current) = state { return current.id == confirmation.id }
    return false
  }

  /// Imports `confirmation`'s documents while it is still the one being asked; the Safe Mode
  /// panel (password / Touch ID) is verified by the sheet before this.
  func confirm(_ confirmation: Confirmation) async {
    guard !dismissed, isPending(confirmation) else { return }
    let batches = pendingBatches
    pendingBatches = []
    await run(confirmation, batches: batches)
  }

  /// Leaves a confirmation or a failure, stops a read or a split, or asks a running import to
  /// stop after the batch in flight (no rollback: the batches sent stay imported).
  func cancel() {
    switch state {
    case .running:
      cancelRequested = true
    case .loading, .preparing:
      stopWork?()
      stopWork = nil
      generation += 1
      state = .idle
    case .confirming, .failed:
      pendingBatches = []
      state = .idle
    case .idle, .done, .cancelled:
      break
    }
  }

  /// The form closed (refused by the presenters while an import runs): nothing new starts and
  /// a running import stops after its batch
  func dismiss() {
    dismissed = true
    cancel()
  }

  // MARK: - Private

  /// The gate's refusal of the import's commands under its effective policy (the connection's
  /// rules and Protected mode), nil when allowed
  private func refusal(for target: Target) async -> String? {
    var commands: [MongoCommand] = [.insertMany(collection: target.collection, documents: [])]
    if case .new(let name) = target {
      commands.insert(.admin(.createCollection(name: name, options: nil)), at: 0)
    }
    let classified = commands.map { MongoCommandClassifier.classify($0, summary: $0.render()) }
    let policy = await context.manager.effectivePolicy(for: context.policy)
    if case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
      classified, policy: policy, dialect: .mongodb)
    {
      return reason
    }
    return nil
  }

  private func writeLimits() async -> MongoWriteLimits {
    if let limits { return limits }
    let read = await context.manager.mongoWriteLimits()
    // `.fallback` means `hello` failed: asked again next time
    if read != .fallback { limits = read }
    return read
  }

  /// Creates a new target, then sends the batches one by one; records one History row and
  /// refreshes the sidebar whatever the outcome.
  private func run(_ confirmation: Confirmation, batches: [[MongoValue]]) async {
    let target = confirmation.target
    let collection = target.collection
    let total = confirmation.documentCount
    importStarted = true
    state = .running(inserted: 0, total: total)
    let started = Date()
    var inserted = 0
    var summary: String?
    var status = QueryHistoryEntry.Status.success
    await PerfSignpost.interval("mongo.import") {
      if case .new(let name) = target {
        do {
          try await send(.admin(.createCollection(name: name, options: nil)), expectedRows: nil)
        } catch {
          state = .failed(
            "The collection could not be created: \(Self.reason(error)); nothing was imported.")
          (status, summary) = (.error, "The collection could not be created")
          return
        }
      }
      for (index, batch) in batches.enumerated() {
        if cancelRequested {
          state = .cancelled(
            "Imported \(inserted) of \(total) documents; cancelled. The documents already "
              + "imported stay in the collection.")
          (status, summary) = (.cancelled, "Import cancelled")
          return
        }
        do {
          try await send(
            .insertMany(collection: collection, documents: batch), expectedRows: batch.count)
        } catch {
          // The ordered insert keeps the documents before the failing one
          if case DatabaseError.batchPartiallyApplied(_, _, _, let written?) = error {
            inserted += written
          }
          let failed = "Imported \(inserted) of \(total) documents; batch \(index + 1) failed"
          state = .failed("\(failed): \(Self.reason(error))")
          // History leaves out the server's reason: it can quote file values
          (status, summary) = (.error, failed)
          return
        }
        inserted += batch.count
        state = .running(inserted: inserted, total: total)
      }
      state = .done("Imported \(inserted) documents into \(collection).")
    }
    cancelRequested = false
    await context.recordHistory([
      QueryHistoryOutcome(
        sql: Self.historyText(
          inserted: inserted, collection: collection,
          fileName: confirmation.fileName),
        duration: Date().timeIntervalSince(started), rowCount: inserted, status: status,
        errorMessage: summary, importSummary: summary)
    ])
    await onFinished?()
  }

  private func send(_ command: MongoCommand, expectedRows: Int?) async throws {
    _ = try await context.manager.executeGatedMongoCommands(
      [command], policy: context.policy, connectionEpoch: connectionEpoch,
      caller: context.caller, expectedRows: expectedRows.map { [$0] })
  }

  /// The server's or the gate's reason for one failed command
  private static func reason(_ error: any Error) -> String {
    if case DatabaseError.batchPartiallyApplied(_, _, let reason, _) = error { return reason }
    if case DatabaseError.notEditable = error {
      return "the connection changed since the import was opened"
    }
    return error.localizedDescription
  }

  /// One mongosh comment line: a name holding a line break cannot end the comment, and format
  /// characters (bidi overrides and the like) are dropped so a name cannot reorder the line
  private static func historyText(inserted: Int, collection: String, fileName: String) -> String {
    func oneLine(_ text: String) -> String {
      let visible = String(
        String.UnicodeScalarView(
          text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
      return visible.components(separatedBy: .newlines.union(.controlCharacters))
        .joined(separator: " ")
    }
    return "// Imported \(inserted) documents into \(oneLine(collection)) from \(oneLine(fileName))"
  }

  /// `documents` in insert batches; a document the server would refuse stops with its number
  nonisolated private static func batches(
    of documents: [MongoValue], limits: MongoWriteLimits
  ) throws -> [[MongoValue]] {
    try PerfSignpost.interval("import.mongo.batches") {
      var batcher = MongoInsertBatcher(limits: limits)
      var batches: [[MongoValue]] = []
      for (index, document) in documents.enumerated() {
        if index % 256 == 0 { try Task.checkCancellation() }
        do {
          if let full = try batcher.append(document, record: index + 1) { batches.append(full) }
        } catch let error as MongoInsertBatcher.OversizeDocument {
          let limit = ByteCountFormatter.string(
            fromByteCount: Int64(error.limit), countStyle: .memory)
          throw MongoImportError(
            message: "Stopped at document \(error.record): it is larger than the server limit "
              + "of \(limit); nothing was sent.")
        } catch {
          throw MongoImportError(
            message: "Stopped at document \(index + 1): \(error.localizedDescription); nothing "
              + "was sent.")
        }
      }
      if let last = batcher.finish() { batches.append(last) }
      return batches
    }
  }
}
