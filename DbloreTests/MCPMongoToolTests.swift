// MCPMongoToolTests.swift
// MCP tools on a MongoDB connection, without a server: the read-only session factory hands out
// the session itself (MongoDB has no read-only transaction, so no BEGIN/ROLLBACK is sent),
// run_query takes exactly one mongosh read command, refuses writes ($out/$merge at any depth)
// and server-side JavaScript ($where, $function, $accumulator, {$code}) before sending, keeps
// the SQL caps (rows, cells, 30 s statement timeout -> maxTimeMS) and records History as `.mcp`;
// describe_table finds the introspector's `<database>.<collection>` keys.

import Foundation
import Testing

@testable import Dblore

/// History rows the service recorded.
private actor RecordedHistory: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

/// A read source that answers every read with one row and counts the reads that reached it.
private final class CountingReadSource: MCPReadSource, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [MCPReadRequest] = []

  var requests: [MCPReadRequest] { lock.withLock { recorded } }

  func listTables(connectionID: UUID, schema: String?) async throws -> [MCPTableName] { [] }

  func describeTable(
    connectionID: UUID, schema: String?, table: String
  ) async throws -> [MCPColumnDescription] { [] }

  func runRead(_ request: MCPReadRequest) async throws -> MCPReadResult {
    lock.withLock { recorded.append(request) }
    return MCPReadResult(
      columns: [MCPResultColumn(name: "_id", type: "objectId")], rows: [[.string("a")]],
      rowsTruncated: false)
  }
}

@MainActor
@Suite("MCP tools on MongoDB")
struct MCPMongoToolTests {
  private let source = CountingReadSource()
  private let history = RecordedHistory()

