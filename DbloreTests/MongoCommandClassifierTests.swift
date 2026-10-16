// MongoCommandClassifierTests.swift
// The mongosh classifier: kind per command, `$out`/`$merge`, affectsAllRows, flags that stay
// false (nonTransactional above all), fail-closed parse errors, splitting, summary and the gate

import Foundation
import Testing

@testable import Dblore

@Suite("mongosh classifier")
struct MongoCommandClassifierTests {

  private func classified(_ text: String) throws -> ClassifiedStatement {
    try #require(MongoCommandClassifier.classifyStatement(text), "\(text)")
  }

  /// Every flag other than `kind`, `affectsAllRows` and `createsTable` is false.
  private func expectQuietFlags(_ statement: ClassifiedStatement) {
    #expect(!statement.hasReturning, "\(statement.text)")
    #expect(!statement.hasTopLevelReturning, "\(statement.text)")
    #expect(!statement.nonTransactional, "\(statement.text)")
    #expect(!statement.resetsSessionBrakes, "\(statement.text)")
    #expect(!statement.changesPrivileges, "\(statement.text)")
  }

  // MARK: - Kinds

  @Test("find, countDocuments, distinct, listCollections and plain aggregates are reads")
  func reads() throws {
    for text in [
      "db.c.find()", "db.c.find({a: 1}, {b: 1}).sort({a: -1}).skip(2).limit(5)",
      "db.c.countDocuments({a: 1})", "db.c.distinct(\"a\")", "show collections",
      "db.getCollectionNames()", "db.c.aggregate([])",
      "db.c.aggregate([{$match: {a: 1}}, {$group: {_id: \"$a\"}}, {$limit: 3}])",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .read, "\(text)")
      #expect(statement.isReadOnlySafe, "\(text)")
      #expect(!statement.affectsAllRows && !statement.createsTable, "\(text)")
      #expect(statement.text == text)
      expectQuietFlags(statement)
    }
  }

  @Test("Inserts, updates, replaceOne and deletes are DML, never non-transactional")
  func writes() throws {
    for text in [
      "db.c.insertOne({a: 1})", "db.c.insertMany([{a: 1}, {a: 2}])",
      "db.c.updateOne({a: 1}, {$set: {b: 2}})", "db.c.updateMany({a: 1}, {$set: {b: 2}})",
      "db.c.updateMany({a: 1}, [{$set: {b: 2}}], {upsert: true})",
      "db.c.replaceOne({a: 1}, {b: 2}, {upsert: true})", "db.c.deleteOne({a: 1})",
      "db.c.deleteMany({a: 1})",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .dml, "\(text)")
      #expect(!statement.isReadOnlySafe, "\(text)")
      #expect(!statement.affectsAllRows && !statement.createsTable, "\(text)")
      expectQuietFlags(statement)
    }
  }

  @Test("affectsAllRows only for updateMany and deleteMany with an empty filter")
  func affectsAllRows() throws {
    for text in [
      "db.c.updateMany({}, {$set: {b: 2}})", "db.c.updateMany({ }, {$set: {b: 2}}, {upsert: true})",
      "db.c.deleteMany({})",
    ] {
      #expect(try classified(text).affectsAllRows, "\(text)")
    }
    for text in [
      "db.c.updateOne({}, {$set: {b: 2}})", "db.c.replaceOne({}, {b: 2})", "db.c.deleteOne({})",
      "db.c.updateMany({a: null}, {$set: {b: 2}})", "db.c.deleteMany({_id: {$exists: true}})",
      "db.c.find()", "db.c.countDocuments()",
    ] {
      #expect(try !classified(text).affectsAllRows, "\(text)")
    }
  }

  @Test("$out is DDL that creates a table; $merge is DML; $out wins over $merge")
  func aggregateWrites() throws {
    for text in [
      "db.c.aggregate([{$match: {a: 1}}, {$out: \"copy\"}])",
      "db.c.aggregate([{$out: {db: \"other\", coll: \"copy\"}}])",
      // Not last (the server rejects it), still classified: fail closed
      "db.c.aggregate([{$out: \"copy\"}, {$match: {a: 1}}])",
      "db.c.aggregate([{$merge: {into: \"copy\"}}, {$out: \"copy\"}])",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .ddl, "\(text)")
      #expect(statement.createsTable, "\(text)")
      #expect(!statement.isReadOnlySafe, "\(text)")
      expectQuietFlags(statement)
    }
    for text in [
      "db.c.aggregate([{$match: {a: 1}}, {$merge: {into: \"copy\"}}])",
      "db.c.aggregate([{$merge: \"copy\"}, {$limit: 1}])",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .dml, "\(text)")
      #expect(!statement.createsTable, "\(text)")
      expectQuietFlags(statement)
    }
  }

  @Test("$out/$merge count as a key at any depth of the pipeline (fail closed), exact case")
  func nestedStageKeys() throws {
    for text in [
      "db.c.aggregate([{$facet: {a: [{$out: \"x\"}]}}])",
      "db.c.aggregate([{$unionWith: {coll: \"o\", pipeline: [{$out: \"x\"}]}}])",
      "db.c.aggregate([{$lookup: {from: \"o\", as: \"j\", pipeline: [{\"\\u0024out\": \"x\"}]}}])",
      "db.c.aggregate([{$match: {'$out': 1}}])",
      "db.c.aggregate([{$facet: {a: [{$merge: \"x\"}]}}, {$facet: {b: [[{$out: \"y\"}]]}}])",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .ddl, "\(text)")
      #expect(statement.createsTable, "\(text)")
    }
    for text in [
      "db.c.aggregate([{$match: {\"$merge\": 1}}])",
      "db.c.aggregate([{$lookup: {from: \"o\", as: \"j\", pipeline: [{$merge: \"x\"}]}}])",
      "db.c.aggregate([{$unionWith: {coll: \"o\", pipeline: [{\"\\u0024merge\": \"x\"}]}}])",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .dml, "\(text)")
      #expect(!statement.createsTable, "\(text)")
    }
    for text in [
      "db.c.aggregate([{$OUT: \"x\"}])", "db.c.aggregate([{$match: {a: \"$out\"}}])",
      "db.c.aggregate([{$match: {a: [\"$merge\"]}}])",
    ] {
      #expect(try classified(text).kind == .read, "\(text)")
    }
    // The parser refuses a stage that is not a document; `hasStage` finds no key in one
    #expect(try classified("db.c.aggregate([\"$out\", 1])").kind == .unknown)
    #expect(MongoCommandClassifier.hasStage(.string("$out"), "$out") == false)
  }

  @Test("An explain is a read only when the explained command is one, never a write")
  func explain() throws {
    for text in [
      "db.c.find().explain()",
      "db.c.find({a: 1}).sort({a: -1}).limit(2).explain(\"executionStats\")",
      "db.c.aggregate([{$match: {a: 1}}]).explain(\"allPlansExecution\")",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .read, "\(text)")
      #expect(statement.isReadOnlySafe, "\(text)")
      expectQuietFlags(statement)
    }
    for text in [
      "db.c.aggregate([{$merge: \"x\"}]).explain(\"executionStats\")",
      "db.c.aggregate([{$match: {}}, {$out: \"x\"}]).explain()",
      "db.c.aggregate([{$facet: {a: [{$out: \"x\"}]}}]).explain()",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .unknown, "\(text)")
      #expect(!statement.isReadOnlySafe, "\(text)")
      #expect(!statement.affectsAllRows && !statement.createsTable, "\(text)")
      expectQuietFlags(statement)
    }
    #expect(MongoCommandClassifier.usesServerSideJavaScript("db.c.find({$where: \"1\"}).explain()"))
  }

  /// The full table is `MCPMongoToolTests.javaScriptRefused`.
  @Test("Server-side JavaScript in a find hint or countDocuments options is found as in a filter")
  func javaScriptInCountOptions() {
    #expect(MongoCommandClassifier.usesServerSideJavaScript("db.c.find().hint({$where: \"1\"})"))
    #expect(
      MongoCommandClassifier.usesServerSideJavaScript(
        "db.c.countDocuments({}, {hint: {$where: \"1\"}})"))
  }

  // MARK: - Fail closed

  @Test("Text that does not parse as one command is unknown")
  func unknown() throws {
    // Helpers nested far below the depth limit: a parse error, never a stack overflow
    let nested =
      String(repeating: "ObjectId(", count: 5000) + "\"x\"" + String(repeating: ")", count: 5000)
    for text in [
      "db.c.drop()", "db.c.find().toArray()", "db.c.find({a: })", "SELECT 1",
      "db.dropDatabase()", "db.c.find()\ndb.d.find()", "db.c.find(); db.d.deleteMany({})",
      "db.c.insertOne({a: 1}", "db.c.find({a: \(nested)})", "db[\(nested)].find()",
    ] {
      let statement = try classified(text)
      #expect(statement.kind == .unknown, "\(text)")
      #expect(!statement.isReadOnlySafe, "\(text)")
      #expect(!statement.affectsAllRows && !statement.createsTable, "\(text)")
      expectQuietFlags(statement)
    }
  }

  @Test("Empty and comment-only text classifies to nothing")
  func empty() {
    for text in ["", "  \n\t", "// note", "/* a */\n// b", ";"] {
      #expect(MongoCommandClassifier.classifyStatement(text) == nil, "\(text)")
      #expect(MongoCommandClassifier.classify(text).isEmpty, "\(text)")
    }
  }

  // MARK: - Cells

  @Test("A cell is split with MongoshSplitter and each piece classified")
  func splitsCells() {
    let cell = """
      // reads first
      db.a.find({x: 1})
        .limit(3); db.b.insertOne({x: 1})
      db.c.deleteMany({})
      db.d.drop()
      """
    let statements = MongoCommandClassifier.classify(cell)
    #expect(statements.map(\.text) == MongoshSplitter.split(cell))
    #expect(statements.map(\.kind) == [.read, .dml, .dml, .unknown])
    #expect(statements.map(\.affectsAllRows) == [false, false, true, false])
  }

  @Test("SQLStatementClassifier.summary aggregates Mongo statements")
  func summary() {
    let reads = SQLStatementClassifier.summary(
      MongoCommandClassifier.classify("db.a.find()\ndb.a.aggregate([{$match: {}}])"))
    #expect(
      reads
        == ClassificationSummary(
          hasModification: false, hasSchemaChange: false, hasUnknown: false,
          affectsAllRows: false, touchesBrake: false, changesPrivileges: false))
    let writes = SQLStatementClassifier.summary(
      MongoCommandClassifier.classify(
        "db.a.updateMany({}, {$set: {b: 1}})\ndb.a.aggregate([{$out: \"b\"}])\ndb.a.drop()"))
    #expect(
      writes
        == ClassificationSummary(
          hasModification: true, hasSchemaChange: true, hasUnknown: true,
          affectsAllRows: true, touchesBrake: false, changesPrivileges: false))
  }

  // MARK: - Gate

  @Test("Schema-only lets Mongo DML run and blocks $out and unknown commands")
  func schemaOnlyGate() {
    let policy = ProtectionPolicy(protectionLevel: .schemaOnly)
    let allowed = MongoCommandClassifier.classify(
      """
      db.c.insertOne({a: 1})
      db.c.insertMany([{a: 1}])
      db.c.updateMany({}, {$set: {a: 2}})
      db.c.replaceOne({a: 1}, {a: 3})
      db.c.deleteOne({a: 1})
      db.c.deleteMany({})
      db.c.aggregate([{$merge: "d"}])
      db.c.find()
      """)
    #expect(allowed.count == 8)
    #expect(DatabaseConnectionManager.evaluate(allowed, policy: policy) == .allowed)
    for text in ["db.c.aggregate([{$out: \"d\"}])", "db.c.drop()"] {
      let statements = MongoCommandClassifier.classify(text)
      #expect(DatabaseConnectionManager.evaluate(statements, policy: policy) != .allowed, "\(text)")
    }
  }

  @Test("Read-only allows reads and blocks every write, $merge and $out included")
  func readOnlyGate() {
    let policy = ProtectionPolicy(protectionLevel: .readOnly)
    let reads = MongoCommandClassifier.classify(
      "db.c.find()\ndb.c.aggregate([{$match: {a: 1}}])\ndb.c.countDocuments()\nshow collections")
    #expect(DatabaseConnectionManager.evaluate(reads, policy: policy) == .allowed)
    for text in [
      "db.c.insertOne({a: 1})", "db.c.deleteOne({a: 1})", "db.c.aggregate([{$merge: \"d\"}])",
      "db.c.aggregate([{$out: \"d\"}])", "db.c.find().pretty()",
    ] {
      let statements = MongoCommandClassifier.classify(text)
      #expect(DatabaseConnectionManager.evaluate(statements, policy: policy) != .allowed, "\(text)")
    }
  }
}
