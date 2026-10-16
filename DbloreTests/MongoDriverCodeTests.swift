// MongoDriverCodeTests.swift
// Driver code export: key tokens of a find with every option and of an aggregate in each
// language, and the imports / connection toggles plus the commands that have no export.

import Foundation
import Testing

@testable import Dblore

@Suite("MongoDB driver code export")
struct MongoDriverCodeTests {

  enum Shape: CaseIterable { case find, aggregate }

  private static let hex = "65a1b2c3d4e5f60718293a4b"
  /// 2024-01-02T03:04:05.678Z
  private static let dateMs: Int64 = 1_704_164_645_678
  /// The Swift string `say "hi" \ done`.
  private static let tricky = "say \"hi\" \\ done"
  /// The same text as a double-quoted literal, in every target language.
  private static let trickyLiteral = #""say \"hi\" \\ done""#

  private static let find = MongoCommand.find(
    collection: "orders",
    filter: .document([
      MongoValue.Field("_id", .objectId(MongoObjectId(hex: hex)!)),
      MongoValue.Field("createdAt", .document([MongoValue.Field("$gte", .date(dateMs))])),
      MongoValue.Field("note", .string(tricky)),
    ]),
    projection: .document([MongoValue.Field("note", .int32(1))]),
    sort: .document([MongoValue.Field("createdAt", .int32(-1))]),
    skip: 10, limit: 5,
    options: MongoCommand.CursorOptions(
      collation: .document([
        MongoValue.Field("locale", .string("fr")), MongoValue.Field("strength", .int32(2)),
      ]),
      hint: .string("createdAt_1"), maxTimeMS: 500))

  private static let aggregate = MongoCommand.aggregate(
    collection: "orders",
    pipeline: [
      .document([
        MongoValue.Field("$match", .document([MongoValue.Field("status", .string("paid"))]))
      ]),
      .document([
        MongoValue.Field(
          "$group",
          .document([
            MongoValue.Field("_id", .string("$customer")),
            MongoValue.Field(
              "total", .document([MongoValue.Field("$sum", .string("$amount"))])),
          ]))
      ]),
    ])

  private static func tokens(_ language: MongoDriverCode.Language, _ shape: Shape) -> [String] {
    switch (language, shape) {
    case (.node, .find):
      return [
        "collection.find(", "projection:", "sort:", "skip: 10", "limit: 5",
        #"collation: { "locale": "fr""#, #"hint: "createdAt_1""#, "maxTimeMS: 500",
        #"new ObjectId("\#(hex)")"#, #"new Date("2024-01-02T03:04:05.678Z")"#, trickyLiteral,
      ]
    case (.node, .aggregate):
      return ["collection.aggregate([", #""$match": { "status": "paid" }"#, #""$group""#]
    case (.python, .find):
      return [
        "collection.find(", #"sort=[("createdAt", -1)]"#, "skip=10", "limit=5",
        #"collation={"locale": "fr""#, #"hint="createdAt_1""#, "max_time_ms=500",
        #"ObjectId("\#(hex)")"#,
        "datetime(2024, 1, 2, 3, 4, 5, 678000, tzinfo=timezone.utc)", trickyLiteral,
      ]
    case (.python, .aggregate):
      return ["collection.aggregate([", #"{"$match": {"status": "paid"}}"#, #""$group""#]
    case (.java, .find):
      return [
        "collection.find(", ".projection(", ".sort(", ".skip(10)", ".limit(5)",
        #"Collation.builder().locale("fr")"#, "CollationStrength.fromInt(2)",
        #".hintString("createdAt_1")"#, ".maxTime(500, TimeUnit.MILLISECONDS)",
        #"new ObjectId("\#(hex)")"#, #"Date.from(Instant.parse("2024-01-02T03:04:05.678Z"))"#,
        trickyLiteral,
      ]
    case (.java, .aggregate):
      return [
        "collection.aggregate(Arrays.asList(", #"new Document("$match", new Document("status""#,
        #"new Document("$group""#,
      ]
    case (.go, .find):
      return [
        "coll.Find(", "SetProjection(", "SetSort(", "SetSkip(10)", "SetLimit(5)",
        #"SetCollation(&options.Collation{Locale: "fr", Strength: 2})"#,
        #"SetHint("createdAt_1")"#, "context.WithTimeout(ctx, 500*time.Millisecond)",
        "bson.ObjectIDFromHex(", #"objectID("\#(hex)")"#,
        "time.Date(2024, 1, 2, 3, 4, 5, 678000000, time.UTC)", trickyLiteral,
      ]
    case (.go, .aggregate):
      return [
        "coll.Aggregate(ctx, pipeline)", "mongo.Pipeline{", #"{Key: "$match", Value: bson.D{"#,
        #"{Key: "$group""#,
      ]
    case (.csharp, .find):
      return [
        "collection.Find(", ".Project(", ".Sort(", ".Skip(10)", ".Limit(5)",
        "Collation.FromBsonDocument(", #"Hint = "createdAt_1""#,
        "MaxTime = TimeSpan.FromMilliseconds(500)", #"ObjectId.Parse("\#(hex)")"#,
        "new BsonDateTime(new DateTime(2024, 1, 2, 3, 4, 5, 678, DateTimeKind.Utc))",
        trickyLiteral,
      ]
    case (.csharp, .aggregate):
      return ["collection.Aggregate(pipeline)", #"{ "$match", new BsonDocument"#, #"{ "$group""#]
    }
  }

  @Test(
    "find with every option and aggregate render the driver calls and literals",
    arguments: MongoDriverCode.Language.allCases, Shape.allCases)
  func keyTokens(language: MongoDriverCode.Language, shape: Shape) throws {
    let command = shape == .find ? Self.find : Self.aggregate
    let code = try #require(
      MongoDriverCode.code(
        for: command, database: "shop", language: language, includeImports: false,
        includeConnection: false))
    for token in Self.tokens(language, shape) {
      #expect(code.contains(token), "\(language) \(shape) is missing \(token):\n\(code)")
    }
  }

  @Test("imports and connection appear only when toggled; other commands have no export")
  func togglesAndUnsupported() throws {
    let importMarkers: [MongoDriverCode.Language: String] = [
      .node: "require(\"mongodb\")", .python: "from bson import", .java: "import org.bson.",
      .go: "\"go.mongodb.org/mongo-driver/v2/bson\"", .csharp: "using MongoDB.Bson;",
    ]
    for language in MongoDriverCode.Language.allCases {
      let marker = try #require(importMarkers[language])
      for (imports, connection) in [(false, false), (true, false), (false, true), (true, true)] {
        let code = try #require(
          MongoDriverCode.code(
            for: Self.find, database: "shop", language: language, includeImports: imports,
            includeConnection: connection))
        #expect(code.contains(marker) == imports, "\(language) imports \(imports):\n\(code)")
        #expect(code.contains("MONGODB_URI") == connection, "\(language):\n\(code)")
        #expect(code.contains("\"shop\"") == connection, "\(language):\n\(code)")
      }
      let count = MongoCommand.countDocuments(collection: "orders", filter: nil)
      let update = MongoCommand.updateOne(
        collection: "orders", filter: .document([]),
        update: .document([MongoValue.Field("$set", .document([MongoValue.Field("a", .int32(1))]))])
      )
      for command in [count, update, .explain(Self.find, verbosity: "executionStats")] {
        #expect(
          MongoDriverCode.code(
            for: command, database: "shop", language: language, includeImports: true,
            includeConnection: true) == nil)
      }
    }
  }
}
