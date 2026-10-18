// MongoshParserTests.swift
// The mongosh subset parser: collection access forms, every method and find chain, refusal
// messages, error offsets, canonical rendering, and parse(render(c)) == c (table and random)

import Foundation
import Testing

@testable import Dblore

@Suite("mongosh parser")
struct MongoshParserTests {

  private static let hex = "507f1f77bcf86cd799439011"

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  private func parse(_ text: String) throws -> MongoCommand {
    try MongoshParser.parse(text)
  }

  private func parseError(_ text: String) -> MongoshParser.ParseError? {
    do {
      _ = try MongoshParser.parse(text)
      return nil
    } catch {
      return error
    }
  }

  /// UTF-16 offset of the first `marker` in `text`; `"$end"` is the end of the text.
  private func offset(of marker: String, in text: String) -> Int? {
    if marker == "$end" { return text.utf16.count }
    guard let range = text.range(of: marker) else { return nil }
    return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
  }

  private func find(
    _ collection: String, filter: MongoValue? = nil, projection: MongoValue? = nil,
    sort: MongoValue? = nil, skip: Int? = nil, limit: Int? = nil,
    options: MongoCommand.CursorOptions = .none
  ) -> MongoCommand {
    .find(
      collection: collection, filter: filter, projection: projection, sort: sort, skip: skip,
      limit: limit, options: options)
  }

  // MARK: - Access forms and methods

