// MongoAdminActionModel.swift
// Runs one MongoDB administration command started from the UI (create / hide / drop an index,
// collections, views, databases): refuses up front on protected connections with the gate's
// text, asks for the exact name before a drop whatever the commit style, then shows the Safe Mode
// panel when the commit style asks for it (Review counts as Confirm: admin DDL cannot be staged),
// and sends the rendered command through `executeGatedSequentialBatch` (which re-checks every
// refusal and the connection epoch). A pipeline ending in `$out` / `$merge` runs the same way
// (`requestPipelineWrite`): an `$out` over an existing collection asks for its name first.
// History rows use source `.structure`.

import Foundation
import Observation

/// The connection, rules and history sink of the tab the action was started from
struct MongoAdminContext {
  var manager: DatabaseConnectionManager
  var policy: ProtectionPolicy
  /// Read at request time, so a commit style changed meanwhile counts
  var commitStyle: @MainActor () -> CommitStyle
  /// The tab's caller token (another tab's pending transaction refuses the command)
  var caller: UUID?
  /// Records outcomes in History under the source the caller chose (the tab honours the History
  /// setting)
  var recordHistory: @MainActor ([QueryHistoryOutcome]) async -> Void
  /// The connection's database, the one `db.dropDatabase()` drops; nil when unknown
  var database: String?
  /// The names among `names` that exist in `database` now (the `$out` replace check); tests
  /// replace it
  var existingNames:
    @Sendable (DatabaseConnectionManager, _ names: [String], _ database: String?) async throws
      -> Set<String> = { manager, names, database in
        try await manager.fetchMongoExistingNames(names, database: database)
      }
}

@MainActor
@Observable
final class MongoAdminActionModel {
  /// What a confirmation runs
  enum Action: Equatable {
    case admin(MongoAdminCommand)
    /// An `aggregate` whose last stage is `$out` (`isOut`) or `$merge` into `target`;
    /// `replacesExisting`: an `$out` over an existing collection
    case pipelineWrite(target: String, isOut: Bool, replacesExisting: Bool)
  }

  /// What the confirm sheet shows before anything is sent
  struct Confirmation: Equatable {
    /// One per request: a late answer meant for an earlier confirmation never sends a later one
    let id = UUID()
    let action: Action
    /// Exactly the text that is sent
    let text: String
    /// The exact name to type first (a drop, an `$out` over an existing collection); nil when
    /// there is no typed-name step
    let typedName: String?
    /// Display text for the typed-name step: "collection", "view" or "index"
    let objectKind: String
    /// The database the command runs in, shown with the confirmation; nil: not shown
    let database: String?
    /// The Safe Mode panel follows the typed-name step
    let needsSafeModePanel: Bool
    let requiresPassword: Bool
  }

  enum State: Equatable {
    case idle
    case confirming(Confirmation)
    case running
    case failed(String)
    case done
  }

  private(set) var state = State.idle
  /// The command running was sent by `confirm`: the confirm sheet stays open to show it. A
  /// command sent at once by `request` runs without the sheet.
  private(set) var runsConfirmed = false

  /// A `requestPipelineWrite` is between its entry and its outcome: a second call returns
  @ObservationIgnored private var requestsPipelineWrite = false
  @ObservationIgnored private let context: MongoAdminContext
  /// The epoch the shown objects were read with; a reconnect since then refuses the command
  @ObservationIgnored private let connectionEpoch: UInt64
  /// Called after a command reached the server (to reload the sidebar schema)
  @ObservationIgnored private let onStatementsExecuted: (@MainActor () async -> Void)?

  init(
    context: MongoAdminContext, connectionEpoch: UInt64,
    onStatementsExecuted: (@MainActor () async -> Void)?
  ) {
    self.context = context
    self.connectionEpoch = connectionEpoch
    self.onStatementsExecuted = onStatementsExecuted
  }

