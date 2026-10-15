// MongoDocumentChangeSetTests.swift
// Staged MongoDB document edits: staging and merging, `$set`/`$unset` interplay, conflicting
// paths, refusals, exact `_id` values per BSON type, command order and preview text, the grid
// overlay, and parse(render(command)) == command.

import Foundation
import Testing

@testable import Dblore

@Suite("Mongo document change set")
@MainActor
struct MongoDocumentChangeSetTests {
  private static let hex1 = "507f1f77bcf86cd799439011"
  private static let hex2 = "507f1f77bcf86cd799439022"
  private static let hex3 = "507f1f77bcf86cd799439033"

  private func doc(_ pairs: (String, MongoValue)...) -> MongoValue {
    .document(pairs.map { MongoValue.Field($0.0, $0.1) })
  }

  private func oid(_ hex: String) -> MongoValue {
    .objectId(MongoObjectId(hex: hex)!)
  }

  private func target(primaryKey: [String] = ["_id"]) -> EditTarget {
    EditTarget(
      qualifiedName: "users", tableID: .mongodb(database: "app", collection: "users"),
      primaryKeyColumns: primaryKey, connectionEpoch: 3, name: "users")
  }

  private func changeSet(idType: String? = "objectId") throws -> MongoDocumentChangeSet {
    var columns = [ColumnInfo(name: "name", type: "string")]
    if let idType { columns.insert(ColumnInfo(name: "_id", type: idType), at: 0) }
    return try MongoDocumentChangeSet(target: target(), columns: columns)
  }

  private func error(
    _ body: () throws -> Void
  ) -> MongoDocumentChangeError? {
    do {
      try body()
      return nil
    } catch let error as MongoDocumentChangeError {
      return error
    } catch {
      return nil
    }
  }

  // MARK: - Target

