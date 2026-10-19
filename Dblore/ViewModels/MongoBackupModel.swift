// MongoBackupModel.swift
// Backup and restore of the connection's MongoDB database (`MongoBackupFormat` files).
//
// Backup: asks where to save first (`<db>-<date>.ndjson`), then `MongoBackupWriter.backUp` reads
// the chosen collections and views under the epoch they were listed with, off the main actor.
// Cancel stops the task and this backup's server read only (killOp of its comment token); no
// partial file is left.
//
// Restore, into the connection's database (the header's database is only shown when it
// differs). Refused up front, before the open panel, when the connection's rules refuse a
// restore (read-only, schema-only, Protected mode: it creates collections and writes). Pass 1
// reads the whole file off the main actor, streamed with no size cap, and checks every line (the
// format, and each document against the server's BSON limit through `MongoInsertBatcher`):
// nothing is sent when any line is bad. The existing names are then read (`listCollections`
// filtered by name). When a collection or view of the backup exists, the restore needs Drop
// existing first, which drops only those, after the typed database name; then the Safe Mode
// panel per commit style (Review counts as Confirm). Views are ordered after their sources; a
// cycle, or a source in neither the backup nor the database, is refused before any prompt, and
// every command is checked against the connection's rules (`evaluate`) before any prompt too.
//
// Pass 2 reads the file again off the main actor and sends typed commands through
// `executeGatedMongoCommands`, one at a time, all with the epoch the model was opened with (a
// reconnect refuses the rest): the drops, every createCollection (its options without the
// validator), then per collection its documents in `MongoInsertBatcher` batches as they fill
// (never the whole file in memory), its createIndex commands and the collMod of its validator
// (after the data, so a strict validator never refuses a restored document); then the views.
// Just before the drops, the file's size, modification date and header are compared with
// pass 1's: a file changed meanwhile is refused before anything is sent. A header that runs
// server-side JavaScript, or a view that writes or reads outside the database, is refused by
// `MongoBackupFormat` in pass 1. Names from the file are shown capped
// (`MongoBackupFormat.label`).
// File options are untrusted: only the createCollection / createIndex / createView keys the
// mongosh subset accepts are sent, plus the server-valid options a backup lists that the
// subset leaves out (index parameters of 2d / text / 2dsphere, changeStreamPreAndPostImages;
// never storageEngine nor indexOptionDefaults, which only holds storageEngine). The first
// failure stops the restore with what was applied; a collection or view created by someone
// else between the check and pass 2 fails its create the same way. Cancel stops before the next command (the typed gate has no token to stop the
// command in flight alone); nothing is rolled back. One History row per backup (`.dump`) and
// per restore (`.restore`), whatever the outcome; the sidebar reloads after a restore.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MongoBackupModel {
  /// The connection the model works on
  struct Context {
    var manager: DatabaseConnectionManager
    var policy: ProtectionPolicy
    /// Read at request time, so a commit style changed meanwhile counts
    var commitStyle: @MainActor () -> CommitStyle
    /// The tab's caller token (another tab's pending transaction refuses the writes)
    var caller: UUID?
    /// The connection's database: a backup reads it, a restore writes into it
    var database: String
    /// Labels the History rows (connection key and name)
    var config: ConnectionConfig
    /// Records one History row (the tab honours the History setting and adds its workspace)
    var recordHistory: @MainActor (QueryHistoryEntry) async -> Void
    /// After a restore ran, whatever its outcome (the sidebar reload)
    var onRestored: @MainActor () async -> Void
  }

  /// Panels and the existing-name read; tests replace them
  struct Environment {
    /// Save panel with a suggested name; nil when cancelled
    var chooseSaveURL: @MainActor (_ suggestedName: String) async -> URL?
    /// Open panel for a backup file; nil when cancelled
    var chooseOpenURL: @MainActor () async -> URL?
    /// The names among `names` that exist in `database` (the session's)
    var existingNames:
      @Sendable (DatabaseConnectionManager, _ names: [String], _ database: String) async throws
        -> Set<String>

    static let live = Environment(
      chooseSaveURL: { await MongoBackupModel.showSavePanel(name: $0) },
      chooseOpenURL: { await MongoBackupModel.showOpenPanel() },
      existingNames: { manager, names, database in
        try await manager.fetchMongoExistingNames(names, database: database)
      })
  }

  /// What the restore asks before anything is sent
  struct RestoreConfirmation: Equatable {
    /// One per request: a late answer meant for an earlier confirmation never sends a later one
    let id = UUID()
    let fileName: String
    /// The database the backup was read from, when it is not the connection's
    let sourceDatabase: String?
    /// The connection's database, written into
    let database: String
    let collections: Int
    let views: Int
    let documents: Int
    /// Existing collections and views dropped first, as labels
    let drops: [String]
    /// The database name to type first when something is dropped; nil otherwise
    let typedName: String?
    let needsSafeModePanel: Bool
    let requiresPassword: Bool
  }

  nonisolated struct RestoreProgress: Equatable, Sendable {
    /// Collections whose documents, indexes and validator are all in
    var collectionsDone: Int
    var collectionsTotal: Int
    var documentsInserted: Int
    var documentsTotal: Int
  }

  enum State: Equatable {
    case idle
    /// Checking the restore file, or reading which of its names exist
    case reading
    case backingUp(MongoBackupWriter.Progress)
    case confirming(RestoreConfirmation)
    case restoring(RestoreProgress)
    /// The result line
    case done(String)
    case failed(String)
    case cancelled(String)
  }

  private(set) var state = State.idle
  /// A save or open panel is open: the form is locked and a second click opens no other one
  private(set) var choosingFile = false
  /// The loaded restore file
  private(set) var restoreURL: URL?
  /// The header of the loaded file, set once every line of it was checked
  private(set) var header: MongoBackupHeader?
  /// The loaded file's size and date as pass 1 found them
  @ObservationIgnored private var restoreStamp: MongoBackupFormat.FileStamp?
  /// The backup's collections and views that exist in the database, in header order
  private(set) var collisions: [String] = []
  /// Cancel was asked while a backup or restore runs
  private(set) var cancelRequested = false
  /// A restore of the loaded file ran (something may have been written): a new restore waits
  /// for the file to be loaded again
  private(set) var restoreStarted = false

  @ObservationIgnored private let context: Context
  @ObservationIgnored private let environment: Environment
  /// The epoch the form was opened (and the names listed) under; a reconnect refuses the work
  @ObservationIgnored private let connectionEpoch: UInt64
  /// The plan of the pending confirmation
  @ObservationIgnored private var pendingPlan: MongoRestorePlan?
  @ObservationIgnored private var limits: MongoWriteLimits?
  /// Stops pass 1
  @ObservationIgnored private var stopWork: (@Sendable () -> Void)?
  @ObservationIgnored private var backupTask: Task<MongoBackupHeader, any Error>?
  /// The comment token of the backup's server read: Cancel kills that operation only
  @ObservationIgnored private var backupToken: String?
  @ObservationIgnored private var backupProgress: MongoBackupWriter.Progress?
  /// The form closed: nothing new starts
  @ObservationIgnored private var dismissed = false
  /// Bumped by every load, request, run and cancel: results of an older one are dropped
  @ObservationIgnored private var generation = 0

  init(context: Context, connectionEpoch: UInt64, environment: Environment = .live) {
    self.context = context
    self.connectionEpoch = connectionEpoch
    self.environment = environment
  }

  /// The model for `tab`'s connection, nil when the tab is not connected. `connectionEpoch`: the
  /// epoch read before the collections were listed.
  convenience init?(tab: NotebookViewModel, connectionEpoch: UInt64) {
    guard let manager = tab.connectionManager, let config = tab.notebook.connectionConfig else {
      return nil
    }
    self.init(
      context: Context(
        manager: manager, policy: tab.protectionPolicy,
        commitStyle: { [weak tab] in
          (tab?.notebook.connectionConfig ?? config)
            .resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
        },
        caller: tab.id,
        database: config.database.isEmpty ? MongoSession.defaultDatabase : config.database,
        config: config,
        // Strong: the History row and the sidebar refresh still happen when the tab closed
        // while the work ran (the tab does not hold the model)
        recordHistory: { entry in
          guard tab.historySettings.historyEnabled else { return }
          var entry = entry
          if let workspace = tab.historyWorkspace() {
            entry.workspaceID = workspace.id
            entry.workspaceName = workspace.name
          }
          await tab.historyRecorder.record(entry)
          tab.onHistoryRecorded?()
        },
        onRestored: { await tab.onStatementsExecuted?() }),
      connectionEpoch: connectionEpoch)
  }

  // MARK: - Derived

  /// A panel is open, or a check, backup or restore runs: the form is locked
  var isBusy: Bool {
    if choosingFile { return true }
    switch state {
    case .reading, .backingUp, .restoring: return true
    case .idle, .confirming, .done, .failed, .cancelled: return false
    }
  }

  /// The connection's database: a backup reads it, a restore writes into it
  var database: String { context.database }

  /// The database the loaded backup was read from, when it is not the connection's
  var sourceDatabase: String? {
    guard let header, header.database != context.database else { return nil }
    return MongoBackupFormat.label(header.database)
  }

  /// Documents in the loaded backup
  var documentCount: Int {
    Int(header?.collections.reduce(Int64(0)) { $0 + $1.count } ?? 0)
  }

  // MARK: - Backup

  /// Asks where to save, then backs up `names` (collections and views of the connection's
  /// database). Nothing is read when the save panel is cancelled.
  func backUp(names: [String]) async {
    guard !dismissed, !isBusy, !names.isEmpty else { return }
    choosingFile = true
    let chosen = await environment.chooseSaveURL(
      Self.backupFileName(database: context.database, date: Date()))
    choosingFile = false
    guard !dismissed, !isBusy, let url = chosen else { return }
    generation += 1
    let current = generation
    cancelRequested = false
    let token = "dblore:backup:\(UUID().uuidString)"
    // The total stays 0 until the writer has told the collections from the views
    let start = MongoBackupWriter.Progress(
      collectionsDone: 0, collectionsTotal: 0, documentsWritten: 0)
    backupProgress = start
    backupToken = token
    state = .backingUp(start)
    let started = ContinuousClock.now
    let (manager, database) = (context.manager, context.database)
    let (caller, epoch) = (context.caller, connectionEpoch)
    let progress: @Sendable (MongoBackupWriter.Progress) async -> Void = { [weak self] value in
      await self?.reportBackup(value, generation: current)
    }
    let task = Task.detached(priority: .userInitiated) {
      try await MongoBackupWriter.backUp(
        names: names, database: database, to: url, manager: manager, caller: caller,
        expectedEpoch: epoch, statementToken: token, progress: progress)
    }
    backupTask = task
    let result = await task.result
    backupTask = nil
    backupToken = nil
    let last = backupProgress ?? start
    var (collections, documents) = (last.collectionsDone, last.documentsWritten)
    let status: QueryHistoryEntry.Status
    var failure: String?
    switch result {
    case .success(let written):
      collections = written.collections.count
      documents = Int(written.collections.reduce(Int64(0)) { $0 + $1.count })
      status = .success
      state = .done(
        "Saved \(url.lastPathComponent): \(Self.counted(collections, "collection")), "
          + "\(Self.counted(written.views.count, "view")) and "
          + "\(Self.counted(documents, "document")).")
    case .failure(let error):
      if cancelRequested || DatabaseBackupModel.historyStatus(for: error) == .cancelled {
        status = .cancelled
        failure = "Backup cancelled"
        state = .cancelled("Backup cancelled. Nothing was saved.")
      } else {
        status = .error
        failure = error.localizedDescription
        state = .failed("The backup failed; nothing was saved: \(error.localizedDescription)")
      }
    }
    cancelRequested = false
    await context.recordHistory(
      QueryHistoryEntry.mongoBackupSummary(
        database: database, collections: collections, documents: documents,
        config: context.config, workspaceID: nil, workspaceName: nil,
        durationMs: Self.milliseconds(since: started), status: status, errorMessage: failure))
  }

  private func reportBackup(_ progress: MongoBackupWriter.Progress, generation current: Int) {
    guard generation == current, case .backingUp = state else { return }
    backupProgress = progress
    state = .backingUp(progress)
  }

  // MARK: - Restore

  /// Refuses before the open panel when the connection's rules refuse a restore, then asks for
  /// the file and loads it
  func chooseRestoreFile() async {
    guard !dismissed, !isBusy else { return }
    if let reason = await refusal(of: Self.probeCommands) {
      state = .failed(reason)
      return
    }
    choosingFile = true
    let chosen = await environment.chooseOpenURL()
    choosingFile = false
    guard !dismissed, !isBusy, let url = chosen else { return }
    await loadRestore(url: url)
  }

  /// Pass 1: reads and checks every line of `url` off the main actor (nothing is sent), then
  /// reads which of the backup's names exist in the database (`collisions`)
  func loadRestore(url: URL) async {
    guard !dismissed, !isBusy else { return }
    generation += 1
    let current = generation
    restoreURL = url
    header = nil
    restoreStamp = nil
    collisions = []
    pendingPlan = nil
    restoreStarted = false
    cancelRequested = false
    if let reason = await refusal(of: Self.probeCommands) {
      if generation == current { state = .failed(reason) }
      return
    }
    guard generation == current, !dismissed else { return }
    state = .reading
    let limits = await writeLimits()
    guard generation == current, !dismissed else { return }
    let checking = Task.detached(priority: .userInitiated) {
      try await Self.check(url: url, limits: limits)
    }
    stopWork = { checking.cancel() }
    let result = await withTaskCancellationHandler {
      await checking.result
    } onCancel: {
      checking.cancel()
    }
    guard generation == current else { return }
    stopWork = nil
    switch result {
    case .success(let (checked, stamp)):
      header = checked
      restoreStamp = stamp
      do {
        let existing = try await environment.existingNames(
          context.manager, Self.lookupNames(checked), context.database)
        guard generation == current else { return }
        collisions = Self.collisions(checked, existing: existing)
        state = .idle
      } catch {
        guard generation == current else { return }
        state = .failed(listFailure(error))
      }
    case .failure(let error):
      state = error is CancellationError ? .idle : .failed(error.localizedDescription)
    }
  }

  /// Does nothing once a restore of the loaded file ran (`restoreStarted`). Reads the existing
  /// names again: a collision needs `dropExisting` (only the colliding collections and views
  /// are dropped). Refuses, before any prompt, a view whose source is in neither the backup nor
  /// the database, a cycle of views, and any command the connection's rules refuse. Then asks
  /// for the one confirmation (the typed database name when something is dropped, then the
  /// Safe Mode panel), or restores at once when nothing needs asking.
  func requestRestore(dropExisting: Bool) async {
    guard !dismissed, !isBusy, !restoreStarted, let header, let url = restoreURL,
      let stamp = restoreStamp
    else { return }
    generation += 1
    let current = generation
    pendingPlan = nil
    cancelRequested = false
    state = .reading
    let existing: Set<String>
    do {
      existing = try await environment.existingNames(
        context.manager, Self.lookupNames(header), context.database)
    } catch {
      if generation == current { state = .failed(listFailure(error)) }
      return
    }
    guard generation == current, !dismissed else { return }
    collisions = Self.collisions(header, existing: existing)
    if !collisions.isEmpty, !dropExisting {
      state = .failed(
        "\(collisions.map(MongoBackupFormat.label).joined(separator: ", ")) already exist\(collisions.count == 1 ? "s" : "") "
          + "in \(context.database). Turn on Drop existing first to replace "
          + "\(collisions.count == 1 ? "it" : "them"); nothing was sent.")
      return
    }
    let plan: MongoRestorePlan
    do {
      plan = try MongoRestorePlan(
        header: header, url: url, stamp: stamp, drops: collisions, existing: existing,
        database: context.database)
    } catch {
      state = .failed(error.message)
      return
    }
    let reason = await refusal(of: plan.commands)
    guard generation == current, !dismissed else { return }
    if let reason {
      state = .failed(reason)
      return
    }
    let commitStyle = context.commitStyle()
    let pending = RestoreConfirmation(
      fileName: url.lastPathComponent, sourceDatabase: sourceDatabase,
      database: context.database, collections: header.collections.count,
      views: header.views.count, documents: plan.documentTotal,
      drops: collisions.map(MongoBackupFormat.label),
      typedName: collisions.isEmpty ? nil : context.database,
      needsSafeModePanel: commitStyle != .immediate,
      requiresPassword: commitStyle.requiresPassword)
    guard pending.typedName != nil || pending.needsSafeModePanel else {
      await run(pending, plan: plan)
      return
    }
    pendingPlan = plan
    state = .confirming(pending)
  }

  /// Whether `confirmation` is still the one being asked (not cancelled or replaced since)
  func isPending(_ confirmation: RestoreConfirmation) -> Bool {
    if case .confirming(let current) = state { return current.id == confirmation.id }
    return false
  }

  /// Restores while `confirmation` is still the one being asked and, when something is
  /// dropped, `typedName` matches the database name; the Safe Mode panel (password / Touch ID)
  /// is verified by the sheet before this.
  func confirm(_ confirmation: RestoreConfirmation, typedName: String = "") async {
    guard !dismissed, isPending(confirmation), let plan = pendingPlan else { return }
    if let name = confirmation.typedName, !TypedNameConfirmation.matches(typedName, name: name) {
      return
    }
    pendingPlan = nil
    await run(confirmation, plan: plan)
  }

  // MARK: - Cancel

  /// Leaves a confirmation or a failure, stops a check, or asks a running backup to stop (at
  /// once) or a running restore to stop before its next command (nothing is rolled back).
  func cancel() {
    switch state {
    case .restoring:
      cancelRequested = true
    case .backingUp:
      cancelRequested = true
      backupTask?.cancel()
      if let token = backupToken {
        let manager = context.manager
        Task { await manager.interruptMongoStatement(token: token) }
      }
    case .reading:
      stopWork?()
      stopWork = nil
      generation += 1
      state = .idle
    case .confirming, .failed:
      pendingPlan = nil
      state = .idle
    case .idle, .done, .cancelled:
      break
    }
  }

  /// The form closed (refused by the presenters while work runs): nothing new starts and
  /// running work stops as Cancel stops it
  func dismiss() {
    dismissed = true
    cancel()
  }

  // MARK: - Private

  /// Stand-ins for what every restore sends (a collection created, documents inserted), checked
  /// before the open panel
  private static let probeCommands: [MongoCommand] = [
    .admin(.createCollection(name: "restore", options: nil)),
    .insertMany(collection: "restore", documents: []),
  ]

  /// The gate's refusal of `commands` under the effective policy (the connection's rules and
  /// Protected mode), nil when allowed
  private func refusal(of commands: [MongoCommand]) async -> String? {
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

  private func listFailure(_ error: any Error) -> String {
    "The collections of \(context.database) could not be listed; nothing was sent: "
      + error.localizedDescription
  }

  /// Pass 2 off the main actor; records one History row and reloads the sidebar whatever the
  /// outcome
  private func run(_ confirmation: RestoreConfirmation, plan: MongoRestorePlan) async {
    restoreStarted = true
    cancelRequested = false
    generation += 1
    let current = generation
    state = .restoring(
      RestoreProgress(
        collectionsDone: 0, collectionsTotal: plan.collections.count, documentsInserted: 0,
        documentsTotal: plan.documentTotal))
    let started = ContinuousClock.now
    let limits = await writeLimits()
    let sender = MongoRestoreRun.Sender(
      manager: context.manager, policy: context.policy, epoch: connectionEpoch,
      caller: context.caller)
    let outcome = await Self.restore(
      plan, sender: sender, limits: limits,
      shouldStop: { [weak self] in await self?.cancelRequested ?? true },
      report: { [weak self] progress in
        await self?.reportRestore(progress, generation: current)
      })
    cancelRequested = false
    switch outcome.status {
    case .success:
      state = .done(
        "Restored \(Self.counted(outcome.progress.collectionsDone, "collection")), "
          + "\(Self.counted(outcome.viewsDone, "view")) and "
          + "\(Self.counted(outcome.progress.documentsInserted, "document")) into "
          + "\(context.database).")
    case .cancelled: state = .cancelled(outcome.message)
    case .error: state = .failed(outcome.message)
    }
    await context.recordHistory(
      QueryHistoryEntry.mongoRestoreSummary(
        collections: outcome.progress.collectionsDone,
        documents: outcome.progress.documentsInserted, config: context.config,
        workspaceID: nil, workspaceName: nil, durationMs: Self.milliseconds(since: started),
        status: outcome.status, errorMessage: outcome.summary))
    await context.onRestored()
  }

  private func reportRestore(_ progress: RestoreProgress, generation current: Int) {
    guard generation == current, case .restoring = state else { return }
    state = .restoring(progress)
  }

  @concurrent nonisolated private static func restore(
    _ plan: MongoRestorePlan, sender: MongoRestoreRun.Sender, limits: MongoWriteLimits,
    shouldStop: @escaping @Sendable () async -> Bool,
    report: @escaping @Sendable (RestoreProgress) async -> Void
  ) async -> MongoRestoreRun.Outcome {
    let run = MongoRestoreRun(
      plan: plan, sender: sender, limits: limits, shouldStop: shouldStop, report: report)
    return await PerfSignpost.interval("mongo.restore") { await run.run() }
  }

  /// Pass 1: every line of the file, each document also against the server's BSON limit, and
  /// the file's stamp read before the lines (a change while they are read changes it too)
  @concurrent nonisolated private static func check(
    url: URL, limits: MongoWriteLimits
  ) async throws -> (MongoBackupHeader, MongoBackupFormat.FileStamp) {
    try await PerfSignpost.interval("mongo.restore.check") {
      let stamp = try MongoBackupFormat.stamp(of: url)
      var batcher = MongoInsertBatcher(limits: limits)
      var current: String?
      var record = 0
      let header = try await MongoBackupFormat.forEachLine(
        url: url, maxBsonObjectSize: limits.maxBsonObjectSize
      ) { line in
        guard case .document(let number, let collection, let document) = line else { return }
        if collection != current {
          current = collection
          record = 0
          batcher = MongoInsertBatcher(limits: limits)
        }
        record += 1
        do {
          // Batches are only built to check sizes: dropped at once
          _ = try batcher.append(document, record: record)
        } catch let error as MongoInsertBatcher.OversizeDocument {
          throw MongoBackupFormatError(
            line: number,
            message: "The document is larger than the server limit of "
              + ByteCountFormatter.string(fromByteCount: Int64(error.limit), countStyle: .memory)
              + "; nothing was sent.")
        } catch {
          throw MongoBackupFormatError(line: number, message: error.localizedDescription)
        }
      }
      return (header, stamp)
    }
  }

  /// Every name the restore checks in the database: collections, views and view sources
  nonisolated private static func lookupNames(_ header: MongoBackupHeader) -> [String] {
    var seen: Set<String> = []
    let names =
      header.collections.map(\.name) + header.views.map(\.name) + header.views.map(\.viewOn)
    return names.filter { seen.insert($0).inserted }
  }

  /// The backup's collections and views among `existing`, in header order
  nonisolated private static func collisions(
    _ header: MongoBackupHeader, existing: Set<String>
  ) -> [String] {
    (header.collections.map(\.name) + header.views.map(\.name)).filter(existing.contains)
  }

  nonisolated static func backupFileName(database: String, date: Date) -> String {
    "\(database)-\(date.formatted(.iso8601.year().month().day())).\(MongoBackupFormat.fileExtension)"
  }

  private static func counted(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int(((ContinuousClock.now - start) / .milliseconds(1)).rounded())
  }

  private static func showSavePanel(name: String) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes =
      UTType(filenameExtension: MongoBackupFormat.fileExtension).map { [$0] } ?? []
    panel.canCreateDirectories = true
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }

  private static func showOpenPanel() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    var types: [UTType] = [.json, .plainText]
    if let ndjson = UTType(filenameExtension: MongoBackupFormat.fileExtension) {
      types.insert(ndjson, at: 0)
    }
    panel.allowedContentTypes = types
    return await withCheckedContinuation { continuation in
      panel.begin { response in
        continuation.resume(returning: response == .OK ? panel.url : nil)
      }
    }
  }
}