  private static func entry() -> ConnectionHistoryEntry {
    ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .mongodb, host: "mongo.internal", port: 27017, database: "shop",
        username: "reader", sslMode: .disable, name: "Shop"))
  }

  private func service(_ entry: ConnectionHistoryEntry) -> MCPToolService {
    let id = entry.id
    return MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, source: source, recorder: history,
      historyEnabled: { true })
  }

  private static func run(
    _ service: MCPToolService, _ id: UUID, _ text: String, maxRows: JSONValue? = nil
  ) async -> MCPToolResult {
    var arguments: [String: JSONValue] = [
      "connection_id": .string(id.uuidString), "sql": .string(text),
    ]
    arguments["max_rows"] = maxRows
    return await service.call("run_query", arguments: arguments)
  }

  /// Every text is refused with `message`, nothing reaches the source, and each is recorded as
  /// a failed MCP query.
  private func expectRefused(_ texts: [String], message: String) async {
    let entry = Self.entry()
    let service = service(entry)
    for text in texts {
      let result = await Self.run(service, entry.id, text)
      #expect(result.isError, "\(text)")
      #expect(result.text == message, "\(text): \(result.text)")
    }
    #expect(source.requests.isEmpty)
    let recorded = await history.entries
    #expect(recorded.count == texts.count)
    #expect(recorded.allSatisfy { $0.source == .mcp && $0.status == .error })
  }

  // MARK: - Session factory and caps, through the pool

  @Test("The session is unwrapped (no BEGIN/ROLLBACK); rows, cells and the timeout are capped")
  func factoryArmAndCaps() async throws {
    var entry = Self.entry()
    entry.config.statementTimeoutSeconds = 120
    let id = entry.id
    let saved = entry
    let longText = String(repeating: "x", count: 3_000)
    let inner = FakeDatabaseSessionFactory(
      capabilities: DatabaseType.mongodb.capabilities,
      columns: [
        ColumnInfo(name: "_id", type: "objectId"), ColumnInfo(name: "doc", type: "object"),
      ],
      rows: (0..<1_500).map { [.string(String(format: "%024x", $0)), .json(longText)] })
    let pool = MCPConnectionPool(
      entry: { $0 == id ? saved : nil }, sessionFactory: inner,
      certificates: InMemoryClientCertificateStore(), sshCredentials: InMemorySSHCredentialStore(),
      knownHosts: InMemorySSHKnownHostStore())
    let service = MCPToolService(
      connections: { [saved] }, allowlist: { [id] }, source: MCPSQLReadSource(pool: pool),
      recorder: history, historyEnabled: { true })

    let capped = await Self.run(service, id, "db.orders.find({status: \"open\"})")
    #expect(!capped.isError, "\(capped.text)")
    let output = try #require(
      JSONSerialization.jsonObject(with: Data(capped.text.utf8)) as? [String: Any])
    #expect(output["row_count"] as? Int == 200)
    #expect(output["rows_truncated"] as? Bool == true)
    #expect(output["truncated_cells"] as? Int == 200)
    #expect(output["notice"] as? String == MCPResultEncoder.dataNotice)
    _ = await Self.run(service, id, "db.orders.find()", maxRows: .number(5_000))

    #expect(
      inner.statements == [
        "db.orders.find({ status: \"open\" }).limit(201)", "db.orders.find().limit(1001)",
      ])
    let (unwrapped, timeout) = try await pool.withManager(for: id) { manager in
      (await manager.session is FakeDatabaseSession, await manager.config?.statementTimeoutSeconds)
    }
    #expect(unwrapped)
    #expect(timeout == MCPConnectionPool.statementTimeoutSeconds)
    await pool.closeAll()
  }

  @Test("The row cap defaults to 200 and is clamped to 1...1000")
  func rowCap() async {
    let entry = Self.entry()
    let service = service(entry)
    for maxRows in [nil, JSONValue.number(5_000), .number(0), .number(50)] {
      _ = await Self.run(service, entry.id, "db.c.find()", maxRows: maxRows)
    }
    #expect(source.requests.map(\.maxRows) == [200, 1_000, 1, 50])
  }

  // MARK: - run_query checks

  @Test("Several commands and comment-only text are refused before sending")
  func oneCommand() async {
    let entry = Self.entry()
    let service = service(entry)
    for text in ["db.c.find(); db.c.find()", "db.c.find()\ndb.d.countDocuments()"] {
      let result = await Self.run(service, entry.id, text)
      #expect(result.text == MCPToolError.multipleStatements.localizedDescription, "\(text)")
    }
    let empty = await Self.run(service, entry.id, "// nothing")
    #expect(empty.text == MCPToolError.emptyStatement.localizedDescription)
    #expect(source.requests.isEmpty)
  }

  @Test("Writes, $out/$merge at any depth and text outside the subset are refused")
  func writesRefused() async {
    await expectRefused(
      [
        "db.c.insertOne({a: 1})", "db.c.insertMany([{a: 1}])",
        "db.c.updateOne({a: 1}, {$set: {a: 2}})", "db.c.updateMany({}, {$set: {a: 2}})",
        "db.c.replaceOne({a: 1}, {a: 2})", "db.c.deleteOne({a: 1})", "db.c.deleteMany({})",
        "db.c.aggregate([{$out: \"x\"}])", "db.c.aggregate([{$merge: {into: \"x\"}}])",
        "db.c.aggregate([{$facet: {a: [{$match: {}}, {$out: \"x\"}]}}])",
        "db.c.aggregate([{$lookup: {from: \"o\", pipeline: [{$merge: \"x\"}], as: \"y\"}}])",
        "db.c.aggregate([{$unionWith: {coll: \"o\", pipeline: [{$out: \"x\"}]}}])",
        "db.dropDatabase()", "db.c.find().toArray()",
      ], message: MCPToolError.notRead.localizedDescription)
  }

  @Test("Server-side JavaScript is refused in every argument, at any depth")
  func javaScriptRefused() async {
    let function = "{$function: {body: \"function() { return true }\", args: [], lang: \"js\"}}"
    let accumulator =
      "{$accumulator: {init: \"function() { return 0 }\", accumulate: \"function(s) { return s }\", "
      + "accumulateArgs: [], merge: \"function(a, b) { return a }\", lang: \"js\"}}"
    await expectRefused(
      [
        // Filters, projections and sorts
        "db.c.find({$where: \"this.a > 1\"})",
        "db.c.find({a: 1, $or: [{b: 2}, {$and: [{$where: \"sleep(100) || true\"}]}]})",
        "db.c.find({$expr: \(function)})",
        "db.c.find({$expr: {$and: [{$eq: [1, 1]}, \(function)]}})",
        "db.c.find({}, {x: \(function)})",
        "db.c.find().sort({a: \(function)})",
        "db.c.countDocuments({$where: \"true\"})",
        "db.c.distinct(\"a\", {$expr: \(function)})",
        // Pipelines, sub-pipelines included
        "db.c.aggregate([{$match: {$where: \"true\"}}])",
        "db.c.aggregate([{$addFields: {y: \(function)}}])",
        "db.c.aggregate([{$group: {_id: null, x: \(accumulator)}}])",
        "db.c.aggregate([{$lookup: {from: \"o\", pipeline: [{$match: {$expr: \(function)}}], "
          + "as: \"x\"}}])",
        "db.c.aggregate([{$facet: {a: [{$match: {$where: \"true\"}}], b: [{$count: \"n\"}]}}])",
        "db.c.aggregate([{$unionWith: {coll: \"o\", pipeline: [{$project: {y: \(function)}}]}}])",
        // BSON JavaScript code values ({$code} is written as code)
        "db.c.find({a: {$code: \"function() { return 1 }\"}})",
        "db.c.find({a: {$in: [1, {$code: \"x\", $scope: {}}]}})",
        // A quoted or escaped key is the same key
        "db.c.find({\"$where\": \"true\"})",
        "db.c.find({\"\\u0024where\": \"true\"})",
      ], message: MCPToolError.serverSideJavaScript.localizedDescription)
  }

  @Test("Fields named like the operators and strings holding them are sent")
  func javaScriptLookalikesSent() async {
    let entry = Self.entry()
    let service = service(entry)
    let texts = [
      "db.c.find({where: 1, function: \"f\", accumulator: {code: 2}})",
      "db.c.find({a: \"$where\"}, {where: 1})",
      "db.c.aggregate([{$project: {where: 1, f: \"$function\"}}])",
      "db.c.distinct(\"where\")",
      // Exact case, as MongoDB matches operators (the server refuses an unknown one)
      "db.c.find({$WHERE: \"true\"})",
    ]
    for text in texts {
      let result = await Self.run(service, entry.id, text)
      #expect(!result.isError, "\(text): \(result.text)")
    }
    #expect(source.requests.map(\.sql) == texts)
  }

  @Test("run_query's description names the mongosh subset and the JavaScript refusal")
  func toolDescription() throws {
    let tool = try #require(MCPToolService.tools.first { $0.name == "run_query" })
    for word in ["MongoDB", "mongosh", "find", "aggregate", "$where", "$function", "$accumulator"] {
      #expect(tool.description.contains(word), "\(word)")
    }
  }

  // MARK: - History and describe_table

  @Test("A read is recorded in History as an MCP read with its text unchanged")
  func historyRecorded() async {
    let entry = Self.entry()
    let service = service(entry)
    let text = "db.orders.find({status: \"open\"}).limit(5)"
    let result = await Self.run(service, entry.id, text)
    #expect(!result.isError)
    let recorded = await history.entries
    #expect(recorded.count == 1)
    #expect(recorded.first?.source == .mcp)
    #expect(recorded.first?.kind == .read)
    #expect(recorded.first?.status == .success)
    #expect(recorded.first?.sql == text)
    #expect(recorded.first?.rowCount == 1)
    #expect(recorded.first?.connectionLabel == "Shop")
    #expect(recorded.first?.connectionKey == QueryHistoryIdentity.connectionKey(for: entry.config))
  }

  @Test("describe_table finds the sampled fields keyed <database>.<collection>")
  func describeTableLookup() throws {
    let sampled = MongoSchemaIntrospector.columns(for: [
      .document([
        MongoValue.Field("_id", .objectId(MongoObjectId(hex: "0123456789abcdef01234567")!)),
        MongoValue.Field("address", .document([MongoValue.Field("city", .string("Paris"))])),
      ])
    ])
    let all = ["shop.users": sampled, "shop.orders": []]
    let described = try MCPSQLReadSource.columns(in: all, schema: nil, table: "users")
    #expect(described == (try MCPSQLReadSource.columns(in: all, schema: "shop", table: "users")))
    #expect(described.map(\.name) == ["_id", "address", "address.city"])
    #expect(described.first?.type == "objectId")
    #expect(described.first?.primaryKey == true)
    #expect(described.last?.type == "string")
    #expect(throws: MCPToolError.tableNotFound) {
      try MCPSQLReadSource.columns(in: all, schema: "other", table: "users")
    }
  }
}
