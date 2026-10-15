// AggregationBuilderModelTests.swift
// The aggregation builder model: editing stages, per-stage parse and body-kind errors, preview
// commands (enabled prefix + `{$limit: 20}`) sent through the gate under a read-only policy,
// `$out`/`$merge` and later stages never previewed, results cached per prefix text, and the
// Insert/Copy command. Fake session, no database needed.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Aggregation builder model")
@MainActor
struct AggregationBuilderModelTests {
  private static let idColumn = [ColumnInfo(name: "_id", type: "objectId")]

  /// A manager on a fake MongoDB session with NO protection: anything refused was refused by
  /// the builder's own read-only policy.
  private static func connected(
    failingQuery: String? = nil
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities, columns: idColumn,
      rows: [[.string("0123456789abcdef01234567")]], failingQuery: failingQuery)
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .mongodb, host: "fake", port: 27017, database: "db", username: "u",
        sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
    return (manager, factory)
  }

  private static func model(
    _ manager: DatabaseConnectionManager, collection: String = "users",
    _ stages: [(String, String)]
  ) -> (AggregationBuilderModel, [AggregationBuilderModel.Stage.ID]) {
    let model = AggregationBuilderModel(collection: collection, connectionManager: manager)
    let ids = stages.map { model.addStage(operator: $0.0, body: $0.1) }
    return (model, ids)
  }

  // MARK: - Editing

  @Test("Stages are added, removed, reordered and switched off")
  func editing() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, [("$match", "{}"), ("$sort", "{a: 1}"), ("$limit", "5")])
    #expect(model.stages.map(\.operator) == ["$match", "$sort", "$limit"])
    #expect(model.stages.map(\.isEnabled) == [true, true, true])

    model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(model.stages.map(\.id) == [ids[2], ids[0], ids[1]])
    model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(model.stages.map(\.id) == ids)

    model.setEnabled(false, for: ids[1])
    #expect(model.stages.map(\.isEnabled) == [true, false, true])
    model.setBody("{b: -1}", for: ids[1])
    model.setOperator("$project", for: ids[1])
    #expect(model.stages[1].operator == "$project")
    #expect(model.stages[1].body == "{b: -1}")

    model.removeStage(ids[0])
    #expect(model.stages.map(\.id) == [ids[1], ids[2]])
    await manager.disconnect()
  }

  // MARK: - Errors

  @Test("A body that does not parse reports the parser's message and offset")
  func parseError() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(manager, [("$match", "{a: 1,, b: 2}"), ("match", "{}")])
    let error = try #require(model.error(for: ids[0]))
    #expect(error.offset == 6)
    #expect(error.localizedDescription.contains("offset 6"))
    let operatorError = try #require(model.error(for: ids[1]))
    #expect(operatorError.offset == nil)
    #expect(operatorError.message.contains("$"))
    #expect(model.commandText == nil)
    await manager.disconnect()
  }

  @Test(
    "Each operator takes its body kind; unknown $ operators take a document",
    arguments: [
      ("$limit", "20", true), ("$limit", "NumberLong(5)", true), ("$limit", "{}", false),
      ("$limit", "2.5", false), ("$skip", "10", true), ("$skip", #""10""#, false),
      ("$count", #""total""#, true), ("$count", "1", false),
      ("$unwind", #""$tags""#, true), ("$unwind", #"{path: "$tags"}"#, true),
      ("$unwind", "[1]", false), ("$out", #""copy""#, true), ("$merge", #"{into: "o"}"#, true),
      ("$unionWith", #""other""#, true), ("$unset", #"["a", "b"]"#, true),
      ("$unset", #""a""#, true), ("$unset", "{a: 1}", false),
      ("$replaceWith", #""$doc""#, true), ("$sortByCount", #""$tag""#, true),
      ("$match", "{a: 1}", true), ("$match", "[{a: 1}]", false), ("$sample", "{size: 3}", true),
      ("$sample", "3", false), ("$myStage", "{x: 1}", true), ("$myStage", "1", false),
      ("$match", "", false),
    ])
  func bodyKinds(name: String, body: String, valid: Bool) async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(manager, [(name, body)])
    #expect((model.error(for: ids[0]) == nil) == valid, "\(name) \(body)")
    await manager.disconnect()
  }

  // MARK: - Preview

  @Test("Previewing stage i sends the enabled prefix plus {$limit: 20}, read-only")
  func previewCommand() async throws {
    let (manager, factory) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, [("$match", "{a: 1}"), ("$sort", "{b: -1}"), ("$project", "{b: 1}")])
    model.setEnabled(false, for: ids[1])
    #expect(
      model.previewCommand(for: ids[0])
        == "db.users.aggregate([ { $match: { a: 1 } }, { $limit: 20 } ])")
    #expect(
      model.previewCommand(for: ids[2])
        == "db.users.aggregate([ { $match: { a: 1 } }, { $project: { b: 1 } }, { $limit: 20 } ])")
    #expect(model.previewCommand(for: ids[1]) == nil)
    #expect(model.previewState(for: ids[1]).isDisabled)

    await model.preview(ids[2])?.value
    // The gate's 7.1 cap rewrite appends its own limit of maxRows + 1 (20 + 1)
    #expect(
      factory.statements == [
        #"db.users.aggregate([ { $match: { a: 1 } }, { $project: { b: 1 } }, { $limit: 20 }, { $limit: NumberLong("21") } ])"#
      ])
    let result = try #require(model.previewState(for: ids[2]).result)
    #expect(result.rowCount == 1)
    await manager.disconnect()
  }

  @Test("$out, $merge and every later stage are never previewed")
  func writesNotPreviewed() async throws {
    let (manager, factory) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, [("$match", "{a: 1}"), ("$out", #""copy""#), ("$project", "{a: 1}")])
    for id in ids.dropFirst() {
      #expect(model.previewCommand(for: id) == nil)
      #expect(model.previewState(for: id).message == "not previewed (writes data)")
      #expect(model.preview(id) == nil)
    }
    #expect(model.previewCommand(for: ids[0]) != nil)
    #expect(factory.statements.isEmpty)

    // A switched-off $out writes nothing, so the stages after it are previewed
    model.setEnabled(false, for: ids[1])
    #expect(
      model.previewCommand(for: ids[2])
        == "db.users.aggregate([ { $match: { a: 1 } }, { $project: { a: 1 } }, { $limit: 20 } ])")

    // A nested $merge (sub-pipeline) or $out key writes too (fail closed)
    model.setOperator("$lookup", for: ids[1])
    model.setBody(#"{from: "o", pipeline: [{$merge: {into: "x"}}], as: "j"}"#, for: ids[1])
    model.setEnabled(true, for: ids[1])
    #expect(model.previewState(for: ids[1]).message == "not previewed (writes data)")
    #expect(model.previewState(for: ids[2]).message == "not previewed (writes data)")
    model.setBody("{$out: 1}", for: ids[0])
    #expect(model.previewState(for: ids[0]).message == "not previewed (writes data)")
    #expect(factory.statements.isEmpty)
    await manager.disconnect()
  }

  @Test("A hand-built prefix with $out or $merge is refused by the gate on the preview path")
  func gateRefusesWritingPrefix() async throws {
    let (manager, factory) = try await Self.connected()
    let match = MongoValue.document([.init("$match", .document([.init("a", .int32(1))]))])
    let limit = MongoValue.document([.init("$limit", .int32(20))])
    let writes: [MongoValue] = [
      .document([.init("$out", .string("copy"))]),
      .document([
        .init(
          "$facet",
          .document([
            .init(
              "x", .array([.document([.init("$merge", .document([.init("into", .string("o"))]))])]))
          ]))
      ]),
    ]
    for write in writes {
      let text = MongoCommand.aggregate(collection: "users", pipeline: [match, write, limit])
        .render()
      do {
        _ = try await AggregationBuilderModel.runPreview(text, on: manager)
        Issue.record("\(text) should be refused")
      } catch DatabaseError.blockedByProtection(let index, let kind, _) {
        #expect(index == 0)
        #expect(kind != .read)
      } catch {
        Issue.record("Unexpected error \(error)")
      }
    }
    #expect(factory.statements.isEmpty)
    await manager.disconnect()
  }

  @Test("Previews are cached per prefix: a repeat is not sent, editing an earlier stage re-runs")
  func cache() async throws {
    let (manager, factory) = try await Self.connected()
    let (model, ids) = Self.model(manager, [("$match", "{a: 1}"), ("$sort", "{a: 1}")])
    await model.preview(ids[0])?.value
    #expect(model.preview(ids[0]) == nil)
    #expect(factory.statements.count == 1)

    // Editing a later stage keeps the earlier stage's result
    model.setBody("{a: -1}", for: ids[1])
    #expect(model.previewState(for: ids[0]).result != nil)

    model.setBody("{a: 2}", for: ids[0])
    #expect(model.previewState(for: ids[0]).result == nil)
    await model.preview(ids[0])?.value
    #expect(factory.statements.count == 2)
    #expect(factory.statements.last?.contains("{ a: 2 }") == true)
    await manager.disconnect()
  }

  @Test("A failed preview shows the error and is sent again on the next preview")
  func failedPreview() async throws {
    let (manager, factory) = try await Self.connected(failingQuery: "aggregate")
    let (model, ids) = Self.model(manager, [("$match", "{a: 1}")])
    await model.preview(ids[0])?.value
    let state = model.previewState(for: ids[0])
    #expect(state.result == nil)
    #expect(state.message?.isEmpty == false)
    await model.preview(ids[0])?.value
    #expect(factory.statements.count == 2)
    await manager.disconnect()
  }

  // MARK: - From a cell

  @Test("A cell holding exactly one aggregate opens as stages that render back the same command")
  func fromCellAggregate() async throws {
    let (manager, _) = try await Self.connected()
    let text = """
      // grouped
      db.getCollection("a.b").aggregate([
        {$match: {n: {$gt: 1}}}, {$group: {_id: "$g", total: {$sum: 1}}}, {$limit: 5}
      ]);
      """
    let command = try #require(AggregationBuilderModel.aggregateCommand(in: text))
    let model = try #require(AggregationBuilderModel(command: command, connectionManager: manager))
    #expect(model.collection == "a.b")
    #expect(model.stages.map(\.operator) == ["$match", "$group", "$limit"])
    #expect(
      model.stages.map(\.body) == ["{ n: { $gt: 1 } }", #"{ _id: "$g", total: { $sum: 1 } }"#, "5"])
    #expect(model.stages.map(\.isEnabled) == [true, true, true])
    #expect(model.commandText == command.render())
    await manager.disconnect()
  }

  @Test(
    "Only a cell of exactly one aggregate with one-key stage documents opens the builder",
    arguments: [
      "db.users.find({})", "db.users.aggregate([{$match: {}}])\ndb.users.find()",
      "db.users.aggregate([{$match: {}, $sort: {a: 1}}])", "db.users.aggregate([1])",
      "db.users.aggregate([{}])", "db.users.aggregate([{$match: {}}", "",
    ])
  func fromCellRefused(text: String) async throws {
    let (manager, _) = try await Self.connected()
    let model = AggregationBuilderModel.aggregateCommand(in: text).flatMap {
      AggregationBuilderModel(command: $0, connectionManager: manager)
    }
    #expect(model == nil, "\(text)")
    await manager.disconnect()
  }

  // MARK: - Insert and Copy

  @Test("Insert/Copy text is the full aggregate: $out kept, disabled stages left out")
  func commandText() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, collection: "a.b",
      [("$match", "{a: 1}"), ("$sort", "{a: 1}"), ("$out", #""copy""#)])
    model.setEnabled(false, for: ids[1])
    let text = #"db.getCollection("a.b").aggregate([ { $match: { a: 1 } }, { $out: "copy" } ])"#
    #expect(model.commandText == text)

    let viewModel = NotebookViewModel()
    viewModel.selectedCellId = viewModel.notebook.cells[0].id
    let inserted = Self.observeCellInserts()
    defer { NotificationCenter.default.removeObserver(inserted.observer) }
    #expect(model.insert(into: viewModel))
    #expect(inserted.texts.value.contains(text))
    await manager.disconnect()
  }

  @Test("Insert reports failure and posts nothing when the tab has nowhere to insert")
  func insertWithoutTarget() async throws {
    let (manager, _) = try await Self.connected()
    let (model, _) = Self.model(manager, [("$match", "{a: 1}")])
    let inserted = Self.observeCellInserts()
    defer { NotificationCenter.default.removeObserver(inserted.observer) }

    let dataViewer = NotebookViewModel()
    dataViewer.viewMode = .editor
    dataViewer.dataViewer = DataViewerState(
      schema: "db", name: "users", orderColumns: ["_id"], page: 1, pageSize: 100)
    let markdown = NotebookViewModel()
    markdown.viewMode = .markdown
    let noSelection = NotebookViewModel()
    for viewModel in [dataViewer, markdown, noSelection] {
      #expect(!model.insert(into: viewModel))
    }
    #expect(inserted.texts.value.isEmpty)
    await manager.disconnect()
  }

  @Test("Text can be inserted into an editor or a selected cell only")
  func canInsertText() {
    let textView = SQLTextView(frame: .zero)
    let editor = NotebookViewModel()
    editor.viewMode = .editor
    #expect(!editor.canInsertText)
    editor.editorTextView = textView
    #expect(editor.canInsertText)
    editor.dataViewer = DataViewerState(
      schema: "db", name: "users", orderColumns: ["_id"], page: 1, pageSize: 100)
    #expect(!editor.canInsertText)

    let notebook = NotebookViewModel()
    #expect(!notebook.canInsertText)
    notebook.selectedCellId = notebook.notebook.cells[0].id
    #expect(notebook.canInsertText)
    notebook.viewMode = .markdown
    #expect(!notebook.canInsertText)
  }

  @Test(
    "Insert replaces the whole cell only when it holds just the aggregate, no comments",
    arguments: [
      ("db.users.aggregate([{$match: {}}])", true),
      ("  db.users.aggregate([{$match: {}}]);\n", true),
      ("// totals per group\ndb.users.aggregate([{$match: {}}])", false),
      ("db.users.aggregate([{$match: {}}]) /* keep */", false),
      ("db.users.aggregate([{$match: {}}])\n// next: add $sort", false),
      ("db.users.find({})", false),
    ])
  func replacesWholeCell(text: String, replaces: Bool) {
    #expect(AggregationBuilderModel.replacesWholeCell(text) == replaces, "\(text)")
  }

  /// Texts posted with `insertTextIntoCell` (synchronously, on the posting thread).
  private static func observeCellInserts() -> (observer: any NSObjectProtocol, texts: TextBox) {
    let texts = TextBox()
    let observer = NotificationCenter.default.addObserver(
      forName: .insertTextIntoCell, object: nil, queue: nil
    ) { notification in
      if let text = notification.userInfo?["text"] as? String { texts.value.append(text) }
    }
    return (observer, texts)
  }
}

/// Holds text posted with `insertTextIntoCell`. The notification callback is sendable.
private final class TextBox: @unchecked Sendable {
  var value: [String] = []
}
