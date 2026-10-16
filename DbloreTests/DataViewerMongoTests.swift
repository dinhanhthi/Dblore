// DataViewerMongoTests.swift
// The data viewer on a MongoDB collection: page and count are rendered `find`/`countDocuments`
// commands (filter, sort, skip, limit) sent through the manager's gate, never the SQL paging or
// LIKE helpers; the Extended JSON filter must parse as a document; header sort maps to the sort
// document; a collection page carries the collection's edit target, a view's page none.
// Fake session, no database needed.

import Foundation
import Testing

@testable import Dblore

@Suite("Data viewer on MongoDB")
@MainActor
struct DataViewerMongoTests {
  private static let idColumn = [ColumnInfo(name: "_id", type: "objectId")]

  private static func state(
    name: String = "users", page: Int = 1, pageSize: Int = 100, filter: String = "",
    sort: DataViewerState.DocumentSort? = nil, options: MongoQueryOptions = MongoQueryOptions()
  ) -> DataViewerState {
    var state = DataViewerState(
      schema: "db", name: name, orderColumns: ["_id"], page: page, pageSize: pageSize)
    state.databaseType = .mongodb
    state.documentFilter = filter
    state.documentSort = sort
    state.documentOptions = options
    return state
  }

  private static func rendered(_ state: DataViewerState) throws -> (page: String?, count: String) {
    let commands = try state.mongoQueries()
    return (commands.page?.render(), commands.count.render())
  }

