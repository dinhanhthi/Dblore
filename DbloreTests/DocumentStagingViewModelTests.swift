// DocumentStagingViewModelTests.swift
// MongoDB document staging on NotebookViewModel: the data viewer stages inserts (+ Row,
// Duplicate, through the document editor) and deletes in `documentChangeSet`; Commit confirms
// the rendered commands in Safe Mode and sends them one by one through
// `executeGatedSequentialBatch` (never BEGIN / COMMIT); inline edits parse by BSON type and
// commit one `$set` each. Fake session, no database needed.

import Foundation
import Testing

@testable import Dblore

@Suite("Document staging view model")
@MainActor
struct DocumentStagingViewModelTests {
  private static let first = "0123456789abcdef01234567"
  private static let second = "89abcdef0123456789abcdef"
  private static let stats = MongoValue.document([
    MongoValue.Field("n", .int64(5)), MongoValue.Field("d", .double(1.5)),
  ])
  private static let columns = [
    ColumnInfo(name: "_id", type: "objectId"), ColumnInfo(name: "name", type: "string"),
    ColumnInfo(name: "stats", type: "object"), ColumnInfo(name: "owner", type: "objectId"),
  ]
  private static let rows: [[CellValue]] = [
    [
      .string(first), .string("ann"),
      MongoBSONMapping.cellValue(stats), .string(second),
    ],
    [.string(second), .string("bob"), .null, .null],
  ]

  /// Collects toasts (the view model shows them through `toastPresenter`).
  private final class Toasts {
    var messages: [String] = []
  }

