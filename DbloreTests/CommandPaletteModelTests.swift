// CommandPaletteModelTests.swift
// Snapshot rank, cancel on the next keystroke, and history scoped to this connection.

import Foundation
import Testing

@testable import Dblore

@Suite("Command palette model")
@MainActor
struct CommandPaletteModelTests {
  @Test("snapshot rows rank by score, keep ties in snapshot order, and stop at 50")
  func snapshotRanksByScoreAndStopsAtFifty() async {
    let favoriteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var snapshot = CommandPaletteSnapshot(
      tables: [
        .init(schema: "b", name: "users"),
        .init(schema: "a", name: "users"),
      ],
      views: [.init(schema: "public", name: "users_extra")],
      functions: [.init(schema: "public", name: "all_users", arguments: "id integer")],
      tabs: [.init(id: tabID, title: "zzusers")],
      favorites: [.init(id: favoriteID, name: "saved users", sql: "SELECT 1")],
      actions: [.init(id: "run", title: "usres")]
    )
    let model = CommandPaletteModel()
    model.query = "Users"
    model.open(snapshot)

    let expected: [CommandPaletteItem] = [
      .table(schema: "b", name: "users"),
      .table(schema: "a", name: "users"),
      .view(schema: "public", name: "users_extra"),
      .function(schema: "public", name: "all_users", arguments: "id integer"),
      .favorite(id: favoriteID, name: "saved users", sql: "SELECT 1"),
      .tab(id: tabID, title: "zzusers"),
      .action(id: "run", title: "usres"),
    ]
    #expect(await waitUntil { model.ranked == expected })
    #expect(model.ranked == expected)

    model.query = "saved users"
    #expect(
      await waitUntil {
        model.ranked == [.favorite(id: favoriteID, name: "saved users", sql: "SELECT 1")]
      })

    snapshot.tables.append(.init(schema: "public", name: "users"))
    model.query = "Users"
    #expect(await waitUntil { model.ranked == expected })
    #expect(model.ranked == expected)

