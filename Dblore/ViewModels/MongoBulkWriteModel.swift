// MongoBulkWriteModel.swift
// Bulk update (`updateMany`) or delete (`deleteMany`) of the documents matching a filter, from
// the Documents header. The preview counts them through the gated read the data viewer uses;
// the run always asks a second step: the typed collection name when the filter is empty or the
// count is unknown or >= 1,000 (fail closed), then the Safe Mode panel when the commit style asks
// for it (Review counts as Confirm), else an inline Confirm step. The command goes through
// `executeGatedSequentialCommands` with the epoch read before the preview; the result shows the
// matched / modified or deleted counts of the reply. History rows use source `.dataViewerEdit`.

import Foundation
import Observation

@MainActor
@Observable
final class MongoBulkWriteModel {
  enum Mode: Equatable {
    case update
    case delete
  }

  /// What the confirm step shows before anything is sent
  struct Confirmation: Equatable {
    /// One per request: a late answer meant for an earlier confirmation never sends a later one
    let id = UUID()
    let mode: Mode
    /// Exactly the text that is sent
    let text: String
    /// The preview count; nil when unknown (failed, cancelled, stale or no preview)
    let count: Int?
    /// The collection name to type first; nil when there is no typed-name step
    let typedName: String?
    /// The filter is empty: the existing all-rows warning is shown
    let affectsAllRows: Bool
    /// The Safe Mode panel follows the typed-name step; otherwise (Immediate) an inline Confirm
    /// step with `question` does
    let needsSafeModePanel: Bool
    let requiresPassword: Bool
    /// Read before the preview (or the request when there was none): a reconnect since refuses
    let epoch: UInt64

    /// "Update 12 documents?" / "Delete 12 documents?"
    var question: String {
      let verb = mode == .update ? "Update" : "Delete"
      guard let count else { return "\(verb) every matching document? Their count is unknown." }
      return "\(verb) \(count.formatted()) document\(count == 1 ? "" : "s")?"
    }
  }

  /// The counts of the server's reply
  struct BulkWriteResult: Equatable {
    let mode: Mode
    /// Matched by an update, deleted by a delete
    let matched: Int
    /// Changed by an update (`nModified`); nil for a delete
    let modified: Int?
    /// The preview count the run was confirmed with; nil when unknown
    let previewCount: Int?

    /// Set when the documents matched differ from the preview count
    var note: String? {
      guard let previewCount, previewCount != matched else { return nil }
      let verb = mode == .update ? "matched" : "deleted"
      return
        "The preview counted \(previewCount.formatted()) document\(previewCount == 1 ? "" : "s"); "
        + "the run \(verb) \(matched.formatted())."
    }
  }

  enum State: Equatable {
    case idle
    case previewing
    /// The preview finished; nil count: unknown (failed or cancelled)
    case ready(count: Int?)
    case confirming(Confirmation)
    case running
    case failed(String)
    case done(BulkWriteResult)
  }

  static let stagedEditsRefusal =
    "Commit or discard the staged document edits first; nothing was sent."
  /// A count at or above this asks for the typed collection name
  static let typedNameThreshold = 1000
  /// Server time limit of the preview count; past it the count is unknown
  static let previewMaxTimeMS: Int32 = 30_000

  private(set) var state = State.idle
  var mode = Mode.update
  /// Prefilled with the applied filter. An edit makes the preview stale: its count is dropped.
  var filterText: String {
    didSet { if filterText != oldValue { dropPreview() } }
  }
  /// An update document of operators (`$set`, ...) or a pipeline array
  var updateText = ""
  let collection: String

  @ObservationIgnored private let context: MongoAdminContext
  @ObservationIgnored private let hasStagedEdits: @MainActor () -> Bool
  /// Called after a run (to reload the page and the count)
  @ObservationIgnored private let onStatementsExecuted: (@MainActor () async -> Void)?
  /// The finished (or cancelled) preview: count nil when unknown; the epoch read before it
  @ObservationIgnored private var preview: (count: Int?, epoch: UInt64)?
  /// The running preview; one cancelled, replaced or made stale never writes back
  @ObservationIgnored private var previewTask: Task<Int?, Never>?
  @ObservationIgnored private var previewGeneration = 0
  @ObservationIgnored private var previewEpoch: UInt64?

