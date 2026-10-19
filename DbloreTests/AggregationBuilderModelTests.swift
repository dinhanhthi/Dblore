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

  @Test("replaceStages replaces every stage in order")
  func replaceStages() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(manager, [("$match", "{}"), ("$limit", "5")])
    model.setEnabled(false, for: ids[1])

    model.replaceStages([
      .init(operator: "$sort", body: "{a: -1}"), .init(operator: "$match", body: "{b: 1}"),
      .init(operator: "$limit", body: "3"),
    ])
    #expect(model.stages.map(\.operator) == ["$sort", "$match", "$limit"])
    #expect(model.stages.map(\.body) == ["{a: -1}", "{b: 1}", "3"])
    #expect(model.stages.map(\.isEnabled) == [true, true, true])
    #expect(Set(model.stages.map(\.id)).isDisjoint(with: ids))
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

  @Test(
    "A cell holding exactly one aggregate opens as stages and options that render back the same command"
  )
  func fromCellAggregate() async throws {
    let (manager, _) = try await Self.connected()
    let text = """
      // grouped
      db.getCollection("a.b").aggregate([
        {$match: {n: {$gt: 1}}}, {$group: {_id: "$g", total: {$sum: 1}}}, {$limit: 5}
      ], {collation: {locale: "en"}, maxTimeMS: 500});
      """
    let command = try #require(AggregationBuilderModel.aggregateCommand(in: text))
    let model = try #require(AggregationBuilderModel(command: command, connectionManager: manager))
    #expect(model.collection == "a.b")
    #expect(model.stages.map(\.operator) == ["$match", "$group", "$limit"])
    #expect(
      model.stages.map(\.body) == ["{ n: { $gt: 1 } }", #"{ _id: "$g", total: { $sum: 1 } }"#, "5"])
    #expect(model.stages.map(\.isEnabled) == [true, true, true])
    #expect(model.options.collation == #"{ locale: "en" }"#)
    #expect(model.options.maxTimeMS == "500")
    #expect(model.commandText == command.render())
    await manager.disconnect()
  }

  @Test(
    "Only a cell of exactly one aggregate with one-key stage documents opens the builder",
    arguments: [
      "db.users.find({})", "db.users.aggregate([{$match: {}}])\ndb.users.find()",
      "db.users.aggregate([{$match: {}, $sort: {a: 1}}])", "db.users.aggregate([1])",
      "db.users.aggregate([{}])", "db.users.aggregate([{$match: {}}", "",
      #"db.users.aggregate([{$match: {}}], {hint: "a_1"})"#,
    ])
  func fromCellRefused(text: String) async throws {
    let (manager, _) = try await Self.connected()
    let model = AggregationBuilderModel.aggregateCommand(in: text).flatMap {
      AggregationBuilderModel(command: $0, connectionManager: manager)
    }
    #expect(model == nil, "\(text)")
    await manager.disconnect()
  }

  // MARK: - Text mode

  @Test("Text that does not parse keeps Text mode with the error and blocks the pipeline")
  func invalidText() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(manager, [("$match", "{a: 1}"), ("$limit", "5")])
    model.showText()
    #expect(model.editMode == .text)
    #expect(
      model.pipelineText
        == AIMongoAssist.pipelineText([
          .init(operator: "$match", body: "{a: 1}"), .init(operator: "$limit", body: "5"),
        ]))

    model.pipelineText = "[{$match: {a: 1},, ]"
    #expect(!model.showStages())
    #expect(model.editMode == .text)
    let error = try #require(model.textError)
    #expect(model.pipeline(verb: "run").reason == error)
    #expect(model.commandText == nil)
    #expect(model.stages.map(\.id) == ids)

    model.pipelineText = "db.orders.aggregate([{$match: {a: 2}}])"
    #expect(!model.showStages())
    #expect(model.textError == "This builder runs on users: the text names orders")
    #expect(model.commandText == nil)
    #expect(model.stages.map(\.id) == ids)

    model.pipelineText = "[{$match: {a: 2}}]"
    #expect(model.textError == nil)
    #expect(model.commandText == "db.users.aggregate([ { $match: { a: 2 } } ])")
    await manager.disconnect()
  }

  @Test("A disabled stage stays disabled and in place through Text mode; text options are kept")
  func textRoundTrip() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, [("$match", "{\n  a: 1\n}"), ("$sort", "{b: -1}"), ("$limit", "5")])
    model.setEnabled(false, for: ids[1])
    model.showText()
    let written = "[\n  { $match: {\n  a: 1\n} },\n  // { $sort: {b: -1} },\n  { $limit: 5 }\n]"
    #expect(model.pipelineText == written)
    #expect(model.showStages())
    #expect(model.stages.map(\.id) == ids)

    model.showText()
    model.pipelineText =
      "db.users.aggregate("
      + written.replacingOccurrences(of: "$limit: 5", with: "$limit: 10")
      + ", {maxTimeMS: 50})"
    let command =
      "db.users.aggregate([ { $match: { a: 1 } }, { $limit: 10 } ], { maxTimeMS: 50 })"
    #expect(model.commandText == command)
    #expect(model.showStages())
    #expect(model.editMode == .stages)
    #expect(model.stages.map(\.operator) == ["$match", "$sort", "$limit"])
    #expect(model.stages.map(\.body) == ["{ a: 1 }", "{ b: -1 }", "10"])
    #expect(model.stages.map(\.isEnabled) == [true, false, true])
    #expect(Set(model.stages.map(\.id)).isDisjoint(with: ids))
    #expect(model.options.maxTimeMS == "50")
    #expect(model.commandText == command)

    // Disabled stages in a row, and one after an enabled line with a trailing comment
    let (adjacent, adjacentIDs) = Self.model(
      manager,
      [("$match", "{a: 1}"), ("$sort", "{b: -1}"), ("$project", "{c: 0}"), ("$limit", "5")])
    adjacent.setEnabled(false, for: adjacentIDs[1])
    adjacent.setEnabled(false, for: adjacentIDs[2])
    adjacent.showText()
    adjacent.pipelineText = adjacent.pipelineText.replacingOccurrences(
      of: "$limit: 5", with: "$limit: 10")
    #expect(adjacent.showStages())
    #expect(adjacent.stages.map(\.operator) == ["$match", "$sort", "$project", "$limit"])
    #expect(adjacent.stages.map(\.body) == ["{ a: 1 }", "{ b: -1 }", "{ c: 0 }", "10"])
    #expect(adjacent.stages.map(\.isEnabled) == [true, false, false, true])

    adjacent.showText()
    adjacent.pipelineText =
      "[\n  { $match: {a: 1} }, // note\n  // { $sort: {b: -1} },\n  { $limit: 5 }\n]"
    #expect(adjacent.showStages())
    #expect(adjacent.stages.map(\.operator) == ["$match", "$sort", "$limit"])
    #expect(adjacent.stages.map(\.isEnabled) == [true, false, true])

    // A body ending in a `//` comment closes on its own line, so an edit still parses
    let (commented, commentedIDs) = Self.model(
      manager, [("$match", "{a: 1} // note"), ("$sort", "{b: -1} // off"), ("$limit", "5")])
    commented.setEnabled(false, for: commentedIDs[1])
    commented.showText()
    #expect(
      commented.pipelineText
        == "[\n  { $match: {a: 1} // note\n  },\n  // { $sort: {b: -1} // off },\n  { $limit: 5 }\n]"
    )
    commented.pipelineText = commented.pipelineText.replacingOccurrences(
      of: "$limit: 5", with: "$limit: 10")
    #expect(commented.commandText == "db.users.aggregate([ { $match: { a: 1 } }, { $limit: 10 } ])")
    #expect(commented.showStages())
    #expect(commented.stages.map(\.operator) == ["$match", "$sort", "$limit"])
    #expect(commented.stages.map(\.body) == ["{ a: 1 }", "{b: -1} // off", "10"])
    #expect(commented.stages.map(\.isEnabled) == [true, false, true])
    await manager.disconnect()
  }

  @Test(
    "A pasted fenced pipeline keeps its disabled stages",
    arguments: [
      "```js\n[\n  { $match: {a: 1} },\n  // { $sort: {b: -1} },\n  { $limit: 5 }\n]\n```",
      "```\ndb.users.aggregate([\n  { $match: {a: 1} },\n  // { $sort: {b: -1} },\n  { $limit: 5 }\n])\n```",
    ])
  func fencedText(text: String) async throws {
    let (manager, _) = try await Self.connected()
    let (model, _) = Self.model(manager, [("$limit", "1")])
    model.showText()
    model.pipelineText = text
    #expect(model.showStages())
    #expect(model.stages.map(\.operator) == ["$match", "$sort", "$limit"])
    #expect(model.stages.map(\.isEnabled) == [true, false, true])
    await manager.disconnect()
  }

  @Test("Format writes the text as a stage array, a long stage indented; text options move over")
  func formatText() async throws {
    let (manager, _) = try await Self.connected()
    let (model, _) = Self.model(manager, [("$limit", "1")])
    model.showText()
    model.pipelineText =
      "db.users.aggregate([{$match:{a:1}},\n// {$sort: {b: -1}},\n"
      + "{$project: {customerFirstName: 1, customerLastName: 1, customerEmail: 1, customerPhone: 1}}"
      + "], {maxTimeMS: 50})"
    let formatted = try #require(model.format())
    #expect(
      formatted
        == """
        [
          { $match: { a: 1 } },
          // { $sort: { b: -1 } },
          {
            $project: {
              customerFirstName: 1,
              customerLastName: 1,
              customerEmail: 1,
              customerPhone: 1
            }
          }
        ]
        """)
    #expect(model.options.maxTimeMS == "50")
    model.pipelineText = formatted
    #expect(
      model.commandText
        == "db.users.aggregate([ { $match: { a: 1 } }, { $project: { customerFirstName: 1, "
        + "customerLastName: 1, customerEmail: 1, customerPhone: 1 } } ], { maxTimeMS: 50 })")

    model.pipelineText = "[{$match: ,]"
    #expect(model.format() == nil)
    #expect(model.textError != nil)
    #expect(model.pipelineText == "[{$match: ,]")
    await manager.disconnect()
  }

  // MARK: - Run

  @Test("Run and Export Data refuse a pipeline with $out or $merge and send nothing")
  func runRefusesWrites() async throws {
    let (manager, factory) = try await Self.connected()
    for (name, body) in [("$out", #""copy""#), ("$merge", #"{into: "x"}"#)] {
      let (model, _) = Self.model(manager, [("$match", "{a: 1}"), (name, body)])
      let reason = try #require(model.runTarget.reason, "\(name)")
      #expect(model.run(maxRows: 50) == nil)
      guard case .failed(let message) = model.runState else {
        Issue.record("\(name) should be refused")
        continue
      }
      #expect(message == reason)
      #expect(model.showsRunResults)

      #expect(model.exportTarget.reason?.contains("not exported") == true)
      // The export sheet refuses the same pipeline before any read
      let pipeline = try #require(model.pipeline(verb: "export").command)
      let export = MongoExportModel(
        collection: "users", database: nil, pipeline: pipeline, connectionManager: manager)
      #expect(export.refusal?.contains("not exported") == true)
      #expect(!export.canExport)
    }
    #expect(factory.statements.isEmpty)
    await manager.disconnect()
  }

  @Test(
    "Run sends the enabled stages and options read-only, capped at maxRows, and shows the result")
  func run() async throws {
    let (manager, factory) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, [("$match", "{a: 1}"), ("$sort", "{b: -1}"), ("$project", "{b: 1}")])
    model.setEnabled(false, for: ids[1])
    model.options.maxTimeMS = "250"
    await model.run(maxRows: 50)?.value
    let command =
      "db.users.aggregate([ { $match: { a: 1 } }, { $project: { b: 1 } } ], { maxTimeMS: 250 })"
    // The gate's cap rewrite appends its own limit of maxRows + 1, the options kept
    #expect(
      factory.statements == [
        #"db.users.aggregate([ { $match: { a: 1 } }, { $project: { b: 1 } }, { $limit: NumberLong("51") } ], { maxTimeMS: 250 })"#
      ])
    guard case .done(let result, let sent) = model.runState else {
      Issue.record("Run should be done, is \(model.runState)")
      return
    }
    #expect(sent == command)
    #expect(result.rowCount == 1)
    #expect(model.showsRunResults)

    // Previewing a stage switches the pane back to the preview
    await model.preview(ids[0])?.value
    #expect(!model.showsRunResults)
    await manager.disconnect()
  }

  @Test("A saved pipeline restores its stages and only collation and maxTimeMS, in Stages mode")
  func restore() async throws {
    let (manager, _) = try await Self.connected()
    let (source, ids) = Self.model(manager, [("$match", "{a: 1}"), ("$sort", "{b: -1}")])
    source.setEnabled(false, for: ids[1])
    var options = MongoQueryOptions()
    options.collation = "{locale: 'fr'}"
    options.maxTimeMS = "100"
    options.sort = "{c: 1}"
    let saved = SavedMongoPipeline(name: "p", stages: source.savedStages(), options: options)

    let (model, _) = Self.model(manager, [("$limit", "5")])
    model.showText()
    model.pipelineText = "not a pipeline"
    #expect(!model.showStages())
    _ = model.run(maxRows: 50)
    model.restore(saved)
    #expect(model.editMode == .stages)
    #expect(model.textError == nil)
    #expect(model.stages.map(\.operator) == ["$match", "$sort"])
    #expect(model.stages.map(\.body) == ["{a: 1}", "{b: -1}"])
    #expect(model.stages.map(\.isEnabled) == [true, false])
    #expect(model.options.collation == "{locale: 'fr'}")
    #expect(model.options.maxTimeMS == "100")
    #expect(model.options.sort.isEmpty)
    guard case .idle = model.runState else {
      Issue.record("Restore should reset the run, is \(model.runState)")
      return
    }
    #expect(!model.showsRunResults)
    await manager.disconnect()
  }

  // MARK: - Insert and Copy

  @Test("Insert/Copy text is the full aggregate: $out kept, disabled stages left out, options")
  func commandText() async throws {
    let (manager, _) = try await Self.connected()
    let (model, ids) = Self.model(
      manager, collection: "a.b",
      [("$match", "{a: 1}"), ("$sort", "{a: 1}"), ("$out", #""copy""#)])
    model.setEnabled(false, for: ids[1])
    model.options.maxTimeMS = "x"
    #expect(model.commandText == nil)
    #expect(model.pipeline(verb: "run").reason?.contains("maxTimeMS") == true)
    model.options.maxTimeMS = "250"
    let text =
      #"db.getCollection("a.b").aggregate([ { $match: { a: 1 } }, { $out: "copy" } ], { maxTimeMS: 250 })"#
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
