// MongoDocumentEditLiveTests.swift
// Staged document edits of the data viewer against the docker fixture (mongo:8.0 on
// TEST_MONGO_PORT, 27018 by default, users in `admin`) through a real DatabaseConnectionManager:
// an insert into an empty collection, an inline field edit and a delete, each confirmed in Safe
// Mode (Protected mode on) and checked on the server; and a commit whose second insert repeats an
// existing `_id`, which reports "Applied 1 of 2" and keeps only that insert staged. Opt-in
// (`.requiresMongo`), serialized; collections use `docedit_` and are dropped before and after.

import Foundation
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoDocumentEditLiveTests {
  /// Collects toasts (the view model shows them through `toastPresenter`).
  private final class Toasts {
    var messages: [String] = []
  }

  private struct Fixture {
    let viewModel: NotebookViewModel
    let manager: DatabaseConnectionManager
    let toasts: Toasts
  }

  /// Runs `body` with a data viewer on `collection` (dropped before and after) and its first
  /// page loaded. `seed` runs through the manager before the page loads.
  private func withDataViewer(
    _ collection: String, seed: String? = nil, _ body: (Fixture) async throws -> Void
  ) async throws {
    await MongoSessionTests.drop(collection)
    // Protected mode on (the default): every write waits for the Safe Mode confirmation.
    let config = MongoSessionTests.config()
    #expect(config.protectedMode)
    let manager = DatabaseConnectionManager()
    do {
      try await manager.connect(config: config)
      #expect(await manager.session is MongoSession)
      if let seed { _ = try await run(manager, seed) }
      let viewModel = NotebookViewModel()
      viewModel.notebook.connectionConfig = config
      let toasts = Toasts()
      viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
      viewModel.connectionManager = manager
      viewModel.connectionState = .connected
      viewModel.viewMode = .editor
      var state = DataViewerState(
        schema: TestMongoDatabase.database, name: collection, orderColumns: ["_id"])
      state.databaseType = .mongodb
      viewModel.dataViewer = state
      await viewModel.loadDataViewerPage()
      #expect(viewModel.stagingEnabled, "\(viewModel.rowStagingUnavailableReason ?? "")")
      try await body(Fixture(viewModel: viewModel, manager: manager, toasts: toasts))
    } catch {
      await manager.disconnect()
      await MongoSessionTests.drop(collection)
      throw error
    }
    await manager.disconnect()
    await MongoSessionTests.drop(collection)
  }

  private func run(
    _ manager: DatabaseConnectionManager, _ text: String
  ) async throws
    -> QueryResult
  {
    try await manager.execute(
      userSQL: text, policy: ProtectionPolicy(protectionLevel: .none), maxRows: 1_000)
  }

  /// Stages one insert through the document editor (+ Row).
  private func stageInsert(_ viewModel: NotebookViewModel, _ text: String) async {
    #expect(viewModel.openDocumentInsertEditor() == nil)
    let error = await viewModel.applyDocumentEditor(text)
    #expect(error == nil, "\(String(describing: error))")
  }

  /// Commit, confirmed in the Safe Mode dialog.
  private func commitConfirmed(_ viewModel: NotebookViewModel) async {
    await viewModel.commitStaged()
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.pendingStagedBatch != nil)
    await viewModel.executePendingQuery()
  }

  private func column(_ name: String, of columns: [ColumnInfo]) throws -> Int {
    try #require(columns.firstIndex { $0.name == name }, "no column \(name)")
  }

  @Test(
    "Insert into an empty collection, inline edit and delete reach the server", .requiresMongo)
  func insertUpdateDelete() async throws {
    let name = "docedit_crud"
    try await withDataViewer(name) { fixture in
      let viewModel = fixture.viewModel
      #expect(viewModel.editorResult?.rows.isEmpty == true)

      // Insert into the empty collection: the server assigns the ObjectId
      await stageInsert(viewModel, #"{name: "ann", n: NumberLong("7"), tags: ["a"]}"#)
      #expect(viewModel.stagedChangeCounts?.inserts == 1)
      await commitConfirmed(viewModel)
      #expect(fixture.toasts.messages.isEmpty, "\(fixture.toasts.messages)")
      #expect(viewModel.dataViewer?.documentChangeSet == nil)
      #expect(viewModel.editorResult?.rows.count == 1)
      let inserted = try await run(fixture.manager, "db.\(name).find()")
      #expect(inserted.rows.count == 1)
      #expect(inserted.columns.map(\.name) == ["_id", "name", "n", "tags"])
      #expect(inserted.columns.first?.type == "objectId")

      // A second document, then reload the page
      _ = try await run(
        fixture.manager,
        #"db.\#(name).insertOne({_id: ObjectId("ffffffffffffffffffffffff"), name: "bob"})"#)
      await viewModel.refreshDataViewer()
      let page = try #require(viewModel.editorResult)
      #expect(page.rows.count == 2)
      let nameIndex = try column("name", of: page.columns)
      let ann = try #require(page.rows.firstIndex { $0[nameIndex] == .string("ann") })
      let bob = try #require(page.rows.firstIndex { $0[nameIndex] == .string("bob") })

      // Inline edit of ann's name: one $set, confirmed
      viewModel.handleGridCellEdit(
        row: page.rows[ann], column: nameIndex, newValue: "zoe", result: page, cellId: nil,
        connectionManager: fixture.manager)
      #expect(viewModel.pendingStagedBatch?.mongoCommands?.count == 1)
      #expect(viewModel.queryConfirmationState.showDialog)
      await viewModel.executePendingQuery()
      #expect(fixture.toasts.messages.isEmpty, "\(fixture.toasts.messages)")

      // Delete bob, confirmed
      #expect(viewModel.stageDelete(rows: [bob]) == nil)
      #expect(viewModel.stagedChangeCounts?.deletes == 1)
      await commitConfirmed(viewModel)
      #expect(fixture.toasts.messages.isEmpty, "\(fixture.toasts.messages)")
      #expect(viewModel.dataViewer?.documentChangeSet == nil)
      #expect(viewModel.editorResult?.rows.count == 1)

      // On the server: ann renamed, her other fields and their types untouched; bob gone
      let stored = try await run(fixture.manager, "db.\(name).find()")
      #expect(stored.rows.count == 1)
      #expect(stored.columns.map(\.name) == ["_id", "name", "n", "tags"])
      #expect(stored.columns.map(\.type) == ["objectId", "string", "long", "array"])
      let row = try #require(stored.rows.first)
      #expect(row[try column("name", of: stored.columns)] == .string("zoe"))
      #expect(row[try column("n", of: stored.columns)] == .int(7))
      let bobLeft = try await run(fixture.manager, #"db.\#(name).countDocuments({name: "bob"})"#)
      #expect(bobLeft.rows == [[.int(0)]])
    }
  }

  @Test(
    "A duplicate _id in the second insert applies the first and keeps the second staged",
    .requiresMongo)
  func partialFailure() async throws {
    let name = "docedit_partial"
    try await withDataViewer(name, seed: #"db.\#(name).insertOne({_id: 1, name: "ann"})"#) {
      fixture in
      let viewModel = fixture.viewModel
      #expect(viewModel.editorResult?.rows.count == 1)
      await stageInsert(viewModel, #"{_id: 2, name: "bob"}"#)
      await stageInsert(viewModel, #"{_id: 1, name: "dup"}"#)
      #expect(viewModel.stagedChangeCounts?.inserts == 2)
      await commitConfirmed(viewModel)

      let message = try #require(fixture.toasts.messages.last)
      #expect(message.hasPrefix("Applied 1 of 2 changes"), "\(message)")
      // Only the failing insert stays staged; the page shows the applied one
      let set = try #require(viewModel.dataViewer?.documentChangeSet)
      #expect(set.deletes.isEmpty && set.updates.isEmpty)
      #expect(
        set.inserts.map(\.document) == [
          .document([MongoValue.Field("_id", .int32(1)), MongoValue.Field("name", .string("dup"))])
        ])
      #expect(viewModel.editorResult?.rows.count == 2)

      let stored = try await run(fixture.manager, "db.\(name).find().sort({_id: 1})")
      #expect(stored.rows == [[.int(1), .string("ann")], [.int(2), .string("bob")]])
    }
  }
}