// MARK: - Restore plan

/// Why a restore was refused before anything was sent
nonisolated private struct MongoRestoreRefusal: Error {
  let message: String
}

/// Every typed command of a restore, built from the checked header before anything is asked.
nonisolated private struct MongoRestorePlan: Sendable {
  /// One command and what a failure names ("index a_1", "its validator", a view's name)
  struct Step: Sendable {
    let command: MongoCommand
    let label: String
  }

  struct CollectionSteps: Sendable {
    let name: String
    /// `name` as failures show it
    let label: String
    let create: MongoCommand
    /// The createIndex commands, then the validator's collMod
    let finishing: [Step]
  }

  private static let validatorKeys: Set<String> = [
    "validator", "validationLevel", "validationAction",
  ]
  /// The `createView` options the mongosh subset accepts
  private static let createViewOptions: Set<String> = ["collation"]
  /// The mongosh subset's index options, plus the parameters of a 2d, text, 2dsphere or
  /// geoHaystack index the server lists (restore only: typed commands never take them)
  private static let restoreIndexOptions = MongoshParser.createIndexOptions.union([
    "bits", "min", "max", "textIndexVersion", "2dsphereIndexVersion", "bucketSize",
  ])
  /// The mongosh subset's createCollection options without the validator, plus the server-valid
  /// options a backup lists (restore only; `storageEngine` and `indexOptionDefaults`, which only
  /// holds `storageEngine`, stay out: engine-specific)
  private static let restoreCollectionOptions = MongoshParser.createCollectionOptions
    .subtracting(validatorKeys).union(["changeStreamPreAndPostImages"])

  let url: URL
  /// The file's size and date when pass 1 checked it
  let stamp: MongoBackupFormat.FileStamp
  let header: MongoBackupHeader
  let drops: [Step]
  let collections: [CollectionSteps]
  /// Position of each collection in `collections`
  let positions: [String: Int]
  /// Each after its source
  let views: [Step]
  let documentTotal: Int

  /// `drops`: the colliding names, dropped first. `existing`: the names of the database among
  /// the backup's names and view sources.
  init(
    header: MongoBackupHeader, url: URL, stamp: MongoBackupFormat.FileStamp, drops: [String],
    existing: Set<String>, database: String
  ) throws(MongoRestoreRefusal) {
    self.url = url
    self.stamp = stamp
    self.header = header
    self.drops = drops.map {
      Step(command: .admin(.drop(collection: $0)), label: MongoBackupFormat.label($0))
    }
    collections = header.collections.map { collection in
      var finishing = collection.indexes.compactMap { spec -> Step? in
        guard case .document(let fields) = spec,
          let key = fields.first(where: { $0.key == "key" })?.value
        else { return nil }
        var label = "an index"
        if case .string(let name)? = fields.first(where: { $0.key == "name" })?.value {
          label = "index \(MongoBackupFormat.label(name))"
        }
        return Step(
          command: .admin(
            .createIndex(
              collection: collection.name, keys: key,
              options: Self.allowed(spec, Self.restoreIndexOptions))),
          label: label)
      }
      if let rules = collection.validator.flatMap({ Self.allowed($0, Self.validatorKeys) }) {
        finishing.append(
          Step(
            command: .admin(.collMod(collection: collection.name, options: rules)),
            label: "its validator"))
      }
      return CollectionSteps(
        name: collection.name, label: MongoBackupFormat.label(collection.name),
        create: .admin(
          .createCollection(
            name: collection.name,
            options: Self.allowed(collection.options, Self.restoreCollectionOptions))),
        finishing: finishing)
    }
    positions = Dictionary(
      collections.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
    views = try Self.ordered(
      header.views, collections: Set(positions.keys), existing: existing, database: database
    ).map { view in
      Step(
        command: .admin(
          .createView(
            name: view.name, source: view.viewOn, pipeline: view.pipeline,
            options: Self.allowed(view.options, Self.createViewOptions))),
        label: MongoBackupFormat.label(view.name))
    }
    documentTotal = Int(header.collections.reduce(Int64(0)) { $0 + $1.count })
  }

  /// Every command the restore can send (an empty insert stands for each collection's
  /// documents), for the up-front check
  var commands: [MongoCommand] {
    drops.map(\.command)
      + collections.flatMap {
        [$0.create, .insertMany(collection: $0.name, documents: [])] + $0.finishing.map(\.command)
      } + views.map(\.command)
  }

  /// The fields of `options` whose key is in `keys`, in file order; nil when none is left
  private static func allowed(_ options: MongoValue, _ keys: Set<String>) -> MongoValue? {
    guard case .document(let fields) = options else { return nil }
    let kept = fields.filter { keys.contains($0.key) }
    return kept.isEmpty ? nil : .document(kept)
  }

  /// `views` with each after the view it reads (breadth first, never recursive: the header is
  /// untrusted). A source that is not a view must be a backup collection or exist in the
  /// database.
  private static func ordered(
    _ views: [MongoBackupHeader.View], collections: Set<String>, existing: Set<String>,
    database: String
  ) throws(MongoRestoreRefusal) -> [MongoBackupHeader.View] {
    let names = Set(views.map(\.name))
    var readers: [String: [Int]] = [:]
    var queue: [Int] = []
    for (index, view) in views.enumerated() {
      if names.contains(view.viewOn) {
        readers[view.viewOn, default: []].append(index)
        continue
      }
      guard collections.contains(view.viewOn) || existing.contains(view.viewOn) else {
        throw MongoRestoreRefusal(
          message: "The view \(MongoBackupFormat.label(view.name)) reads "
            + "\(MongoBackupFormat.label(view.viewOn)), which is neither in the backup "
            + "nor in \(database); nothing was sent.")
      }
      queue.append(index)
    }
    var next = 0
    while next < queue.count {
      queue += readers[views[queue[next]].name] ?? []
      next += 1
    }
    guard queue.count == views.count else {
      let placed = Set(queue)
      let cycle = views.indices.filter { !placed.contains($0) }
        .map { MongoBackupFormat.label(views[$0].name) }
      throw MongoRestoreRefusal(
        message: "The views \(cycle.joined(separator: ", ")) read each other in a cycle; "
          + "nothing was sent.")
    }
    return queue.map { views[$0] }
  }
}

// MARK: - Restore run

/// Pass 2 of a restore, off the main actor: reads the file again and sends the plan's commands
/// one by one, keeping count of what was applied. Used by one task only.
nonisolated private final class MongoRestoreRun {
  /// Sends one typed command through the gate
  struct Sender: Sendable {
    let manager: DatabaseConnectionManager
    let policy: ProtectionPolicy
    let epoch: UInt64
    let caller: UUID?

    func send(_ command: MongoCommand, expectedRows: Int?) async throws {
      _ = try await manager.executeGatedMongoCommands(
        [command], policy: policy, connectionEpoch: epoch, caller: caller,
        expectedRows: expectedRows.map { [$0] })
    }
  }

  struct Outcome: Sendable {
    let status: QueryHistoryEntry.Status
    let progress: MongoBackupModel.RestoreProgress
    let viewsDone: Int
    /// The result line of a failure or cancel (empty on success)
    let message: String
    /// The History error text: what was applied and where it stopped, without the server's
    /// reason (it can quote file values); nil on success
    let summary: String?
  }

  private struct Stop: Error {
    let status: QueryHistoryEntry.Status
    let message: String
    let summary: String
  }

  private let plan: MongoRestorePlan
  private let sender: Sender
  private let limits: MongoWriteLimits
  private let shouldStop: @Sendable () async -> Bool
  private let report: @Sendable (MongoBackupModel.RestoreProgress) async -> Void
  private var progress: MongoBackupModel.RestoreProgress
  private var dropsDone = 0
  private var dropsFinished = false
  private var viewsDone = 0
  /// The collection whose documents are being read (its position in the plan), its batcher,
  /// its documents read and inserted
  private var current: Int?
  private var batcher: MongoInsertBatcher
  private var read = 0
  private var inserted = 0
  private var finished: Set<Int> = []

  init(
    plan: MongoRestorePlan, sender: Sender, limits: MongoWriteLimits,
    shouldStop: @escaping @Sendable () async -> Bool,
    report: @escaping @Sendable (MongoBackupModel.RestoreProgress) async -> Void
  ) {
    self.plan = plan
    self.sender = sender
    self.limits = limits
    self.shouldStop = shouldStop
    self.report = report
    batcher = MongoInsertBatcher(limits: limits)
    progress = MongoBackupModel.RestoreProgress(
      collectionsDone: 0, collectionsTotal: plan.collections.count, documentsInserted: 0,
      documentsTotal: plan.documentTotal)
  }

  func run() async -> Outcome {
    do {
      try checkFile()
      for drop in plan.drops {
        try await send(drop.command, expectedRows: nil) { reason, _ in
          self.dropFailure("\(drop.label) could not be dropped", reason)
        }
        dropsDone += 1
      }
      dropsFinished = true
      for collection in plan.collections {
        try await send(collection.create, expectedRows: nil) { reason, _ in
          self.failure("\(collection.label) could not be created", reason)
        }
      }
      do {
        try await MongoBackupFormat.forEachLine(
          url: plan.url, maxBsonObjectSize: limits.maxBsonObjectSize
        ) { line in
          switch line {
          case .header(let header):
            guard header == plan.header else {
              throw failure("the file changed since it was checked", nil)
            }
          case .document(_, let collection, let document):
            try await add(document, to: collection)
          }
        }
      } catch let stop as Stop {
        throw stop
      } catch {
        throw failure("the file could not be read again", error.localizedDescription)
      }
      if let current, !finished.contains(current) { try await finish(current) }
      for position in plan.collections.indices where !finished.contains(position) {
        try await finish(position)
      }
      for view in plan.views {
        try await send(view.command, expectedRows: nil) { reason, _ in
          self.failure("the view \(view.label) could not be created", reason)
        }
        viewsDone += 1
      }
      return Outcome(
        status: .success, progress: progress, viewsDone: viewsDone, message: "", summary: nil)
    } catch let stop as Stop {
      return Outcome(
        status: stop.status, progress: progress, viewsDone: viewsDone, message: stop.message,
        summary: stop.summary)
    } catch {
      let stop = failure("the restore stopped", error.localizedDescription)
      return Outcome(
        status: .error, progress: progress, viewsDone: viewsDone, message: stop.message,
        summary: stop.summary)
    }
  }

  // MARK: - Steps

  /// Refuses, before anything is sent, a file whose size, date or header is not the one pass 1
  /// checked
  private func checkFile() throws {
    let unchanged: Bool
    do {
      unchanged =
        try MongoBackupFormat.stamp(of: plan.url) == plan.stamp
        && MongoBackupFormat.readHeader(url: plan.url) == plan.header
    } catch {
      let text = "The file could not be read again; nothing was sent"
      throw Stop(
        status: .error, message: "\(text): \(error.localizedDescription)", summary: text)
    }
    guard unchanged else {
      let text = "The file changed since it was checked; nothing was sent. Choose it again"
      throw Stop(status: .error, message: text + ".", summary: text)
    }
  }

  private func add(_ document: MongoValue, to name: String) async throws {
    guard let position = plan.positions[name] else {
      throw failure("the file changed since it was checked", nil)
    }
    if position != current {
      if let current { try await finish(current) }
      current = position
      batcher = MongoInsertBatcher(limits: limits)
      (read, inserted) = (0, 0)
    }
    read += 1
    let full: [MongoValue]?
    do {
      full = try batcher.append(document, record: read)
    } catch {
      throw failure(
        "\(plan.collections[position].label) failed at document \(read.formatted())",
        error.localizedDescription)
    }
    if let full { try await insert(full) }
  }

  private func insert(_ batch: [MongoValue]) async throws {
    guard let current else { return }
    let (name, label) = (plan.collections[current].name, plan.collections[current].label)
    let first = inserted + 1
    try await send(.insertMany(collection: name, documents: batch), expectedRows: batch.count) {
      reason, written in
      // The ordered insert keeps the documents before the failing one
      let at: String
      if let written {
        self.inserted += written
        self.progress.documentsInserted += written
        at = "at document \((first + written).formatted())"
      } else {
        at = "in documents \(first.formatted())–\((first + batch.count - 1).formatted())"
      }
      return self.failure("\(label) failed \(at)", reason)
    }
    inserted += batch.count
    progress.documentsInserted += batch.count
    await report(progress)
  }

  /// Sends the last batch of `position` when it is the collection being read, then its indexes
  /// and validator
  private func finish(_ position: Int) async throws {
    if position == current, let last = batcher.finish() { try await insert(last) }
    let collection = plan.collections[position]
    for step in collection.finishing {
      try await send(step.command, expectedRows: nil) { reason, _ in
        self.failure("\(collection.label) failed at \(step.label)", reason)
      }
    }
    finished.insert(position)
    progress.collectionsDone += 1
    await report(progress)
  }

  /// Stops before `command` when Cancel was asked; a send error becomes `failure(reason,
  /// written)`
  private func send(
    _ command: MongoCommand, expectedRows: Int?,
    failure: (_ reason: String, _ written: Int?) -> Stop
  ) async throws {
    if await shouldStop() { throw cancelled() }
    do {
      try await sender.send(command, expectedRows: expectedRows)
    } catch {
      var written: Int?
      if case DatabaseError.batchPartiallyApplied(_, _, _, let count?) = error { written = count }
      throw failure(Self.reason(error), written)
    }
  }

  // MARK: - Messages

  /// "Restored 3 of 5 collections (12,000 documents)", and the views once some are created
  private var applied: String {
    var text =
      "Restored \(progress.collectionsDone) of \(progress.collectionsTotal) collections "
      + "(\(progress.documentsInserted.formatted()) documents)"
    if viewsDone > 0 { text += " and \(viewsDone) of \(plan.views.count) views" }
    return text
  }

  /// `what` went wrong after the drops; `reason` (the server's or the gate's) is left out of
  /// the History text
  private func failure(_ what: String, _ reason: String?) -> Stop {
    Stop(
      status: .error, message: "\(applied); \(what)" + (reason.map { ": \($0)" } ?? ""),
      summary: "\(applied); \(what)")
  }

  private func dropFailure(_ what: String, _ reason: String) -> Stop {
    let text =
      "Dropped \(dropsDone) of \(plan.drops.count) existing collections and views; \(what); "
      + "nothing was restored"
    return Stop(status: .error, message: "\(text): \(reason)", summary: text)
  }

  private func cancelled() -> Stop {
    guard dropsFinished else {
      let text =
        dropsDone == 0
        ? "Cancelled; nothing was sent."
        : "Cancelled after dropping \(dropsDone) of \(plan.drops.count) existing collections "
          + "and views; nothing was restored."
      return Stop(status: .cancelled, message: text, summary: text)
    }
    return Stop(
      status: .cancelled,
      message: "\(applied); cancelled. What was restored stays in the database.",
      summary: "\(applied); cancelled")
  }

  /// The server's or the gate's reason for one failed command
  private static func reason(_ error: any Error) -> String {
    if case DatabaseError.batchPartiallyApplied(_, _, let reason, _) = error { return reason }
    if case DatabaseError.notEditable = error {
      return "the connection changed since the restore was opened"
    }
    return error.localizedDescription
  }
}
