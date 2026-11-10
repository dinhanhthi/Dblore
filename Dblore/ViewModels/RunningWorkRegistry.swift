// RunningWorkRegistry.swift
// Long work that Quit, a window close or a disconnect would stop: Copy Objects, imports, exports,
// dumps, restores and schema compares. Each model joins when its run starts and leaves when it
// ends, fails or is cancelled, with its own Cancel as the entry's cancel. Running queries are not
// entries: the caller passes them from the workspaces' tabs. `decide` turns both into the
// question to ask, if any; `ask` asks it once and `stop` stops what the user chose to stop.

import AppKit

@MainActor
final class RunningWorkRegistry {
  static let shared = RunningWorkRegistry()

  /// What runs, for the prompt's wording
  nonisolated enum Kind: Equatable, Sendable {
    case copyObjects
    case dataImport
    case dataExport
    /// A SQL dump, a SQLite file copy or a MongoDB backup
    case dump
    /// A restore into the connected database of this engine
    case restore(DatabaseType)
    /// A schema compare reading both sides
    case schemaCompare
    /// A compare's script being sent on this engine (it has no Cancel: it runs to its end)
    case schemaChange(DatabaseType)
  }

  /// One running piece of work, as the prompt lists it
  nonisolated struct Item: Equatable, Sendable {
    /// The workspace it belongs to; nil for work no workspace owns (listed at quit only)
    var workspaceID: UUID?
    var label: String
    var kind: Kind

    /// What stopping it does, said after its label; nil when nothing needs saying
    var stopConsequence: String? {
      switch kind {
      case .restore(let engine), .schemaChange(let engine):
        RunningWorkRegistry.restoreConsequence(engine)
      default: nil
      }
    }

    /// The prompt's line
    var line: String { stopConsequence.map { "\(label) \($0)" } ?? label }
  }

  /// A query running in a tab of `workspaceID`
  nonisolated struct RunningQuery: Equatable, Sendable {
    var workspaceID: UUID
    var label: String
    /// What stopping it does to its transaction (`QueryCancelWarning.stopConsequence`)
    var stopConsequence: String? = nil
    /// The transaction `stopConsequence` was read from: Stop consents to cancel only that one
    var consent: StopConsent? = nil

    /// The prompt's line
    var line: String { stopConsequence.map { "\(label) \($0)" } ?? label }
  }

  /// What asks: Quit (every workspace), or a workspace's window close or disconnect
  nonisolated enum Scope: Equatable, Sendable {
    case quit
    case close(workspaceID: UUID)
    case disconnect(workspaceID: UUID)

    /// Nil at quit: every workspace's work counts
    var workspaceID: UUID? {
      switch self {
      case .quit: nil
      case .close(let id), .disconnect(let id): id
      }
    }
  }

  /// The question listing the running work, one line per query or item
  nonisolated struct Prompt: Equatable, Sendable {
    var title: String
    var message: String
    var lines: [String]
    /// The button that stops the work and goes on
    var stopTitle: String
  }

  nonisolated enum Decision: Equatable, Sendable {
    /// Nothing to ask
    case proceed
    /// Nothing runs and Confirm before quit is on: the generic "Quit Dblore?"
    case confirmQuit
    case runningWork(Prompt)

    var prompt: Prompt? {
      if case .runningWork(let prompt) = self { return prompt }
      return nil
    }
  }

  /// What `ask` got: nothing to ask, the generic "Quit Dblore?" (the caller asks it), or the
  /// running-work prompt's Stop or Cancel
  nonisolated enum Answer: Equatable, Sendable {
    case proceed
    case confirmQuit
    case stop
    case cancel
  }

  /// The workspace's transaction a running query's line was built from (the mirror's
  /// `generation` and user transaction). A cancel during Stop skips its own warning only while
  /// the connection still reports the same: one opened or grown since the prompt asks again.
  nonisolated struct StopConsent: Equatable, Sendable {
    var generation: UInt64
    var userTxOpen: Bool

    func covers(_ status: RunningStatementStatus) -> Bool {
      status.generation == generation && status.userTxOpen == userTxOpen
    }
  }

  /// A `stop` under way: its scope and the transaction each workspace's lines named
  private struct Stopping {
    let id = UUID()
    let scope: Scope
    let consents: [UUID: StopConsent]
  }

  /// Identifies one `begin`; `end` takes it back
  nonisolated struct Token: Hashable, Sendable {
    fileprivate let id: UUID
  }

  private struct Entry {
    let item: Item
    let confirmingCancel: (@MainActor () -> Task<Bool, Never>)?
    let cancel: @MainActor () -> Void
  }

  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  /// Scopes whose work the user chose to stop, while `stop` waits for it
  private var stopping: [Stopping] = []

