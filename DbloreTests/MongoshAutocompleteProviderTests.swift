// MongoshAutocompleteProviderTests.swift
// mongosh completions: collections, methods, chains, field paths, operators and stages.
// Suggestion texts include the editor token stem (see MongoshAutocompleteProvider).

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Mongosh autocomplete")
struct MongoshAutocompleteProviderTests {

  // MARK: - Collections

  @Test("After db. every collection is offered, odd names through getCollection")
  func collectionsAfterDb() {
    let texts = suggest("db.|")
    #expect(texts.contains("db.users"))
    #expect(texts.contains("db.orders"))
    #expect(texts.contains("db.getCollection(\"a.b\")"))
    #expect(texts.contains("db.getCollection(\"my-logs\")"))
    #expect(texts.contains("db.getCollection"))
    #expect(texts.contains("db.getCollectionNames"))
    #expect(suggest("db.US|") == ["db.users"])
    #expect(suggest("db.a|") == ["db.getCollection(\"a.b\")"])
    #expect(suggestions("db.us|").first?.type.isTable == true)
  }

  @Test("Collection-name strings offer raw names and keep the rest of the token")
  func collectionNameStrings() {
    #expect(suggest("db.getCollection(\"a.|\")") == ["\"a.b\""])
    #expect(suggest("db[\"my|\"].find()") == ["db[\"my-logs\"].find"])
    #expect(suggest("db.getCollection('U|") == ["'users"])
  }

  @Test("Names inserted in a collection-name string stay one string: no command injection")
  func collectionNameEscaping() throws {
    let names = [
      "x\"); db.users.deleteMany({}); db.getCollection(\"y",
      "x'); db.users.deleteMany({}); db.getCollection('y",
      "ends\\", "a\nb", "a\u{2028}b\u{2029}c", "t\tq\u{1}",
    ]
    let contexts = [
      "db.getCollection(\"|\").find()", "db.getCollection('|').find()", "db[\"|\"].find()",
      "db['|'].find()",
    ]
    for name in names {
      let tables = [DatabaseTable(schema: "shop", name: name)]
      for context in contexts {
        let text = try #require(completedText(context, tables: tables), "\(context)")
        #expect(MongoshSplitter.split(text) == [text], "\(text)")
        let command = try MongoshParser.parse(text)
        guard case .find(let collection, _, _, _, _, _, _) = command else {
          Issue.record("not a single find: \(text)")
          continue
        }
        #expect(collection == name, "\(text)")
      }
    }
  }

  @Test("A collection named like a db method is offered through getCollection")
  func reservedCollectionNames() throws {
    let tables = MongoshAutocompleteProvider.databaseMethods.map {
      DatabaseTable(schema: "shop", name: $0)
    }
    let texts = MongoshAutocompleteProvider.suggestions(
      for: "db.", at: 3, tables: tables
    ).map(\.text)
    for name in MongoshAutocompleteProvider.databaseMethods {
      let completion = "db.getCollection(\"\(name)\")"
      #expect(texts.contains(completion))
      #expect(try MongoshParser.parse(completion + ".find()").collection == name)
    }
  }

  // MARK: - Methods and chains

  @Test("After db.<collection>. exactly the supported methods are offered")
  func methodsAfterCollection() {
    let methods = suggest("db.users.|").map { String($0.dropFirst("db.users.".count)) }
    #expect(Set(methods) == Set(MongoshAutocompleteProvider.collectionMethods))
    #expect(suggest("db.users.UPD|") == ["db.users.updateMany", "db.users.updateOne"])
    #expect(suggest("db.getCollection(\"a.b\").c|") == [".countDocuments", ".createIndex"])
    #expect(suggest("db[\"a.b\"].del|") == ["db[\"a.b\"].deleteMany", "db[\"a.b\"].deleteOne"])
  }

  @Test("Every offered method is one the parser accepts")
  func methodsMatchParserSubset() {
    #expect(MongoshAutocompleteProvider.collectionMethods.count == 17)
    for method in MongoshAutocompleteProvider.collectionMethods {
      do {
        _ = try MongoshParser.parse("db.c.\(method)()")
      } catch {
        #expect(!error.message.contains("is not supported"), "\(method)")
      }
    }
  }

