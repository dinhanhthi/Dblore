// DriverCodeSyntaxHighlighterTests.swift
// Token categories of the driver code highlighter (Export Code sheet) for each driver language.

import Foundation
import Testing

@testable import Dblore

@Suite("Driver Code Syntax Highlighter Tests")
@MainActor
struct DriverCodeSyntaxHighlighterTests {
  typealias TokenType = SQLSyntaxHighlighter.TokenType
  typealias Language = MongoDriverCode.Language

  // MARK: - Helpers

  /// Type of the single token that exactly covers the first `needle`, nil if none does
  private func type(of needle: String, in text: String, _ language: Language) -> TokenType? {
    let target = (text as NSString).range(of: needle)
    return DriverCodeSyntaxHighlighter.tokens(in: text, language: language)
      .first { $0.range == target }?.type
  }

  // MARK: - Languages

  @Test("Node.js")
  func node() {
    let text = """
      // Expects `collection`.
      const cursor = collection.find({ "qty": { "$gt": 5.5 } }).limit(10);
      """
    #expect(type(of: "// Expects `collection`.", in: text, .node) == .comment)
    #expect(type(of: "const", in: text, .node) == .keyword)
    #expect(type(of: "find", in: text, .node) == .function)
    #expect(type(of: "limit", in: text, .node) == .function)
    #expect(type(of: "\"$gt\"", in: text, .node) == .string)
    #expect(type(of: "5.5", in: text, .node) == .number)
    #expect(type(of: "10", in: text, .node) == .number)
    #expect(type(of: "cursor", in: text, .node) == nil)
    // Constants stay in the default color
    #expect(type(of: "MONGODB_URI", in: "const uri = process.env.MONGODB_URI;", .node) == nil)
  }

  @Test("Python")
  func python() {
    let text = """
      # Expects `collection`.
      cursor = collection.find({"done": True, "tag": None}, limit=3)
      """
    #expect(type(of: "# Expects `collection`.", in: text, .python) == .comment)
    #expect(type(of: "True", in: text, .python) == .keyword)
    #expect(type(of: "None", in: text, .python) == .keyword)
    #expect(type(of: "find", in: text, .python) == .function)
    #expect(type(of: "3", in: text, .python) == .number)
  }

  @Test("Java")
  func java() {
    let text = #"FindIterable<Document> cursor = collection.find(new Document("n", 5L));"#
    #expect(type(of: "Document", in: text, .java) == .type)
    #expect(type(of: "new", in: text, .java) == .keyword)
    #expect(type(of: "5L", in: text, .java) == .number)
    #expect(type(of: "\"n\"", in: text, .java) == .string)
  }

  @Test("Go")
  func go() {
    let text = #"filter := bson.D{{Key: "a", Value: 1e-3}}; if err != nil { return }"#
    #expect(type(of: "D", in: text, .go) == .type)
    // Struct field names stay in the default color
    #expect(type(of: "Key", in: text, .go) == nil)
    #expect(type(of: "Value", in: text, .go) == nil)
    #expect(type(of: "1e-3", in: text, .go) == .number)
    #expect(type(of: "if", in: text, .go) == .keyword)
    #expect(type(of: "nil", in: text, .go) == .keyword)
    #expect(type(of: "return", in: text, .go) == .keyword)
  }

  @Test("C#")
  func csharp() {
    let text = #"var cursor = collection.Find(new BsonDocument("a", "x\"y")).Limit(2);"#
    #expect(type(of: "var", in: text, .csharp) == .keyword)
    #expect(type(of: "Find", in: text, .csharp) == .function)
    #expect(type(of: "BsonDocument", in: text, .csharp) == .type)
    #expect(type(of: #""x\"y""#, in: text, .csharp) == .string)
  }

  // MARK: - Comments and strings

  @Test("Comment markers follow the language")
  func commentMarkers() {
    #expect(type(of: "# x", in: "a = 1 # x", .python) == .comment)
    #expect(type(of: "// x", in: "a = 1 // x", .python) == nil)
    #expect(type(of: "// x", in: "a = 1; // x", .java) == .comment)
  }

  @Test("Markers inside strings stay in the string")
  func markersInStrings() {
    let text = #"uri = "mongodb://h/#a" # c"#
    #expect(type(of: #""mongodb://h/#a""#, in: text, .python) == .string)
    #expect(type(of: "# c", in: text, .python) == .comment)
  }

  @Test("Generated code yields ordered, disjoint tokens")
  func generatedCode() {
    let command = MongoCommand.find(
      collection: "orders", filter: .document([MongoValue.Field("qty", .int64(5))]),
      projection: nil, sort: nil, skip: 1, limit: 2)
    for language in Language.allCases {
      let code = MongoDriverCode.code(
        for: command, database: "shop", language: language, includeImports: true,
        includeConnection: true)!
      let tokens = DriverCodeSyntaxHighlighter.tokens(in: code, language: language)
      #expect(!tokens.isEmpty)
      for (lhs, rhs) in zip(tokens, tokens.dropFirst()) {
        #expect(NSMaxRange(lhs.range) <= rhs.range.location)
      }
    }
  }
}