  @Test("Only a Mongo edit target keyed by _id is accepted; the collection comes from it")
  func targetChecks() throws {
    #expect(
      error { _ = try MongoDocumentChangeSet(target: target(primaryKey: ["id"]), columns: []) }
        == .notMongoTarget)
    let set = try changeSet()
    #expect(set.collection == "users")
    #expect(set.isEmpty)
  }

  @Test("invalidated(by:) is nil only for the same target")
  func invalidation() throws {
    let editTarget = target()
    let set = try MongoDocumentChangeSet(
      target: editTarget, columns: [ColumnInfo(name: "_id", type: "objectId")])
    #expect(set.invalidated(by: editTarget) == nil)
    #expect(set.invalidated(by: target()) == "The collection changed; staged edits were discarded.")
  }

  // MARK: - idValue

  @Test("idValue converts a grid cell back to the exact BSON _id per column type")
  func idValuePerType() {
    let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    let accepted: [(CellValue, String, MongoValue)] = [
      (.string(Self.hex1), "objectId", oid(Self.hex1)),
      (.string(Self.hex1.uppercased()), "objectId", oid(Self.hex1)),
      (.string("abc"), "string", .string("abc")),
      (.string(Self.hex1), "string", .string(Self.hex1)),
      (.int(42), "int", .int32(42)),
      (.int(5_000_000_000), "long", .int64(5_000_000_000)),
      (.int(7), "long", .int64(7)),
      (.double(1.5), "double", .double(1.5)),
      (.string("12.50"), "decimal", .decimal128("12.50")),
      (.bool(true), "bool", .bool(true)),
      (.date(date), "date", .date(1_700_000_000_123)),
      (
        .json(#"{"a": {"$numberLong": "1"}, "b": "x"}"#), "object",
        doc(("a", .int64(1)), ("b", .string("x")))
      ),
      (.string("Timestamp(5, 6)"), "timestamp", .timestamp(t: 5, i: 6)),
      (.string("MinKey()"), "minKey", .minKey),
      (.string("MaxKey()"), "maxKey", .maxKey),
    ]
    for (cell, type, expected) in accepted {
      #expect(MongoDocumentChangeSet.idValue(cell: cell, columnType: type) == expected, "\(type)")
      // The grid keys staged rows by the loaded cell, so the value must map back to it.
      if cell != .string(Self.hex1.uppercased()) {
        #expect(MongoBSONMapping.cellValue(expected) == cell, "\(type)")
      }
    }
    let refused: [(CellValue, String)] = [
      (.string("not hex"), "objectId"),
      (.int(1), "objectId"),
      (.null, "objectId"),
      (.int(5_000_000_000), "int"),
      (.string("42"), "int"),
      (.int(1), "double"),
      (.string("abc"), "decimal"),
      (.data(Data([1, 2])), "binData"),
      (.string("/a/"), "regex"),
      (.json("[1]"), "array"),
      (.null, "null"),
      (.string("x"), "mixed"),
      (.json(#"{"$code": "f()"}"#), "javascript"),
      (.json(#"{"$gt": 1}"#), "object"),
      (.json("not json"), "object"),
      (.string("MinKey()"), "maxKey"),
      (.string("x"), "unknownType"),
    ]
    for (cell, type) in refused {
      #expect(MongoDocumentChangeSet.idValue(cell: cell, columnType: type) == nil, "\(type)")
    }
  }

  @Test("An objectId cell becomes ObjectId, never a string, and maps back to the same cell")
  func objectIdIsExact() throws {
    let cell = CellValue.string(Self.hex1)
    let value = try #require(MongoDocumentChangeSet.idValue(cell: cell, columnType: "objectId"))
    #expect(value == oid(Self.hex1))
    #expect(value != .string(Self.hex1))
    #expect(MongoBSONMapping.cellValue(value) == cell)
  }

  // MARK: - Staging and merging

  @Test("Updates merge per _id; inserts and deletes stage in order")
  func stagingAndMerging() throws {
    var set = try changeSet()
    try set.stageSet(id: .string(Self.hex1), path: ["name"], value: .string("Ann"))
    try set.stageSet(id: .string(Self.hex1), path: ["age"], value: .int32(30))
    try set.stageSet(id: .string(Self.hex2), path: ["name"], value: .string("Bob"))
    try set.stageSet(id: .string(Self.hex1), path: ["name"], value: .string("Anna"))
    try set.stageDelete(id: .string(Self.hex3))
    let insertID = try set.stageInsert(doc(("name", .string("Cy"))))

    #expect(set.counts == RowChangeSet.Counts(inserts: 1, deletes: 1, edits: 2))
    #expect(set.updates.map(\.id) == [oid(Self.hex1), oid(Self.hex2)])
    // A restaged path replaces its change and moves to the end.
    #expect(
      set.updates[0].changes == [
        .init(path: ["age"], value: .int32(30)), .init(path: ["name"], value: .string("Anna")),
      ])
    #expect(set.deletes == [oid(Self.hex3)])
    #expect(set.inserts.map(\.localID) == [insertID])

    // A second delete of the same document stays one delete.
    try set.stageDelete(id: .string(Self.hex3))
    #expect(set.deletes == [oid(Self.hex3)])
  }

  @Test("A later $set of a path removes its pending $unset and vice versa")
  func setUnsetInterplay() throws {
    var set = try changeSet()
    let id = CellValue.string(Self.hex1)
    try set.stageSet(id: id, path: ["a"], value: .int32(1))
    try set.stageUnset(id: id, path: ["a"])
    #expect(set.updates[0].changes == [.init(path: ["a"], value: nil)])
    try set.stageSet(id: id, path: ["a"], value: .int32(2))
    #expect(set.updates[0].changes == [.init(path: ["a"], value: .int32(2))])
    #expect(
      set.commands() == [
        .updateOne(
          collection: "users", filter: doc(("_id", oid(Self.hex1))),
          update: doc(("$set", doc(("a", .int32(2))))))
      ])
    try set.stageUnset(id: id, path: ["a"])
    #expect(
      set.commands() == [
        .updateOne(
          collection: "users", filter: doc(("_id", oid(Self.hex1))),
          update: doc(("$unset", doc(("a", .string(""))))))
      ])
  }

  @Test("A parent path replaces pending child paths; a child of a pending path is refused")
  func conflictingPaths() throws {
    var set = try changeSet()
    let id = CellValue.string(Self.hex1)
    try set.stageSet(id: id, path: ["a", "b"], value: .int32(1))
    try set.stageUnset(id: id, path: ["a", "c", "d"])
    try set.stageSet(id: id, path: ["ab"], value: .int32(3))
    try set.stageSet(id: id, path: ["a"], value: doc(("x", .int32(2))))
    #expect(
      set.updates[0].changes == [
        .init(path: ["ab"], value: .int32(3)), .init(path: ["a"], value: doc(("x", .int32(2)))),
      ])
    #expect(
      error { try set.stageSet(id: id, path: ["a", "y"], value: .int32(4)) }
        == .conflictingPath(path: "a.y", pending: "a"))
    try set.stageUnset(id: id, path: ["ab"])
    #expect(
      error { try set.stageUnset(id: id, path: ["ab", "z"]) }
        == .conflictingPath(path: "ab.z", pending: "ab"))
    #expect(set.updates[0].changes.count == 2)
  }

  @Test("Deleting a document drops its updates; edits to a deleted document are refused")
  func deleteDropsUpdatesAndRefusesEdits() throws {
    var set = try changeSet()
    let id = CellValue.string(Self.hex1)
    try set.stageSet(id: id, path: ["name"], value: .string("x"))
    try set.stageDelete(id: id)
    #expect(set.updates.isEmpty)
    #expect(set.deletes == [oid(Self.hex1)])
    #expect(error { try set.stageSet(id: id, path: ["name"], value: .null) } == .deletedDocument)
    #expect(error { try set.stageUnset(id: id, path: ["name"]) } == .deletedDocument)

    set.revert(id: id)
    #expect(set.isEmpty)
    try set.stageSet(id: id, path: ["name"], value: .string("y"))
    #expect(set.counts.edits == 1)
  }

  @Test("Deleting a staged insert removes it; revertAll clears everything")
  func insertRemovalAndRevertAll() throws {
    var set = try changeSet()
    let first = try set.stageInsert(doc(("n", .int32(1))))
    let second = try set.stageInsert(doc(("n", .int32(2))))
    #expect(first != second)
    set.deleteInsert(localID: first)
    #expect(set.inserts.map(\.localID) == [second])
    #expect(set.counts.deletes == 0)

    try set.stageDelete(id: .string(Self.hex1))
    try set.stageSet(id: .string(Self.hex2), path: ["n"], value: .int32(3))
    set.revertAll()
    #expect(set.isEmpty)
  }

  // MARK: - Refusals

  @Test("_id, dotted or $ top-level keys, empty paths and non-documents are refused")
  func refusals() throws {
    var set = try changeSet()
    let id = CellValue.string(Self.hex1)
    #expect(error { try set.stageSet(id: id, path: ["_id"], value: .int32(1)) } == .idField)
    #expect(error { try set.stageSet(id: id, path: ["_id", "x"], value: .int32(1)) } == .idField)
    #expect(error { try set.stageUnset(id: id, path: ["_id"]) } == .idField)
    for path in [["a.b"], ["$x"], ["a", "$"], [], [""], ["a", ""]] {
      let name = path.joined(separator: ".")
      #expect(
        error { try set.stageSet(id: id, path: path, value: .int32(1)) } == .invalidPath(name),
        "\(path)")
      #expect(error { try set.stageUnset(id: id, path: path) } == .invalidPath(name), "\(path)")
    }
    #expect(error { _ = try set.stageInsert(.int32(1)) } == .notDocument)
    #expect(
      error { try set.stageSet(id: .null, path: ["a"], value: .int32(1)) }
        == .unsupportedID(type: "objectId"))
    #expect(error { try set.stageDelete(id: .string("nope")) } == .unsupportedID(type: "objectId"))
    #expect(set.isEmpty)
  }

  @Test("A mixed or missing _id column refuses updates and deletes but allows inserts")
  func mixedOrMissingIDColumn() throws {
    for idType in ["mixed", nil] as [String?] {
      var set = try changeSet(idType: idType)
      let id = CellValue.string(Self.hex1)
      #expect(
        error { try set.stageSet(id: id, path: ["a"], value: .int32(1)) } == .idColumnUnavailable)
      #expect(error { try set.stageUnset(id: id, path: ["a"]) } == .idColumnUnavailable)
      #expect(error { try set.stageDelete(id: id) } == .idColumnUnavailable)
      _ = try set.stageInsert(doc(("a", .int32(1))))
      #expect(set.counts == RowChangeSet.Counts(inserts: 1, deletes: 0, edits: 0))
    }
  }

  @Test("Errors carry user-facing messages")
  func messages() {
    let errors: [MongoDocumentChangeError] = [
      .notMongoTarget, .idColumnUnavailable, .unsupportedID(type: "binData"), .idField,
      .invalidPath("a.b"), .deletedDocument, .conflictingPath(path: "a.b", pending: "a"),
      .notDocument,
    ]
    for error in errors {
      #expect(!error.message.isEmpty)
      #expect(error.errorDescription == error.message)
    }
    #expect(
      MongoDocumentChangeError.deletedDocument.message
        == "This document is staged for deletion. Revert the delete before editing it.")
  }

  // MARK: - Commands

  private func populated() throws -> MongoDocumentChangeSet {
    var set = try changeSet()
    _ = try set.stageInsert(doc(("name", .string("Cy")), ("n", .int64(5))))
    try set.stageSet(id: .string(Self.hex1), path: ["name"], value: .string("Ann"))
    try set.stageUnset(id: .string(Self.hex1), path: ["meta", "old"])
    try set.stageDelete(id: .string(Self.hex2))
    try set.stageSet(id: .string(Self.hex3), path: ["score"], value: .double(2.5))
    _ = try set.stageInsert(doc(("_id", .string("own")), ("name", .string("Di"))))
    return set
  }

  @Test("commands() orders deletes, then updates, then inserts, each in staging order")
  func commandOrder() throws {
    let set = try populated()
    #expect(
      set.commands() == [
        .deleteOne(collection: "users", filter: doc(("_id", oid(Self.hex2)))),
        .updateOne(
          collection: "users", filter: doc(("_id", oid(Self.hex1))),
          update: doc(
            ("$set", doc(("name", .string("Ann")))), ("$unset", doc(("meta.old", .string("")))))),
        .updateOne(
          collection: "users", filter: doc(("_id", oid(Self.hex3))),
          update: doc(("$set", doc(("score", .double(2.5)))))),
        .insertOne(collection: "users", document: doc(("name", .string("Cy")), ("n", .int64(5)))),
        .insertOne(
          collection: "users", document: doc(("_id", .string("own")), ("name", .string("Di")))),
      ])
  }

  @Test("previewText() is exactly the rendered commands joined by newlines")
  func previewText() throws {
    let set = try populated()
    #expect(
      set.previewText()
        == """
        db.users.deleteOne({ _id: ObjectId("\(Self.hex2)") })
        db.users.updateOne({ _id: ObjectId("\(Self.hex1)") }, { $set: { name: "Ann" }, $unset: { "meta.old": "" } })
        db.users.updateOne({ _id: ObjectId("\(Self.hex3)") }, { $set: { score: 2.5 } })
        db.users.insertOne({ name: "Cy", n: NumberLong("5") })
        db.users.insertOne({ _id: "own", name: "Di" })
        """)
    #expect(set.previewText() == set.commands().map { $0.render() }.joined(separator: "\n"))
    #expect(try changeSet().previewText() == "")
  }

  @Test("removeApplied drops the sent changes by identity; changes staged meanwhile stay")
  func removeAppliedByIdentity() throws {
    var set = try changeSet()
    try set.stageDelete(id: .string(Self.hex2))
    try set.stageSet(id: .string(Self.hex1), path: ["name"], value: .string("Ann"))
    let sentInsert = try set.stageInsert(doc(("name", .string("Cy"))))
    let keys = set.changeKeys()
    #expect(keys.count == set.commands().count)

    // Staged while the commit is in flight: a new delete, a new $set, a new insert
    try set.stageDelete(id: .string(Self.hex3))
    try set.stageSet(id: .string(Self.hex1), path: ["age"], value: .int32(30))
    let laterInsert = try set.stageInsert(doc(("name", .string("Di"))))

    var partial = set
    partial.removeApplied(keys.prefix(1))
    #expect(partial.deletes == [oid(Self.hex3)])
    #expect(partial.updates.count == 1 && partial.updates[0].changes.count == 2)
    #expect(partial.inserts.map(\.localID) == [sentInsert, laterInsert])

    set.removeApplied(keys)
    #expect(set.deletes == [oid(Self.hex3)])
    #expect(set.updates.map(\.id) == [oid(Self.hex1)])
    #expect(set.updates[0].changes == [.init(path: ["age"], value: .int32(30))])
    #expect(set.inserts.map(\.localID) == [laterInsert])
  }

  @Test("Every rendered command parses back to the same command")
  func roundTrip() throws {
    var set = try populated()
    try set.stageSet(
      id: .string(Self.hex1), path: ["when"], value: .date(1_700_000_000_123))
    try set.stageSet(id: .string(Self.hex1), path: ["price"], value: .decimal128("9.99"))
    try set.stageSet(
      id: .string(Self.hex1), path: ["tags", "0"], value: .regex(pattern: "a", options: "i"))
    _ = try set.stageInsert(
      doc(("_id", oid(Self.hex3)), ("bin", .binary(subtype: 4, data: Data([1, 2, 3])))))
    for command in set.commands() {
      #expect(try MongoshParser.parse(command.render()) == command, "\(command.render())")
    }
  }

  // MARK: - Grid overlay

  @Test("displayRowChangeSet keys rows by the _id cell and draws top-level edits")
  func displayRowChangeSet() throws {
    var set = try populated()
    try set.stageUnset(id: .string(Self.hex3), path: ["name"])
    try set.stageSet(id: .string(Self.hex3), path: ["nick"], value: .null)
    let editTarget = target()
    let display = set.displayRowChangeSet(target: editTarget)

    let row1 = RowChangeSet.RowKey(values: [.string(Self.hex1)])
    let row2 = RowChangeSet.RowKey(values: [.string(Self.hex2)])
    let row3 = RowChangeSet.RowKey(values: [.string(Self.hex3)])
    #expect(display.qualifiedName == "users")
    #expect(display.generation == editTarget.generation)
    #expect(display.primaryKeyColumns == ["_id"])
    #expect(display.deletes == [row2])
    // Nested paths (meta.old) are not drawn: grid columns are top-level keys.
    #expect(display.edits[row1]?.count == 1)
    #expect(display.edits[row1]?["name"] == .string("Ann"))
    #expect(display.edits[row3]?["score"] == .double(2.5))
    #expect(display.edits[row3]?["name"] == .null)
    #expect(display.edits[row3]?["nick"] == .null)
    #expect(display.inserts.count == 2)
    #expect(display.inserts[0].values["name"] == .string("Cy"))
    #expect(display.inserts[0].values["n"] == .int(5))
    #expect(display.inserts[0].values["_id"] == nil)
    #expect(display.inserts[1].values["_id"] == .string("own"))
    #expect(display.counts == RowChangeSet.Counts(inserts: 2, deletes: 1, edits: 2))
  }
}
