// MongoCommandRewriterTests.swift
// The row-cap rewrite: find limits (none, 0, negative, Int.min, below and above the cap),
// aggregate `$limit` stages (skipped after `$out`/`$merge`), other commands, and the text form

import Foundation
import Testing

@testable import Dblore

@Suite("mongosh row-cap rewriter")
struct MongoCommandRewriterTests {

  private func find(limit: Int?) -> MongoCommand {
    .find(
      collection: "c", filter: .document([MongoValue.Field("a", .int32(1))]),
      projection: .document([MongoValue.Field("b", .int32(1))]),
      sort: .document([MongoValue.Field("a", .int32(-1))]), skip: 4, limit: limit)
  }

  private func limit(of command: MongoCommand) -> Int? {
    guard case .find(_, _, _, _, _, let limit, _) = command else { return nil }
    return limit
  }

  private func limitStage(_ value: Int64) -> MongoValue {
    .document([MongoValue.Field("$limit", .int64(value))])
  }

  // MARK: - find

  @Test(
    "find: missing or 0 limit is unlimited, negative counts as its absolute value",
    arguments: [
      (nil, 1001), (0, 1001), (1, 1), (5, 5), (1000, 1000), (1001, 1001), (1002, 1001),
      (5000, 1001), (-1, 1), (-5, 5), (-1001, 1001), (-5000, 1001), (Int.min, 1001),
      (Int.max, 1001),
    ] as [(Int?, Int)])
  func findLimit(written: Int?, expected: Int) {
    let rewritten = MongoCommandRewriter.withLimit(find(limit: written), maxRows: 1000)
    #expect(rewritten == find(limit: expected))
  }

  @Test("find: maxRows 0 or negative caps at 1; maxRows Int.max does not overflow")
  func findEdgeCaps() {
    for written in [nil, 0, 1, 7, -3, Int.min, Int.max] as [Int?] {
      for maxRows in [0, -1, Int.min] {
        #expect(
          limit(of: MongoCommandRewriter.withLimit(find(limit: written), maxRows: maxRows)) == 1)
      }
    }
    #expect(limit(of: MongoCommandRewriter.withLimit(find(limit: nil), maxRows: .max)) == .max)
    #expect(limit(of: MongoCommandRewriter.withLimit(find(limit: Int.min), maxRows: .max)) == .max)
    #expect(limit(of: MongoCommandRewriter.withLimit(find(limit: -9), maxRows: .max)) == 9)
  }

  @Test("find: the limit is always in 1...maxRows + 1")
  func findLimitRange() throws {
    let limits: [Int?] = [
      nil, 0, 1, -1, 2, -2, 199, 200, 201, 202, -201, -202, .max, .min, .min + 1,
    ]
    for maxRows in [0, 1, 2, 199, 200, 1000] {
      for written in limits {
        let capped = try #require(
          limit(of: MongoCommandRewriter.withLimit(find(limit: written), maxRows: maxRows)))
        #expect((1...(maxRows + 1)).contains(capped), "\(String(describing: written)) \(maxRows)")
      }
    }
  }

  // MARK: - aggregate

  @Test("aggregate: appends {$limit: NumberLong(maxRows + 1)}")
  func aggregateAppendsLimit() {
    let match = MongoValue.document([MongoValue.Field("$match", .document([]))])
    let limitFive = MongoValue.document([MongoValue.Field("$limit", .int32(5))])
    let cases: [([MongoValue], [MongoValue])] = [
      ([], [limitStage(201)]),
      ([match], [match, limitStage(201)]),
      ([match, limitFive], [match, limitFive, limitStage(201)]),
      // `$out` not last: the server rejects the pipeline either way
      (
        [.document([MongoValue.Field("$out", .string("x"))]), match],
        [.document([MongoValue.Field("$out", .string("x"))]), match, limitStage(201)]
      ),
    ]
    for (pipeline, expected) in cases {
      #expect(
        MongoCommandRewriter.withLimit(
          .aggregate(collection: "c", pipeline: pipeline), maxRows: 200)
          == .aggregate(collection: "c", pipeline: expected))
    }
    #expect(
      MongoCommandRewriter.withLimit(.aggregate(collection: "c", pipeline: []), maxRows: 0)
        == .aggregate(collection: "c", pipeline: [limitStage(1)]))
  }

  @Test("aggregate: unchanged when the last stage is $out or $merge")
  func aggregateWritesUnchanged() throws {
    for text in [
      "db.c.aggregate([{$match: {a: 1}}, {$out: \"copy\"}])",
      "db.c.aggregate([{$out: {db: \"o\", coll: \"copy\"}}])",
      "db.c.aggregate([{$match: {a: 1}}, {$merge: {into: \"copy\"}}])",
    ] {
      let command = try MongoshParser.parse(text)
      #expect(MongoCommandRewriter.withLimit(command, maxRows: 200) == command, "\(text)")
    }
  }

  // MARK: - Other commands

  @Test("Commands other than find and aggregate are unchanged")
  func otherCommandsUnchanged() throws {
    for text in [
      "db.c.countDocuments({a: 1})", "db.c.distinct(\"a\")", "show collections",
      "db.c.insertOne({a: 1})", "db.c.insertMany([{a: 1}])", "db.c.updateOne({}, {$set: {a: 1}})",
      "db.c.updateMany({}, {$set: {a: 1}})", "db.c.replaceOne({}, {a: 1})", "db.c.deleteOne({})",
      "db.c.deleteMany({})",
    ] {
      let command = try MongoshParser.parse(text)
      #expect(MongoCommandRewriter.withLimit(command, maxRows: 200) == command, "\(text)")
    }
  }

  // MARK: - Text

  @Test("Text form: parses, caps and renders canonical mongosh; throws on bad text")
  func textForm() throws {
    #expect(
      try MongoCommandRewriter.withLimit(text: "db['c'].find({a: 1}) // note", maxRows: 200)
        == "db.c.find({ a: 1 }).limit(201)")
    #expect(
      try MongoCommandRewriter.withLimit(text: "db.c.find().limit(-3)", maxRows: 200)
        == "db.c.find().limit(3)")
    #expect(
      try MongoCommandRewriter.withLimit(text: "db.c.aggregate([])", maxRows: 200)
        == "db.c.aggregate([ { $limit: NumberLong(\"201\") } ])")
    #expect(throws: MongoshParser.ParseError.self) {
      try MongoCommandRewriter.withLimit(text: "db.c.find().toArray()", maxRows: 200)
    }
  }
}
