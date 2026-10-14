// MongoSchemaIntrospectorTests.swift
// MongoSchemaIntrospector: the pure parts without a server (listCollections entries to tables and
// views, `system.*` hidden, the 200-relation sampling cap, sample commands, field paths to depth
// 3 and type merging); then, against the docker fixture (mongo:8.0 on 27018), tables, views with
// their pipeline, sampled columns (a view through find), row counts and the `_id` key. Live cases
// are opt-in (`.requiresMongo`).

import BSON
import Foundation
import MongoKitten
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoSchemaIntrospectorTests {
  private typealias Introspector = MongoSchemaIntrospector

  private static func parse(_ text: String) throws -> MongoValue {
    try MongoRelaxedJSON.parse(text)
  }

  private static func shape(_ columns: [DatabaseColumn]) -> [String] {
    columns.map { "\($0.name):\($0.type)\($0.isPrimaryKey ? ":pk" : "")" }
  }

  // MARK: - Relations

  @Test("listCollections entries: system.* hidden, sorted, views keep their pipeline")
  func relations() throws {
    let entries = try [
      "{name: 'orders', type: 'collection', options: {}}",
      "{name: 'system.views', type: 'collection', options: {}}",
      "{name: 'system.buckets.metrics', type: 'collection', options: {}}",
      "{name: 'metrics', type: 'timeseries', options: {timeseries: {timeField: 't'}}}",
      "{name: 'big_orders', type: 'view', options: {viewOn: 'orders', pipeline: [{$match: {n: {$gt: 1}}}]}}",
      "{name: 'Accounts', type: 'collection'}",
      "{type: 'collection'}",
    ].map(Self.parse)

    let relations = Introspector.relations(from: entries)

    #expect(relations.map(\.name) == ["Accounts", "big_orders", "metrics", "orders"])
    #expect(relations.map(\.isView) == [false, true, false, false])
    #expect(relations[1].definition == "[ { $match: { n: { $gt: 1 } } } ]")
    #expect(relations[0].definition == nil)
  }

  @Test("At most 200 relations are sampled, the first by name")
  func samplingCap() {
    let names = (0..<250).map { String(format: "c%03d", $0) }
    let entries = names.shuffled().map {
      MongoValue.document([.init("name", .string($0)), .init("type", .string("collection"))])
    }

    let sampled = Introspector.sampledRelations(Introspector.relations(from: entries))

    #expect(sampled.map(\.name) == Array(names.prefix(200)))
  }

  @Test("A collection samples with $sample then find; a view only with find")
  func sampleCommands() throws {
    let collection = Introspector.sampleCommands(
      for: .init(name: "orders", isView: false, definition: nil))
    #expect(collection.map { $0.first?.key } == ["aggregate", "find"])
    #expect(
      collection[0].first { $0.key == "pipeline" }?.value
        == .array([try Self.parse("{$sample: {size: 100}}")]))
    #expect(collection[1].first { $0.key == "limit" }?.value == .int64(100))

    let view = Introspector.sampleCommands(for: .init(name: "v", isView: true, definition: "[]"))
    #expect(view.map { $0.first?.key } == ["find"])
  }

  // MARK: - Columns

  @Test("Field paths go three levels deep; arrays and JavaScript are not entered; _id first")
  func fieldPaths() throws {
    let document = try Self.parse(
      """
      {name: 'a', _id: 1, a: {b: {c: {d: 1}}, x: [{y: 1}]}, tags: ['t'], js: {$code: 'f()'}}
      """)

    let columns = Introspector.columns(for: [document])

    #expect(
      Self.shape(columns) == [
        "_id:int:pk", "name:string", "a:object", "a.b:object", "a.b.c:object", "a.x:array",
        "tags:array", "js:javascript",
      ])
    #expect(columns[0].isNullable == false)
    #expect(columns[1].isNullable)
  }

  @Test("Types merge across samples: different types are mixed, null never is")
  func typeMerge() throws {
    let documents = try [
      "{_id: ObjectId('0123456789abcdef01234567'), v: 1, n: null, p: {q: 1}}",
      "{_id: ObjectId('0123456789abcdef01234568'), v: 'x', n: NumberLong(2), p: 'flat'}",
    ].map(Self.parse)

    let columns = Introspector.columns(for: documents)

    #expect(Self.shape(columns) == ["_id:objectId:pk", "v:mixed", "n:long", "p:mixed", "p.q:int"])
  }

  @Test("No sampled documents gives just _id")
  func emptySample() {
    #expect(Self.shape(Introspector.columns(for: [])) == ["_id:objectId:pk"])
  }

  // MARK: - Live server

  static let orders = "introspect_orders"
  static let empty = "introspect_empty"
  static let view = "introspect_numbered"

  static func dropFixtures() async {
    for name in [view, orders, empty] { await MongoSessionTests.drop(name) }
  }

  @Test("Tables, views, sampled columns, row counts and _id against the server", .requiresMongo)
  func liveCatalog() async throws {
    await Self.dropFixtures()
    let session = try await MongoSessionTests.openSession()
    do {
      try await Self.checkCatalog(session)
    } catch {
      await session.close()
      await Self.dropFixtures()
      throw error
    }
    await session.close()
    await Self.dropFixtures()
  }

  private static func checkCatalog(_ session: MongoSession) async throws {
    _ = try await session.command(
      """
      db.\(orders).insertMany([
        {_id: 1, n: 1, customer: {name: "A", address: {city: "Oslo", geo: {lat: 1}}}, tags: ["x"]},
        {_id: 2, n: "two", customer: {name: "B"}},
        {_id: 3, n: 3}
      ])
      """, binds: [])
    _ = try await session.command("db.\(empty).insertOne({_id: 1})", binds: [])
    _ = try await session.command("db.\(empty).deleteMany({})", binds: [])
    // Creating a view also creates `system.views`, which stays hidden.
    let created = try await MongoSpike.withDatabase { db in
      try await MongoSpike.command(
        db,
        [
          "create": view, "viewOn": orders,
          "pipeline": [["$match": ["n": ["$type": "number"] as Document] as Document] as Document]
            as Document,
        ])
    }
    #expect(MongoSession.int(created["ok"]) == 1)

    let introspector = MongoSchemaIntrospector()
    let database = TestMongoDatabase.database
    let tables = try await introspector.tables(in: session)
    #expect(tables.filter { $0.name.hasPrefix("introspect_") }.map(\.name) == [empty, orders])
    #expect(!tables.contains { $0.name.hasPrefix("system.") })
    #expect(tables.allSatisfy { $0.schema == database })

    let views = try await introspector.views(in: session)
    let numbered = try #require(views.first { $0.name == view })
    #expect(numbered.schema == database)
    #expect(numbered.definition?.contains("$match") == true)
    #expect(numbered.definition?.contains("$type") == true)
    #expect(!tables.contains { $0.name == view })

    let columns = try await introspector.allColumns(in: session)
    let orderColumns = try #require(columns["\(database).\(orders)"])
    #expect(orderColumns.first?.name == "_id")
    #expect(
      Set(shape(orderColumns)) == [
        "_id:int:pk", "n:mixed", "customer:object", "customer.name:string",
        "customer.address:object", "customer.address.city:string", "customer.address.geo:object",
        "tags:array",
      ])
    #expect(shape(try #require(columns["\(database).\(empty)"])) == ["_id:objectId:pk"])
    // The view reads with find: only its numeric documents, so `n` is not mixed.
    let viewColumns = shape(try #require(columns["\(database).\(view)"]))
    #expect(viewColumns.first == "_id:int:pk")
    #expect(viewColumns.contains("n:int"))
    #expect(!columns.keys.contains { $0.hasPrefix("\(database).system.") })
    // Sampling used its own maxTimeMS; the statement timeout (30 s) is unchanged.
    #expect(session.maxTimeMS == 30_000)

    #expect(try await introspector.rowCount(schema: database, table: orders, in: session) == 3)
    #expect(try await introspector.rowCount(schema: database, table: view, in: session) == 2)
    #expect(try await introspector.rowCount(schema: database, table: empty, in: session) == 0)
    #expect(try await introspector.primaryKeyColumns(of: orders, in: session) == ["_id"])
    #expect(try await introspector.editTable(named: orders, in: session) == nil)
    await #expect(throws: MongoSessionError.self) {
      _ = try await introspector.tableStructure(schema: database, table: orders, in: session)
    }
  }

  @Test("The manager reads the MongoDB catalog through MongoSchemaIntrospector", .requiresMongo)
  func managerCatalog() async throws {
    await MongoSessionTests.drop(Self.orders)
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: MongoSessionTests.config())
    do {
      let session = try #require(await manager.session as? MongoSession)
      _ = try await session.command("db.\(Self.orders).insertOne({_id: 1, a: {b: 1}})", binds: [])
      #expect(try await manager.fetchTables().contains { $0.name == Self.orders })
      let columns = try await manager.fetchAllColumns()
      let key = "\(TestMongoDatabase.database).\(Self.orders)"
      #expect(Self.shape(try #require(columns[key])) == ["_id:int:pk", "a:object", "a.b:int"])
    } catch {
      await manager.disconnect()
      await MongoSessionTests.drop(Self.orders)
      throw error
    }
    await manager.disconnect()
    await MongoSessionTests.drop(Self.orders)
  }
}