  @Test("Collection access forms, list commands, whitespace, comments and a trailing semicolon")
  func accessForms() throws {
    for text in [
      "db.users.find()", "db.getCollection(\"users\").find()", "db.getCollection('users').find()",
      "db['users'].find()", "db[\"users\"].find()", " db . users . find ( ) ; ",
      "// c\ndb./* x */users\n  .find()\n;\n// end",
    ] {
      #expect(try parse(text) == find("users"), "\(text)")
    }
    #expect(
      try parse("db.getCollection(\"a.b-c\").countDocuments()")
        == .countDocuments(collection: "a.b-c", filter: nil))
    #expect(
      try parse("db['my-coll'].countDocuments()")
        == .countDocuments(collection: "my-coll", filter: nil))
    #expect(try parse("db.stats.find()") == find("stats"))
    #expect(try parse("show collections") == .listCollections)
    #expect(try parse("show  collections ;") == .listCollections)
    #expect(try parse("db.getCollectionNames()") == .listCollections)
    #expect(MongoCommand.listCollections.collection == nil)
    #expect(find("users").collection == "users")
  }

  @Test("Every method, with and without its optional arguments")
  func methods() throws {
    let a1 = doc(("a", .int32(1)))
    let id1 = doc(("_id", .int32(1)))
    let set = doc(("$set", doc(("a", .int32(2)))))
    let cases: [(String, MongoCommand)] = [
      ("db.c.find({a: 1}, {b: 1})", find("c", filter: a1, projection: doc(("b", .int32(1))))),
      (
        "db.c.find({_id: ObjectId('\(Self.hex)')})",
        find("c", filter: doc(("_id", .objectId(MongoObjectId(hex: Self.hex)!))))
      ),
      (
        "db.c.aggregate([{$match: {a: 1}}, {$limit: 5}])",
        .aggregate(collection: "c", pipeline: [doc(("$match", a1)), doc(("$limit", .int32(5)))])
      ),
      ("db.c.aggregate([])", .aggregate(collection: "c", pipeline: [])),
      ("db.c.countDocuments()", .countDocuments(collection: "c", filter: nil)),
      ("db.c.countDocuments({a: 1})", .countDocuments(collection: "c", filter: a1)),
      ("db.c.distinct('a.b')", .distinct(collection: "c", field: "a.b", filter: nil)),
      ("db.c.distinct(\"a\", {a: 1})", .distinct(collection: "c", field: "a", filter: a1)),
      (
        "db.c.insertOne({_id: 1, a: 'x'})",
        .insertOne(collection: "c", document: doc(("_id", .int32(1)), ("a", .string("x"))))
      ),
      ("db.c.insertOne({})", .insertOne(collection: "c", document: .document([]))),
      (
        "db.c.insertMany([{a: 1}, {a: 2},])",
        .insertMany(collection: "c", documents: [a1, doc(("a", .int32(2)))])
      ),
      (
        "db.c.updateOne({_id: 1}, {$set: {a: 2}})",
        .updateOne(collection: "c", filter: id1, update: set)
      ),
      (
        "db.c.updateOne({}, {$set: {a: 2}}, {upsert: true})",
        .updateOne(collection: "c", filter: .document([]), update: set, upsert: true)
      ),
      (
        "db.c.updateMany({a: 1}, [{$set: {b: '$a'}}], {upsert: false})",
        .updateMany(
          collection: "c", filter: a1, update: .array([doc(("$set", doc(("b", .string("$a")))))]))
      ),
      (
        "db.c.updateMany({}, {$inc: {n: 1}, $unset: {x: ''}}, {})",
        .updateMany(
          collection: "c", filter: .document([]),
          update: doc(("$inc", doc(("n", .int32(1)))), ("$unset", doc(("x", .string(""))))))
      ),
      (
        "db.c.replaceOne({_id: 1}, {a: 1}, {upsert: true})",
        .replaceOne(collection: "c", filter: id1, replacement: a1, upsert: true)
      ),
      (
        "db.c.replaceOne({_id: 1}, {})",
        .replaceOne(collection: "c", filter: id1, replacement: .document([]))
      ),
      ("db.c.deleteOne({_id: 1})", .deleteOne(collection: "c", filter: id1)),
      ("db.c.deleteMany({})", .deleteMany(collection: "c", filter: .document([]))),
    ]
    for (text, command) in cases {
      #expect(try parse(text) == command, "\(text)")
    }
  }

  @Test("find chains: sort, skip and limit in any order, each at most once")
  func findChains() throws {
    let expected = find(
      "c", filter: doc(("a", .int32(1))), sort: doc(("b", .int32(-1))), skip: 5, limit: 10)
    for text in [
      "db.c.find({a: 1}).sort({b: -1}).skip(5).limit(10)",
      "db.c.find({a: 1}).limit(10).sort({b: -1}).skip(5)",
      "db.c.find({a: 1})\n  .skip(5)\n  // why\n  .limit(10)\n  .sort({b: -1});",
    ] {
      #expect(try parse(text) == expected, "\(text)")
    }
    #expect(try parse("db.c.find().limit(0)") == find("c", limit: 0))
    #expect(try parse("db.c.find().limit(-3).skip(NumberLong(7))") == find("c", skip: 7, limit: -3))
  }

  @Test("An empty document in an optional slot is the same as none")
  func emptyOptionalDocuments() throws {
    #expect(try parse("db.c.find({})") == find("c"))
    let projected = find("c", projection: doc(("a", .int32(1))))
    #expect(try parse("db.c.find({}, {a: 1})") == projected)
    #expect(projected.render() == "db.c.find({}, { a: 1 })")
    #expect(try parse("db.c.find({}, {}).sort({})") == find("c"))
    #expect(try parse("db.c.find().sort({})").render() == "db.c.find()")
    #expect(try parse("db.c.countDocuments({})") == .countDocuments(collection: "c", filter: nil))
    #expect(
      try parse("db.c.distinct('a', {})") == .distinct(collection: "c", field: "a", filter: nil))
  }

  // MARK: - Errors

  @Test("Methods outside the subset are refused with the subset message at the method name")
  func refusals() {
    let cases: [(text: String, name: String, at: String)] = [
      ("db.c.findOne({a: x})", "findOne", "findOne"),
      ("db.c.remove({})", "remove", "remove"),
      ("db.c.bulkWrite([])", "bulkWrite", "bulkWrite"),
      ("db.c.count()", "count", "count"),
      ("db.c.estimatedDocumentCount()", "estimatedDocumentCount", "estimatedDocumentCount"),
      ("db.c.find().toArray()", "toArray", "toArray"),
      ("db.c.find().pretty()", "pretty", "pretty"),
      ("db.c.find().count()", "count", "count"),
      ("db.c.aggregate([]).sort({a: 1})", "sort", "sort"),
      ("db.c.countDocuments().limit(1)", "limit", "limit"),
      ("db.getCollectionNames().forEach(print)", "forEach", "forEach"),
      ("db.dropAllUsers()", "dropAllUsers", "dropAllUsers"),
      ("db.c.drop().pretty()", "pretty", "pretty"),
      ("show dbs", "show dbs", "show"),
      ("use admin", "use", "use"),
      ("rs.status()", "rs", "rs"),
      ("var x = 1", "var", "var"),
    ]
    for item in cases {
      let error = parseError(item.text)
      #expect(
        error?.message == "\(item.name) is not supported in the Dblore MongoDB subset",
        "\(item.text)")
      #expect(error?.offset == offset(of: item.at, in: item.text), "\(item.text)")
    }
  }

  @Test("Malformed commands fail with their own message and a UTF-16 offset")
  func structuralErrors() {
    let update =
      "The update must be a document of update operators such as $set, or a pipeline array"
    let cases: [(text: String, message: String, at: String)] = [
      ("", "Expected a command such as db.<collection>.find()", "$end"),
      ("{a: 1}", "Expected a command such as db.<collection>.find()", "{"),
      ("db.c.find().limit(1).limit(2)", "limit can only be used once", "limit(2"),
      ("db.c.find().sort({a: 1}).sort({b: 1})", "sort can only be used once", "sort({b"),
      ("db.c.find().limit('5')", "limit needs an integer", "'5'"),
      ("db.c.find().skip(1.5)", "skip needs an integer", "1.5"),
      ("db.c.find().limit()", "limit needs an integer", "limit"),
      ("db.c.find().sort(1)", "The sort must be a document", "1)"),
      ("db.c.find(1)", "The filter must be a document", "1"),
      ("db.c.find({}, [1])", "The projection must be a document", "[1]"),
      (
        "db.c.find({}, {}, {})", "find options are not supported in the Dblore MongoDB subset",
        "{})"
      ),
      ("db.c.aggregate({$match: {}})", "aggregate needs a pipeline array", "{$match"),
      ("db.c.aggregate()", "aggregate needs a pipeline array", "aggregate"),
      ("db.c.aggregate([1])", "Each pipeline stage must be a document", "[1]"),
      (
        "db.c.aggregate([], {allowDiskUse: true})",
        "aggregate option allowDiskUse is not supported in the Dblore MongoDB subset", "{allow"
      ),
      (
        "db.c.countDocuments({}, {limit: 1, batchSize: 2})",
        "The option batchSize is not supported in the Dblore MongoDB subset", "{limit"
      ),
      (
        "db.c.countDocuments({}, {}, {})",
        "countDocuments takes at most a filter and an options document", "{})"
      ),
      ("db.c.find().explain().limit(1)", "explain must be the last method", "limit"),
      ("db.c.updateOne({}, {a: 1})", update, "{a"),
      ("db.c.updateOne({}, {})", update, "{})"),
      ("db.c.updateOne({}, [1])", "Each pipeline stage must be a document", "[1]"),
      (
        "db.c.updateMany({}, {$set: {a: 1}}, {multi: true})",
        "The option multi is not supported in the Dblore MongoDB subset", "{multi"
      ),
      (
        "db.c.updateOne({}, {$set: {a: 1}}, {upsert: 1})", "upsert must be true or false", "{upsert"
      ),
      ("db.c.updateOne({}, {$set: {a: 1}}, 1)", "The options must be a document", "1)"),
      ("db.c.updateOne({}, {$set: {a: 1}}, {}, {})", "updateOne takes at most 3 arguments", "{})"),
      ("db.c.updateOne({a: 1})", "updateOne needs a filter and an update", "updateOne"),
      ("db.c.updateOne(1, {$set: {a: 1}})", "The filter must be a document", "1,"),
      (
        "db.c.replaceOne({}, {$set: {a: 1}})",
        "The replacement must not contain update operators ($ keys)", "{$set"
      ),
      ("db.c.replaceOne({}, [])", "The replacement must be a document", "[]"),
      ("db.c.deleteMany()", "deleteMany needs a filter document", "deleteMany"),
      (
        "db.c.deleteOne({}, {})",
        "deleteOne options are not supported in the Dblore MongoDB subset", "{})"
      ),
      ("db.c.insertMany([])", "insertMany needs at least one document", "[]"),
      ("db.c.insertMany({a: 1})", "insertMany needs an array of documents", "{a"),
      ("db.c.insertMany([1])", "insertMany needs an array of documents", "[1]"),
      ("db.c.insertOne([{a: 1}])", "insertOne needs a document", "[{a"),
      ("db.c.distinct(1)", "distinct needs a field name string", "1"),
      ("db.c.d.find()", "Use db.getCollection(\"c.d\") for a collection name with dots", "d.find"),
      ("db.getCollection(1).find()", "getCollection needs a collection name string", "1)"),
      (
        "db.getCollection().find()", "getCollection needs a collection name string", "getCollection"
      ),
      ("db.getCollectionNames(1)", "getCollectionNames takes no arguments", "getCollectionNames"),
      ("db[\"\"].find()", "The collection name must not be empty", "\"\""),
      ("db[1].find()", "The collection name must be a string", "1"),
      ("db['c'.find()", "Expected ']'", ".find"),
      ("db", "Expected '.' or '[' after db", "$end"),
      ("db.c", "Expected a method such as .find() after the collection", "$end"),
      ("db.c.find", "Expected '(' after find", "$end"),
      ("db.c.find().", "Expected a method name", "$end"),
      ("db.c.find() db.d.find()", "Unexpected text after the command", "db.d"),
      ("db.c.find(); db.d.find()", "Unexpected text after the command", "db.d"),
      ("db.c.find({a: 1} {b: 2})", "Expected ',' or ')'", "{b"),
      ("db.c.find({a: x})", "Unknown identifier x", "x}"),
      ("db[\"😀\"].find({a: x})", "Unknown identifier x", "x}"),
      ("db.c.find(/* x", "Unterminated comment", "/*"),
      ("show", "Expected what to show, such as show collections", "$end"),
      (
        "db.runCommand({ping: 1})", "runCommand only supports collMod in the Dblore MongoDB subset",
        "{ping"
      ),
      (
        "db.runCommand({validator: {}, collMod: \"c\"})",
        "runCommand only supports collMod in the Dblore MongoDB subset", "{validator"
      ),
      (
        "db.c.renameCollection(\"d\", true)",
        "renameCollection takes only the new name (dropTarget is not supported)", "true"
      ),
      (
        "db.c.dropIndex(\"*\")", "dropIndex(\"*\") is not supported: drop one index at a time",
        "\"*\""
      ),
      (
        "db.runCommand({collMod: \"c\", $db: \"admin\"})",
        "The option $db is not supported in the Dblore MongoDB subset", "{collMod"
      ),
      (
        "db.createCollection(\"c\", {writeConcern: {w: 0}})",
        "The option writeConcern is not supported in the Dblore MongoDB subset", "{writeConcern"
      ),
    ]
    for item in cases {
      let error = parseError(item.text)
      #expect(error?.message == item.message, "\(item.text)")
      #expect(error?.offset == offset(of: item.at, in: item.text), "\(item.text)")
    }
  }

  @Test("Text over 1 MiB is refused")
  func inputLimit() {
    let text = "db.c.find({a: \"" + String(repeating: "x", count: 1_048_576) + "\"})"
    #expect(parseError(text)?.message == "The text is larger than 1 MiB")
  }

  // MARK: - Rendering and round-trips

  @Test("render writes canonical mongosh text that parses back to the same command")
  func renderAndRoundTripTable() throws {
    let a1 = doc(("a", .int32(1)))
    let id1 = doc(("_id", .int32(1)))
    let cases: [(MongoCommand, String)] = [
      (
        find(
          "users", filter: a1, projection: doc(("b", .int32(1))), sort: doc(("a", .int32(-1))),
          skip: 5, limit: 10),
        "db.users.find({ a: 1 }, { b: 1 }).sort({ a: -1 }).skip(5).limit(10)"
      ),
      (
        find(
          "c", filter: a1, sort: doc(("a", .int32(-1))), skip: 5, limit: 10,
          options: .init(
            collation: doc(("locale", .string("fr"))), hint: .string("a_1"), maxTimeMS: 500)),
        "db.c.find({ a: 1 }).sort({ a: -1 }).skip(5).limit(10).collation({ locale: \"fr\" })"
          + ".hint(\"a_1\").maxTimeMS(500)"
      ),
      (find("users"), "db.users.find()"),
      (find("Orders2", skip: 0, limit: 0), "db.Orders2.find().skip(0).limit(0)"),
      (find("c", limit: -5), "db.c.find().limit(-5)"),
      (.aggregate(collection: "a.b", pipeline: []), "db.getCollection(\"a.b\").aggregate([])"),
      (
        .aggregate(collection: "c", pipeline: [doc(("$match", a1))]),
        "db.c.aggregate([ { $match: { a: 1 } } ])"
      ),
      (
        .aggregate(
          collection: "c", pipeline: [doc(("$match", a1))],
          options: .init(
            collation: doc(("locale", .string("fr"))), hint: .string("a_1"), maxTimeMS: 500)),
        "db.c.aggregate([ { $match: { a: 1 } } ], { collation: { locale: \"fr\" }, hint: \"a_1\","
          + " maxTimeMS: 500 })"
      ),
      (
        .countDocuments(collection: "stats", filter: nil),
        "db.getCollection(\"stats\").countDocuments()"
      ),
      (
        .countDocuments(
          collection: "c", filter: nil,
          options: doc(
            ("skip", .int32(5)), ("limit", .int32(10)),
            ("collation", doc(("locale", .string("fr")))),
            ("hint", a1), ("maxTimeMS", .int32(500)))),
        "db.c.countDocuments({}, { skip: 5, limit: 10, collation: { locale: \"fr\" }, hint: { a: 1 },"
          + " maxTimeMS: 500 })"
      ),
      (
        .distinct(collection: "my-coll", field: "x", filter: a1),
        "db.getCollection(\"my-coll\").distinct(\"x\", { a: 1 })"
      ),
      (
        .insertOne(
          collection: "c", document: doc(("_id", .objectId(MongoObjectId(hex: Self.hex)!)))),
        "db.c.insertOne({ _id: ObjectId(\"\(Self.hex)\") })"
      ),
      (
        .insertMany(collection: "c", documents: [a1, doc(("a", .int64(2)))]),
        "db.c.insertMany([ { a: 1 }, { a: NumberLong(\"2\") } ])"
      ),
      (
        .updateOne(collection: "c", filter: id1, update: doc(("$set", doc(("a", .int32(2)))))),
        "db.c.updateOne({ _id: 1 }, { $set: { a: 2 } })"
      ),
      (
        .updateMany(
          collection: "c", filter: .document([]), update: doc(("$inc", doc(("n", .int32(1))))),
          upsert: true),
        "db.c.updateMany({}, { $inc: { n: 1 } }, { upsert: true })"
      ),
      (
        .updateMany(collection: "c", filter: a1, update: .array([doc(("$unset", .string("b")))])),
        "db.c.updateMany({ a: 1 }, [ { $unset: \"b\" } ])"
      ),
      (
        .replaceOne(collection: "c", filter: id1, replacement: doc(("a", .double(1.5)))),
        "db.c.replaceOne({ _id: 1 }, { a: 1.5 })"
      ),
      (.deleteOne(collection: "c", filter: id1), "db.c.deleteOne({ _id: 1 })"),
      (.deleteMany(collection: "c", filter: .document([])), "db.c.deleteMany({})"),
      (.listCollections, "show collections"),
      (
        .explain(find("c", filter: a1, limit: 5), verbosity: "executionStats"),
        "db.c.find({ a: 1 }).limit(5).explain(\"executionStats\")"
      ),
      (
        .explain(
          .aggregate(collection: "c", pipeline: [doc(("$match", a1))]), verbosity: "queryPlanner"),
        "db.c.aggregate([ { $match: { a: 1 } } ]).explain(\"queryPlanner\")"
      ),
      (find("_x"), "db.getCollection(\"_x\").find()"),
      (find("$cmd"), "db.getCollection(\"$cmd\").find()"),
      (find("getCollection"), "db.getCollection(\"getCollection\").find()"),
      (find("x\"y"), "db.getCollection(\"x\\\"y\").find()"),
      (
        .admin(
          .createIndex(
            collection: "c", keys: doc(("a", .int32(1)), ("b", .int32(-1))),
            options: doc(("unique", .bool(true)), ("partialFilterExpression", a1)))),
        "db.c.createIndex({ a: 1, b: -1 }, { unique: true, partialFilterExpression: { a: 1 } })"
      ),
      (.admin(.dropIndex(collection: "c", index: .string("a_1"))), "db.c.dropIndex(\"a_1\")"),
      (
        .admin(.setIndexHidden(collection: "c", name: "a_1", hidden: true)),
        "db.c.hideIndex(\"a_1\")"
      ),
      (
        .admin(.setIndexHidden(collection: "c", name: "a_1", hidden: false)),
        "db.c.unhideIndex(\"a_1\")"
      ),
      (
        .admin(
          .createCollection(
            name: "logs", options: doc(("capped", .bool(true)), ("size", .int32(4096))))),
        "db.createCollection(\"logs\", { capped: true, size: 4096 })"
      ),
      (
        .admin(.createView(name: "v", source: "c", pipeline: [doc(("$match", a1))], options: nil)),
        "db.createView(\"v\", \"c\", [ { $match: { a: 1 } } ])"
      ),
      (.admin(.drop(collection: "c")), "db.c.drop()"),
      (.admin(.renameCollection(collection: "c", to: "d")), "db.c.renameCollection(\"d\")"),
      (
        .admin(.collMod(collection: "c", options: doc(("validationLevel", .string("moderate"))))),
        "db.runCommand({ collMod: \"c\", validationLevel: \"moderate\" })"
      ),
    ]
    for (command, text) in cases {
      #expect(command.render() == text)
      #expect(try parse(command.render()) == command, "\(text)")
    }
  }

  @Test("parse(render(c)) == c for seeded random commands")
  func roundTripRandomCommands() throws {
    var rng = SplitMix64(seed: 0x3_2026_1014)
    for _ in 0..<400 {
      let command = randomCommand(rng: &rng)
      let text = command.render()
      #expect(try parse(text) == command, "\(text)")
    }
  }

  // MARK: - Random commands

  private static let collections = [
    "users", "a.b", "my-coll", "stats", "getCollection", "_x", "é", "c d", "x\"y", "$cmd",
    "Orders2",
  ]
  private static let fields = ["a", "a.b", "", "x\"y", "$v"]
  /// Never a lone Extended JSON wrapper key (`{$oid: …}` reads back as the wrapper).
  private static let keys = ["a", "_id", "b c", "", "é", "x.y", "q\"", "1"]
  private static let operators = ["$set", "$inc", "$unset", "$push"]
  private static let stages = ["$match", "$project", "$sort", "$out", "$merge"]

  private func randomCommand(rng: inout SplitMix64) -> MongoCommand {
    let name = Self.collections.randomElement(using: &rng)!
    switch Int.random(in: 0..<13, using: &rng) {
    case 0:
      let filter = optionalDocument(rng: &rng)
      return .find(
        collection: name, filter: filter, projection: optionalDocument(rng: &rng),
        sort: optionalDocument(rng: &rng), skip: optionalInt(rng: &rng),
        limit: optionalInt(rng: &rng))
    case 1:
      let count = Int.random(in: 0..<4, using: &rng)
      return .aggregate(
        collection: name,
        pipeline: (0..<count).map { _ in
          .document([MongoValue.Field(Self.stages.randomElement(using: &rng)!, document(rng: &rng))]
          )
        })
    case 2: return .countDocuments(collection: name, filter: optionalDocument(rng: &rng))
    case 3:
      return .distinct(
        collection: name, field: Self.fields.randomElement(using: &rng)!,
        filter: optionalDocument(rng: &rng))
    case 4: return .insertOne(collection: name, document: document(rng: &rng))
    case 5:
      let count = Int.random(in: 1..<4, using: &rng)
      return .insertMany(collection: name, documents: (0..<count).map { _ in document(rng: &rng) })
    case 6:
      return .updateOne(
        collection: name, filter: document(rng: &rng), update: update(rng: &rng),
        upsert: Bool.random(using: &rng))
    case 7:
      return .updateMany(
        collection: name, filter: document(rng: &rng), update: update(rng: &rng),
        upsert: Bool.random(using: &rng))
    case 8:
      return .replaceOne(
        collection: name, filter: document(rng: &rng), replacement: document(rng: &rng),
        upsert: Bool.random(using: &rng))
    case 9: return .deleteOne(collection: name, filter: document(rng: &rng))
    case 10: return .deleteMany(collection: name, filter: document(rng: &rng))
    case 11: return .admin(adminCommand(name, rng: &rng))
    default: return .listCollections
    }
  }

  private static let createIndexOptions = ["name", "unique", "partialFilterExpression", "hidden"]
  private static let createCollectionOptions = ["capped", "size", "validator", "validationLevel"]
  private static let collModOptions = ["validator", "validationLevel", "expireAfterSeconds"]

  private func adminCommand(_ name: String, rng: inout SplitMix64) -> MongoAdminCommand {
    let other = Self.collections.randomElement(using: &rng)!
    switch Int.random(in: 0..<8, using: &rng) {
    case 0:
      return .createIndex(
        collection: name, keys: nonEmptyDocument(rng: &rng),
        options: adminOptions(Self.createIndexOptions, rng: &rng))
    case 1:
      let index: MongoValue =
        Bool.random(using: &rng) ? .string(other) : nonEmptyDocument(rng: &rng)
      return .dropIndex(collection: name, index: index)
    case 2:
      return .setIndexHidden(collection: name, name: other, hidden: Bool.random(using: &rng))
    case 3:
      return .createCollection(
        name: name, options: adminOptions(Self.createCollectionOptions, rng: &rng))
    case 4:
      let count = Int.random(in: 0..<3, using: &rng)
      return .createView(
        name: name, source: other,
        pipeline: (0..<count).map { _ in
          .document([MongoValue.Field(Self.stages.randomElement(using: &rng)!, document(rng: &rng))]
          )
        },
        options: adminOptions(["collation"], rng: &rng))
    case 5: return .drop(collection: name)
    case 6: return .renameCollection(collection: name, to: other)
    default:
      return .collMod(
        collection: name, options: adminOptions(Self.collModOptions, rng: &rng) ?? .document([]))
    }
  }

  /// Nil or a non-empty document of distinct `allowed` keys (an empty one parses back as nil).
  private func adminOptions(_ allowed: [String], rng: inout SplitMix64) -> MongoValue? {
    let keys = allowed.filter { _ in Bool.random(using: &rng) }
    guard !keys.isEmpty else { return nil }
    return .document(keys.map { MongoValue.Field($0, value(rng: &rng, depth: 0)) })
  }

  private func nonEmptyDocument(rng: inout SplitMix64) -> MongoValue {
    let value = document(rng: &rng)
    return value == .document([]) ? doc(("a", .int32(1))) : value
  }

  /// Nil or a non-empty document (an empty one parses back as nil).
  private func optionalDocument(rng: inout SplitMix64) -> MongoValue? {
    guard Bool.random(using: &rng) else { return nil }
    let value = document(rng: &rng)
    return value == .document([]) ? doc(("a", .int32(1))) : value
  }

  private func optionalInt(rng: inout SplitMix64) -> Int? {
    switch Int.random(in: 0..<3, using: &rng) {
    case 0: nil
    case 1: Int.random(in: -50...50, using: &rng)
    default: Int(truncatingIfNeeded: rng.next())
    }
  }

  private func update(rng: inout SplitMix64) -> MongoValue {
    let count = Int.random(in: 1..<3, using: &rng)
    if Bool.random(using: &rng) {
      return .array((0..<count).map { _ in doc(("$set", document(rng: &rng))) })
    }
    return .document(
      (0..<count).map { _ in
        MongoValue.Field(Self.operators.randomElement(using: &rng)!, document(rng: &rng))
      })
  }

  private func document(rng: inout SplitMix64, depth: Int = 0) -> MongoValue {
    let count = Int.random(in: 0..<4, using: &rng)
    return .document(
      (0..<count).map { _ in
        MongoValue.Field(Self.keys.randomElement(using: &rng)!, value(rng: &rng, depth: depth))
      })
  }

  private func value(rng: inout SplitMix64, depth: Int) -> MongoValue {
    switch Int.random(in: 0..<(depth < 2 ? 11 : 9), using: &rng) {
    case 0: return .int32(Int32(truncatingIfNeeded: rng.next()))
    case 1: return .int64(Int64(truncatingIfNeeded: rng.next()))
    case 2: return .double(Double(Int.random(in: -1000...1000, using: &rng)) / 8)
    case 3: return .string(["", "x", "a;b", "'q'", "é😀", "\n"].randomElement(using: &rng)!)
    case 4: return .bool(Bool.random(using: &rng))
    case 5: return .null
    case 6: return .objectId(MongoObjectId(hex: Self.hex)!)
    case 7: return .date(Int64.random(in: -10_000_000_000_000...10_000_000_000_000, using: &rng))
    case 8: return .regex(pattern: ["a", "a/b", "x;y"].randomElement(using: &rng)!, options: "i")
    case 9:
      let count = Int.random(in: 0..<3, using: &rng)
      return .array((0..<count).map { _ in value(rng: &rng, depth: depth + 1) })
    default: return document(rng: &rng, depth: depth + 1)
    }
  }
}

/// Deterministic generator for the random round-trip test.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