  /// Default MongoDB connection: Protected mode on, so writes confirm (Phase 4/7).
  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable)
  }

  private struct Fixture {
    let viewModel: NotebookViewModel
    let manager: DatabaseConnectionManager
    let factory: FakeDatabaseSessionFactory
    let toasts: Toasts
  }

  /// A view model connected to a fake MongoDB session that answers every read with `rows` and
  /// every write with `commandRows` (1 by default).
  private static func connected(
    columns: [ColumnInfo] = columns, rows: [[CellValue]] = rows,
    commandRows: @escaping @Sendable (String) -> Int? = { _ in 1 }
  ) async throws -> Fixture {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, columns: columns, rows: rows,
      commandRows: commandRows)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config())
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = config()
    let toasts = Toasts()
    viewModel.toastPresenter = { message, _ in toasts.messages.append(message) }
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.viewMode = .editor
    return Fixture(viewModel: viewModel, manager: manager, factory: factory, toasts: toasts)
  }

  /// A data viewer on `users` with its first page loaded.
  private static func dataViewer(
    columns: [ColumnInfo] = columns, rows: [[CellValue]] = rows,
    commandRows: @escaping @Sendable (String) -> Int? = { _ in 1 }
  ) async throws -> Fixture {
    let fixture = try await connected(columns: columns, rows: rows, commandRows: commandRows)
    var state = DataViewerState(schema: "db", name: "users", orderColumns: ["_id"])
    state.databaseType = .mongodb
    fixture.viewModel.dataViewer = state
    await fixture.viewModel.loadDataViewerPage()
    #expect(fixture.viewModel.editorResult?.editTarget != nil)
    return fixture
  }

  private static func id(_ hex: String) -> MongoValue {
    .objectId(MongoObjectId(hex: hex)!)
  }

  private static func filter(_ hex: String) -> MongoValue {
    .document([MongoValue.Field("_id", id(hex))])
  }

  private static func setCommand(_ hex: String, _ field: String, _ value: MongoValue) -> String {
    MongoCommand.updateOne(
      collection: "users", filter: filter(hex),
      update: .document([MongoValue.Field("$set", .document([MongoValue.Field(field, value)]))])
    ).render()
  }

  private static let pageCommand = "db.users.find().sort({ _id: 1 }).limit(100)"

  /// Edits `column` of loaded row `row` in the data-viewer grid.
  private static func gridEdit(
    _ viewModel: NotebookViewModel, row: Int, column: String, text: String
  ) throws {
    let result = try #require(viewModel.editorResult)
    let index = try #require(result.columns.firstIndex { $0.name == column })
    viewModel.handleGridCellEdit(
      row: result.rows[row], column: index, newValue: text, result: result, cellId: nil,
      connectionManager: viewModel.connectionManager)
  }

  // MARK: - Gating

  @Test("A Mongo data-viewer page can stage; the capability flag stays false")
  func stagingEnabled() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    #expect(!DatabaseType.mongodb.capabilities.supportsRowStaging)
    #expect(viewModel.rowEditingUnsupportedReason == nil)
    #expect(viewModel.rowStagingUnavailableReason == nil)
    #expect(viewModel.stagingEnabled)
    #expect(viewModel.mongoDocumentTarget != nil)
    #expect(viewModel.canEdit(try #require(viewModel.editorResult)))
    #expect(viewModel.stagedChangeCounts == nil)
    await fixture.manager.disconnect()
  }

  @Test("An aggregate result with an _id column is read-only")
  func aggregateRefusesStaging() async throws {
    let fixture = try await Self.connected()
    let viewModel = fixture.viewModel
    await viewModel.executeEditorQuery("db.users.aggregate([])")
    let result = try #require(viewModel.editorResult)
    #expect(result.columns.first?.name == "_id")
    #expect(result.editTarget == nil)
    #expect(!viewModel.canEdit(result))
    let sent = fixture.factory.statements.count
    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    #expect(fixture.toasts.messages.last == NotebookViewModel.notEditableMessage)

    var state = DataViewerState(schema: "db", name: "users", orderColumns: ["_id"])
    state.databaseType = .mongodb
    viewModel.dataViewer = state
    viewModel.editorResult = result
    #expect(!viewModel.stagingEnabled)
    #expect(viewModel.mongoDocumentTarget == nil)
    await viewModel.toggleAddRowForm()
    #expect(viewModel.dataViewer?.pendingDocumentEditor == nil)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(fixture.factory.statements.count == sent)
    await fixture.manager.disconnect()
  }

  // MARK: - Inserts

  @Test("+ Row opens the document editor, never the SQL Add Row form, and stages an insert")
  func addRowStagesDocument() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    await viewModel.toggleAddRowForm()
    let request = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    #expect(request.kind == .insert)
    #expect(viewModel.addRowFields.isEmpty)
    #expect(viewModel.rightSidebarContent != .addRow)

    let error = await viewModel.applyDocumentEditor(#"{name: "cy", age: NumberLong("7")}"#)
    #expect(error == nil)
    #expect(viewModel.dataViewer?.pendingDocumentEditor == nil)
    #expect(viewModel.addRowFields.isEmpty)
    #expect(viewModel.dataViewer?.changeSet == nil)
    let set = try #require(viewModel.dataViewer?.documentChangeSet)
    #expect(
      set.inserts.map(\.document) == [
        .document([
          MongoValue.Field("name", .string("cy")), MongoValue.Field("age", .int64(7)),
        ])
      ])
    #expect(viewModel.hasPendingStagedChanges)
    #expect(viewModel.stagedChangeCounts?.inserts == 1)
    #expect(!viewModel.undoManager.canUndo)
    #expect(viewModel.previewStagedSQL() == set.previewText())

    // The grid's Insert item does the same; a parse error keeps the editor open
    await viewModel.openAddRowForm()
    let parseError = try #require(await viewModel.applyDocumentEditor("{a: "))
    #expect(parseError.offset != nil)
    #expect(viewModel.dataViewer?.pendingDocumentEditor != nil)
    #expect(viewModel.dataViewer?.documentChangeSet?.inserts.count == 1)
    await fixture.manager.disconnect()
  }

  @Test("Duplicate copies the document without _id, keeping nested int64 and double")
  func duplicateStagesCopy() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    #expect(await viewModel.stageDuplicate(rows: [0]) == nil)
    let request = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    #expect(request.kind == .insert)
    #expect(viewModel.addRowFields.isEmpty)
    #expect(viewModel.dataViewer?.changeSet == nil)

    #expect(await viewModel.applyDocumentEditor(request.text) == nil)
    let copy = MongoValue.document([
      MongoValue.Field("name", .string("ann")), MongoValue.Field("stats", Self.stats),
      MongoValue.Field("owner", Self.id(Self.second)),
    ])
    #expect(viewModel.dataViewer?.documentChangeSet?.inserts.map(\.document) == [copy])
    #expect(viewModel.dataViewer?.changeSet == nil)

    // Two rows, one of them the staged copy: one editor with both documents
    #expect(await viewModel.stageDuplicate(rows: [1, 2]) == nil)
    let both = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    #expect(await viewModel.applyDocumentEditor(both.text) == nil)
    #expect(
      viewModel.dataViewer?.documentChangeSet?.inserts.map(\.document) == [
        copy, .document([MongoValue.Field("name", .string("bob"))]), copy,
      ])
    await fixture.manager.disconnect()
  }

  @Test("A staged insert's cell edit sets the field; an object cell opens the whole document")
  func stagedInsertCellEdit() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    await viewModel.toggleAddRowForm()
    #expect(await viewModel.applyDocumentEditor("{name: 'cy'}") == nil)
    let result = try #require(viewModel.editorResult)
    let row = result.rows.count
    let owner = try #require(result.columns.firstIndex { $0.name == "owner" })
    viewModel.handleStagedGridCellEdit(
      row: row, column: owner, newValue: Self.first, result: result)
    let expected = MongoValue.document([
      MongoValue.Field("name", .string("cy")), MongoValue.Field("owner", Self.id(Self.first)),
    ])
    #expect(viewModel.dataViewer?.documentChangeSet?.inserts.map(\.document) == [expected])

    let stats = try #require(result.columns.firstIndex { $0.name == "stats" })
    viewModel.handleStagedGridCellEdit(row: row, column: stats, newValue: "{}", result: result)
    let request = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    #expect(request.text == MongoRelaxedJSON.render(expected, as: .mongosh))
    #expect(await viewModel.applyDocumentEditor("{name: 'dee'}") == nil)
    #expect(
      viewModel.dataViewer?.documentChangeSet?.inserts.map(\.document) == [
        .document([MongoValue.Field("name", .string("dee"))])
      ])
    #expect(fixture.factory.statements.count == 2)
    await fixture.manager.disconnect()
  }

  @Test("An empty collection's page accepts an insert and commits it")
  func insertIntoEmptyResult() async throws {
    let fixture = try await Self.dataViewer(
      columns: [ColumnInfo(name: "_id", type: "objectId")], rows: [])
    let viewModel = fixture.viewModel
    #expect(viewModel.editorResult?.rows.isEmpty == true)
    #expect(viewModel.stagingEnabled)
    await viewModel.toggleAddRowForm()
    #expect(await viewModel.applyDocumentEditor("{a: 1}") == nil)

    let sent = fixture.factory.statements.count
    await viewModel.commitStaged()
    #expect(viewModel.queryConfirmationState.showDialog)
    await viewModel.executePendingQuery()
    #expect(
      Array(fixture.factory.statements.dropFirst(sent)).first
        == "db.users.insertOne({ a: 1 })")
    #expect(viewModel.dataViewer?.documentChangeSet == nil)
    await fixture.manager.disconnect()
  }

  // MARK: - Commit

  @Test("Commit confirms the commands, then sends them one by one and reloads the page")
  func commitSendsSequentially() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    #expect(viewModel.stageDelete(rows: [1]) == nil)
    await viewModel.toggleAddRowForm()
    #expect(await viewModel.applyDocumentEditor("{name: 'cy'}") == nil)
    let set = try #require(viewModel.dataViewer?.documentChangeSet)
    let commands = set.commands().map { $0.render() }
    #expect(
      commands == [
        MongoCommand.deleteOne(collection: "users", filter: Self.filter(Self.second)).render(),
        #"db.users.insertOne({ name: "cy" })"#,
      ])

    let sent = fixture.factory.statements.count
    await viewModel.commitStaged()
    #expect(viewModel.queryConfirmationState.showDialog)
    let batch = try #require(viewModel.pendingStagedBatch)
    #expect(batch.mongoCommands == commands)
    #expect(batch.statements.isEmpty)
    #expect(batch.preview == set.previewText())
    #expect(fixture.factory.statements.count == sent)
    #expect(viewModel.hasPendingStagedChanges)

    await viewModel.executePendingQuery()
    let after = Array(fixture.factory.statements.dropFirst(sent))
    #expect(Array(after.prefix(2)) == commands)
    #expect(after.dropFirst(2).first == Self.pageCommand)
    #expect(!after.contains { $0.uppercased().hasPrefix("BEGIN") || $0 == "COMMIT" })
    #expect(viewModel.dataViewer?.documentChangeSet == nil)
    #expect(!viewModel.hasPendingStagedChanges)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(fixture.toasts.messages.isEmpty)
    await fixture.manager.disconnect()
  }

  @Test("A committed insert or delete counts the documents again")
  func commitRecountsTheTotal() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    // The count was read before the commit
    viewModel.dataViewer?.totalRows = 2
    await viewModel.toggleAddRowForm()
    #expect(await viewModel.applyDocumentEditor("{name: 'cy'}") == nil)
    let sent = fixture.factory.statements.count
    await viewModel.commitStaged()
    await viewModel.executePendingQuery()
    let after = Array(fixture.factory.statements.dropFirst(sent))
    #expect(after.contains("db.users.countDocuments()"))
    await fixture.manager.disconnect()
  }

  @Test("A partly applied commit keeps only the unapplied changes")
  func partialCommitKeepsTheRest() async throws {
    let fixture = try await Self.dataViewer(commandRows: { $0.contains("insertOne") ? 0 : 1 })
    let viewModel = fixture.viewModel
    #expect(viewModel.stageDelete(rows: [0, 1]) == nil)
    await viewModel.toggleAddRowForm()
    #expect(await viewModel.applyDocumentEditor("{name: 'cy'}") == nil)
    await viewModel.commitStaged()
    await viewModel.executePendingQuery()
    // Both deletes ran, the insert affected nothing: only the insert stays staged
    #expect(fixture.toasts.messages.last?.hasPrefix("Applied 2 of 3 changes") == true)
    let set = try #require(viewModel.dataViewer?.documentChangeSet)
    #expect(set.deletes.isEmpty && set.updates.isEmpty)
    #expect(set.inserts.map(\.document) == [.document([MongoValue.Field("name", .string("cy"))])])
    // Refreshed without a new target, so the kept change is still valid for this page
    let target = try #require(viewModel.mongoDocumentTarget)
    #expect(set.invalidated(by: target) == nil)
    await fixture.manager.disconnect()
  }

  @Test("Changes staged while a commit is in flight stay staged and are not sent again")
  func stagingDuringCommitIsKept() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    #expect(viewModel.stageDelete(rows: [0]) == nil)
    await viewModel.commitStaged()
    #expect(viewModel.queryConfirmationState.showDialog)

    let pause = CommitPause()
    await fixture.manager.setBatchCheckpointHook { index in
      if index == 0 { await pause.checkpoint() }
    }
    let commit = Task { await viewModel.executePendingQuery() }
    await pause.waitUntilArrived()
    // The first delete reached the server; stage more before the batch returns
    #expect(viewModel.stageDelete(rows: [1]) == nil)
    _ = viewModel.openDocumentInsertEditor()
    #expect(await viewModel.applyDocumentEditor("{name: 'cy'}") == nil)
    await pause.resume()
    await commit.value
    await fixture.manager.setBatchCheckpointHook(nil)

    let set = try #require(viewModel.dataViewer?.documentChangeSet)
    #expect(set.deletes == [Self.id(Self.second)])
    #expect(set.inserts.map(\.document) == [.document([MongoValue.Field("name", .string("cy"))])])

    // The next commit sends only what is still staged
    let sent = fixture.factory.statements.count
    await viewModel.commitStaged()
    await viewModel.executePendingQuery()
    #expect(
      Array(fixture.factory.statements.dropFirst(sent).prefix(2)) == [
        MongoCommand.deleteOne(collection: "users", filter: Self.filter(Self.second)).render(),
        #"db.users.insertOne({ name: "cy" })"#,
      ])
    #expect(viewModel.dataViewer?.documentChangeSet == nil)
    await fixture.manager.disconnect()
  }

  @Test("Delete, revert and discard work on documents; edits to a deleted document are refused")
  func deleteRevertDiscard() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    #expect(viewModel.stageDelete(rows: [0]) == nil)
    #expect(viewModel.dataViewer?.documentChangeSet?.deletes == [Self.id(Self.first)])
    #expect(viewModel.dataViewer?.changeSet == nil)

    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    #expect(fixture.toasts.messages.last == MongoDocumentChangeError.deletedDocument.message)
    #expect(viewModel.pendingStagedBatch == nil)

    #expect(viewModel.revertStaged(rows: [0]) == nil)
    #expect(viewModel.dataViewer?.documentChangeSet == nil)

    #expect(viewModel.stageDelete(rows: [1]) == nil)
    viewModel.discardStaged()
    #expect(viewModel.dataViewer?.documentChangeSet == nil)
    #expect(!viewModel.hasPendingStagedChanges)
    await fixture.manager.disconnect()
  }

  // MARK: - Inline edits

  @Test("A field edit commits one $set by BSON type, leaving the nested int64 and double alone")
  func inlineEditKeepsTypes() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    let batch = try #require(viewModel.pendingStagedBatch)
    let expected = Self.setCommand(Self.first, "name", .string("zoe"))
    #expect(batch.mongoCommands == [expected])
    #expect(viewModel.pendingInlineEdit == nil)

    let sent = fixture.factory.statements.count
    await viewModel.executePendingQuery()
    // Nothing else staged: the page reloads (find, then the count)
    #expect(
      Array(fixture.factory.statements.dropFirst(sent).prefix(2)) == [expected, Self.pageCommand])

    // The object opens the editor in mongosh notation; staging it keeps both nested types
    try Self.gridEdit(viewModel, row: 0, column: "stats", text: "ignored")
    let request = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    #expect(request.text == MongoRelaxedJSON.render(Self.stats, as: .mongosh))
    #expect(await viewModel.applyDocumentEditor(request.text) == nil)
    #expect(
      viewModel.pendingStagedBatch?.mongoCommands == [
        Self.setCommand(Self.first, "stats", Self.stats)
      ])
    // The editor closes first; the Safe Mode dialog opens once the sheet has dismissed
    #expect(viewModel.dataViewer?.pendingDocumentEditor == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)
    viewModel.documentEditorDismissed()
    #expect(viewModel.queryConfirmationState.showDialog)
    #expect(viewModel.pendingStagedBatch != nil)
    await fixture.manager.disconnect()
  }

  @Test("A Documents-view edit of a nested field commits one $set of its dotted path")
  func documentFieldEditSetsPath() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    let result = try #require(viewModel.editorResult)
    viewModel.handleDocumentFieldEdit(
      row: 0, keys: ["stats", "n"], editType: "long", text: "7", current: .int64(5),
      result: result, cellId: nil)
    let batch = try #require(viewModel.pendingStagedBatch)
    #expect(batch.mongoCommands == [Self.setCommand(Self.first, "stats.n", .int64(7))])
    #expect(viewModel.pendingInlineEdit == nil)
    await viewModel.executePendingQuery()

    // An object opens the editor sheet on its path; applying it sets that path
    let page = try #require(viewModel.editorResult)
    viewModel.handleDocumentFieldEdit(
      row: 0, keys: ["stats"], editType: nil, text: nil, current: Self.stats, result: page,
      cellId: nil)
    let request = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    #expect(request.kind == .value(id: .string(Self.first), path: ["stats"]))
    #expect(request.text == MongoRelaxedJSON.render(Self.stats, as: .mongosh))
    #expect(await viewModel.applyDocumentEditor(request.text) == nil)
    #expect(
      viewModel.pendingStagedBatch?.mongoCommands == [
        Self.setCommand(Self.first, "stats", Self.stats)
      ])
    await fixture.manager.disconnect()
  }

  @Test("Row Details applies one changed field as one $set; two fields at once are refused")
  func rowDetailApplyOnDocuments() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    let result = try #require(viewModel.editorResult)
    viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
    let name = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "name" })
    let owner = try #require(viewModel.rowDetail?.fields.firstIndex { $0.name == "owner" })

    viewModel.rowDetail?.fields[name].text = "zoe"
    viewModel.rowDetail?.fields[owner].text = Self.first
    viewModel.applyRowDetail()
    #expect(fixture.toasts.messages.last == NotebookViewModel.oneDocumentFieldMessage)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(viewModel.pendingInlineEdit == nil)

    viewModel.rowDetail?.fields[owner].revert()
    viewModel.applyRowDetail()
    let batch = try #require(viewModel.pendingStagedBatch)
    #expect(batch.mongoCommands == [Self.setCommand(Self.first, "name", .string("zoe"))])
    #expect(viewModel.pendingInlineEdit == nil)
    await fixture.manager.disconnect()
  }

  @Test("The editor refuses to apply once the page it was opened on changed")
  func editorRefusesChangedTarget() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    let sent = fixture.factory.statements.count
    func replaceTarget() throws {
      let old = try #require(viewModel.editorResult?.editTarget)
      viewModel.editorResult?.editTarget = EditTarget(
        qualifiedName: old.qualifiedName, tableID: old.tableID,
        primaryKeyColumns: old.primaryKeyColumns, connectionEpoch: old.connectionEpoch,
        updateOnly: old.updateOnly, schema: old.schema, name: old.name,
        generatedColumns: old.generatedColumns)
    }

    // A field opened on the old page is never applied to the new one
    try Self.gridEdit(viewModel, row: 0, column: "stats", text: "ignored")
    let request = try #require(viewModel.dataViewer?.pendingDocumentEditor)
    try replaceTarget()
    let error = try #require(await viewModel.applyDocumentEditor(request.text))
    #expect(error.message == NotebookViewModel.documentEditorTargetChanged)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(!viewModel.queryConfirmationState.showDialog)

    // Same for an insert
    viewModel.dataViewer?.pendingDocumentEditor = nil
    _ = viewModel.openDocumentInsertEditor()
    try replaceTarget()
    let insertError = try #require(await viewModel.applyDocumentEditor("{name: 'cy'}"))
    #expect(insertError.message == NotebookViewModel.documentEditorTargetChanged)
    #expect(viewModel.dataViewer?.documentChangeSet == nil)
    #expect(fixture.factory.statements.count == sent)
    await fixture.manager.disconnect()
  }

  @Test("A computed, renamed or partial projected field leaves the find read-only")
  func projectionTargetRules() async throws {
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = Self.config()
    let manager = DatabaseConnectionManager()
    func target(_ text: String) async -> EditTarget? {
      await viewModel.resultTargets(
        for: text,
        result: QueryResult(columns: Self.columns, rows: [], rowCount: 0, executionTime: 0),
        connectionManager: manager, epoch: 1
      ).editTarget
    }
    for text in [
      "db.users.find({}, {a: 1, b: 0})", "db.users.find({}, {a: true})",
      "db.users.find({}, {a: NumberLong(\"1\"), b: 1.0, c: false})",
    ] {
      #expect(await target(text) != nil, "\(text)")
    }
    for text in [
      "db.users.find({}, {a: \"$b\"})",
      "db.users.find({}, {t: {$add: [\"$x\", \"$y\"]}})",
      "db.users.find({}, {arr: {$slice: 2}})",
      "db.users.find({}, {arr: {$elemMatch: {x: 1}}})",
      "db.users.find({}, {a: 1, \"b.c\": 1})",
      "db.users.find({}, {a: 2})",
      "db.users.find({}, {a: null})",
    ] {
      #expect(await target(text) == nil, "\(text)")
    }
  }

  @Test("An objectId field stages ObjectId(\"…\"), never a string; bad hex is refused")
  func objectIdEdit() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    try Self.gridEdit(viewModel, row: 0, column: "owner", text: "not-hex")
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(fixture.toasts.messages.last?.contains("24 hexadecimal") == true)

    try Self.gridEdit(viewModel, row: 0, column: "owner", text: Self.first)
    #expect(
      viewModel.pendingStagedBatch?.mongoCommands == [
        Self.setCommand(Self.first, "owner", Self.id(Self.first))
      ])
    #expect(viewModel.pendingStagedBatch?.preview.contains(#"owner: ObjectId(""#) == true)
    await fixture.manager.disconnect()
  }

  @Test("A $set on _id is refused before anything is sent")
  func idEditRefused() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    let result = try #require(viewModel.editorResult)
    let sent = fixture.factory.statements.count
    viewModel.cellDetailEditTarget = result.editTarget
    viewModel.handleCellValueEdit(
      columnName: "_id", columnType: "objectId", newValue: Self.second,
      originalValue: .string(Self.first), tableName: "users",
      rowData: CellResult.rowData(columns: result.columns, row: result.rows[0]),
      primaryKeyColumns: ["_id"], cellId: nil, connectionManager: fixture.manager)
    #expect(fixture.toasts.messages.last == MongoDocumentChangeError.idField.message)
    #expect(viewModel.pendingStagedBatch == nil)
    #expect(fixture.factory.statements.count == sent)
    await fixture.manager.disconnect()
  }

  @Test("An edit while changes are staged refreshes the page with mongoQueries(), keeping them")
  func editRefreshKeepsStagedSet() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    #expect(viewModel.stageDelete(rows: [1]) == nil)
    let generation = viewModel.editorResult?.editTarget?.generation
    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    let sent = fixture.factory.statements.count
    await viewModel.executePendingQuery()
    #expect(
      Array(fixture.factory.statements.dropFirst(sent)) == [
        Self.setCommand(Self.first, "name", .string("zoe")), Self.pageCommand,
      ])
    #expect(viewModel.editorResult?.editTarget?.generation == generation)
    #expect(viewModel.dataViewer?.documentChangeSet?.deletes == [Self.id(Self.second)])
    await fixture.manager.disconnect()
  }

  @Test("A notebook find cell commits a field edit and re-runs; objects need the data viewer")
  func notebookCellEdit() async throws {
    let fixture = try await Self.connected()
    let viewModel = fixture.viewModel
    viewModel.viewMode = .notebook
    viewModel.notebook.cells = [NotebookCell(cellType: .sql, content: "db.users.find()")]
    let cellId = viewModel.notebook.cells[0].id
    await viewModel.runCell(id: cellId)
    await viewModel.executionQueue.waitForIdle()
    let result = try #require(viewModel.notebook.cells[0].result)
    #expect(viewModel.canEdit(result))

    func edit(_ column: String, _ text: String) throws {
      let index = try #require(result.columns.firstIndex { $0.name == column })
      viewModel.handleGridCellEdit(
        row: result.rows[0], column: index, newValue: text, result: result, cellId: cellId,
        connectionManager: fixture.manager)
    }
    try edit("stats", "{}")
    #expect(
      fixture.toasts.messages.last == "Open the collection in the data viewer to edit this value")
    #expect(viewModel.pendingStagedBatch == nil)

    try edit("name", "zoe")
    let expected = Self.setCommand(Self.first, "name", .string("zoe"))
    #expect(viewModel.pendingStagedBatch?.mongoCommands == [expected])
    let sent = fixture.factory.statements.count
    await viewModel.executePendingQuery()
    await viewModel.executionQueue.waitForIdle()
    let after = Array(fixture.factory.statements.dropFirst(sent))
    #expect(after.first == expected)
    #expect(after.count == 2 && after[1].hasPrefix("db.users.find("))
    await fixture.manager.disconnect()
  }

  @Test("An SQL-file editor result commits a field edit and runs its query once again")
  func editorResultEditReruns() async throws {
    let fixture = try await Self.connected()
    let viewModel = fixture.viewModel
    await viewModel.executeEditorQuery("db.users.find()")
    #expect(viewModel.editorResult?.editTarget != nil)

    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    let expected = Self.setCommand(Self.first, "name", .string("zoe"))
    #expect(viewModel.pendingStagedBatch?.mongoCommands == [expected])
    let sent = fixture.factory.statements.count
    await viewModel.executePendingQuery()
    let after = Array(fixture.factory.statements.dropFirst(sent))
    #expect(after.first == expected)
    #expect(after.count == 2 && after[1].hasPrefix("db.users.find("))
    await fixture.manager.disconnect()
  }

  @Test("A multi-statement run refreshes only the edited statement's result")
  func multiStatementEditRefreshesSelectedResult() async throws {
    let fixture = try await Self.connected()
    let viewModel = fixture.viewModel
    await viewModel.executeEditorQuery("db.users.find(); db.orders.find()")
    try #require(viewModel.editorStatementResults.count == 2)
    viewModel.selectEditorStatement(at: 0)
    let other = viewModel.editorStatementResults[1]
    let before = viewModel.editorStatementResults[0].result.timestamp

    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    let expected = Self.setCommand(Self.first, "name", .string("zoe"))
    let sent = fixture.factory.statements.count
    await viewModel.executePendingQuery()
    let after = Array(fixture.factory.statements.dropFirst(sent))
    #expect(after.count == 2 && after.first == expected)
    #expect(after.last?.hasPrefix("db.users.find(") == true)
    #expect(viewModel.editorStatementResults.count == 2)
    #expect(viewModel.selectedStatementIndex == 0)
    #expect(viewModel.editorStatementResults.last?.id == other.id)
    #expect(viewModel.editorStatementResults.last?.result.timestamp == other.result.timestamp)
    let refreshed = viewModel.editorStatementResults.first?.result.timestamp
    #expect(refreshed != before && refreshed == viewModel.editorResult?.timestamp)
    await fixture.manager.disconnect()
  }

  @Test("Picking another statement during the commit skips the refresh, never runs it")
  func statementPickedDuringCommitIsNotRun() async throws {
    let fixture = try await Self.connected()
    let viewModel = fixture.viewModel
    await viewModel.executeEditorQuery("db.users.find(); db.orders.find()")
    try #require(viewModel.editorStatementResults.count == 2)
    viewModel.selectEditorStatement(at: 0)

    try Self.gridEdit(viewModel, row: 0, column: "name", text: "zoe")
    let expected = Self.setCommand(Self.first, "name", .string("zoe"))
    let pause = CommitPause()
    await fixture.manager.setBatchCheckpointHook { _ in await pause.checkpoint() }
    let sent = fixture.factory.statements.count
    let commit = Task { await viewModel.executePendingQuery() }
    await pause.waitUntilArrived()
    viewModel.selectEditorStatement(at: 1)
    await pause.resume()
    await commit.value
    await fixture.manager.setBatchCheckpointHook(nil)

    // Only the `$set`: the shown result is no longer the edited one, so nothing re-runs
    #expect(Array(fixture.factory.statements.dropFirst(sent)) == [expected])
    #expect(viewModel.selectedStatementIndex == 1)
    await fixture.manager.disconnect()
  }

  // MARK: - Grid overlay

  @Test("The grid overlay keeps its staged insert ids until the staged documents change")
  func gridOverlayIsStable() async throws {
    let fixture = try await Self.dataViewer()
    let viewModel = fixture.viewModel
    let target = try #require(viewModel.editorResult?.editTarget)
    let overlay = StagedDocumentOverlay()
    func drawn() -> RowChangeSet? {
      overlay.rowChangeSet(for: viewModel.dataViewer?.documentChangeSet, target: target)
    }
    #expect(drawn() == nil)

    _ = viewModel.openDocumentInsertEditor()
    #expect(await viewModel.applyDocumentEditor(#"{name: "cy"}"#) == nil)
    let first = try #require(drawn())
    #expect(first.inserts.count == 1)
    // A view update with the same staged set draws the same rows (same temp ids)
    #expect(drawn() == first)

    _ = viewModel.openDocumentInsertEditor()
    #expect(await viewModel.applyDocumentEditor(#"{name: "di"}"#) == nil)
    #expect(drawn()?.inserts.count == 2)
    #expect(overlay.rowChangeSet(for: nil, target: target) == nil)
    await fixture.manager.disconnect()
  }
}

/// Holds a sequential batch at a checkpoint until the test resumes it.
private actor CommitPause {
  private var arrived = false
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?

  func checkpoint() async {
    arrived = true
    arrivalWaiter?.resume()
    arrivalWaiter = nil
    await withCheckedContinuation { resumeWaiter = $0 }
  }

  func waitUntilArrived() async {
    if arrived { return }
    await withCheckedContinuation { arrivalWaiter = $0 }
  }

  func resume() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }
}
