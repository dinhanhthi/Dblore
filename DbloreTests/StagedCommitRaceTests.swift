// StagedCommitRaceTests.swift
// A staged commit is sent once: a second Commit (header, preview sheet or leave prompt) while
// the first is still in flight is refused. No database: the first commit is held at its key
// lookup through `keyLookupCheckpointForTesting`.

import Foundation
import Testing

@testable import Dblore

@Suite("Staged commit race")
@MainActor
struct StagedCommitRaceTests {
  @Test("A second commit while the first is in flight is refused")
  func secondCommitInFlightIsRefused() async {
    let viewModel = makeViewModel()
    viewModel.toastPresenter = { _, _ in }
    #expect(viewModel.stageInsert() == nil)
    let gate = Gate()
    viewModel.keyLookupCheckpointForTesting = { await gate.checkpoint() }

    let first = Task { await viewModel.commitStaged() }
    await gate.waitUntilParked()
    // The first commit is parked at its key lookup: a second one must not start
    await viewModel.commitStaged()
    #expect(gate.hits == 1)

    gate.release()
    await first.value
    // The first commit finished: Commit works again (a new row needs a key again)
    #expect(viewModel.stageInsert() == nil)
    await viewModel.commitStaged()
    #expect(gate.hits == 2)
  }

  /// Import (or MongoDB inline edit) sends are not commits: two of them overlapping, the first
  /// finishing first, must not leave Commit refused for the rest of the tab's life
  @Test("Overlapping sends that are not commits leave Commit available")
  func overlappingSendsLeaveCommitAvailable() async {
    let viewModel = makeViewModel()
    viewModel.toastPresenter = { _, _ in }
    let gate = SendGate()
    viewModel.onStatementsExecuted = { await gate.park() }
    let batch = PendingStagedBatch(
      statements: [BoundStatement(sql: "INSERT INTO public.users (id) VALUES ($1)", values: ["2"])],
      preview: "INSERT INTO public.users (id) VALUES (2)", connectionEpoch: 0,
      historySource: .dataImport)

    let first = Task { await viewModel.runConfirmedStagedBatch(batch) }
    await gate.waitForParked(1)
    let second = Task { await viewModel.runConfirmedStagedBatch(batch) }
    await gate.waitForParked(2)
    // The first send ends before the second
    gate.release(0)
    _ = await first.value
    gate.release(1)
    _ = await second.value
    #expect(viewModel.isCommittingStaged == false)
  }

  /// Parks every send at its end (`onStatementsExecuted`) until released by start order.
  @MainActor
  private final class SendGate {
    private var held: [CheckedContinuation<Void, Never>?] = []
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func park() async {
      await withCheckedContinuation { continuation in
        held.append(continuation)
        if let waiter, held.count >= waiter.count {
          self.waiter = nil
          waiter.continuation.resume()
        }
      }
    }

    func waitForParked(_ count: Int) async {
      guard held.count < count else { return }
      await withCheckedContinuation { waiter = (count, $0) }
    }

    func release(_ index: Int) {
      held[index]?.resume()
      held[index] = nil
    }
  }

  /// Holds the first commit at the key lookup; later lookups pass through.
  @MainActor
  private final class Gate {
    private(set) var hits = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func checkpoint() async {
      hits += 1
      guard hits == 1 else { return }
      await withCheckedContinuation { continuation in
        held = continuation
        parked?.resume()
        parked = nil
      }
    }

    func waitUntilParked() async {
      guard held == nil else { return }
      await withCheckedContinuation { parked = $0 }
    }

    func release() {
      held?.resume()
      held = nil
    }
  }

  private static let usersID = TableRef.postgresql(oid: 1)

  private func makeViewModel() -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.viewMode = .editor
    viewModel.notebook.connectionConfig = ConnectionConfig(
      host: "localhost", port: 5432, database: "app", username: "ana", password: "x",
      protectionLevel: .none, safeMode: .silent, protectedMode: false)
    viewModel.dataViewer = DataViewerState(
      schema: "public", name: "users", orderColumns: ["id"])
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "int4",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 1)),
        ColumnInfo(
          name: "nickname", type: "text",
          origin: ColumnOrigin(tableID: Self.usersID, columnOrdinal: 2)),
      ],
      rows: [[.int(1), .string("old")]],
      rowCount: 1,
      editTarget: EditTarget(
        qualifiedName: "public.users", tableID: Self.usersID, primaryKeyColumns: ["id"],
        connectionEpoch: 0, updateOnly: true))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }
}