  /// Shows the running-work prompt; true is its Stop button. Tests answer it (never an alert).
  var presentPrompt: @MainActor (Prompt) -> Bool = RunningWorkRegistry.showAlert

  /// Longest `stop` waits for the work to end, like a quit's wait for closing connections (tests
  /// shorten it)
  var stopLimit: Duration = .seconds(3)

  init() {}

  /// The running work, in the order it started
  var items: [Item] { order.compactMap { entries[$0]?.item } }

  /// Joins the list; `cancel` is the work's own Cancel (it must not wait). `label` is shown on
  /// one line: a name's line breaks, control and format (bidi) characters become spaces.
  /// - Parameter confirmingCancel: the Cancel `stop` runs instead of `cancel` when the work's
  ///   cancel may ask first; its task is true when the user answered "Keep running"
  @discardableResult
  func begin(
    workspaceID: UUID?, label: String, kind: Kind,
    confirmingCancel: (@MainActor () -> Task<Bool, Never>)? = nil,
    cancel: @escaping @MainActor () -> Void
  ) -> Token {
    let id = UUID()
    let shown = AISchemaContext.oneLine(label).trimmingCharacters(in: .whitespaces)
    entries[id] = Entry(
      item: Item(workspaceID: workspaceID, label: shown, kind: kind),
      confirmingCancel: confirmingCancel, cancel: cancel)
    order.append(id)
    return Token(id: id)
  }

  /// Leaves the list; a second call does nothing
  func end(_ token: Token) {
    guard entries.removeValue(forKey: token.id) != nil else { return }
    order.removeAll { $0 == token.id }
  }

  /// Runs the cancel of every entry in `scope`. Entries stay until their work ends.
  func cancelAll(in scope: Scope) {
    cancelAll(in: scope, skipping: [])
  }

  /// `cancelAll`, leaving out the entries `skipping` names (already cancelled)
  private func cancelAll(in scope: Scope, skipping: Set<UUID>) {
    let cancels = order.compactMap { id -> (@MainActor () -> Void)? in
      guard !skipping.contains(id), let entry = entries[id],
        Self.belongs(entry.item.workspaceID, to: scope)
      else {
        return nil
      }
      return entry.cancel
    }
    for cancel in cancels { cancel() }
  }

  // MARK: - Asking and stopping

  /// Asks what `scope` needs, once: running work in scope shows the prompt (whatever
  /// `confirmBeforeQuit`), so a Cmd+Q never gets the generic question as well
  func ask(
    _ scope: Scope, runningQueries: [RunningQuery], confirmBeforeQuit: Bool = false
  ) -> Answer {
    switch Self.decide(
      items: items, runningQueries: runningQueries, scope: scope,
      confirmBeforeQuit: confirmBeforeQuit)
    {
    case .proceed: .proceed
    case .confirmQuit: .confirmQuit
    case .runningWork(let prompt): presentPrompt(prompt) ? .stop : .cancel
    }
  }

  /// Stops the work in `scope` after the prompt's Stop: `stopQueries` first, waiting for every
  /// cancel it started (a cancel warning waits for the user's answer, whatever the limit), then
  /// each entry's confirming cancel (awaited the same way), then every other entry's cancel.
  /// Waits until the entries left and `queriesRunning` is false, at most `limit` (`stopLimit`
  /// when nil): a cancel that hangs never holds the quit or close longer.
  /// Meanwhile a cancel of a running statement in scope does not ask again while its
  /// transaction is the one `queries` (the prompt's lines) named (`stopConsent`).
  /// - Parameter stopQueries: the running statements' cancels; each task is true when its
  ///   warning was answered "Keep running"
  /// - Returns: false when one was, or an entry's confirming cancel was: the user keeps it
  ///   running, so nothing else is stopped and the quit, close or disconnect is cancelled
  @discardableResult
  func stop(
    _ scope: Scope, queries: [RunningQuery] = [],
    stopQueries: @MainActor () -> [Task<Bool, Never>],
    queriesRunning: @MainActor () -> Bool, limit: Duration? = nil
  ) async -> Bool {
    var consents: [UUID: StopConsent] = [:]
    for query in queries where Self.belongs(query.workspaceID, to: scope) {
      if let consent = query.consent { consents[query.workspaceID] = consent }
    }
    let entry = Stopping(scope: scope, consents: consents)
    stopping.append(entry)
    defer { stopping.removeAll { $0.id == entry.id } }
    var keptRunning = false
    for cancel in stopQueries() where await cancel.value { keptRunning = true }
    guard !keptRunning else { return false }
    // Entries whose cancel may ask, one at a time: "Keep running" leaves every other entry be
    var confirmed: Set<UUID> = []
    for id in order {
      guard let work = entries[id], let confirm = work.confirmingCancel,
        Self.belongs(work.item.workspaceID, to: scope)
      else { continue }
      confirmed.insert(id)
      if await confirm().value { return false }
    }
    cancelAll(in: scope, skipping: confirmed)
    // Lets the cancels the entries started read `stopConsent` before the scope clears (with
    // nothing left to wait for, the loop below would end without suspending)
    await Task.yield()
    let clock = ContinuousClock()
    let deadline = clock.now + (limit ?? stopLimit)
    while hasWork(in: scope) || queriesRunning() {
      let left = deadline - clock.now
      guard left > .zero else { return true }
      // Sleeps without holding the main actor; a cancelled task stops waiting at once
      do { try await Task.sleep(for: min(left, .milliseconds(50))) } catch { return true }
    }
    return true
  }