  /// The model for `tab`'s connection. Nil when the tab is not connected. `onExecuted` runs
  /// after a command reached the server, before the sidebar reload.
  convenience init?(
    tab: NotebookViewModel, connectionEpoch: UInt64,
    onExecuted: (@MainActor () -> Void)? = nil
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
        recordHistory: { [weak tab] in await tab?.recordExecution($0, source: .structure) },
        database: config.database.isEmpty ? MongoSession.defaultDatabase : config.database),
      connectionEpoch: connectionEpoch,
      onStatementsExecuted: { [weak tab] in
        onExecuted?()
        await tab?.onStatementsExecuted?()
      })
  }

  /// Refuses on a read-only or schema-only connection; otherwise asks what the command needs
  /// (typed name, Safe Mode panel) or sends it at once when nothing needs confirming. `isView`:
  /// the dropped collection is a view (the confirmation says "view"). `database`: shown with
  /// the confirmation (the connection's database when nil). `db.dropDatabase()` always shows and
  /// asks for the connection's database, the one the server drops, whatever `database` says.
  func request(
    _ command: MongoAdminCommand, isView: Bool = false, database: String? = nil
  ) async {
    guard state != .running else { return }
    runsConfirmed = false
    let text = command.render()
    let classified = SQLStatementClassifier.classify(text, dialect: .mongodb)
    if case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
      classified, policy: context.policy, dialect: .mongodb)
    {
      state = .failed(reason)
      return
    }
    let dropsOwn = command == .dropDatabase(database: nil)
    let database = dropsOwn ? context.database : database ?? context.database
    if dropsOwn, database == nil {
      state = .failed("The connection's database is unknown; nothing was sent.")
      return
    }
    let pending = Self.confirmation(
      for: command, text: text, commitStyle: context.commitStyle(), isView: isView,
      database: database)
    guard pending.typedName != nil || pending.needsSafeModePanel else {
      await send(text)
      return
    }
    state = .confirming(pending)
  }

  /// Why the gate refuses the pipeline write `text` under `policy`, before any prompt: over the
  /// parser's 1 MiB, or blocked by the rules (read-only blocks both stages, schema-only `$out`).
  /// Nil when it may be asked. The view hides its Run button on a refusal.
  static func pipelineWriteRefusal(text: String, policy: ProtectionPolicy) -> String? {
    // Text over the cap is unknown to the classifier, which `.none` would let through
    guard text.utf8.count <= MongoRelaxedJSON.maxInputBytes else {
      return "The text is larger than 1 MiB"
    }
    let classified = SQLStatementClassifier.classify(text, dialect: .mongodb)
    if case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
      classified, policy: policy, dialect: .mongodb)
    {
      return reason
    }
    return nil
  }

  /// Runs an `aggregate` whose last stage is `$out` (`isOut`) or `$merge` into `target` in the
  /// connection's database. Refused before any prompt by `pipelineWriteRefusal` under the
  /// effective policy (the connection's rules, Protected mode). An `$out` over an existing
  /// collection (`replacesExisting`, or found by a live check: the caller's list may be stale)
  /// asks for the exact target name first, whatever the commit style; a failed live check
  /// refuses. Then the Safe Mode panel when the commit style asks; otherwise it is sent at once.
  func requestPipelineWrite(
    text: String, target: String, replacesExisting: Bool, isOut: Bool
  ) async {
    guard state != .running, !requestsPipelineWrite else { return }
    requestsPipelineWrite = true
    defer { requestsPipelineWrite = false }
    runsConfirmed = false
    let policy = await context.manager.effectivePolicy(for: context.policy)
    if let reason = Self.pipelineWriteRefusal(text: text, policy: policy) {
      state = .failed(reason)
      return
    }
    var replaces = isOut && replacesExisting
    if isOut {
      do {
        let existing = try await context.existingNames(context.manager, [target], context.database)
        replaces = replaces || existing.contains(target)
      } catch {
        state = .failed("Could not check whether \(target) exists; nothing was sent.")
        return
      }
    }
    let commitStyle = context.commitStyle()
    let pending = Confirmation(
      action: .pipelineWrite(target: target, isOut: isOut, replacesExisting: replaces),
      text: text, typedName: replaces ? target : nil, objectKind: "collection",
      database: context.database, needsSafeModePanel: commitStyle != .immediate,
      requiresPassword: commitStyle.requiresPassword)
    guard pending.typedName != nil || pending.needsSafeModePanel else {
      await send(text, refreshesSchema: !isOut)
      return
    }
    state = .confirming(pending)
  }

  /// Whether `confirmation` is still the one being asked (not cancelled or replaced since)
  func isPending(_ confirmation: Confirmation) -> Bool {
    if case .confirming(let current) = state { return current.id == confirmation.id }
    return false
  }

  /// Sends `confirmation`'s command while it is still the one being asked. A drop is sent only
  /// when `typedName` matches its exact name; the Safe Mode panel (password / Touch ID) is
  /// verified by the sheet before this.
  func confirm(_ confirmation: Confirmation, typedName: String = "") async {
    guard isPending(confirmation), case .confirming(let pending) = state else { return }
    if let name = pending.typedName, !TypedNameConfirmation.matches(typedName, name: name) {
      return
    }
    runsConfirmed = true
    var isMerge = false
    if case .pipelineWrite(_, let isOut, _) = pending.action { isMerge = !isOut }
    await send(pending.text, refreshesSchema: isMerge)
  }

  /// Leaves the confirmation (or a failure) without sending anything. A finished command keeps
  /// `.done`, so every view watching the model sees it (the Create Index form closes on it).
  func cancel() {
    guard state != .running, state != .done else { return }
    state = .idle
  }

  /// What `command` asks before it is sent under `commitStyle`
  static func confirmation(
    for command: MongoAdminCommand, text: String, commitStyle: CommitStyle, isView: Bool = false,
    database: String? = nil
  ) -> Confirmation {
    let typedName: String?
    let objectKind: String
    var shownDatabase = database
    switch command {
    case .drop(let collection):
      (typedName, objectKind) = (collection, isView ? "view" : "collection")
    case .dropIndex(_, .string(let name)):
      (typedName, objectKind) = (name, "index")
    case .dropIndex(let collection, _):
      // An index given by its key document: the collection name is what the user types
      (typedName, objectKind) = (collection, "collection")
    case .dropDatabase(let name):
      // `request` refuses a drop of the connection's database when that name is unknown
      (typedName, objectKind) = (name ?? database ?? "", "database")
      shownDatabase = name ?? database
    case .createDatabase(let target, _, _):
      (typedName, objectKind) = (nil, "database")
      shownDatabase = target
    case .createIndex, .setIndexHidden, .createCollection, .createView, .renameCollection,
      .collMod:
      (typedName, objectKind) = (nil, "collection")
    }
    return Confirmation(
      action: .admin(command), text: text, typedName: typedName, objectKind: objectKind,
      database: shownDatabase, needsSafeModePanel: commitStyle != .immediate,
      requiresPassword: commitStyle.requiresPassword)
  }

  // MARK: - Private

  /// `refreshesSchema`: reload the sidebar after it whatever the gate noted (a `$merge` is DML
  /// to the gate, yet it creates a missing target, even when it fails partway)
  private func send(_ text: String, refreshesSchema: Bool = false) async {
    state = .running
    let started = Date()
    do {
      _ = try await context.manager.executeGatedSequentialBatch(
        [text], policy: context.policy, connectionEpoch: connectionEpoch,
        caller: context.caller, expectedRows: nil)
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: text, duration: Date().timeIntervalSince(started), rowCount: nil,
          status: .success, errorMessage: nil)
      ])
      state = .done
    } catch {
      let message: String
      if case DatabaseError.batchPartiallyApplied(_, _, let reason, _) = error {
        // One command: "Applied 0 of 1 changes" adds nothing to the server's reason
        message = reason
      } else if case DatabaseError.notEditable = error {
        // The gate's epoch check: a reconnect since the shown objects were read
        message = "The connection changed since this list was read; nothing was sent."
      } else {
        message = error.localizedDescription
      }
      await context.recordHistory([
        QueryHistoryOutcome(
          sql: text, duration: Date().timeIntervalSince(started), rowCount: nil,
          status: .error, errorMessage: message)
      ])
      state = .failed(message)
    }
    if refreshesSchema { await context.manager.restoreSchemaRefresh() }
    await onStatementsExecuted?()
  }
}