  init(
    context: MongoAdminContext, collection: String, filterText: String,
    hasStagedEdits: @escaping @MainActor () -> Bool,
    onStatementsExecuted: (@MainActor () async -> Void)?
  ) {
    self.context = context
    self.collection = collection
    self.filterText = filterText
    self.hasStagedEdits = hasStagedEdits
    self.onStatementsExecuted = onStatementsExecuted
  }

  /// The model for the collection `tab` shows, prefilled with its applied filter. Nil when the
  /// tab is not connected or shows no collection. The page and count reload after a run.
  convenience init?(tab: NotebookViewModel) {
    guard let manager = tab.connectionManager, let config = tab.notebook.connectionConfig,
      let state = tab.dataViewer
    else { return nil }
    self.init(
      context: MongoAdminContext(
        manager: manager, policy: tab.protectionPolicy,
        commitStyle: { [weak tab] in
          (tab?.notebook.connectionConfig ?? config)
            .resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
        },
        caller: tab.id,
        recordHistory: { [weak tab] in await tab?.recordExecution($0, source: .dataViewerEdit) }),
      collection: state.name, filterText: state.documentFilter,
      hasStagedEdits: { [weak tab] in tab?.hasPendingStagedChanges ?? false },
      onStatementsExecuted: { [weak tab] in await tab?.refreshDataViewer() })
  }

  /// Counts the documents matching the filter through the gated read. The epoch is read first;
  /// the run uses it. A failure leaves the count unknown.
  func preview() async {
    switch state {
    case .running, .confirming: return
    default: break
    }
    let filter: MongoValue?
    switch DataViewerState.documentFilterValue(filterText) {
    case .success(let value): filter = value
    case .failure(let error):
      state = .failed(error.message)
      return
    }
    previewTask?.cancel()
    previewGeneration += 1
    let generation = previewGeneration
    state = .previewing
    (preview, previewEpoch) = (nil, nil)
    let manager = context.manager
    let epoch = await manager.connectionEpoch
    guard generation == previewGeneration, state == .previewing else { return }
    previewEpoch = epoch
    let text = MongoCommand.countDocuments(
      collection: collection, filter: filter,
      options: .document([.init("maxTimeMS", .int32(Self.previewMaxTimeMS))])
    ).render()
    let (policy, caller) = (context.policy, context.caller)
    let task = Task {
      await PerfSignpost.interval("MongoBulkWritePreview") {
        let result = try? await manager.execute(
          userSQL: text, policy: policy, maxRows: 1, caller: caller, expectedEpoch: epoch)
        return result.flatMap(DataViewerState.total(from:))
      }
    }
    previewTask = task
    let count = await task.value
    // Cancelled, replaced or made stale meanwhile: the answer is dropped
    guard generation == previewGeneration, state == .previewing else { return }
    previewTask = nil
    preview = (count, epoch)
    state = .ready(count: count)
  }