  @Test("After find(...) the unused chain methods are offered")
  func chainAfterFind() {
    #expect(
      suggest("db.users.find({}).|")
        == [".collation", ".explain", ".hint", ".limit", ".maxTimeMS", ".skip", ".sort"])
    #expect(
      suggest("db.users.find().sort({a: 1})\n  .limit(1).hint(\"a_1\").|")
        == [".collation", ".explain", ".maxTimeMS", ".skip"])
    #expect(suggest("db.users.find()\n.L|") == [".limit"])
    #expect(suggest("db.users.find().explain().|").isEmpty)
    #expect(suggest("db.users.countDocuments().|").isEmpty)
  }

  // MARK: - Documents

  @Test("Filter keys offer the collection's field paths and query operators")
  func filterFieldsAndOperators() {
    #expect(suggest("db.users.find({na|") == ["{name"])
    #expect(suggest("db.users.find({ a|") == ["\"address.city\"", "age"])
    #expect(suggest("db.users.find({am|").isEmpty)
    #expect(
      suggest("db.users.find({age: {$G|") == ["{$geoIntersects", "{$geoWithin", "{$gt", "{$gte"])
    #expect(suggest("db.users.deleteMany({$o|") == ["{$or"])
    #expect(suggest("db.users.find({$or: [{na|") == ["[{name"])
    #expect(suggestions("db.users.find({na|").first?.type.isColumn == true)
  }

  @Test("Fields come only from the collection of the current command")
  func fieldsFromCurrentCollection() {
    #expect(suggest("db.users.find();\ndb.orders.find({am|") == ["{amount"])
    #expect(suggest("db.users.find()\ndb.orders.find({na|").isEmpty)
    #expect(suggest("db.getCollection(\"a.b\").find({ k|") == ["key"])
  }

  @Test("A bare filter or stage body offers the field paths of its collection, odd names too")
  func bareDocumentFields() {
    let source = SQLAutocompleteProvider()
    source.update(tables: [
      DatabaseTable(
        schema: "shop", name: "ai-credentials",
        columns: [DatabaseColumn(name: "status", type: "string")])
    ])
    let filter = MongoDocumentAutocompleteProvider(
      collection: "ai-credentials", mode: .filter, source: source)
    #expect(filter.getSuggestions(for: "{sta", at: 4, dialect: .mongodb).map(\.text) == ["{status"])
    #expect(
      filter.getSuggestions(for: "{sta}", at: 4, dialect: .mongodb).map(\.text) == ["{status}"])
    let stage = MongoDocumentAutocompleteProvider(
      collection: "ai-credentials", mode: .stage("$match"), source: source)
    #expect(stage.getSuggestions(for: "{ st", at: 4, dialect: .mongodb).map(\.text) == ["status"])
  }

  @Test("A stage body whose stage name is not $ and ASCII letters offers nothing")
  func untrustedStageName() {
    let tables = [
      DatabaseTable(
        schema: "shop", name: "users", columns: [DatabaseColumn(name: "status", type: "string")])
    ]
    func texts(_ op: String) -> [String] {
      MongoshAutocompleteProvider.documentSuggestions(
        for: "{ st", at: 4, collection: "users", mode: .stage(op), tables: tables
      ).map(\.text)
    }
    #expect(texts("$project") == ["status"])
    for op in ["$match: {}}, {$project", "project", "$", "$project1"] {
      #expect(texts(op).isEmpty, "\(op)")
    }
  }

  @Test("An update's second argument offers update operators at its top level")
  func updateOperators() {
    #expect(suggest("db.users.updateOne({_id: 1}, {$s|") == ["{$set"])
    #expect(suggest("db.users.updateOne({$s|") == ["{$size"])
    #expect(suggest("db.users.updateMany({}, {$set: {na|") == ["{name"])
    #expect(suggest("db.users.updateOne({}, {na|").isEmpty)
  }

  @Test("Inside aggregate([...]) stage names are offered")
  func aggregateStages() {
    #expect(suggest("db.users.aggregate([{$m|") == ["[{$match", "[{$merge"])
    #expect(
      suggest("db.users.aggregate([{$match: {}}, {$s|")
        == ["{$sample", "{$set", "{$setWindowFields", "{$skip", "{$sort", "{$sortByCount"])
    #expect(suggest("db.users.aggregate([{$match: {ag|") == ["{age"])
  }

  @Test("Stage bodies offer accumulators, expression operators and option keys by position")
  func stageBodyOperators() {
    let cases: [(marked: String, expected: [String])] = [
      ("db.users.aggregate([{$group: {_|", ["{_id"]),
      ("db.users.aggregate([{$group: {na|", []),
      (
        "db.users.aggregate([{$group: {_id: \"$a\", n: {$su|",
        ["{$sum", "{$substr", "{$substrCP", "{$subtract"]
      ),
      ("db.users.aggregate([{$project: {na|", ["{name"]),
      ("db.users.aggregate([{$project: {full: {$conc|", ["{$concat", "{$concatArrays"]),
      (
        "db.users.aggregate([{$project: {total: {$su|",
        ["{$substr", "{$substrCP", "{$subtract", "{$sum"]
      ),
      ("db.users.aggregate([{$replaceWith: {$mer|", ["{$mergeObjects"]),
      ("db.users.find({$expr: {$cm|", ["{$cmp"]),
      ("db.users.find({$expr: {$and: [{$cm|", ["[{$cmp"]),
      (
        "db.users.aggregate([{$bucket: {output: {n: {$su|",
        ["{$sum", "{$substr", "{$substrCP", "{$subtract"]
      ),
      ("db.users.aggregate([{$lookup: {fo|", ["{foreignField"]),
      ("db.users.aggregate([{$lookup: {from: \"orders\", l|", ["let", "localField"]),
    ]
    for (marked, expected) in cases {
      #expect(suggest(marked) == expected, "\(marked)")
    }
    let filter = MongoshAutocompleteProvider.documentSuggestions(
      for: "{$expr: {$cm", at: 12, collection: "users", mode: .filter, tables: [])
    #expect(filter.map(\.text) == ["{$cmp"])
  }

  @Test("Server-side JavaScript operators are never offered")
  func noServerSideJavaScript() {
    let contexts = [
      "db.users.find({", "db.users.find({$expr: {", "db.users.aggregate([{",
      "db.users.aggregate([{$group: {n: {", "db.users.aggregate([{$project: {a: {",
    ]
    for context in contexts {
      for name in ["$where", "$function", "$accumulator"] {
        #expect(suggest(context + name + "|").isEmpty, "\(context)\(name)")
      }
    }
  }

  @Test("Keys need a typed prefix and value positions offer nothing")
  func noSuggestionsWithoutPrefix() {
    #expect(suggest("db.users.find({|").isEmpty)
    #expect(suggest("db.users.find({name: na|").isEmpty)
  }

  // MARK: - Strings and comments

  @Test("No completions inside strings, regex literals or comments")
  func noCompletionsInLiterals() {
    #expect(suggest("db.users.find({name: \"na|").isEmpty)
    #expect(suggest("db.users.find({name: 'db.|").isEmpty)
    #expect(suggest("db.users.find({name: /na|").isEmpty)
    #expect(suggest("// db.|").isEmpty)
    #expect(suggest("/* db.us|").isEmpty)
    #expect(suggest("db.users.find({\"na|").isEmpty)
  }

  @Test("Brackets inside strings and comments do not change the context")
  func literalsAreSkipped() {
    #expect(suggest("// db.\ndb.us|") == ["db.users"])
    #expect(suggest("db.users.find({name: \"}{\", /* ) */ ag|") == ["age"])
    #expect(suggest("db.users.find({name: /[}]/, ag|") == ["age"])
  }

  // MARK: - Delegation

  @Test("SQLAutocompleteProvider delegates for .mongodb only")
  func delegation() {
    let provider = makeProvider()
    let text = "db.us"
    let mongo = provider.getSuggestions(for: text, at: utf16(text), dialect: .mongodb)
    #expect(mongo.map(\.text) == ["db.users"])
    let sql = provider.getSuggestions(for: text, at: utf16(text), dialect: .postgresql)
    #expect(!sql.map(\.text).contains("db.users"))
    let select = "SELECT na"
    #expect(provider.getSuggestions(for: select, at: utf16(select), dialect: .mongodb).isEmpty)
  }

  // MARK: - Helpers

  private func makeProvider() -> SQLAutocompleteProvider {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      DatabaseTable(
        schema: "shop", name: "users",
        columns: [
          DatabaseColumn(name: "_id", type: "objectId"),
          DatabaseColumn(name: "name", type: "string"),
          DatabaseColumn(name: "address.city", type: "string"),
          DatabaseColumn(name: "age", type: "int"),
        ]),
      DatabaseTable(
        schema: "shop", name: "orders", columns: [DatabaseColumn(name: "amount", type: "double")]),
      DatabaseTable(
        schema: "shop", name: "a.b", columns: [DatabaseColumn(name: "key", type: "string")]),
      DatabaseTable(schema: "shop", name: "my-logs"),
    ])
    return provider
  }

  /// Suggestions at the `|` marker of `marked` (the marker is removed)
  private func suggestions(_ marked: String) -> [AutocompleteSuggestion] {
    let marker = (marked as NSString).range(of: "|")
    let text = (marked as NSString).replacingCharacters(in: marker, with: "")
    return makeProvider().getSuggestions(for: text, at: marker.location, dialect: .mongodb)
  }

  private func suggest(_ marked: String) -> [String] { suggestions(marked).map(\.text) }

  /// The text after accepting the only suggestion at the `|` of `marked`: the editor replaces its
  /// token (between whitespace or `(),;`, as `SQLTextView.findTokenRange`) with it.
  private func completedText(_ marked: String, tables: [DatabaseTable]) -> String? {
    let ns = marked as NSString
    let cursor = ns.range(of: "|").location
    let text =
      ns.replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString
    let found = MongoshAutocompleteProvider.suggestions(
      for: text as String, at: cursor, tables: tables)
    guard found.count == 1 else { return nil }
    let boundaries = CharacterSet(charactersIn: "(),;").union(.whitespacesAndNewlines)
    func isBoundary(_ index: Int) -> Bool {
      Unicode.Scalar(text.character(at: index)).map(boundaries.contains) ?? false
    }
    var start = cursor
    while start > 0 && !isBoundary(start - 1) { start -= 1 }
    var end = cursor
    while end < text.length && !isBoundary(end) { end += 1 }
    return text.replacingCharacters(
      in: NSRange(location: start, length: end - start), with: found[0].text)
  }

  private func utf16(_ text: String) -> Int { (text as NSString).length }
}

extension AutocompleteSuggestionType {
  fileprivate var isTable: Bool {
    if case .table = self { return true }
    return false
  }

  fileprivate var isColumn: Bool {
    if case .column = self { return true }
    return false
  }
}
