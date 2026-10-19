// MCPMongoLiveTests.swift
// The MCP tools on the docker MongoDB (mongo:8.0 on 27018, `MongoSessionTests.config()`), through
// the whole stack (`MCPToolService` over `MCPSQLReadSource` and `MCPConnectionPool` on the app's
// sessions): list_tables and describe_table read the sampled catalog, run_query reads with the
// row cap and a 30 s `maxTimeMS`, and refused writes and server-side JavaScript leave the data
// unchanged. Collections are seeded with a plain session and dropped on every path. Opt-in
// (`.requiresMongo`).

import Foundation
import Testing

@testable import Dblore

/// History rows the service recorded.
private actor LiveHistory: QueryHistoryRecording {
  private(set) var entries: [QueryHistoryEntry] = []

  func record(_ entry: QueryHistoryEntry) async {
    entries.append(entry)
  }
}

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct MCPMongoLiveTests {
  private typealias Call = (String, [String: JSONValue]) async -> MCPToolResult

  /// Runs `body` with a tool service on the fixture and the pool behind it.
  private func withToolService(
    history: LiveHistory,
    _ body: (_ call: Call, _ pool: MCPConnectionPool, _ id: UUID)
      async throws -> Void
  ) async throws {
    // The service lists entries without passwords; the pool's lookup loads it.
    let config = MongoSessionTests.config()
    let entry = ConnectionHistoryEntry(config: config)
    var withPassword = entry
    withPassword.config.password = config.password
    let saved = withPassword
    let id = entry.id
    let pool = MCPConnectionPool(entry: { $0 == id ? saved : nil })
    let service = MCPToolService(
      connections: { [entry] }, allowlist: { [id] }, aiSettings: { .empty },
      source: MCPSQLReadSource(pool: pool),
      recorder: history, historyEnabled: { true })
    let call: Call = { tool, arguments in
      await service.call(
        tool, arguments: arguments.merging(["connection_id": .string(id.uuidString)]) { $1 })
    }
    do {
      try await body(call, pool, id)
    } catch {
      await pool.closeAll()
      throw error
    }
    await pool.closeAll()
  }

  private static func json(_ result: MCPToolResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
  }

  /// `[{_id: n, name: "user n", address: {city: "City n"}}]` for n in 0..<count
  private static func seed(_ session: MongoSession, _ collection: String, count: Int) async throws {
    let documents = (0..<count).map {
      "{_id: \($0), name: \"user \($0)\", address: {city: \"City \($0)\"}}"
    }
    let inserted = try await session.command(
      "db.\(collection).insertMany([\(documents.joined(separator: ", "))])", binds: [])
    #expect(inserted.affectedRows == count)
  }

  @Test(
    "list_tables, describe_table and a capped find read the fixture with a 30 s maxTimeMS",
    .requiresMongo)
  func readTools() async throws {
    let collection = "mcp_live_reads"
    let history = LiveHistory()
    try await MongoSessionTests.withCollection(collection) { session in
      try await Self.seed(session, collection, count: 30)
      try await withToolService(history: history) { call, pool, id in
        let tables = await call("list_tables", [:])
        #expect(!tables.isError, "\(tables.text)")
        let listed = try #require(Self.json(tables)["tables"] as? [[String: String]])
        #expect(
          listed.contains { $0 == ["schema": TestMongoDatabase.database, "name": collection] })

        let described = await call("describe_table", ["table": .string(collection)])
        #expect(!described.isError, "\(described.text)")
        let columns = try #require(Self.json(described)["columns"] as? [[String: Any]])
        #expect(
          columns.map { $0["name"] as? String } == ["_id", "name", "address", "address.city"])
        #expect(columns.map { $0["type"] as? String } == ["int", "string", "object", "string"])
        #expect(columns.first?["primary_key"] as? Bool == true)

        let read = await call(
          "run_query",
          [
            "sql": .string("db.\(collection).find({}, {name: 1}).sort({_id: 1})"),
            "max_rows": .number(10),
          ])
        #expect(!read.isError, "\(read.text)")
        let rows = try Self.json(read)
        #expect(rows["row_count"] as? Int == 10)
        #expect(rows["rows_truncated"] as? Bool == true)
        #expect((rows["rows"] as? [[Any]])?.first?.last as? String == "user 0")

        let maxTimeMS = try await pool.withManager(for: id) { manager in
          (await manager.session as? MongoSession)?.maxTimeMS
        }
        #expect(maxTimeMS == 30_000)
      }
    }
    let recorded = await history.entries
    #expect(recorded.map(\.source) == [.mcp])
    #expect(recorded.first?.status == .success)
    #expect(recorded.first?.rowCount == 10)
  }

  @Test("Refused writes and server-side JavaScript leave the data unchanged", .requiresMongo)
  func refusedWritesChangeNothing() async throws {
    let collection = "mcp_live_writes"
    let target = "mcp_live_writes_out"
    let history = LiveHistory()
    await MongoSessionTests.drop(target)
    try await MongoSessionTests.withCollection(collection) { session in
      try await Self.seed(session, collection, count: 3)
      try await withToolService(history: history) { call, _, _ in
        for text in [
          "db.\(collection).insertOne({_id: 99})", "db.\(collection).deleteMany({})",
          "db.\(collection).updateMany({}, {$set: {name: \"x\"}})",
          "db.\(collection).aggregate([{$out: \"\(target)\"}])",
          "db.\(collection).aggregate([{$facet: {a: [{$merge: \"\(target)\"}]}}])",
          "db.\(collection).find({$where: \"sleep(5000) || true\"})",
        ] {
          let result = await call("run_query", ["sql": .string(text)])
          #expect(result.isError, "\(text): \(result.text)")
          #expect(result.text.hasSuffix("Nothing was sent to the database."), "\(result.text)")
        }
      }
      let names = try await MongoSessionTests.read(
        session, "db.\(collection).find({}, {name: 1}).sort({_id: 1})")
      #expect(names.rows.map(\.last) == ["user 0", "user 1", "user 2"].map { .string($0) })
      let collections = try await MongoSessionTests.read(session, "show collections")
      #expect(!collections.rows.contains { $0.first == .string(target) })
    }
    await MongoSessionTests.drop(target)
    let recorded = await history.entries
    #expect(recorded.count == 6)
    #expect(recorded.allSatisfy { $0.source == .mcp && $0.status == .error })
  }
}
