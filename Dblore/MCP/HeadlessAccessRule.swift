// HeadlessAccessRule.swift
// Which saved connection a caller without a window may use: the dblore command-line tool or a
// Shortcuts action. A connection is named by its id or its label (`MCPToolService.label`); a
// label two usable rows share is refused, so the id must be used. Then, in order: the caller's
// allowlist, the lock (any identity the row reaches, `LockRegistry.isLocked`, even after the user
// unlocked it in the app) and the caller's own rule.
// - cli: the MCP allowlist minus rows whose AI access is Never, with the strictest policy of
//   every saved row of the identity, Use default resolved through the global default (as MCP's
//   list_connections, `MCPToolService.decision`). Ask once per session runs with no prompt (the
//   user paired the tool). Read-only.
// - shortcuts: off until the user turns Shortcuts on, then its own allowlist; the MCP server may
//   be off. Nothing reaches a model, so the AI policy plays no part.
// The unattended refusal (password command, unpinned SSH host key) stays in
// `MCPConnectionPool.refuseUnattended`, which both callers reach through their pool.

import Foundation

nonisolated struct HeadlessAccessRule: Sendable {
  /// Who asks, with the settings its rule reads (taken by the caller, on the main actor)
  nonisolated enum Caller: Sendable {
    /// `aiSettings` nil: unreadable, read as `MCPToolService.unreadableAISettings`
    case cli(mcpAllowlist: Set<UUID>, aiSettings: AIConfiguration?)
    case shortcuts(enabled: Bool, allowlist: Set<UUID>)

    /// The command-line tool only reads; Shortcuts may add rows through the execution gate
    var isReadOnly: Bool {
      switch self {
      case .cli: true
      case .shortcuts: false
      }
    }
  }

  /// Why a connection was refused. Never carries a secret. A missing, not allowlisted, locked
  /// or AI-Never row reads the same, so a caller cannot tell which applies (as MCP).
  nonisolated enum Refusal: Error, Equatable, LocalizedError {
    case shortcutsOff
    case ambiguousName
    case notFound
    case notAllowlisted
    case locked
    case aiAccessNever

    var errorDescription: String? {
      switch self {
      case .shortcutsOff:
        "Shortcuts actions are turned off in Dblore. Turn them on in Settings > Shortcuts."
      case .ambiguousName:
        "The connection name is ambiguous; use the id."
      case .notFound, .notAllowlisted, .locked, .aiAccessNever:
        "No connection with that name or id is available. In Dblore, check that it is allowed "
          + "in Settings and not locked; the command line also skips connections whose AI "
          + "access is Never."
      }
    }
  }

  let gate: AIAccessGate
  let lockSource: LockRegistry

  init(gate: AIAccessGate = .shared, lockSource: LockRegistry = .shared) {
    self.gate = gate
    self.lockSource = lockSource
  }

  /// The rows `caller` may use, by label then id (as list_connections). `saved` is every saved
  /// row, allowlisted or not: their AI policies tighten the others of their identity.
  func entries(
    saved: [ConnectionHistoryEntry], caller: Caller
  ) -> [ConnectionHistoryEntry] {
    saved.filter { (try? check($0, saved: saved, caller: caller)) != nil }
      .sorted {
        (MCPToolService.label(of: $0.config), $0.id.uuidString)
          < (MCPToolService.label(of: $1.config), $1.id.uuidString)
      }
  }

  /// The row `reference` names: a saved row's id, else the label of exactly one usable row
  /// (trimmed, exact match).
  func resolve(
    _ reference: String, saved: [ConnectionHistoryEntry], caller: Caller
  ) throws -> ConnectionHistoryEntry {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = UUID(uuidString: reference), saved.contains(where: { $0.id == id }) {
      return try entry(id: id, saved: saved, caller: caller)
    }
    try checkEnabled(caller)
    let matches = entries(saved: saved, caller: caller).filter {
      MCPToolService.label(of: $0.config) == reference
    }
    guard matches.count < 2 else { throw Refusal.ambiguousName }
    guard let match = matches.first else { throw Refusal.notFound }
    return match
  }

  /// The saved row `id` when `caller` may use it
  func entry(
    id: UUID, saved: [ConnectionHistoryEntry], caller: Caller
  ) throws -> ConnectionHistoryEntry {
    try checkEnabled(caller)
    guard let entry = saved.first(where: { $0.id == id }) else { throw Refusal.notFound }
    try check(entry, saved: saved, caller: caller)
    return entry
  }

  /// A pool's lookup for `caller` (Shortcuts runs its own pool, the MCP server may be off): the
  /// row `id` while the rule allows it, checked again at every connect, with its password read
  /// only after the rule passed (one the Keychain could not read throws: the pool refuses the
  /// row). `saved` and `caller` read the settings as they are now.
  func entryLookup(
    saved: @escaping @Sendable () async -> [ConnectionHistoryEntry],
    caller: @escaping @Sendable () async -> Caller,
    password: @escaping @Sendable (ConnectionConfig) throws -> String?
  ) -> MCPConnectionPool.EntryLookup {
    { id in
      let rows = await saved()
      let current = await caller()
      guard var entry = try? self.entry(id: id, saved: rows, caller: current) else { return nil }
      if entry.config.databaseType.capabilities.usesPassword,
        let saved = try password(entry.config)
      {
        entry.config.password = saved
      }
      return entry
    }
  }

  private func checkEnabled(_ caller: Caller) throws {
    if case .shortcuts(enabled: false, _) = caller { throw Refusal.shortcutsOff }
  }

  private func check(
    _ entry: ConnectionHistoryEntry, saved: [ConnectionHistoryEntry], caller: Caller
  ) throws {
    try checkEnabled(caller)
    switch caller {
    case .cli(let allowlist, let aiSettings):
      guard allowlist.contains(entry.id) else { throw Refusal.notAllowlisted }
      guard !MCPToolService.isLocked(entry, lockSource: lockSource) else { throw Refusal.locked }
      let settings = aiSettings ?? MCPToolService.unreadableAISettings
      let decision = MCPToolService.decision(
        for: entry, saved: saved, settings: settings, gate: gate)
      guard decision != .denied else { throw Refusal.aiAccessNever }
    case .shortcuts(_, let allowlist):
      guard allowlist.contains(entry.id) else { throw Refusal.notAllowlisted }
      guard !MCPToolService.isLocked(entry, lockSource: lockSource) else { throw Refusal.locked }
    }
  }
}
