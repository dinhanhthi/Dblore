// ShortcutsRunnerTests.swift
// Shortcuts has no approval dialog: Add Row under a commit style that needs the user, and a Run
// Query that is not one read, are refused before anything is connected or sent; the pool's
// lookup reads a password only for a row the rule allows; Open Connection refuses rows that
// would run the user's scripts.

import Foundation
import Security
import Testing

@testable import Dblore

/// History rows, readable by the test
private actor HistoryBook: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// How many passwords were read
private final class PasswordReads: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0

  var count: Int { lock.withLock { reads } }

  func read(_ config: ConnectionConfig) -> String? {
    lock.withLock { reads += 1 }
    return "secret"
  }
}

@MainActor
@Suite("Shortcuts runner")
struct ShortcutsRunnerTests {
  private let factory = FakeDatabaseSessionFactory(
    capabilities: .contract(), columns: [ColumnInfo(name: "n", type: "integer")],
    rows: [[.int(1)]])
  private let history = HistoryBook()

  private static func entry(
    name: String = "Orders", style: CommitStyle = .immediate
  ) -> ConnectionHistoryEntry {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      sslMode: .disable, protectionLevel: .none, name: name, safeMode: .silent,
      protectedMode: false)
    config.applyCommitStyle(style)
    return ConnectionHistoryEntry(config: config)
  }

  private func runner(
    _ rows: [ConnectionHistoryEntry],
    password: @escaping @Sendable (ConnectionConfig) throws -> String? = { _ in nil }
  ) -> ShortcutsRunner {
    let allowed = Set(rows.map(\.id))
    return ShortcutsRunner(
      rule: HeadlessAccessRule(gate: AIAccessGate(), lockSource: LockRegistry()),
      saved: { rows }, caller: { .shortcuts(enabled: true, allowlist: allowed) },
      defaultCommitStyle: { .immediate }, recorder: history, historyEnabled: { true },
      password: password, sessionFactory: factory)
  }

  @Test(
    "Add Row is refused before any send when the commit style needs the user",
    arguments: [CommitStyle.confirm, .review, .password])
  func addRowRefusedUnderCommitStyle(_ style: CommitStyle) async {
    let entry = Self.entry(style: style)
    let runner = runner([entry])
    await #expect(throws: ShortcutsRunner.Refusal.commitStyle(style)) {
      try await runner.addRow(connectionID: entry.id, table: "orders", values: #"{"n": 1}"#)
    }
    #expect(factory.sessions.isEmpty)
    #expect(await history.entries.isEmpty)
    await runner.pool.closeAll()
  }

  @Test("Run Query refuses a write before any send and records the refusal as Shortcuts")
  func runQueryRefusesWrite() async throws {
    let entry = Self.entry()
    let runner = runner([entry])
    await #expect(throws: ReadOnlyQueryGuard.Refusal.notRead) {
      try await runner.runQuery(connectionID: entry.id, sql: "DELETE FROM orders")
    }
    #expect(factory.sessions.isEmpty)
    let refused = await history.entries
    #expect(refused.map(\.source) == [.shortcuts])
    #expect(refused.map(\.status) == [.error])

    // A read on the same runner does reach the database
    let csv = try await runner.runQuery(connectionID: entry.id, sql: "SELECT n FROM orders")
    #expect(factory.sessions.count == 1)
    #expect(csv.hasPrefix("n\r\n1\r\n1 row."))
    #expect(csv.hasSuffix(MCPResultEncoder.dataNotice))
    await runner.pool.closeAll()
  }

  @Test("The pool's lookup reads a password only for a row Shortcuts may use")
  func lookupReadsPasswordAfterRule() async throws {
    let allowed = Self.entry(name: "Allowed")
    let other = Self.entry(name: "Other")
    let reads = PasswordReads()
    let rule = HeadlessAccessRule(gate: AIAccessGate(), lockSource: LockRegistry())
    let allowlist: Set<UUID> = [allowed.id]
    let lookup = { (enabled: Bool) in
      rule.entryLookup(
        saved: { [allowed, other] },
        caller: { .shortcuts(enabled: enabled, allowlist: allowlist) },
        password: reads.read)
    }
    #expect(try await lookup(true)(other.id) == nil)
    #expect(try await lookup(false)(allowed.id) == nil)
    #expect(reads.count == 0)
    let found = try await lookup(true)(allowed.id)
    #expect(found?.id == allowed.id)
    #expect(found?.config.password == "secret")
    #expect(reads.count == 1)
  }

  @Test("A row whose saved password the Keychain cannot read is refused with that reason")
  func unreadablePasswordRefused() async {
    let entry = Self.entry()
    let runner = runner([entry]) { _ in
      throw ConnectionPasswordError.unreadable(errSecInteractionNotAllowed)
    }
    await #expect(throws: MCPConnectionError.passwordStoreUnreadable) {
      try await runner.runQuery(connectionID: entry.id, sql: "SELECT n FROM orders")
    }
    #expect(factory.sessions.isEmpty)
    await runner.pool.closeAll()
  }

  @Test("Open Connection refuses a row with a password command, as the actions run here do")
  func openRefusesPasswordCommand() async throws {
    var scripted = Self.entry()
    scripted.config.passwordCommandScript = "pw.sh"
    let plain = Self.entry(name: "Plain")
    let runner = runner([scripted, plain])
    await #expect(throws: ShortcutsRunner.Refusal.opensWithScripts) {
      try await runner.openableEntry(id: scripted.id)
    }
    #expect(try await runner.openableEntry(id: plain.id).id == plain.id)
    #expect(factory.sessions.isEmpty)
    await runner.pool.closeAll()
  }

  @Test("Open Connection refuses a row with a pre-connect or post-disconnect script")
  func openRefusesConnectionScripts() async throws {
    var preConnect = Self.entry(name: "Pre")
    preConnect.config.preConnectScript = "pre.sh"
    var postDisconnect = Self.entry(name: "Post")
    postDisconnect.config.postDisconnectScript = "post.sh"
    let runner = runner([preConnect, postDisconnect])
    for row in [preConnect, postDisconnect] {
      await #expect(throws: ShortcutsRunner.Refusal.opensWithScripts) {
        try await runner.openableEntry(id: row.id)
      }
    }
    #expect(factory.sessions.isEmpty)
    await runner.pool.closeAll()
  }
}