  /// The user already chose to stop the work of `workspaceID` (or everything, at quit), and
  /// `stop` still waits for it
  func stopsWithoutAsking(workspaceID: UUID?) -> Bool {
    stopping.contains { entry in
      guard let id = entry.scope.workspaceID else { return true }
      return id == workspaceID
    }
  }

  /// The transaction the prompt's Stop consented to roll back for `workspaceID`'s running
  /// query, while that stop waits; nil when no line named it (its cancel asks as usual)
  func stopConsent(workspaceID: UUID) -> StopConsent? {
    stopping.lazy.compactMap { entry in
      Self.belongs(workspaceID, to: entry.scope) ? entry.consents[workspaceID] : nil
    }.first
  }

  private func hasWork(in scope: Scope) -> Bool {
    items.contains { Self.belongs($0.workspaceID, to: scope) }
  }

  /// The prompt as an alert: the stop button needs a click (Return never stops the work), Escape
  /// cancels. The test host never shows it (an unanswered alert would hang the run).
  static func showAlert(_ prompt: Prompt) -> Bool {
    guard !SessionManager.isRunningAsTestHost else { return true }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = prompt.title
    alert.informativeText = prompt.message
    let stop = alert.addButton(withTitle: prompt.stopTitle)
    stop.keyEquivalent = ""
    stop.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: - Decision

  /// What `scope` asks before it stops anything. `runningQueries` are every workspace's
  /// (filtered here like the items). Work running in scope asks with its list, whatever
  /// `confirmBeforeQuit`; nothing running asks only at quit with `confirmBeforeQuit` on.
  nonisolated static func decide(
    items: [Item], runningQueries: [RunningQuery], scope: Scope, confirmBeforeQuit: Bool
  ) -> Decision {
    let lines =
      runningQueries.filter { belongs($0.workspaceID, to: scope) }.map(\.line)
      + items.filter { belongs($0.workspaceID, to: scope) }.map(\.line)
    guard !lines.isEmpty else {
      return scope == .quit && confirmBeforeQuit ? .confirmQuit : .proceed
    }
    let (title, stopTitle) =
      switch scope {
      case .quit: ("Quit Dblore?", "Stop and Quit")
      case .close: ("Close this workspace?", "Stop and Close")
      case .disconnect: ("Disconnect?", "Stop and Disconnect")
      }
    return .runningWork(
      Prompt(
        title: title,
        message: "Still running:\n" + lines.map { "- \($0)" }.joined(separator: "\n"),
        lines: lines, stopTitle: stopTitle))
  }

  /// What stopping a restore or a compare's script does on `engine`: PostgreSQL, SQLite and
  /// DuckDB roll it back (one transaction), MySQL and MongoDB keep what already ran
  nonisolated static func restoreConsequence(_ engine: DatabaseType) -> String {
    switch engine {
    case .postgresql, .sqlite, .duckdb: "will be stopped and rolled back"
    case .mysql, .mongodb: "will be stopped; statements already run stay in the database"
    }
  }

  /// The open workspace whose connection is `manager`; nil when none is (tests, a closed window)
  static func workspaceID(of manager: DatabaseConnectionManager) -> UUID? {
    WorkspaceWindowManager.shared.allWorkspaces.first { $0.connectionManager === manager }?.id
  }

  /// At quit everything belongs; otherwise only work of that workspace (nil-workspace work never)
  private nonisolated static func belongs(_ workspaceID: UUID?, to scope: Scope) -> Bool {
    guard let id = scope.workspaceID else { return true }
    return workspaceID == id
  }
}
