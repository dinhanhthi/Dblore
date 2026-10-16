// MongoConfirmationTests.swift
// MongoDB in the notebook view model: Safe Mode confirmation of Mongo writes (rendered command
// text, the all-documents warning, Run All), SQL-only LIKE helpers off, result targets of a
// `find` (cells, editor and data-viewer pages) and none for other reads, and Explain of a read.
// Fake session, no database needed.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB confirmation, result targets and Explain")
@MainActor
struct MongoConfirmationTests {
  private static let idColumn = [ColumnInfo(name: "_id", type: "objectId")]
  private static let allDocumentsReason = "Empty filter — affects every document in users"

  /// Default MongoDB connection: Protected mode on, no stored commit style.
  private static func config() -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable)
  }

  private static func viewModel(
    _ config: ConnectionConfig = config(), cells: [String] = []
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = config
    viewModel.notebook.cells = cells.map { NotebookCell(cellType: .sql, content: $0) }
    viewModel.toastPresenter = { _, _ in }
    return viewModel
  }

  /// A view model connected to a fake MongoDB session that answers every read with `columns`.
  private static func connected(
    cells: [String] = [], columns: [ColumnInfo] = idColumn
  ) async throws -> (NotebookViewModel, DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    var config = config()
    config.protectedMode = false
    config.applyCommitStyle(.immediate)
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, columns: columns,
      rows: [[.string("0123456789abcdef01234567")]])
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config)
    let viewModel = viewModel(config, cells: cells)
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    return (viewModel, manager, factory)
  }

  private static func listed(_ text: String, _ style: CommitStyle) -> [StatementConfirmation]? {
    NotebookViewModel.statementsNeedingConfirmation(
      MongoCommandClassifier.classify(text), commitStyle: style, dialect: .mongodb)
  }

  // MARK: - Safe Mode

  @Test("A default MongoDB connection confirms insertOne and deleteMany({})")
  func defaultConfigConfirmsWrites() throws {
    let config = Self.config()
    #expect(config.protectedMode)
    #expect(config.resolvedCommitStyle(fallback: .review) == .confirm)
    for write in ["db.users.insertOne({a: 1})", "db.users.deleteMany({})"] {
      let viewModel = Self.viewModel()
      #expect(viewModel.presentConfirmationIfNeeded(for: write, cellId: nil), "\(write)")
      #expect(viewModel.queryConfirmationState.statements.count == 1)
    }
    let reader = Self.viewModel()
    #expect(!reader.presentConfirmationIfNeeded(for: "db.users.find()", cellId: nil))
  }

  @Test("The dialog's all-rows warning names the documents on MongoDB, rows on SQL")
  func allRowsWarningPerDialect() {
    let mongo = Self.viewModel()
    #expect(
      mongo.presentConfirmationIfNeeded(for: "db.users.updateMany({}, {$set: {a: 1}})", cellId: nil)
    )
    #expect(mongo.queryConfirmationState.affectsAllRows)
    #expect(
      mongo.queryConfirmationState.allRowsWarning
        == "WARNING: This command has an empty filter and will affect ALL documents in users!")
    var sql = QueryConfirmationState()
    sql.affectsAllRows = true
    #expect(
      sql.allRowsWarning == "WARNING: This query has no WHERE clause and will affect ALL rows!")
  }

  @Test("The dialog message is one text: warning, the statement list and the question")
  func dialogMessageListsTheStatements() {
    let viewModel = Self.viewModel()
    #expect(viewModel.presentConfirmationIfNeeded(for: "db.users.deleteMany({})", cellId: nil))
    let state = viewModel.queryConfirmationState
    let message = state.dialogMessage(statementSummary: "1. db.users.deleteMany({})")
    #expect(
      message
        == "⚠️ " + state.allRowsWarning
        + "\n\n1. db.users.deleteMany({})\n\nAre you sure you want to proceed?")
    let plain = QueryConfirmationState().dialogMessage(statementSummary: "1. INSERT ...")
    #expect(
      plain
        == "These statements need confirmation:\n\n1. INSERT ...\n\nAre you sure you want to proceed?"
    )
  }

  @Test("A stored Immediate style with the Protected flag is raised to Confirm")
  func storedImmediateWithProtectedFlag() {
    var config = Self.config()
    config.commitStyle = .immediate
    #expect(config.protectedMode)
    #expect(config.resolvedCommitStyle(fallback: .review) == .confirm)
    let viewModel = Self.viewModel(config)
    #expect(viewModel.presentConfirmationIfNeeded(for: "db.users.deleteMany({})", cellId: nil))
  }

  @Test("A stored Immediate style without the Protected flag stays Immediate")
  func storedImmediateWithoutProtectedFlag() {
    var config = Self.config()
    config.protectedMode = false
    config.commitStyle = .immediate
    #expect(config.resolvedCommitStyle(fallback: .review) == .immediate)
    let viewModel = Self.viewModel(config)
    #expect(!viewModel.presentConfirmationIfNeeded(for: "db.users.deleteMany({})", cellId: nil))
  }

  @Test("Confirm and Password list Mongo writes with their rendered text and the warning")
  func confirmationListsRenderedWrites() throws {
    let text = """
      db.users.find()
      // drop everything
      db["users"].deleteMany({})
      db.users.updateMany({age: {$gt: 1}}, {$set: {old: true}})
      db.users.frobnicate()
      """
    for style in [CommitStyle.confirm, .password] {
      let listed = try #require(Self.listed(text, style))
      #expect(listed.map(\.index) == [1, 2, 3])
      #expect(listed[0].preview == "db.users.deleteMany({})")
      #expect(listed[0].reasons == [Self.allDocumentsReason])
      #expect(
        listed[1].preview == "db.users.updateMany({ age: { $gt: 1 } }, { $set: { old: true } })")
      #expect(listed[1].reasons.isEmpty)
      #expect(listed[2].preview == "db.users.frobnicate()")
      #expect(listed.allSatisfy { $0.parameterNote == nil && !$0.likePatternAffectsAllRows })
    }
    #expect(Self.listed(text, .immediate) == nil)
    #expect(Self.listed(text, .review) == nil)
    #expect(Self.listed("db.users.find()", .confirm) == nil)
  }

  @Test("The cell dialog shows the all-documents warning")
  func cellDialogWarns() throws {
    var config = Self.config()
    config.applyCommitStyle(.password)
    let viewModel = Self.viewModel(config)
    #expect(viewModel.presentConfirmationIfNeeded(for: "db.users.deleteMany({})", cellId: nil))
    let state = viewModel.queryConfirmationState
    #expect(state.requiresPassword)
    #expect(state.affectsAllRows)
    #expect(!state.likePatternAffectsAllRows)
    #expect(state.statements.first?.reasons == [Self.allDocumentsReason])
    #expect(
      NotebookViewModel.confirmationSummary(state.statements)
        == "1. db.users.deleteMany({})\n   ! \(Self.allDocumentsReason)")
  }

  @Test("Run All confirms Mongo writes the same way")
  func runAllConfirmsWrites() async throws {
    let cells = ["db.users.find()", "db.users.deleteMany({})"]
    let confirm = Self.viewModel(cells: cells)
    await confirm.runAllCells(bypass: false)
    #expect(confirm.queryConfirmationState.showRunAllConfirmation)
    let pending = confirm.queryConfirmationState.runAllConfirmCells
    #expect(pending.map(\.number) == [2])
    #expect(
      NotebookViewModel.runAllSummary(pending)
        == "Cell 2, 1. db.users.deleteMany({})\n   ! \(Self.allDocumentsReason)")

    var config = Self.config()
    config.applyCommitStyle(.password)
    let password = Self.viewModel(config, cells: cells)
    await password.runAllCells(bypass: true)
    let state = password.queryConfirmationState
    #expect(state.runAllAwaitingUnlock)
    #expect(state.requiresPassword)
    #expect(state.affectsAllRows)
    #expect(state.statements.map(\.preview) == ["Cell 2: db.users.deleteMany({})"])
    #expect(state.statements.first?.reasons == [Self.allDocumentsReason])
  }

  @Test("The SQL-only LIKE helpers return false for MongoDB")
  func likeHelpersOff() throws {
    // PostgreSQL rules would read `LIKE '%'` after `//`; mongosh treats it as a comment.
    let text = "db.users.updateMany({}, {$set: {a: 1}}) // LIKE '%'"
    let classified = MongoCommandClassifier.classify(text)
    #expect(classified.count == 1)
    #expect(
      !NotebookViewModel.scriptMatchesAllRowsByLike(classified, parameters: [:], dialect: .mongodb))
    let listed = try #require(Self.listed(text, .confirm))
    #expect(!listed[0].likePatternAffectsAllRows)
    #expect(listed[0].preview == "db.users.updateMany({}, { $set: { a: 1 } })")
  }

  // MARK: - Result targets

  private static func expectCollectionTarget(
    _ target: EditTarget?, epoch: UInt64, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    guard let target else {
      Issue.record("Expected a collection target", sourceLocation: sourceLocation)
      return
    }
    #expect(target.qualifiedName == "users", sourceLocation: sourceLocation)
    #expect(target.name == "users", sourceLocation: sourceLocation)
    #expect(target.schema == nil, sourceLocation: sourceLocation)
    #expect(
      target.tableID == TableRef.mongodb(database: "db", collection: "users"),
      sourceLocation: sourceLocation)
    #expect(target.primaryKeyColumns == ["_id"], sourceLocation: sourceLocation)
    #expect(target.connectionEpoch == epoch, sourceLocation: sourceLocation)
    #expect(!target.updateOnly, sourceLocation: sourceLocation)
    #expect(target.generatedColumns.isEmpty, sourceLocation: sourceLocation)
  }

  @Test("A find cell result gets the collection target, without any catalog lookup")
  func findCellTarget() async throws {
    let (viewModel, manager, factory) = try await Self.connected(cells: ["db.users.find()"])
    let id = viewModel.notebook.cells[0].id
    let epoch = await manager.connectionEpoch
    await viewModel.runCell(id: id)
    await viewModel.executionQueue.waitForIdle()
    let first = try #require(viewModel.notebook.cells[0].result)
    #expect(first.error == nil)
    Self.expectCollectionTarget(first.editTarget, epoch: epoch)
    #expect(first.lookupRelation == nil)
    // Only the find reached the session: no SQL relation lookup or catalog query.
    #expect(factory.statements.count == 1)
    #expect(factory.statements.allSatisfy { $0.hasPrefix("db.users.find(") })

    await viewModel.runCell(id: id)
    await viewModel.executionQueue.waitForIdle()
    let second = try #require(viewModel.notebook.cells[0].result?.editTarget)
    #expect(second.generation != first.editTarget?.generation)
    await manager.disconnect()
  }

  @Test("A data-viewer page through executeEditorQuery gets the collection target")
  func dataViewerPageTarget() async throws {
    let (viewModel, manager, _) = try await Self.connected()
    viewModel.viewMode = .editor
    let epoch = await manager.connectionEpoch
    await viewModel.executeEditorQuery(
      "db.users.find({}).sort({_id: 1}).skip(50)", maxRows: 50, source: .internal)
    let result = try #require(viewModel.editorResult)
    #expect(result.error == nil)
    Self.expectCollectionTarget(result.editTarget, epoch: epoch)
    #expect(result.lookupRelation == nil)
    await manager.disconnect()
  }

  @Test("Only a find on a collection with a plain _id gets a target")
  func targetRules() async throws {
    let viewModel = Self.viewModel()
    viewModel.databaseViews = [DatabaseView(schema: "db", name: "active_users")]
    let manager = DatabaseConnectionManager()
    func target(_ text: String, columns: [ColumnInfo] = Self.idColumn) async -> ResultTargets {
      await viewModel.resultTargets(
        for: text,
        result: QueryResult(columns: columns, rows: [], rowCount: 0, executionTime: 0),
        connectionManager: manager, epoch: 7)
    }
    for text in [
      "db.users.find()", "db['users'].find({a: 1}, {_id: 1, a: 1})",
      "db.users.find({}, {_id: true})",
      "db.users.find({}, {name: 1}).limit(5)",
    ] {
      let targets = await target(text)
      Self.expectCollectionTarget(targets.editTarget, epoch: 7)
      #expect(targets.lookupRelation == nil)
    }
    for text in [
      "db.users.aggregate([{$group: {_id: \"$city\"}}])",
      "db.users.distinct(\"city\")",
      "db.users.countDocuments()",
      "show collections",
      "db.active_users.find()",
      "db.users.find({}, {_id: {$toString: \"$_id\"}})",
      "db.users.find({}, {_id: \"$other\"})",
      "db.users.find({}, {_id: 0})",
      "db.users.find({}, {_id: false})",
      "db.users.find({}, {\"_id.a\": 1})",
      "db.users.find(); db.users.find()",
      "db.users.deleteMany({})",
      "db.users.find(",
      "SELECT * FROM users",
    ] {
      let targets = await target(text)
      #expect(targets.editTarget == nil, "\(text)")
      #expect(targets.lookupRelation == nil, "\(text)")
    }
    // No `_id` column, or one whose BSON type differs between documents.
    #expect(await target("db.users.find()", columns: []).editTarget == nil)
    #expect(
      await target("db.users.find()", columns: [ColumnInfo(name: "a", type: "string")]).editTarget
        == nil)
    #expect(
      await target("db.users.find()", columns: [ColumnInfo(name: "_id", type: "mixed")])
        .editTarget == nil)
  }

  @Test("A connection without a database name identifies collections in test")
  func defaultDatabaseIdentity() async throws {
    var config = Self.config()
    config.database = ""
    let viewModel = Self.viewModel(config)
    let targets = await viewModel.resultTargets(
      for: "db.users.find()",
      result: QueryResult(columns: Self.idColumn, rows: [], rowCount: 0, executionTime: 0),
      connectionManager: DatabaseConnectionManager(), epoch: 0)
    #expect(targets.editTarget?.tableID == TableRef.mongodb(database: "test", collection: "users"))
    #expect(
      TableRef.mongodb(database: "a.b", collection: "c")
        != TableRef.mongodb(database: "a", collection: "b.c"))
  }

  // MARK: - Explain

  @Test("Explain sends the executionStats explain of one find; nothing else is explained")
  func explainFind() async throws {
    let (viewModel, manager, factory) = try await Self.connected(cells: ["db.users.find({a: 1})"])
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    await viewModel.explainSelectedStatement(analyze: false)
    await viewModel.executionQueue.waitForIdle()
    #expect(toasts.isEmpty)
    #expect(factory.statements == [#"db.users.find({ a: 1 }).explain("executionStats")"#])

    // Explain Analyze and a pipeline that writes are refused before anything is sent.
    await viewModel.explainSelectedStatement(analyze: true)
    await viewModel.explain(statement: "db.users.find()", analyze: true, buffers: true)
    await viewModel.explain(
      statement: "db.users.aggregate([{$match: {}}, {$out: \"copy\"}])", analyze: false,
      buffers: false)
    await viewModel.executionQueue.waitForIdle()
    #expect(toasts.count == 3)
    #expect(
      toasts.prefix(2).allSatisfy {
        $0 == "Explain Analyze is not available for MongoDB connections"
      })
    #expect(!viewModel.queryConfirmationState.showDialog)
    #expect(factory.statements.count == 1)
    await manager.disconnect()
  }
}