  private static func config() -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
      sslMode: .disable)
    config.protectedMode = false
    config.applyCommitStyle(.immediate)
    return config
  }

  /// A data viewer tab connected to a fake MongoDB session answering every read with one `_id`.
  private static func connected(
    _ state: DataViewerState = state()
  ) async throws -> (NotebookViewModel, DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, columns: idColumn,
      rows: [[.string("0123456789abcdef01234567")]])
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(config: config())
    let viewModel = NotebookViewModel()
    viewModel.notebook.connectionConfig = config()
    viewModel.toastPresenter = { _, _ in }
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    viewModel.viewMode = .editor
    viewModel.dataViewer = state
    return (viewModel, manager, factory)
  }

  // MARK: - Commands

  @Test("Page 1 without a filter sorts by _id and limits to the page size")
  func noFilter() throws {
    let text = try Self.rendered(Self.state())
    #expect(text.page == "db.users.find().sort({ _id: 1 }).limit(100)")
    #expect(text.count == "db.users.countDocuments()")
  }

  @Test("The filter goes to find and countDocuments, {} and blank text mean no filter")
  func filter() throws {
    let text = try Self.rendered(Self.state(filter: #" {status: "active", n: {$gt: 1}} "#))
    #expect(
      text.page
        == #"db.users.find({ status: "active", n: { $gt: 1 } }).sort({ _id: 1 }).limit(100)"#)
    #expect(text.count == #"db.users.countDocuments({ status: "active", n: { $gt: 1 } })"#)
    for blank in ["{}", "  ", "{ }"] {
      #expect(
        try Self.rendered(Self.state(filter: blank)).page
          == "db.users.find().sort({ _id: 1 }).limit(100)")
    }
  }

  @Test("A header sort maps to the sort document with _id as the tiebreak")
  func sort() throws {
    let descending = try Self.rendered(
      Self.state(sort: DataViewerState.DocumentSort(field: "age", ascending: false)))
    #expect(descending.page == "db.users.find().sort({ age: -1, _id: 1 }).limit(100)")
    #expect(descending.count == "db.users.countDocuments()")
    let byID = try Self.rendered(
      Self.state(sort: DataViewerState.DocumentSort(field: "_id", ascending: false)))
    #expect(byID.page == "db.users.find().sort({ _id: -1 }).limit(100)")
    let dotted = try Self.rendered(
      Self.state(sort: DataViewerState.DocumentSort(field: "a.b \"c\"", ascending: true)))
    #expect(dotted.page == #"db.users.find().sort({ "a.b \"c\"": 1, _id: 1 }).limit(100)"#)
  }

  @Test("Page 3 at page size 50 skips 100 documents")
  func offset() throws {
    let text = try Self.rendered(Self.state(page: 3, pageSize: 50, filter: "{a: 1}"))
    #expect(text.page == "db.users.find({ a: 1 }).sort({ _id: 1 }).skip(100).limit(50)")
    #expect(text.count == "db.users.countDocuments({ a: 1 })")
  }

  @Test("User skip and limit compose with paging; a page past the limit is not sent")
  func optionsPaging() throws {
    var options = MongoQueryOptions()
    options.skip = "10"
    options.limit = "250"
    options.collation = #"{locale: "en"}"#
    let third = try Self.rendered(Self.state(page: 3, options: options))
    #expect(
      third.page
        == #"db.users.find().sort({ _id: 1 }).skip(210).limit(50).collation({ locale: "en" })"#)
    #expect(
      third.count
        == #"db.users.countDocuments({}, { collation: { locale: "en" }, skip: 10, limit: 250 })"#)
    #expect(try Self.state(page: 4, options: options).mongoQueries().page == nil)
  }

  @Test("The Sort option is the base sort, a header sort overrides it, _id breaks ties once")
  func optionsSort() throws {
    var options = MongoQueryOptions()
    options.sort = "{b: -1}"
    #expect(
      try Self.rendered(Self.state(options: options)).page
        == "db.users.find().sort({ b: -1, _id: 1 }).limit(100)")
    let header = DataViewerState.DocumentSort(field: "age", ascending: false)
    #expect(
      try Self.rendered(Self.state(sort: header, options: options)).page
        == "db.users.find().sort({ age: -1, _id: 1 }).limit(100)")
    options.sort = "{b: -1, _id: -1}"
    #expect(
      try Self.rendered(Self.state(options: options)).page
        == "db.users.find().sort({ b: -1, _id: -1 }).limit(100)")
  }

  @Test("Collection names with dots, quotes or method names render through getCollection")
  func collectionNames() throws {
    #expect(
      try Self.rendered(Self.state(name: "a.b")).page
        == #"db.getCollection("a.b").find().sort({ _id: 1 }).limit(100)"#)
    #expect(
      try Self.rendered(Self.state(name: #"x"); db.dropDatabase(); ("#)).count
        == #"db.getCollection("x\"); db.dropDatabase(); (").countDocuments()"#)
    #expect(
      try Self.rendered(Self.state(name: "stats")).count
        == #"db.getCollection("stats").countDocuments()"#)
  }

  // MARK: - Filter text

  @Test("A filter that does not parse reports the parser's message and offset")
  func parseError() {
    let result = DataViewerState.documentFilterValue("{a: 1,, b: 2}")
    guard case .failure(let error) = result else {
      Issue.record("expected a parse error, got \(result)")
      return
    }
    #expect(error.offset == 6)
    #expect(error.localizedDescription.contains("offset 6"))
    #expect(throws: DataViewerState.DocumentFilterError.self) {
      try Self.state(filter: "{a: ").mongoQueries()
    }
  }

  @Test("Arrays and scalars are refused: the filter must be a document")
  func notADocument() {
    for text in ["[{a: 1}]", "1", #""active""#, "null", #"ObjectId("0123456789abcdef01234567")"#] {
      let result = DataViewerState.documentFilterValue(text)
      guard case .failure(let error) = result else {
        Issue.record("\(text) should be refused, got \(result)")
        continue
      }
      #expect(error.localizedDescription.contains("must be a document"), "\(text)")
    }
  }

  @Test("The document filter and the sort are part of the load key")
  func loadKey() {
    let base = Self.state()
    var filtered = base
    filtered.documentFilter = "{a: 1}"
    var sorted = base
    sorted.documentSort = DataViewerState.DocumentSort(field: "a", ascending: true)
    #expect(filtered.loadKey != base.loadKey)
    #expect(sorted.loadKey != base.loadKey)
  }

  // MARK: - Loading through the gate

  @Test("A page load sends the rendered find and countDocuments, never SQL")
  func loadSendsCommands() async throws {
    var state = Self.state(page: 2, pageSize: 50, filter: "{a: 1}")
    // A stale SQL filter and order columns must not leak into the commands
    state.filter = TableFilter(conditions: [
      FilterCondition(column: "name", op: .like, value: "x%")
    ])
    let (viewModel, manager, factory) = try await Self.connected(state)
    await viewModel.loadDataViewerPage()
    #expect(
      factory.statements == [
        "db.users.find({ a: 1 }).sort({ _id: 1 }).skip(50).limit(50)",
        "db.users.countDocuments({ a: 1 })",
      ])
    let result = try #require(viewModel.editorResult)
    #expect(result.error == nil)
    #expect(!result.wasLimited)
    await manager.disconnect()
  }

  @Test("The SQL filter form is a no-op for MongoDB: no WHERE or LIKE is built or sent")
  func sqlFilterIgnored() async throws {
    let (viewModel, manager, factory) = try await Self.connected()
    await viewModel.applyFilter(
      TableFilter(conditions: [FilterCondition(column: "name", op: .like, value: "x%")]))
    #expect(viewModel.dataViewer?.filter.isEmpty == true)
    #expect(factory.statements.isEmpty)
    await manager.disconnect()
  }

  @Test("Applying a filter validates it, goes to page 1 and reloads with the filter")
  func applyDocumentFilter() async throws {
    let (viewModel, manager, factory) = try await Self.connected(Self.state(page: 3))
    let refused = await viewModel.applyDocumentFilter("[1]")
    #expect(refused != nil)
    #expect(viewModel.dataViewer?.documentFilter == "")
    #expect(factory.statements.isEmpty)

    let error = await viewModel.applyDocumentFilter("{a: 1}")
    #expect(error == nil)
    #expect(viewModel.dataViewer?.documentFilter == "{a: 1}")
    #expect(viewModel.dataViewer?.page == 1)
    #expect(factory.statements.first == "db.users.find({ a: 1 }).sort({ _id: 1 }).limit(100)")

    _ = await viewModel.applyDocumentFilter(" { } ")
    #expect(viewModel.dataViewer?.documentFilter == "")

    _ = await viewModel.applyDocumentFilter("{a: 1}")
    await viewModel.clearDocumentFilter()
    #expect(viewModel.dataViewer?.documentFilter == "")
    #expect(factory.statements.contains("db.users.find().sort({ _id: 1 }).limit(100)"))
    await manager.disconnect()
  }

  @Test("Applying options refuses a projection without _id; a Sort option clears the header sort")
  func applyDocumentQuery() async throws {
    let header = DataViewerState.DocumentSort(field: "age", ascending: false)
    let (viewModel, manager, factory) = try await Self.connected(Self.state(page: 2, sort: header))
    var options = MongoQueryOptions()
    options.project = "{_id: 0}"
    let refused = await viewModel.applyDocumentQuery(filter: "", options: options)
    #expect(refused?.message == "Projection must keep _id: rows are edited by _id")
    #expect(viewModel.dataViewer?.documentOptions == MongoQueryOptions())
    #expect(viewModel.dataViewer?.documentSort == header)
    #expect(factory.statements.isEmpty)

    // Reshaping projections would let an edit write the reshaped value back
    for project in [#"{"address.city": 1}"#, "{tags: {$slice: 3}}", #"{_id: "$name"}"#] {
      options.project = project
      let reshaped = await viewModel.applyDocumentQuery(filter: "", options: options)
      #expect(
        reshaped?.message
          == "Projection: only top-level fields set to 1 or 0 are allowed here, and _id must stay"
      )
      #expect(viewModel.dataViewer?.documentOptions == MongoQueryOptions())
      #expect(factory.statements.isEmpty)
    }

    options.project = ""
    options.sort = "{b: -1}"
    let error = await viewModel.applyDocumentQuery(filter: "", options: options)
    #expect(error == nil)
    #expect(viewModel.dataViewer?.documentOptions == options)
    #expect(viewModel.dataViewer?.documentSort == nil)
    #expect(viewModel.dataViewer?.page == 1)
    #expect(factory.statements.first == "db.users.find().sort({ b: -1, _id: 1 }).limit(100)")

    // Re-applying the same Sort option with another filter keeps the header sort
    viewModel.dataViewer?.documentSort = header
    _ = await viewModel.applyDocumentQuery(filter: "{a: 1}", options: options)
    #expect(viewModel.dataViewer?.documentSort == header)

    // Top-level inclusions and exclusions keep the page editable
    for project in ["{name: 1, age: true}", "{big: 0}"] {
      options.project = project
      let accepted = await viewModel.applyDocumentQuery(filter: "", options: options)
      #expect(accepted == nil)
      #expect(viewModel.dataViewer?.documentOptions == options)
    }
    await manager.disconnect()
  }

  @Test("A header sort goes to page 1 and reloads with the sort document")
  func headerSort() async throws {
    let (viewModel, manager, factory) = try await Self.connected(Self.state(page: 2))
    await viewModel.setDocumentSort("age", ascending: false)
    #expect(
      viewModel.dataViewer?.documentSort
        == DataViewerState.DocumentSort(field: "age", ascending: false))
    #expect(viewModel.dataViewer?.page == 1)
    #expect(factory.statements.first == "db.users.find().sort({ age: -1, _id: 1 }).limit(100)")
    await viewModel.setDocumentSort(nil, ascending: true)
    #expect(viewModel.dataViewer?.documentSort == nil)
    await manager.disconnect()
  }

  @Test("A collection page carries the collection's edit target, a view's page none")
  func editTargets() async throws {
    let (viewModel, manager, _) = try await Self.connected()
    let epoch = await manager.connectionEpoch
    await viewModel.loadDataViewerPage()
    let target = try #require(viewModel.editorResult?.editTarget)
    #expect(target.tableID == TableRef.mongodb(database: "db", collection: "users"))
    #expect(target.primaryKeyColumns == ["_id"])
    #expect(target.connectionEpoch == epoch)

    viewModel.databaseViews = [DatabaseView(schema: "db", name: "active_users")]
    viewModel.dataViewer = Self.state(name: "active_users")
    await viewModel.loadDataViewerPage()
    let result = try #require(viewModel.editorResult)
    #expect(result.error == nil)
    #expect(result.editTarget == nil)
    await manager.disconnect()
  }

  @Test("A data viewer tab on a MongoDB workspace gets the mongodb dialect")
  func tabDialect() throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: Self.config()), restoreTabs: false)
    manager.openDataViewer(schema: "db", name: "users", orderColumns: ["_id"])
    let id = try #require(manager.tabs.first?.id)
    let viewModel = try #require(manager.viewModel(for: id))
    #expect(viewModel.sqlDialect == .mongodb)
    #expect(viewModel.dataViewer?.databaseType == .mongodb)
  }
}
