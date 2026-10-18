// MongoAdminCommand.swift
// One administration command of the Dblore mongosh subset (indexes, collections, views), as
// `MongoCommand.admin` carries it: rendered back to canonical mongosh text and built into the
// server command document.

import Foundation

/// An administration command on the connection's database. Option documents are raw
/// `MongoValue` documents, nil when none is written; `collMod` stores its document without the
/// `collMod` key (`render` and `commandDocument` put it first).
nonisolated enum MongoAdminCommand: Equatable, Sendable {
  typealias Field = MongoValue.Field

  case createIndex(collection: String, keys: MongoValue, options: MongoValue?)
  /// `index` is the index name (a string) or its key document.
  case dropIndex(collection: String, index: MongoValue)
  /// `hideIndex(name)` when `hidden`, else `unhideIndex(name)`.
  case setIndexHidden(collection: String, name: String, hidden: Bool)
  case createCollection(name: String, options: MongoValue?)
  case createView(name: String, source: String, pipeline: [MongoValue], options: MongoValue?)
  case drop(collection: String)
  case renameCollection(collection: String, to: String)
  case collMod(collection: String, options: MongoValue)

  /// The target collection: the one created for `createCollection` and `createView`, the
  /// source for `renameCollection`.
  var collection: String {
    switch self {
    case .createIndex(let name, _, _), .dropIndex(let name, _), .setIndexHidden(let name, _, _),
      .createCollection(let name, _), .createView(let name, _, _, _), .drop(let name),
      .renameCollection(let name, _), .collMod(let name, _):
      name
    }
  }

  /// `drop` and `dropIndex` remove data or an index for good.
  var isDestructive: Bool {
    switch self {
    case .drop, .dropIndex: true
    case .createIndex, .setIndexHidden, .createCollection, .createView, .renameCollection,
      .collMod:
      false
    }
  }

  /// Every document or array argument (keys, options, index key, pipeline), for the server-side
  /// JavaScript scan.
  var documentArguments: [MongoValue] {
    switch self {
    case .createIndex(_, let keys, let options): [keys] + (options.map { [$0] } ?? [])
    case .dropIndex(_, let index): [index]
    case .createCollection(_, let options): options.map { [$0] } ?? []
    case .createView(_, _, let pipeline, let options):
      [.array(pipeline)] + (options.map { [$0] } ?? [])
    case .collMod(_, let options): [options]
    case .setIndexHidden, .drop, .renameCollection: []
    }
  }

  /// Canonical mongosh text: the collection helpers `createIndex`, `dropIndex`, `hideIndex`,
  /// `unhideIndex`, `drop()` and `renameCollection`, the database helpers `createCollection` and
  /// `createView`, and `db.runCommand({collMod: …})`. Options only when set.
  func render() -> String {
    switch self {
    case .createIndex(let name, let keys, let options):
      return MongoCommand.call(name, "createIndex", [keys] + (options.map { [$0] } ?? []))
    case .dropIndex(let name, let index):
      return MongoCommand.call(name, "dropIndex", [index])
    case .setIndexHidden(let name, let index, let hidden):
      return MongoCommand.call(name, hidden ? "hideIndex" : "unhideIndex", [.string(index)])
    case .createCollection(let name, let options):
      return Self.databaseCall("createCollection", [.string(name)] + (options.map { [$0] } ?? []))
    case .createView(let name, let source, let pipeline, let options):
      return Self.databaseCall(
        "createView",
        [.string(name), .string(source), .array(pipeline)] + (options.map { [$0] } ?? []))
    case .drop(let name):
      return MongoCommand.call(name, "drop", [])
    case .renameCollection(let name, let target):
      return MongoCommand.call(name, "renameCollection", [.string(target)])
    case .collMod(let name, let options):
      return Self.databaseCall(
        "runCommand", [.document([Field("collMod", .string(name))] + Self.fields(of: options))])
    }
  }

  /// The server command and the database it runs in: `database` for every command but
  /// `renameCollection`, which runs in `admin` with `<database>.<name>` namespaces and
  /// `dropTarget: false`. A `createIndex` without a `name` option gets the drivers' generated
  /// name.
  func commandDocument(in database: String) -> (fields: [Field], database: String) {
    switch self {
    case .createIndex(let name, let keys, let options):
      var spec = [Field("key", keys)]
      let optionFields = options.map(Self.fields(of:)) ?? []
      if !optionFields.contains(where: { $0.key == "name" }) {
        spec.append(Field("name", .string(Self.indexName(keys))))
      }
      return (
        [
          Field("createIndexes", .string(name)),
          Field("indexes", .array([.document(spec + optionFields)])),
        ],
        database
      )
    case .dropIndex(let name, let index):
      return ([Field("dropIndexes", .string(name)), Field("index", index)], database)
    case .setIndexHidden(let name, let index, let hidden):
      return (
        [
          Field("collMod", .string(name)),
          Field(
            "index", .document([Field("name", .string(index)), Field("hidden", .bool(hidden))])),
        ],
        database
      )
    case .createCollection(let name, let options):
      return ([Field("create", .string(name))] + (options.map(Self.fields(of:)) ?? []), database)
    case .createView(let name, let source, let pipeline, let options):
      return (
        [
          Field("create", .string(name)), Field("viewOn", .string(source)),
          Field("pipeline", .array(pipeline)),
        ] + (options.map(Self.fields(of:)) ?? []),
        database
      )
    case .drop(let name):
      return ([Field("drop", .string(name))], database)
    case .renameCollection(let name, let target):
      return (
        [
          Field("renameCollection", .string("\(database).\(name)")),
          Field("to", .string("\(database).\(target)")), Field("dropTarget", .bool(false)),
        ],
        "admin"
      )
    case .collMod(let name, let options):
      return ([Field("collMod", .string(name))] + Self.fields(of: options), database)
    }
  }

  /// The drivers' index name: `<field>_<kind>` per key, joined by `_` (`a_1_b_-1`, `a_text`,
  /// `$**_1`, `loc_2dsphere`). A whole double is written as an integer.
  private static func indexName(_ keys: MongoValue) -> String {
    fields(of: keys).map { "\($0.key)_\(kindText($0.value))" }.joined(separator: "_")
  }

  private static func kindText(_ value: MongoValue) -> String {
    switch value {
    case .int32(let number): String(number)
    case .int64(let number): String(number)
    case .double(let number): Int(exactly: number).map(String.init) ?? String(number)
    case .string(let text): text
    default: MongoCommand.value(value)
    }
  }

  private static func fields(of value: MongoValue) -> [Field] {
    guard case .document(let fields) = value else { return [] }
    return fields
  }

  private static func databaseCall(_ method: String, _ arguments: [MongoValue]) -> String {
    "db.\(method)(\(arguments.map(MongoCommand.value).joined(separator: ", ")))"
  }
}