    var crowded = CommandPaletteSnapshot()
    crowded.tables = (0..<48).map { .init(schema: "public", name: "t\($0)") }
    crowded.actions = (0..<5).map { .init(id: "act-\($0)", title: "Action \($0)") }
    let capped = CommandPaletteModel()
    capped.open(crowded)
    var cappedExpected: [CommandPaletteItem] = crowded.tables.map {
      .table(schema: $0.schema, name: $0.name)
    }
    cappedExpected.append(.action(id: "act-0", title: "Action 0"))
    cappedExpected.append(.action(id: "act-1", title: "Action 1"))
    #expect(await waitUntil { capped.ranked == cappedExpected })
    #expect(capped.ranked.count == 50)
    #expect(capped.ranked == cappedExpected)
  }

  @Test("a new keystroke cancels the previous rank")
  func newKeystrokeCancelsPreviousRank() async {
    let gate = PaletteRankGate()
    let model = CommandPaletteModel(rank: BlockingRank.make(gate))
    let snapshot = CommandPaletteSnapshot(
      tables: [
        .init(schema: "public", name: "orders"),
        .init(schema: "public", name: "customers"),
      ])
    model.open(snapshot)
    #expect(await waitUntil { model.ranked.count == 2 })
    #expect(model.isRankFresh)
    let old = model.ranked

    // The previous rows stay on screen, marked stale, so Return refuses them.
    model.query = "block"
    #expect(model.ranked == old)
    #expect(!model.isRankFresh)
    #expect(!model.canPerform(old[0]))
    #expect(await gate.waitUntilStarted())
    #expect(model.ranked == old)
    #expect(!model.canPerform(old[0]))

    model.query = "orders"
    #expect(await gate.waitUntilCancelled())
    let orders: [CommandPaletteItem] = [.table(schema: "public", name: "orders")]
    #expect(await waitUntil { model.ranked == orders })
    #expect(model.ranked == orders)
    #expect(model.isRankFresh)
    #expect(model.canPerform(orders[0]))
  }

  @Test("perform inserts a favorite and a normal history row")
  func performInsertsFavoriteAndHistory() {
    let manager = makeWorkspace()
    manager.newNotebook()
    manager.activeViewModel?.selectedCellId = manager.activeViewModel?.notebook.cells.first?.id
    let favorite = FavoriteStatement(name: "saved", sql: "SELECT favorite")
    manager.saveFavorite(favorite)

    withInsertionCapture { captured in
      let row = manager.paletteSources().favorites.first { $0.id == favorite.id }
      #expect(row?.sql == "SELECT favorite")
      manager.perform(.favorite(id: favorite.id, name: favorite.name, sql: favorite.sql))
      #expect(captured.text == "SELECT favorite")

      captured.text = nil
      manager.perform(.history(id: 7, sql: "SELECT history_row"))
      #expect(captured.text == "SELECT history_row")
    }
  }

  @Test("perform stays open when commit, rollback, or the right sidebar would do nothing")
  func performStaysOpenWhenCommitRollbackOrSidebarWouldDoNothing() {
    let manager = makeWorkspace()
    #expect(!manager.perform(.action(id: "commit", title: "Commit")))
    #expect(!manager.isCommitConfirmationVisible)
    #expect(!manager.perform(.action(id: "rollback", title: "Roll Back")))
    #expect(!manager.perform(.action(id: "toggle-right-sidebar", title: "Toggle Right Sidebar")))

    // The connection-loss banner's Reconnect needs the unremembered certificate.
    let certificate = ClientCertificateStoreFactory.ConnectionMaterial(
      account: "lost", material: ClientCertificateMaterial(certificatePEM: "c", privateKeyPEM: "k"))
    manager.activeUnrememberedCertificate = certificate
    #expect(manager.connectionState == .disconnected)
    #expect(!manager.perform(.action(id: "disconnect", title: "Disconnect")))
    #expect(manager.activeUnrememberedCertificate == certificate)
    manager.activeUnrememberedCertificate = nil

    manager.pendingTransaction = .aborted(reason: "failed", pending: [])
    #expect(!manager.perform(.action(id: "commit", title: "Commit")))
    #expect(!manager.isCommitConfirmationVisible)

    manager.pendingTransaction = .appTx(pending: [])
    #expect(manager.perform(.action(id: "commit", title: "Commit")))
    #expect(manager.isCommitConfirmationVisible)
    #expect(manager.perform(.action(id: "rollback", title: "Roll Back")))

    manager.isCommitConfirmationVisible = false
    manager.pendingTransaction = .ending(kind: .commit, pending: [])
    #expect(!manager.perform(.action(id: "commit", title: "Commit")))
    #expect(!manager.perform(.action(id: "rollback", title: "Roll Back")))

    manager.newNotebook()
    manager.pendingTransaction = .appTx(pending: [])
    manager.transactionOriginTabId = manager.activeTabId
    manager.activeViewModel?.isEditorQueryRunning = true
    #expect(!manager.perform(.action(id: "commit", title: "Commit")))
    #expect(!manager.isCommitConfirmationVisible)
    #expect(!manager.perform(.action(id: "rollback", title: "Roll Back")))
    manager.activeViewModel?.isEditorQueryRunning = false
    manager.pendingTransaction = .idle
    manager.transactionOriginTabId = nil

    #expect(manager.activeViewModel?.isRightSidebarVisible == false)
    #expect(manager.perform(.action(id: "toggle-right-sidebar", title: "Toggle Right Sidebar")))
    #expect(manager.activeViewModel?.isRightSidebarVisible == true)
  }

  private func makeWorkspace() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(), restoreTabs: false)
  }

  private func withInsertionCapture(_ body: (PaletteInsertionCapture) -> Void) {
    let captured = PaletteInsertionCapture()
    let token = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { note in
      captured.text = note.userInfo?["text"] as? String
    }
    defer { NotificationCenter.default.removeObserver(token) }
    body(captured)
  }

  private func waitUntil(
    timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(15))
    }
    return condition()
  }

  private static func entry(
    sql: String, at executedAt: Date, connectionKey: String, kind: QueryHistoryEntry.Kind
  ) -> QueryHistoryEntry {
    QueryHistoryEntry(
      id: 0, sql: sql, executedAt: executedAt, durationMs: 1, rowCount: 1, status: .success,
      errorMessage: nil, connectionKey: connectionKey, connectionLabel: "palette",
      workspaceID: nil, workspaceName: nil, source: .cell, kind: kind)
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-palette-\(UUID().uuidString).sqlite")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
  }
}

/// Holds text posted with `insertTextIntoCell`. The notification callback is sendable.
private final class PaletteInsertionCapture: @unchecked Sendable {
  var text: String?
}

/// Counts run notifications posted by palette actions. The observer is sendable.
private final class PaletteNoteCount: @unchecked Sendable {
  var runAll = 0
  var editor = 0
  var unfocus = 0
}

/// Waits are upper bounds that return as soon as the flag flips. A loaded full-suite run can
/// delay the detached rank task by tens of seconds, so the bound is generous.
private actor PaletteRankGate {
  private var started = false
  private var cancelled = false

  func markStarted() { started = true }

  func markCancelled() { cancelled = true }

  func waitUntilStarted(timeout: Duration = .seconds(30)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !started {
      if clock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  func waitUntilCancelled(timeout: Duration = .seconds(30)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !cancelled {
      if clock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }
}

private enum BlockingRank {
  static func make(
    _ gate: PaletteRankGate
  )
    -> @Sendable ([CommandPaletteItem], String) async ->
    [CommandPaletteItem]
  {
    { items, query in
      if query == "block" {
        await gate.markStarted()
        // Blocks until cancelled. A short sleep can end on its own while a loaded suite holds
        // the test on the main actor, and then the cancel never reaches it.
        do {
          try await Task.sleep(for: .seconds(600))
        } catch {
          await gate.markCancelled()
        }
        return []
      }
      return await CommandPaletteRanking.rank(items, query)
    }
  }
}
