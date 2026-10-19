// MongoAdminCommandTests.swift
// The admin commands of the mongosh subset as sent: command documents (rename on admin with full
// namespaces, the drivers' generated index name), the database writeCommand routes to and the
// command tag of a reply; the index, collection and view drafts and the validation rules checked
// and round-tripped; the database commands (the only getSiblingDB forms accepted, the refusals and
// the session's reserved-database guard)

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB admin commands")
struct MongoAdminCommandTests {

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  @Test("A rename runs in admin with <db>.<name> namespaces and dropTarget false")
  func renameNamespaces() {
    let command = MongoAdminCommand.renameCollection(collection: "a", to: "b")
    let (fields, database) = command.commandDocument(in: "shop")
    #expect(database == "admin")
    #expect(
      fields == [
        .init("renameCollection", .string("shop.a")), .init("to", .string("shop.b")),
        .init("dropTarget", .bool(false)),
      ])
  }

  @Test(
    "createIndex without a name gets the drivers' generated index name",
    arguments: [
      ("a_1_b_-1", MongoValue.document([.init("a", .int32(1)), .init("b", .int32(-1))])),
      ("a_text", .document([.init("a", .string("text"))])),
      ("$**_1", .document([.init("$**", .int32(1))])),
      ("loc_2dsphere", .document([.init("loc", .string("2dsphere"))])),
    ])
  func generatedIndexName(name: String, keys: MongoValue) {
    let (fields, database) = MongoAdminCommand.createIndex(
      collection: "c", keys: keys, options: nil
    ).commandDocument(in: "shop")
    #expect(database == "shop")
    #expect(
      fields == [
        .init("createIndexes", .string("c")),
        .init("indexes", .array([doc(("key", keys), ("name", .string(name)))])),
      ])
  }

  @Test("An explicit index name is kept, never replaced by a generated one")
  func explicitIndexName() {
    let keys = doc(("a", .int32(1)))
    let (fields, _) = MongoAdminCommand.createIndex(
      collection: "c", keys: keys, options: doc(("name", .string("by_a")), ("unique", .bool(true)))
    ).commandDocument(in: "shop")
    #expect(
      fields.last
        == .init(
          "indexes",
          .array([doc(("key", keys), ("name", .string("by_a")), ("unique", .bool(true)))])))
  }

  @Test("writeCommand sends an admin command to its database: admin for a rename")
  func writeCommandRouting() throws {
    let drop = try #require(MongoSession.writeCommand(.admin(.drop(collection: "c")), in: "db"))
    #expect(drop.database == "db")
    #expect(drop.fields == [.init("drop", .string("c"))])
    let rename = try #require(
      MongoSession.writeCommand(.admin(.renameCollection(collection: "c", to: "d")), in: "db"))
    #expect(rename.database == "admin")
  }

  @Test("An admin reply gives its command tag and no affected count")
  func commandResultTag() throws {
    let reply = doc(("ok", .double(1)))
    let result = try MongoSession.commandResult(
      for: .admin(.setIndexHidden(collection: "c", name: "a_1", hidden: false)), reply: reply)
    #expect(result == CommandResult(affectedRows: 0, tag: "UNHIDE INDEX"))
    let drop = try MongoSession.commandResult(for: .admin(.drop(collection: "c")), reply: reply)
    #expect(drop == CommandResult(affectedRows: 0, tag: "DROP"))
  }

  private static func draft(
    _ keys: [MongoIndexDraft.Key], _ edit: (inout MongoIndexDraft) -> Void
  ) -> MongoIndexDraft {
    var draft = MongoIndexDraft()
    draft.keys = keys
    edit(&draft)
    return draft
  }

  @Test(
    "The index draft refuses options its keys cannot take",
    arguments: [
      (
        draft([.init(field: "a"), .init(field: "b")]) { $0.ttlSeconds = "60" },
        "TTL needs a single-field index, not a compound key"
      ),
      (
        draft([.init(field: "a", kind: .wildcard)]) { $0.wildcardProjection = "{ b: 1 }" },
        "A wildcard projection needs a $** key"
      ),
      (
        draft([.init(field: "body", kind: .text)]) { $0.unique = true },
        "A text or wildcard index cannot be unique"
      ),
    ])
  func draftRefuses(draft: MongoIndexDraft, message: String) {
    #expect(draft.validationMessages() == [message])
    #expect(draft.command(collection: "c") == nil)
  }

  @Test(
    "A valid index draft renders mongosh text that parses back to the same createIndex",
    arguments: [
      (
        "c",
        draft([.init(field: "a.b", kind: .descending)]) {
          $0.name = "by_ab"
          $0.ttlSeconds = "3600"
          $0.partialFilter = "{ qty: { $gt: 5 } }"
          $0.collation = "{ locale: \"fr\", strength: 2 }"
        }
      ),
      (
        "my-coll",
        draft([.init(kind: .wildcard)]) {
          $0.sparse = true
          $0.wildcardProjection = "{ \"a.b\": 1, _id: 0 }"
          $0.hidden = true
        }
      ),
    ])
  func draftRoundTrip(collection: String, draft: MongoIndexDraft) throws {
    let command = try #require(draft.command(collection: collection))
    #expect(try MongoshParser.parse(command.render()) == .admin(command), "\(command.render())")
  }

  // MARK: - Collection and view drafts

  private static func collectionDraft(
    _ kind: MongoCollectionDraft.Kind, _ edit: (inout MongoCollectionDraft) -> Void = { _ in }
  ) -> MongoCollectionDraft {
    var draft = MongoCollectionDraft()
    draft.name = "events"
    draft.kind = kind
    edit(&draft)
    return draft
  }

  @Test(
    "The collection draft refuses a time series without a time field and capped without a size",
    arguments: [
      (collectionDraft(.timeSeries), "A time-series collection needs a time field"),
      (
        collectionDraft(.capped) { $0.cappedMax = "10" },
        "A capped collection needs a size in bytes"
      ),
    ])
  func collectionDraftRefuses(draft: MongoCollectionDraft, message: String) {
    #expect(draft.validationMessages() == [message])
    #expect(draft.command() == nil)
  }

  @Test(
    "A valid collection draft renders mongosh text that parses back to the same createCollection",
    arguments: [
      collectionDraft(.capped) { $0.cappedSize = "2147483648" },
      collectionDraft(.timeSeries) {
        $0.name = "my-metrics"
        $0.timeField = "ts"
        $0.metaField = "sensor"
        $0.granularity = .minutes
        $0.expireAfterSeconds = "86400"
      },
    ])
  func collectionDraftRoundTrip(draft: MongoCollectionDraft) throws {
    let command = try #require(draft.command())
    #expect(try MongoshParser.parse(command.render()) == .admin(command), "\(command.render())")
  }

  @Test("A capped size above Int32.max is sent as int64")
  func cappedSizeInt64() throws {
    let draft = Self.collectionDraft(.capped) { $0.cappedSize = "2147483648" }
    let command = try #require(draft.command())
    guard case .createCollection(_, .document(let options)?) = command else {
      Issue.record("not a createCollection with options: \(command)")
      return
    }
    #expect(options.first { $0.key == "size" }?.value == MongoValue.int64(2_147_483_648))
  }

  @Test("Editing a view sends collMod with viewOn and pipeline, which parses back")
  func viewEditRoundTrip() throws {
    let draft = MongoViewDraft(
      editedName: "big_orders", name: "big_orders", source: "orders",
      definition: "[ { $match: { n: { $gt: 1 } } } ]")
    let command = try #require(draft.command())
    let stage = doc(("$match", doc(("n", doc(("$gt", .int32(1)))))))
    #expect(
      command
        == .collMod(
          collection: "big_orders",
          options: doc(("viewOn", .string("orders")), ("pipeline", .array([stage])))))
    #expect(try MongoshParser.parse(command.render()) == .admin(command), "\(command.render())")
  }

  // MARK: - Validation rules

  /// Hand-built: an int64 above Int32.max and nested `properties`.
  private static func handBuiltRules() -> MongoValidationRules {
    let field = { (key: String, value: MongoValue) in MongoValue.Field(key, value) }
    let nested = MongoValue.document([
      field("bsonType", .string("object")),
      field(
        "properties", .document([field("b", .document([field("bsonType", .string("string"))]))])),
    ])
    let schema = MongoValue.document([
      field("bsonType", .string("object")),
      field("required", .array([.string("a")])),
      field(
        "properties",
        .document([
          field(
            "a",
            .document([field("bsonType", .string("long")), field("minimum", .int64(3_000_000_000))])
          ),
          field("nested", nested),
        ])),
    ])
    return MongoValidationRules(
      validator: .document([field("$jsonSchema", schema)]), level: .moderate, action: .warn)
  }

  /// From a sampled report with a nested document.
  private static func sampledRules() throws -> MongoValidationRules {
    let documents = try ["{a: 1, nested: {b: 'x'}}", "{a: 2, nested: {b: 'y', c: true}}"].map {
      try MongoRelaxedJSON.parse($0)
    }
    let report = MongoSchemaAnalyzer.analyze(documents, calendar: Calendar(identifier: .gregorian))
    return MongoValidationRules(
      validator: try MongoValidationRules.fromSample(report), level: .off, action: .errorAndLog)
  }

  @Test(
    "Validation rules render as collMod that parses back, and their editor text reads back",
    arguments: [false, true])
  func validationRulesRoundTrip(sampled: Bool) throws {
    let rules = sampled ? try Self.sampledRules() : Self.handBuiltRules()
    guard case .document(let top) = rules.validator, case .document(let schema)? = top.first?.value,
      !schema.isEmpty
    else {
      Issue.record("no $jsonSchema document: \(rules.validator)")
      return
    }
    let command = rules.command(collection: "orders")
    #expect(try MongoshParser.parse(command.render()) == .admin(command), "\(command.render())")
    #expect(
      try MongoValidationRules(
        validatorText: rules.validatorText, level: rules.level, action: rules.action) == rules,
      "\(rules.validatorText)")
    guard case .collMod(_, let options) = command else {
      Issue.record("not collMod: \(command)")
      return
    }
    #expect(MongoValidationRules(options: options) == rules)
  }

  @Test(
    "A validator with server-side JavaScript is refused; a plain $jsonSchema is accepted",
    arguments: [
      ("{ $where: \"this.a > 1\" }", false),
      (
        "{ $expr: { $function: { body: \"function() { return true }\", args: [], lang: \"js\" } } }",
        false
      ),
      ("{ $jsonSchema: { required: [\"name\"] } }", true),
    ])
  func validatorRefusesServerSideJavaScript(text: String, isAccepted: Bool) {
    let result = Result { () throws(MongoRelaxedJSON.ParseError) in
      try MongoValidationRules(validatorText: text, level: .strict, action: .error)
    }
    switch result {
    case .success: #expect(isAccepted, "\(text)")
    case .failure(let error):
      #expect(!isAccepted, "\(text): \(error.message)")
      #expect(error.message == "Server-side JavaScript is not allowed in a validator")
    }
  }

  // MARK: - Database commands

  @Test(
    "The three database command forms parse to their typed command and render back",
    arguments: [
      (
        "db.getSiblingDB(\"shop\").createCollection(\"c\", {capped: true, size: 4096})",
        MongoAdminCommand.createDatabase(
          database: "shop", collection: "c",
          options: .document([.init("capped", .bool(true)), .init("size", .int32(4096))]))
      ),
      ("db.getSiblingDB(\"shop\").dropDatabase()", .dropDatabase(database: "shop")),
      ("db.dropDatabase()", .dropDatabase(database: nil)),
      ("db /*a*/ .getSiblingDB( \"x\" ) // c\n.dropDatabase()", .dropDatabase(database: "x")),
    ])
  func databaseCommandRoundTrip(text: String, command: MongoAdminCommand) throws {
    #expect(try MongoshParser.parse(text) == .admin(command))
    #expect(try MongoshParser.parse(command.render()) == .admin(command), "\(command.render())")
  }

  @Test("Database commands run in their named database, dropDatabase() in the connection's")
  func databaseCommandRouting() throws {
    let create = try #require(
      MongoSession.writeCommand(
        .admin(.createDatabase(database: "shop", collection: "c", options: nil)), in: "db"))
    #expect(create.database == "shop")
    #expect(create.fields == [.init("create", .string("c"))])
    let drop = try #require(
      MongoSession.writeCommand(.admin(.dropDatabase(database: "shop")), in: "db"))
    #expect(drop.database == "shop")
    #expect(drop.fields == [.init("dropDatabase", .int32(1))])
    let current = try #require(
      MongoSession.writeCommand(.admin(.dropDatabase(database: nil)), in: "db"))
    #expect(current.database == "db")
  }

  @Test(
    "getSiblingDB is refused except before createCollection or dropDatabase on a valid name",
    arguments: [
      ("db.getSiblingDB(\"x\").c.find()", nil),
      ("db.getSiblingDB(\"x\")[\"c\"].find()", nil),
      ("db.getSiblingDB(\"x\").dropDatabase().c.find()", nil),
      ("db.getSiblingDB(\"x\").createCollection(\"c\").find()", nil),
      ("db.getSiblingDB(\"x\")", nil),
      ("db.getSiblingDB(\"x\").getSiblingDB(\"y\").dropDatabase()", nil),
      ("db.getSiblingDB(name).dropDatabase()", nil),
      ("db.getSiblingDB(\"admin\").dropDatabase()", "reserved"),
      ("db.getSiblingDB(\"\\u0061dmin\").dropDatabase()", "reserved"),
      ("db.getSiblingDB(\"Local\").dropDatabase()", "reserved"),
      ("db.getSiblingDB(\"config\").createCollection(\"c\")", "reserved"),
      ("db.getSiblingDB(\"a.b\").dropDatabase()", nil),
      ("db.getSiblingDB(\"x\").createCollection(\"c\", {writeConcern: {w: 0}})", nil),
      ("db.runCommand({dropDatabase: 1})", nil),
    ] as [(String, String?)])
  func databaseCommandRefused(text: String, reason: String?) {
    do {
      let command = try MongoshParser.parse(text)
      Issue.record("\(text) parsed as \(command)")
    } catch {
      if let reason { #expect(error.message.contains(reason), "\(text): \(error.message)") }
    }
  }

  @Test(
    "The session refuses a typed database command on a reserved name, before sending",
    arguments: [
      ("admin", .dropDatabase(database: nil)),
      ("local", .dropDatabase(database: nil)),
      ("config", .dropDatabase(database: nil)),
      ("db", .createDatabase(database: "admin", collection: "c", options: nil)),
      ("db", .dropDatabase(database: "CONFIG")),
    ] as [(String, MongoAdminCommand)])
  func sessionRefusesReservedDrop(database: String, command: MongoAdminCommand) async {
    let session = MongoSession(
      config: ConnectionConfig(
        databaseType: .mongodb, host: "localhost", port: 27017, database: database,
        username: "u", sslMode: .disable))
    do {
      _ = try await session.command(.admin(command))
      Issue.record("\(command) in \(database) was not refused")
    } catch {
      #expect((error as? MongoSessionError)?.message.contains("reserved") == true, "\(error)")
    }
  }

  @Test("A view pipeline with $out is refused")
  func viewDraftRefusesOut() {
    var draft = MongoViewDraft(editedName: nil, name: "v", source: "orders", definition: nil)
    draft.pipelineText = "[{ $match: {} }, { $out: \"copy\" }]"
    #expect(draft.validationMessages() == ["A view pipeline cannot write: remove the $out stage"])
    #expect(draft.command() == nil)
  }
}
