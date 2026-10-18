// MongoAdminActionModel.swift
// Runs one MongoDB administration command started from the UI (create / hide / drop an index,
// collections, views): refuses up front on protected connections with the gate's text, asks for
// the exact name before a drop whatever the commit style, then shows the Safe Mode panel when
// the commit style asks for it (Review counts as Confirm: admin DDL cannot be staged), and sends
// the rendered command through `executeGatedSequentialBatch` (which re-checks every refusal and
// the connection epoch). History rows use source `.structure`.

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
}

@MainActor
@Observable
final class MongoAdminActionModel {
  /// What the confirm sheet shows before anything is sent
  struct Confirmation: Equatable {
    /// One per request: a late answer meant for an earlier confirmation never sends a later one
    let id = UUID()
    let command: MongoAdminCommand
    /// Exactly the text that is sent
    let text: String
    /// The exact name to type first (a drop); nil when there is no typed-name step
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
        recordHistory: { [weak tab] in await tab?.recordExecution($0, source: .structure) }),
      connectionEpoch: connectionEpoch,
      onStatementsExecuted: { [weak tab] in
        onExecuted?()
        await tab?.onStatementsExecuted?()
      })
  }

  /// Refuses on a read-only or schema-only connection; otherwise asks what the command needs
  /// (typed name, Safe Mode panel) or sends it at once when nothing needs confirming. `isView`:
  /// the dropped collection is a view (the confirmation says "view"). `database`: shown with
  /// the confirmation.
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
    let pending = Self.confirmation(
      for: command, text: text, commitStyle: context.commitStyle(), isView: isView,
      database: database)
    guard pending.typedName != nil || pending.needsSafeModePanel else {
      await send(text)
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
    await send(pending.text)
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
    switch command {
    case .drop(let collection):
      (typedName, objectKind) = (collection, isView ? "view" : "collection")
    case .dropIndex(_, .string(let name)):
      (typedName, objectKind) = (name, "index")
    case .dropIndex(let collection, _):
      // An index given by its key document: the collection name is what the user types
      (typedName, objectKind) = (collection, "collection")
    case .createIndex, .setIndexHidden, .createCollection, .createView, .renameCollection,
      .collMod:
      (typedName, objectKind) = (nil, "collection")
    }
    return Confirmation(
      command: command, text: text, typedName: typedName, objectKind: objectKind,
      database: database, needsSafeModePanel: commitStyle != .immediate,
      requiresPassword: commitStyle.requiresPassword)
  }

  // MARK: - Private

  private func send(_ text: String) async {
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
      if case DatabaseError.batchPartiallyApplied(_, _, let reason) = error {
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
    await onStatementsExecuted?()
  }
}