  /// Builds the command and asks the second step; nothing is sent here. Refuses on staged
  /// document edits, a filter or update that does not parse, or a policy that blocks DML.
  func run() async {
    switch state {
    case .running, .previewing: return
    default: break
    }
    guard !hasStagedEdits() else {
      state = .failed(Self.stagedEditsRefusal)
      return
    }
    let filter: MongoValue
    let text: String
    do {
      (filter, text) = try command()
    } catch {
      state = .failed(error.message)
      return
    }
    let classified = SQLStatementClassifier.classify(text, dialect: .mongodb)
    if case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
      classified, policy: context.policy, dialect: .mongodb)
    {
      state = .failed(reason)
      return
    }
    let count = preview?.count
    let epoch: UInt64
    if let preview {
      epoch = preview.epoch
    } else {
      epoch = await context.manager.connectionEpoch
    }
    let isEmpty = filter == .document([])
    let commitStyle = context.commitStyle()
    state = .confirming(
      Confirmation(
        mode: mode, text: text, count: count,
        typedName: isEmpty || (count ?? Self.typedNameThreshold) >= Self.typedNameThreshold
          ? collection : nil,
        affectsAllRows: classified.contains(where: \.affectsAllRows),
        needsSafeModePanel: commitStyle != .immediate,
        requiresPassword: commitStyle.requiresPassword, epoch: epoch))
  }

  /// Whether `confirmation` is still the one being asked (not cancelled or replaced since)
  func isPending(_ confirmation: Confirmation) -> Bool {
    if case .confirming(let current) = state { return current.id == confirmation.id }
    return false
  }

  /// Sends `confirmation`'s command while it is still the one being asked, and only when
  /// `typedName` matches the collection name if one is asked. The Safe Mode panel (password /
  /// Touch ID) or the inline Confirm step is answered by the sheet before this.
  func confirm(_ confirmation: Confirmation, typedName: String = "") async {
    guard isPending(confirmation), case .confirming(let pending) = state else { return }
    if let name = pending.typedName, !TypedNameConfirmation.matches(typedName, name: name) {
      return
    }
    guard !hasStagedEdits() else {
      state = .failed(Self.stagedEditsRefusal)
      return
    }
    await send(pending)
  }

  /// Stops a running preview (the count stays unknown) or leaves a confirmation or a failure
  /// without sending anything, back to the preview's count. A finished run keeps `.done`.
  func cancel() {
    switch state {
    case .running, .done, .idle, .ready: return
    case .previewing:
      previewTask?.cancel()
      previewTask = nil
      preview = previewEpoch.map { (nil, $0) }
      state = .ready(count: nil)
    case .confirming, .failed:
      state = preview.map { .ready(count: $0.count) } ?? .idle
    }
  }

  /// The text Run would send, or why the filter or update does not parse (shown by the form)
  var commandText: Result<String, MongoRelaxedJSON.ParseError> {
    Result { () throws(MongoRelaxedJSON.ParseError) in try command().1 }
  }

  // MARK: - Private

  /// The rendered command, re-parsed by `MongoshParser` (the gate parses it the same way): its
  /// errors refuse an update that is neither operators nor a pipeline. An empty or blank filter
  /// is `{}`.
  private func command() throws(MongoRelaxedJSON.ParseError) -> (MongoValue, String) {
    let filter: MongoValue
    switch DataViewerState.documentFilterValue(filterText) {
    case .success(let value): filter = value ?? .document([])
    case .failure(let error):
      throw MongoRelaxedJSON.ParseError(message: error.message, offset: error.offset ?? 0)
    }
    let command: MongoCommand
    switch mode {
    case .update:
      command = .updateMany(
        collection: collection, filter: filter, update: try MongoRelaxedJSON.parse(updateText))
    case .delete:
      command = .deleteMany(collection: collection, filter: filter)
    }
    let text = command.render()
    _ = try MongoshParser.parse(text)
    return (filter, text)
  }

  /// A filter edit: the preview count no longer applies (a running preview is dropped)
  private func dropPreview() {
    preview = nil
    switch state {
    case .previewing, .ready:
      previewTask?.cancel()
      previewTask = nil
      state = .idle
    default: break
    }
  }

  private func send(_ pending: Confirmation) async {
    state = .running
    let started = Date()
    do {
      let reply = try await context.manager.executeGatedSequentialCommands(
        [pending.text], policy: context.policy, connectionEpoch: pending.epoch,
        caller: context.caller, expectedRows: nil
      ).first
      let matched = reply?.affectedRows ?? 0
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: pending.text, duration: Date().timeIntervalSince(started), rowCount: matched,
          status: .success, errorMessage: nil)
      ])
      preview = nil
      state = .done(
        BulkWriteResult(
          mode: pending.mode, matched: matched,
          modified: pending.mode == .update ? reply?.modifiedRows : nil,
          previewCount: pending.count))
    } catch {
      let message: String
      if case DatabaseError.batchPartiallyApplied(_, _, let reason) = error {
        // One command: "Applied 0 of 1 changes" adds nothing to the server's reason
        message = reason
      } else if case DatabaseError.notEditable = error {
        // The gate's epoch check: a reconnect since the preview
        message =
          "The connection changed since the preview; nothing was sent. Preview again to count."
      } else {
        message = error.localizedDescription
      }
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: pending.text, duration: Date().timeIntervalSince(started), rowCount: nil,
          status: .error, errorMessage: message)
      ])
      // The count no longer holds (a reconnect, or a partly applied write): the next Run reads
      // the current epoch and, the count being unknown, asks for the typed name
      preview = nil
      state = .failed(message)
    }
    await onStatementsExecuted?()
  }
}
