// RunningWorkRegistry.swift
// Long work that Quit, a window close or a disconnect would stop: Copy Objects, imports, exports,
// dumps, restores and schema compares. Each model joins when its run starts and leaves when it
// ends, fails or is cancelled, with its own Cancel as the entry's cancel. Running queries are not
// entries: the caller passes them from the workspaces' tabs. `decide` turns both into the
// question to ask, if any.

import Foundation

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

  /// Identifies one `begin`; `end` takes it back
  nonisolated struct Token: Hashable, Sendable {
    fileprivate let id: UUID
  }

  private struct Entry {
    let item: Item
    let cancel: @MainActor () -> Void
  }

  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []

  init() {}

  /// The running work, in the order it started
  var items: [Item] { order.compactMap { entries[$0]?.item } }

  /// Joins the list; `cancel` is the work's own Cancel (it must not wait). `label` is shown on
  /// one line: a name's line breaks, control and format (bidi) characters become spaces.
  @discardableResult
  func begin(
    workspaceID: UUID?, label: String, kind: Kind, cancel: @escaping @MainActor () -> Void
  ) -> Token {
    let id = UUID()
    let shown = AISchemaContext.oneLine(label).trimmingCharacters(in: .whitespaces)
    entries[id] = Entry(
      item: Item(workspaceID: workspaceID, label: shown, kind: kind), cancel: cancel)
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
    let cancels = order.compactMap { id -> (@MainActor () -> Void)? in
      guard let entry = entries[id], Self.belongs(entry.item.workspaceID, to: scope) else {
        return nil
      }
      return entry.cancel
    }
    for cancel in cancels { cancel() }
  }

  // MARK: - Decision

  /// What `scope` asks before it stops anything. `runningQueries` are every workspace's
  /// (filtered here like the items). Work running in scope asks with its list, whatever
  /// `confirmBeforeQuit`; nothing running asks only at quit with `confirmBeforeQuit` on.
  nonisolated static func decide(
    items: [Item], runningQueries: [RunningQuery], scope: Scope, confirmBeforeQuit: Bool
  ) -> Decision {
    let lines =
      runningQueries.filter { belongs($0.workspaceID, to: scope) }.map(\.label)
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
