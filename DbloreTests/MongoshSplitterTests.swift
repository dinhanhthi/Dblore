// MongoshSplitterTests.swift
// Splitting a mongosh cell into commands: top-level semicolons, newlines after a complete
// command, leading-dot chain continuation, comments, CRLF, and unbalanced input

import Foundation
import Testing

@testable import Dblore

@Suite("mongosh splitter")
struct MongoshSplitterTests {

  private func split(_ text: String) -> [String] {
    MongoshSplitter.split(text)
  }

  @Test("Splits at top-level semicolons, never inside strings, documents, regexes or comments")
  func semicolons() {
    #expect(split("db.a.find(); db.b.find();") == ["db.a.find()", "db.b.find()"])
    let quoted = #"db.a.find({s: "x;y", t: 'u;\'v', e: "\";"})"#
    #expect(split(quoted + "; db.b.find()") == [quoted, "db.b.find()"])
    #expect(split("db.a.find({a: 1; b: 2})") == ["db.a.find({a: 1; b: 2})"])
    #expect(
      split("db.a.find({a: /x;y/i}); db.b.find()") == ["db.a.find({a: /x;y/i})", "db.b.find()"])
    #expect(
      split("db.a.find({a: /[/;]/}); db.b.find()") == ["db.a.find({a: /[/;]/})", "db.b.find()"])
    #expect(split("db.a.find() // x; y\n") == ["db.a.find() // x; y"])
    #expect(split("db.a.find(/* ; */); db.b.find()") == ["db.a.find(/* ; */)", "db.b.find()"])
  }

  @Test("Splits at a newline after a complete command")
  func newlines() {
    #expect(split("db.a.find()\ndb.b.find()") == ["db.a.find()", "db.b.find()"])
    let insert = "db.a.insertOne({\n  a: 1,\n  b: [\n    2\n  ]\n})"
    #expect(split(insert + "\ndb.b.find()") == [insert, "db.b.find()"])
    #expect(split("db.a.find(\n)\n\n\n   db.b.find()   \n\n") == ["db.a.find(\n)", "db.b.find()"])
    #expect(split("db.a.\nfind()") == ["db.a.\nfind()"])
    #expect(
      split("show collections\ndb.getCollectionNames()")
        == ["show collections", "db.getCollectionNames()"])
  }

  @Test("A line starting with '.' continues the chain, across blank lines and comments")
  func leadingDot() {
    let chain = "db.c.find({a: 1})\n  .sort({a: 1})\n  .limit(5)"
    #expect(split(chain + "\ndb.d.find()") == [chain, "db.d.find()"])
    let spaced = "db.c.find()\n\n  // sorted\n  /* by a */\n  .sort({a: 1})"
    #expect(split(spaced) == [spaced])
  }

  @Test("Blank and comment-only pieces are dropped; comments stay with their command")
  func blanksAndComments() {
    #expect(split("") == [])
    #expect(split(" \n\t\r\n ;; ; ") == [])
    #expect(split("// only a comment") == [])
    #expect(split("/* a */ ; // b\n") == [])
    #expect(split("// header\ndb.a.find()") == ["// header\ndb.a.find()"])
    #expect(split("db.a.find() // trailing\n// done\n/* end */") == ["db.a.find() // trailing"])
    #expect(
      split("db.a.find(); /* note */ db.b.find() /* x */")
        == ["db.a.find()", "/* note */ db.b.find() /* x */"])
    #expect(
      split("db.a.find() /* multi\nline */\ndb.b.find()")
        == ["db.a.find() /* multi\nline */", "db.b.find()"])
  }

  @Test("CRLF and lone CR line endings")
  func carriageReturns() {
    #expect(split("db.a.find()\r\ndb.b.find()\r\n") == ["db.a.find()", "db.b.find()"])
    #expect(
      split("db.a.find()\r\n  .limit(1)\r\ndb.b.find()")
        == ["db.a.find()\r\n  .limit(1)", "db.b.find()"])
    #expect(split("db.a.find()\rdb.b.find()") == ["db.a.find()", "db.b.find()"])
  }

  @Test("Unbalanced input never crashes: an unterminated string, bracket or comment takes the rest")
  func unbalanced() {
    for text in [
      "db.a.find({a: 1\ndb.b.find(); db.c.find()",
      "db.a.find({a: \"x;\ndb.b.find()",
      "db.a.find() /* open; \ndb.b.find()",
      "db.a.find({s: 'x\\",
      "db.a.find({a: /x",
    ] {
      #expect(split(text) == [text], "\(text)")
    }
    #expect(split("db.a.find()); db.b.find()") == ["db.a.find())", "db.b.find()"])
    #expect(
      split("db.a.find({a: /x;\n}); db.b.find()") == ["db.a.find({a: /x;\n})", "db.b.find()"])
    #expect(split("]]}};)(") == ["]]}}", ")("])
  }

  @Test("Text above 1 MiB is one piece, left whole for the parser to refuse")
  func sizeLimit() {
    let command = "db.a.find()\n"
    let count = MongoRelaxedJSON.maxInputBytes / command.utf8.count + 1
    let text = String(repeating: command, count: count) + "db.b.deleteMany({})"
    #expect(text.utf8.count > MongoRelaxedJSON.maxInputBytes)
    #expect(split(text) == [text])
    #expect(MongoCommandClassifier.classify(text).map(\.kind) == [.unknown])
  }

  @Test("A line of unclosed regex literals splits in linear time", .timeLimit(.minutes(1)))
  func unclosedRegexLine() {
    let text = String(repeating: "/[", count: 300_000)
    var pieces: [String] = []
    let elapsed = ContinuousClock().measure { pieces = split(text) }
    #expect(pieces == [text])
    #expect(elapsed < .seconds(2))
  }

  @Test("Pieces are exact substrings that the parser accepts")
  func exactSubstrings() throws {
    #expect(
      split("db.c.find({a: \"é😀\"});\ndb[\"ü\"].find()")
        == ["db.c.find({a: \"é😀\"})", "db[\"ü\"].find()"])
    let script = """
      db.a.find({a: 1})
        .limit(2);
      show collections
      db.b.updateOne({_id: 1},
        {$set: {x: 'a;b'}})
      """
    let commands = try split(script).map { try MongoshParser.parse($0) }
    #expect(
      commands == [
        .find(
          collection: "a", filter: .document([MongoValue.Field("a", .int32(1))]), projection: nil,
          sort: nil, skip: nil, limit: 2),
        .listCollections,
        .updateOne(
          collection: "b", filter: .document([MongoValue.Field("_id", .int32(1))]),
          update: .document([
            MongoValue.Field("$set", .document([MongoValue.Field("x", .string("a;b"))]))
          ])),
      ])
  }
}
